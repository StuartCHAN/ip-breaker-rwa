// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal identity interface used by protocol modules.
interface IIdentityRegistry {
    function ROLE_ASSET_OWNER() external view returns (uint256);

    function ROLE_LICENSEE() external view returns (uint256);

    function ROLE_VERIFIER() external view returns (uint256);

    function hasBusinessRole(address account, uint256 roleMask) external view returns (bool);
}
