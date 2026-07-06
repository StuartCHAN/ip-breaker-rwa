// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface used by downstream registries.
/// @dev EvidenceRegistry and LicenseEscrow will rely on this interface
///      instead of importing the full IPAssetRegistry implementation.
interface IIPAssetRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);

    function exists(uint256 assetId) external view returns (bool);
}
