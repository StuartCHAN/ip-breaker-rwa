// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @title EvidenceRegistry
/// @notice Stores evidence records for IP Asset NFTs.
/// @dev This contract forms the evidence passport layer for IP Breaker RWA.
///      Evidence is anchored by hash and URI; legal documents or reports stay offchain.
contract EvidenceRegistry {
    enum EvidenceStatus {
        Submitted,
        Verified,
        Rejected,
        Revoked
    }

    struct Evidence {
        uint256 assetId;
        string evidenceType;
        bytes32 evidenceHash;
        string evidenceURI;
        bytes32 attestationUID;
        address submittedBy;
        uint256 submittedAt;
        EvidenceStatus status;
        address reviewedBy;
        uint256 reviewedAt;
    }

    error ZeroAssetRegistry();
    error ZeroIdentityRegistry();
    error AssetDoesNotExist(uint256 assetId);
    error EvidenceDoesNotExist(uint256 evidenceId);
    error EmptyEvidenceType();
    error ZeroEvidenceHash();
    error EmptyEvidenceURI();
    error NotAssetOwner(uint256 assetId, address caller);
    error NotVerifiedAssetOwner(address caller);
    error NotVerifiedVerifier(address caller);
    error InvalidEvidenceStatus(uint256 evidenceId, EvidenceStatus current, EvidenceStatus required);

    event EvidenceAdded(
        uint256 indexed assetId,
        uint256 indexed evidenceId,
        address indexed submittedBy,
        string evidenceType,
        bytes32 evidenceHash,
        string evidenceURI,
        bytes32 attestationUID
    );

    event EvidenceStatusChanged(
        uint256 indexed evidenceId,
        EvidenceStatus indexed previousStatus,
        EvidenceStatus indexed newStatus,
        address reviewedBy
    );

    IIPAssetRegistry public immutable assetRegistry;
    IIdentityRegistry public immutable identityRegistry;

    uint256 private _nextEvidenceId = 1;

    mapping(uint256 evidenceId => Evidence evidence) public evidences;
    mapping(uint256 assetId => uint256[] evidenceIds) private _assetEvidenceIds;

    constructor(address assetRegistry_, address identityRegistry_) {
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        if (identityRegistry_ == address(0)) revert ZeroIdentityRegistry();
        assetRegistry = IIPAssetRegistry(assetRegistry_);
        identityRegistry = IIdentityRegistry(identityRegistry_);
    }

    /// @notice Adds evidence to an existing IP asset.
    /// @dev The caller must own the asset and hold an active ASSET_OWNER identity role.
    function addEvidence(
        uint256 assetId,
        string calldata evidenceType,
        bytes32 evidenceHash,
        string calldata evidenceURI,
        bytes32 attestationUID
    ) external returns (uint256 evidenceId) {
        if (bytes(evidenceType).length == 0) revert EmptyEvidenceType();
        if (evidenceHash == bytes32(0)) revert ZeroEvidenceHash();
        if (bytes(evidenceURI).length == 0) revert EmptyEvidenceURI();
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);

        uint256 assetOwnerRole = identityRegistry.ROLE_ASSET_OWNER();
        if (!identityRegistry.hasBusinessRole(msg.sender, assetOwnerRole)) {
            revert NotVerifiedAssetOwner(msg.sender);
        }

        address assetOwner = assetRegistry.ownerOf(assetId);
        if (msg.sender != assetOwner) revert NotAssetOwner(assetId, msg.sender);

        evidenceId = _nextEvidenceId++;

        evidences[evidenceId] = Evidence({
            assetId: assetId,
            evidenceType: evidenceType,
            evidenceHash: evidenceHash,
            evidenceURI: evidenceURI,
            attestationUID: attestationUID,
            submittedBy: msg.sender,
            submittedAt: block.timestamp,
            status: EvidenceStatus.Submitted,
            reviewedBy: address(0),
            reviewedAt: 0
        });

        _assetEvidenceIds[assetId].push(evidenceId);

        emit EvidenceAdded(assetId, evidenceId, msg.sender, evidenceType, evidenceHash, evidenceURI, attestationUID);
    }

    /// @notice Approves submitted evidence.
    function verifyEvidence(uint256 evidenceId) external {
        _reviewEvidence(evidenceId, EvidenceStatus.Submitted, EvidenceStatus.Verified);
    }

    /// @notice Rejects submitted evidence.
    function rejectEvidence(uint256 evidenceId) external {
        _reviewEvidence(evidenceId, EvidenceStatus.Submitted, EvidenceStatus.Rejected);
    }

    /// @notice Revokes evidence that was previously verified.
    function revokeEvidence(uint256 evidenceId) external {
        _reviewEvidence(evidenceId, EvidenceStatus.Verified, EvidenceStatus.Revoked);
    }

    /// @notice Returns one evidence record by ID.
    function getEvidence(uint256 evidenceId) external view returns (Evidence memory evidence) {
        if (evidenceId == 0 || evidenceId >= _nextEvidenceId) {
            revert EvidenceDoesNotExist(evidenceId);
        }

        return evidences[evidenceId];
    }

    /// @notice Returns all evidence IDs attached to a given asset.
    function getEvidenceIds(uint256 assetId) external view returns (uint256[] memory evidenceIds) {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        return _assetEvidenceIds[assetId];
    }

    /// @notice Returns the next evidence ID that will be assigned.
    function nextEvidenceId() external view returns (uint256) {
        return _nextEvidenceId;
    }

    function _reviewEvidence(uint256 evidenceId, EvidenceStatus requiredStatus, EvidenceStatus newStatus) internal {
        uint256 verifierRole = identityRegistry.ROLE_VERIFIER();
        if (!identityRegistry.hasBusinessRole(msg.sender, verifierRole)) {
            revert NotVerifiedVerifier(msg.sender);
        }

        if (evidenceId == 0 || evidenceId >= _nextEvidenceId) {
            revert EvidenceDoesNotExist(evidenceId);
        }

        Evidence storage evidence = evidences[evidenceId];
        if (evidence.status != requiredStatus) {
            revert InvalidEvidenceStatus(evidenceId, evidence.status, requiredStatus);
        }

        EvidenceStatus previousStatus = evidence.status;
        evidence.status = newStatus;
        evidence.reviewedBy = msg.sender;
        evidence.reviewedAt = block.timestamp;

        emit EvidenceStatusChanged(evidenceId, previousStatus, newStatus, msg.sender);
    }
}
