// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MockToken.sol";
import "../src/htlc.sol";

contract htlc_script is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        MockToken token = new MockToken();
        htlc h = new htlc();

        console2.log("MockToken", address(token));
        console2.log("HTLC_TRAD", address(h));

        vm.stopBroadcast();
    }
}
