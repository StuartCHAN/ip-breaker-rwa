// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @title EvidenceRegistry
/// @notice Stores evidence records for IP Asset NFTs.
/// @dev This contract forms the evidence passport layer for IP Breaker RWA.
///      Evidence is anchored by hash and URI; legal documents or reports stay offchain.
contract EvidenceRegistry is Ownable {
    struct Evidence {
        uint256 assetId;
        string evidenceType;
        bytes32 evidenceHash;
        string evidenceURI;
        bytes32 attestationUID;
        address submittedBy;
        uint256 submittedAt;
    }

    error ZeroAssetRegistry();
    error ZeroReviewer();
    error AssetDoesNotExist(uint256 assetId);
    error EvidenceDoesNotExist(uint256 evidenceId);
    error EmptyEvidenceType();
    error ZeroEvidenceHash();
    error EmptyEvidenceURI();
    error NotAssetOwner(uint256 assetId, address caller);
    error NotReviewer(address caller);

    event ReviewerUpdated(address indexed reviewer, bool approved);

    event EvidenceAdded(
        uint256 indexed assetId,
        uint256 indexed evidenceId,
        address indexed submittedBy,
        string evidenceType,
        bytes32 evidenceHash,
        string evidenceURI,
        bytes32 attestationUID
    );

    IIPAssetRegistry public immutable assetRegistry;

    uint256 private _nextEvidenceId = 1;

    mapping(uint256 evidenceId => Evidence evidence) public evidences;
    mapping(uint256 assetId => uint256[] evidenceIds) private _assetEvidenceIds;
    mapping(address reviewer => bool approved) public reviewers;

    bytes32 private constant FTO_REPORT_TYPEHASH = keccak256("FTO_REPORT");
    bytes32 private constant RISK_REPORT_TYPEHASH = keccak256("RISK_REPORT");

    constructor(address assetRegistry_) Ownable(msg.sender) {
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        assetRegistry = IIPAssetRegistry(assetRegistry_);
    }

    /// @notice Adds or removes an authorized reviewer.
    /// @dev Reviewers can add FTO_REPORT and RISK_REPORT evidence.
    function setReviewer(address reviewer, bool approved) external onlyOwner {
        if (reviewer == address(0)) revert ZeroReviewer();

        reviewers[reviewer] = approved;

        emit ReviewerUpdated(reviewer, approved);
    }

    /// @notice Adds evidence to an existing IP asset.
    /// @dev Ordinary evidence must be submitted by the asset owner.
    ///      FTO_REPORT and RISK_REPORT must be submitted by an authorized reviewer.
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

        if (_isReviewerEvidence(evidenceType)) {
            if (!reviewers[msg.sender]) revert NotReviewer(msg.sender);
        } else {
            address assetOwner = assetRegistry.ownerOf(assetId);
            if (msg.sender != assetOwner) revert NotAssetOwner(assetId, msg.sender);
        }

        evidenceId = _nextEvidenceId++;

        evidences[evidenceId] = Evidence({
            assetId: assetId,
            evidenceType: evidenceType,
            evidenceHash: evidenceHash,
            evidenceURI: evidenceURI,
            attestationUID: attestationUID,
            submittedBy: msg.sender,
            submittedAt: block.timestamp
        });

        _assetEvidenceIds[assetId].push(evidenceId);

        emit EvidenceAdded(
            assetId,
            evidenceId,
            msg.sender,
            evidenceType,
            evidenceHash,
            evidenceURI,
            attestationUID
        );
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

    /// @notice Returns whether an evidence type must be submitted by a reviewer.
    function isReviewerEvidence(string calldata evidenceType) external pure returns (bool) {
        return _isReviewerEvidence(evidenceType);
    }

    function _isReviewerEvidence(string memory evidenceType) internal pure returns (bool) {
        bytes32 evidenceTypeHash = keccak256(bytes(evidenceType));

        return evidenceTypeHash == FTO_REPORT_TYPEHASH
            || evidenceTypeHash == RISK_REPORT_TYPEHASH;
    }
} 
