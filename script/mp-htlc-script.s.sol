// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockToken} from "../src/MockToken.sol";
import {mp_htlc} from "../src/mp-htlc.sol";

contract mp_htlc_script is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tssSigner = vm.envAddress("TSS_SIGNER");

        vm.startBroadcast(pk);

        MockToken token = new MockToken();
        mp_htlc htlc = new mp_htlc(tssSigner);

        console2.log("MockToken:", address(token));
        console2.log("MP-HTLC  :", address(htlc));
        console2.log("TSS signer:", tssSigner);

        vm.stopBroadcast();
    }
}
