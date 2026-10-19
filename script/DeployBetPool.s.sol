// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BetPool} from "../src/BetPool.sol";

/// @notice Local deployment rehearsal. The launch service deploys BetPool's bytecode directly.
/// @dev This script neither reads keys nor broadcasts. Ownership is independent of its caller.
contract DeployBetPool {
    /// @notice Creates a fully constructed BetPool with fixed launch settings and an unset signer.
    /// @return pool The locally deployed instance.
    function run() external returns (BetPool pool) {
        return new BetPool();
    }
}
