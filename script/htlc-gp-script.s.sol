// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {MockToken} from "../src/MockToken.sol";
import {htlc_gp} from "../src/htlc-gp.sol";

contract htlc_gp_script is Script {
    function run() external {
        // Lấy PRIVATE_KEY từ env (export bên ngoài)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockToken (MTK)
        MockToken token = new MockToken();

        // Deploy HTLC-GP
        htlc_gp htlc = new htlc_gp();

        vm.stopBroadcast();

        console2.log("MockToken (HTLC-GP) deployed at:", address(token));
        console2.log("HTLC_GP deployed at:", address(htlc));
    }
}
