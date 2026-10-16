// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRobobetToken} from "../script/DeployRobobetToken.s.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

contract DeployRobobetTokenTest is Test {
    function test_deployMintsWholeSupplyToTheScriptCaller() public {
        DeployRobobetToken deployer = new DeployRobobetToken();
        RobobetToken token = deployer.deploy();
        assertEq(token.name(), "Robobet");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        // The script contract was `msg.sender` of the constructor, so it holds the supply.
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
    }
}
