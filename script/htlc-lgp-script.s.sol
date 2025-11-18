// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockToken} from "../src/MockToken.sol";
import {htlc_lgp} from "../src/htlc-lgp.sol";

contract htlc_lgp_script is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tssSigner = vm.envAddress("TSS_SIGNER"); // địa chỉ MPC/TSS

        vm.startBroadcast(pk);

        MockToken token = new MockToken();
        htlc_lgp htlc = new htlc_lgp(tssSigner);

        console2.log("MockToken:", address(token));
        console2.log("HTLC-LGP :", address(htlc));
        console2.log("TSS signer:", tssSigner);

        vm.stopBroadcast();
    }
}

