// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockToken} from "../src/MockToken.sol";
import {htlc_lgp} from "../src/htlc-lgp.sol";

contract htlc_lgp_test is Test {
    MockToken token;
    htlc_lgp htlc;

    address deployer = address(this);
    address sender = address(0xA11CE);
    address receiver = address(0xB0B);

    function setUp() public {
        token = new MockToken();
        htlc = new htlc_lgp(deployer);

        // Mint token cho sender
        token.mint(sender, 1_000e18);

        // Fund ETH cho sender & receiver để trả gas / nộp deposit
        vm.deal(sender, 100 ether);
        vm.deal(receiver, 100 ether);
    }

    function _approveSender(uint256 amt) internal {
        vm.prank(sender);
        token.approve(address(htlc), amt);
    }

    function testA_ConfirmDeposit_ClaimInPenaltyWindow() public {
        uint256 amount = 100e18;
        uint256 timelock = 1800; // 30'
        uint256 timeBased = 600; // penalty window 10'
        uint256 depositRequired = 1 ether;
        uint256 depositWindow = 600; // 10'

        bytes memory preimage = bytes("super-secret-preimage");
        bytes32 lockId = sha256(preimage); // dùng đúng sha256 như contract

        _approveSender(amount);

        // sender lock
        vm.prank(sender);
        htlc.lock(receiver, address(token), lockId, amount, timelock, timeBased, depositRequired, depositWindow);

        // receiver confirm deposit
        vm.prank(receiver);
        htlc.confirmParticipation{value: depositRequired}(lockId);

        // warp tới giữa penalty window
        // t = timelock - timeBased + timeBased/2
        vm.warp(block.timestamp + (timelock - timeBased) + (timeBased / 2));

        // expect event LockClaimed với penalty > 0 và < depositRequired
        // Tính penalty kỳ vọng
        uint256 elapsed = timeBased / 2;
        uint256 expectedPenalty = (depositRequired * elapsed) / timeBased;
        assertGt(expectedPenalty, 0);
        assertLt(expectedPenalty, depositRequired);

        vm.expectEmit(true, true, true, true);
        emit htlc_lgp.LockClaimed(lockId, receiver, expectedPenalty);

        vm.prank(receiver);
        htlc.claim(lockId, preimage);

        // token về receiver
        assertEq(token.balanceOf(receiver), amount);

        // tiền deposit đã chi trả hết (0 giữ trong contract)
        // (không có getter, nhưng claim đã hoàn tất và event đã xác nhận penalty)
        // Có thể kiểm tra số dư ETH contract == 0 trong case này (tất cả đã chuyển ra):
        assertEq(address(htlc).balance, 0);
    }

    function testB_NoDeposit_UntilWindowEnds_SenderRefundImmediate() public {
        uint256 amount = 50e18;
        uint256 timelock = 1800;
        uint256 timeBased = 600;
        uint256 depositRequired = 1 ether;
        uint256 depositWindow = 300;

        bytes memory preimage = bytes("no-deposit-preimage");
        bytes32 lockId = sha256(preimage);

        _approveSender(amount);

        // sender lock
        vm.prank(sender);
        htlc.lock(receiver, address(token), lockId, amount, timelock, timeBased, depositRequired, depositWindow);

        // Không confirm deposit. Chờ qua depositWindow
        vm.warp(block.timestamp + depositWindow + 1);

        vm.expectEmit(true, true, true, true);
        emit htlc_lgp.LockRefunded(lockId, sender, 0);

        // sender refund ngay
        vm.prank(sender);
        htlc.refund(lockId);

        assertEq(token.balanceOf(sender), 1_000e18); // 1000 - 50 + 50
    }

    function testC_DepositConfirmed_ButTimeout_SenderRefundAll() public {
        uint256 amount = 70e18;
        uint256 timelock = 1200;
        uint256 timeBased = 300;
        uint256 depositRequired = 0.5 ether;
        uint256 depositWindow = 300;

        bytes memory preimage = bytes("confirm-but-timeout");
        bytes32 lockId = sha256(preimage);

        _approveSender(amount);

        // lock
        vm.prank(sender);
        htlc.lock(receiver, address(token), lockId, amount, timelock, timeBased, depositRequired, depositWindow);

        // receiver confirm
        vm.prank(receiver);
        htlc.confirmParticipation{value: depositRequired}(lockId);

        // qua unlockTime
        vm.warp(block.timestamp + timelock + 1);

        vm.expectEmit(true, true, true, true);
        // penalty = toàn bộ depositPaid
        emit htlc_lgp.LockRefunded(lockId, sender, depositRequired);

        // sender refund, lấy token + full deposit
        uint256 senderEthBefore = sender.balance;
        vm.prank(sender);
        htlc.refund(lockId);

        assertEq(token.balanceOf(sender), 1_000e18); // 1000 - 70 + 70
        // không assert chặt chẽ ETH do gas; event đã xác nhận penalty
        assertEq(address(htlc).balance, 0);
        assertGt(sender.balance, senderEthBefore); // về nguyên tắc có +deposit (trừ gas)
    }
}
