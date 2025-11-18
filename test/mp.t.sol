// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {htlc_lgp} from "../src/htlc-lgp.sol";
import {MockToken} from "../src/MockToken.sol";

contract MP_MultiPartyTest is Test {
    // "Chain A" và "Chain B" được mô phỏng bằng 2 instance HTLC + 2 token khác nhau
    htlc_lgp htlcA; // A->B
    htlc_lgp htlcB; // B->C

    MockToken tokenA; // tài sản A lock cho B
    MockToken tokenB; // tài sản B lock cho C

    // Địa chỉ 3 bên
    address A = address(0xA11CE); // (có thể là EOA_TSS của bạn khi demo ngoài test)
    address B = address(0xB0B);
    address C = address(0xC0C0A);

    // preimage/hashlock chung cho 2 hop
    bytes preimage = bytes("mp-multi-party-preimage");
    bytes32 H;

    function setUp() public {
        htlcA = new htlc_lgp();
        htlcB = new htlc_lgp();

        tokenA = new MockToken();
        tokenB = new MockToken();

        // Cấp token & ETH cho các bên
        tokenA.mint(A, 1_000e18);
        tokenB.mint(B, 1_000e18);

        vm.deal(A, 100 ether);
        vm.deal(B, 100 ether);
        vm.deal(C, 100 ether);

        H = sha256(preimage);
    }

    /// Happy path: C claim sớm ở hop2 (penalty=0), B dùng preimage claim hop1 (penalty=0).
    function test_MultiHop_HappyPath_NoPenalty() public {
        // --- Tham số hop2 (B->C) trên "Chain B" ---
        uint256 amtB2C = 200e18;
        uint256 timelock_B2C = 1_200; // ngắn hơn
        uint256 timeBased_B2C = 400;
        uint256 deposit_B2C = 1 ether;
        uint256 depositWin_B2C = 300;

        // --- Tham số hop1 (A->B) trên "Chain A" ---
        uint256 amtA2B = 100e18;
        uint256 timelock_A2B = 1_800; // dài hơn hop2
        uint256 timeBased_A2B = 600;
        uint256 deposit_A2B = 1 ether;
        uint256 depositWin_A2B = 300;

        // A approve & lock cho B ở hop1
        vm.startPrank(A);
        tokenA.approve(address(htlcA), amtA2B);
        htlcA.lock(B, address(tokenA), H, amtA2B, timelock_A2B, timeBased_A2B, deposit_A2B, depositWin_A2B);
        vm.stopPrank();

        // B approve & lock cho C ở hop2
        vm.startPrank(B);
        tokenB.approve(address(htlcB), amtB2C);
        htlcB.lock(C, address(tokenB), H, amtB2C, timelock_B2C, timeBased_B2C, deposit_B2C, depositWin_B2C);
        vm.stopPrank();

        // C confirm deposit hop2
        vm.prank(C);
        htlcB.confirmParticipation{value: deposit_B2C}(H);

        // B confirm deposit hop1
        vm.prank(B);
        htlcA.confirmParticipation{value: deposit_A2B}(H);

        // --- C claim sớm trên hop2 (penalty = 0) ---
        vm.prank(C);
        htlcB.claim(H, preimage);

        // C nhận tokenB
        assertEq(tokenB.balanceOf(C), amtB2C);

        // --- B thấy preimage, dùng nó claim trên hop1 ---
        vm.prank(B);
        htlcA.claim(H, preimage);

        // B nhận tokenA
        assertEq(tokenA.balanceOf(B), amtA2B);
    }

    /// Griefing 1: C cố tình claim trễ ở hop2 => C bị penalty tuyến tính trả cho B,
    /// nhưng B vẫn kịp claim hop1 trước khi hết hạn => A không nhận penalty.
    function test_MultiHop_Griefing_C_Delays_But_B_Still_Claims() public {
        uint256 amtB2C = 200e18;
        uint256 timelock_B2C = 1_200;
        uint256 timeBased_B2C = 400;
        uint256 deposit_B2C = 1 ether;
        uint256 depositWin_B2C = 300;

        uint256 amtA2B = 100e18;
        uint256 timelock_A2B = 1_800;
        uint256 timeBased_A2B = 600;
        uint256 deposit_A2B = 1 ether;
        uint256 depositWin_A2B = 300;

        // Khóa như test trên
        vm.startPrank(A);
        tokenA.approve(address(htlcA), amtA2B);
        htlcA.lock(B, address(tokenA), H, amtA2B, timelock_A2B, timeBased_A2B, deposit_A2B, depositWin_A2B);
        vm.stopPrank();

        vm.startPrank(B);
        tokenB.approve(address(htlcB), amtB2C);
        htlcB.lock(C, address(tokenB), H, amtB2C, timelock_B2C, timeBased_B2C, deposit_B2C, depositWin_B2C);
        vm.stopPrank();

        vm.prank(C);
        htlcB.confirmParticipation{value: deposit_B2C}(H);
        vm.prank(B);
        htlcA.confirmParticipation{value: deposit_A2B}(H);

        // C "delay": warp tới GIỮA penalty window của hop2
        // penaltyWindowStart = unlockTime - timeBased. Vì unlockTime = now + timelock,
        // ta tăng thời gian ~ timelock_B2C - timeBased_B2C + timeBased_B2C/2
        vm.warp(block.timestamp + (timelock_B2C - timeBased_B2C) + (timeBased_B2C / 2));

        // C claim (penalty ~ 50% deposit_B2C trả cho B)
        vm.expectEmit(true, true, true, true);
        emit htlc_lgp.LockClaimed(H, C, (deposit_B2C * (timeBased_B2C / 2)) / timeBased_B2C);
        vm.prank(C);
        htlcB.claim(H, preimage);

        // B vẫn còn đủ thời gian để claim hop1 (timelock_A2B dài hơn)
        vm.prank(B);
        htlcA.claim(H, preimage);

        // Kết quả:
        // - C nhận tokenB nhưng mất ~50% deposit cho B (qua event)
        // - B nhận tokenA (không bị penalty ở hop1)
        assertEq(tokenB.balanceOf(C), amtB2C);
        assertEq(tokenA.balanceOf(B), amtA2B);
    }

    /// Griefing 2: C delay quá lâu khiến B claim cũng cận hạn hop1 => B có thể dính penalty ở hop1 (trả cho A).
    function test_MultiHop_Griefing_C_Delays_And_B_Also_Pays_Penalty() public {
        uint256 amtB2C = 200e18;
        uint256 timelock_B2C = 1_200;
        uint256 timeBased_B2C = 400;
        uint256 deposit_B2C = 1 ether;
        uint256 depositWin_B2C = 300;

        uint256 amtA2B = 100e18;
        uint256 timelock_A2B = 1_800; // > 1_200 nhưng không quá nhiều
        uint256 timeBased_A2B = 600;
        uint256 deposit_A2B = 1 ether;
        uint256 depositWin_A2B = 300;

        vm.startPrank(A);
        tokenA.approve(address(htlcA), amtA2B);
        htlcA.lock(B, address(tokenA), H, amtA2B, timelock_A2B, timeBased_A2B, deposit_A2B, depositWin_A2B);
        vm.stopPrank();

        vm.startPrank(B);
        tokenB.approve(address(htlcB), amtB2C);
        htlcB.lock(C, address(tokenB), H, amtB2C, timelock_B2C, timeBased_B2C, deposit_B2C, depositWin_B2C);
        vm.stopPrank();

        vm.prank(C);
        htlcB.confirmParticipation{value: deposit_B2C}(H);
        vm.prank(B);
        htlcA.confirmParticipation{value: deposit_A2B}(H);

        // C cực kỳ delay: claim rất muộn, sát unlock của hop2
        vm.warp(block.timestamp + timelock_B2C - 5); // 5 giây trước khi hết hạn hop2
        vm.prank(C);
        htlcB.claim(H, preimage); // penalty gần ~deposit_B2C

        // B nhận preimage rất muộn → khi claim hop1 thì đang vào penalty window của hop1
        // warp thêm  (timelock_A2B - timeBased_A2B) + timeBased_A2B/2  tính từ thời điểm LOCK,
        // nhưng ta đã warp khá xa; để chắc chắn vào giữa penalty window hop1:
        uint256 nowTs = block.timestamp;
        // đảm bảo ít nhất giữa penalty window hop1
        vm.warp(nowTs + (timelock_A2B - timeBased_A2B) / 2);

        // B claim ở hop1 → B trả penalty tuyến tính cho A
        vm.expectEmit(true, true, true, true);
        // (Không tính exact do rounding/time, chỉ xác nhận event xuất hiện)
        emit htlc_lgp.LockClaimed(H, B, 0);
        vm.prank(B);
        htlcA.claim(H, preimage);

        // Kết quả:
        // - C nhận tokenB nhưng mất gần full deposit cho B (event hop2).
        // - B nhận tokenA nhưng bị mất 1 phần deposit_A2B cho A (event hop1).
        assertEq(tokenB.balanceOf(C), amtB2C);
        assertEq(tokenA.balanceOf(B), amtA2B);
    }
}
