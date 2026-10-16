// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @title Deploy script for RobobetToken
/// @notice For local or manual deployments only. The IMD launch deploys the token from its built
///         bytecode through the factory; this script is not part of that path. The constructor
///         takes no arguments, so there is no configuration to read from the environment.
/// @dev `deploy()` is the function the tests exercise directly; `run()` only wraps it in a broadcast.
contract DeployRobobetToken is Script {
    /// @notice Deploys a new RobobetToken. Whoever calls this (the broadcaster under `run()`)
    ///         receives the whole supply.
    function deploy() public returns (RobobetToken token) {
        token = new RobobetToken();
    }

    function run() external returns (RobobetToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
