// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "../../contracts/interfaces/IIdentityRegistry.sol";

/// @dev Keeps downstream Phase 1 tests focused on their own contract behavior.
contract MockIdentityRegistry is IIdentityRegistry {
    uint256 public constant ROLE_ASSET_OWNER = 1 << 0;
    uint256 public constant ROLE_VERIFIER = 1 << 3;

    function hasBusinessRole(address, uint256) external pure returns (bool) {
        return true;
    }
}
