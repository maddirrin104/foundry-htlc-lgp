// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {MockToken} from "../src/MockToken.sol"; // chỉnh path cho đúng
import {htlc_gpz} from "../src/htlc-gpz.sol";

contract htlc_gpz_script is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        MockToken token = new MockToken();
        htlc_gpz htlc = new htlc_gpz();

        vm.stopBroadcast();

        console2.log("MockToken (GPz) deployed at:", address(token));
        console2.log("HTLC_GPZ deployed at:", address(htlc));
    }
}
