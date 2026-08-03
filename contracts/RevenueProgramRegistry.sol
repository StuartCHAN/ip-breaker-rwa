// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IRevenueProgramRegistry} from "./interfaces/IRevenueProgramRegistry.sol";

/// @title RevenueProgramRegistry
/// @notice Canonical one-program-per-offering registry and per-asset live-program uniqueness boundary.
contract RevenueProgramRegistry is AccessControl, IRevenueProgramRegistry {
    bytes32 public constant PROGRAM_MANAGER_ROLE = keccak256("PROGRAM_MANAGER");

    mapping(bytes32 offeringId => RevenueProgram program) private _programs;
    mapping(uint256 assetId => bytes32 offeringId) public liveOfferingByAsset;
    mapping(uint256 assetId => bytes32 offeringId) public activeOfferingByAsset;

    error ZeroAdmin();
    error ZeroOfferingId();
    error InvalidAssetId();
    error ZeroProgramAddress();
    error InvalidProgramContract(address account);
    error ProgramAlreadyExists(bytes32 offeringId);
    error ProgramNotFound(bytes32 offeringId);
    error AssetHasLiveReservation(uint256 assetId, bytes32 offeringId);
    error AssetHasActiveProgram(uint256 assetId, bytes32 offeringId);
    error InvalidProgramStatus(bytes32 offeringId, ProgramStatus current, ProgramStatus required);
    error AssetReservationMismatch(uint256 assetId, bytes32 expectedOfferingId, bytes32 actualOfferingId);

    event RevenueProgramReserved(
        bytes32 indexed offeringId,
        uint256 indexed assetId,
        address indexed issuer,
        address revenueToken,
        address revenueVault,
        address settlementToken,
        uint64 reservedAt
    );
    event RevenueProgramActivated(bytes32 indexed offeringId, uint256 indexed assetId, uint64 activatedAt);
    event RevenueProgramFailed(bytes32 indexed offeringId, uint256 indexed assetId, uint64 failedAt);

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _setRoleAdmin(PROGRAM_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    function reserveProgram(
        bytes32 offeringId,
        uint256 assetId,
        address issuer,
        address revenueToken,
        address revenueVault,
        address settlementToken
    ) external onlyRole(PROGRAM_MANAGER_ROLE) {
        if (offeringId == bytes32(0)) revert ZeroOfferingId();
        if (assetId == 0) revert InvalidAssetId();
        if (
            issuer == address(0) || revenueToken == address(0) || revenueVault == address(0)
                || settlementToken == address(0)
        ) {
            revert ZeroProgramAddress();
        }
        _requireContract(revenueToken);
        _requireContract(revenueVault);
        _requireContract(settlementToken);
        if (_programs[offeringId].status != ProgramStatus.None) revert ProgramAlreadyExists(offeringId);

        bytes32 activeOfferingId = activeOfferingByAsset[assetId];
        if (activeOfferingId != bytes32(0)) revert AssetHasActiveProgram(assetId, activeOfferingId);
        bytes32 liveOfferingId = liveOfferingByAsset[assetId];
        if (liveOfferingId != bytes32(0)) revert AssetHasLiveReservation(assetId, liveOfferingId);

        uint64 reservedAt = uint64(block.timestamp);
        _programs[offeringId] = RevenueProgram({
            assetId: assetId,
            offeringId: offeringId,
            issuer: issuer,
            revenueToken: revenueToken,
            revenueVault: revenueVault,
            settlementToken: settlementToken,
            status: ProgramStatus.Reserved,
            reservedAt: reservedAt,
            activatedAt: 0,
            failedAt: 0
        });
        liveOfferingByAsset[assetId] = offeringId;

        emit RevenueProgramReserved(
            offeringId, assetId, issuer, revenueToken, revenueVault, settlementToken, reservedAt
        );
    }

    function activateProgram(bytes32 offeringId) external onlyRole(PROGRAM_MANAGER_ROLE) {
        RevenueProgram storage program = _requireProgram(offeringId);
        _requireStatus(offeringId, program.status, ProgramStatus.Reserved);
        _requireLiveReservation(program.assetId, offeringId);

        bytes32 activeOfferingId = activeOfferingByAsset[program.assetId];
        if (activeOfferingId != bytes32(0)) {
            revert AssetHasActiveProgram(program.assetId, activeOfferingId);
        }

        program.status = ProgramStatus.Active;
        program.activatedAt = uint64(block.timestamp);
        delete liveOfferingByAsset[program.assetId];
        activeOfferingByAsset[program.assetId] = offeringId;

        emit RevenueProgramActivated(offeringId, program.assetId, program.activatedAt);
    }

    function failProgram(bytes32 offeringId) external onlyRole(PROGRAM_MANAGER_ROLE) {
        RevenueProgram storage program = _requireProgram(offeringId);
        _requireStatus(offeringId, program.status, ProgramStatus.Reserved);
        _requireLiveReservation(program.assetId, offeringId);

        program.status = ProgramStatus.Failed;
        program.failedAt = uint64(block.timestamp);
        delete liveOfferingByAsset[program.assetId];

        emit RevenueProgramFailed(offeringId, program.assetId, program.failedAt);
    }

    function getProgram(bytes32 offeringId) external view returns (RevenueProgram memory) {
        RevenueProgram memory program = _programs[offeringId];
        if (program.status == ProgramStatus.None) revert ProgramNotFound(offeringId);
        return program;
    }

    function _requireProgram(bytes32 offeringId) private view returns (RevenueProgram storage program) {
        program = _programs[offeringId];
        if (program.status == ProgramStatus.None) revert ProgramNotFound(offeringId);
    }

    function _requireStatus(bytes32 offeringId, ProgramStatus current, ProgramStatus required) private pure {
        if (current != required) revert InvalidProgramStatus(offeringId, current, required);
    }

    function _requireLiveReservation(uint256 assetId, bytes32 offeringId) private view {
        bytes32 actualOfferingId = liveOfferingByAsset[assetId];
        if (actualOfferingId != offeringId) {
            revert AssetReservationMismatch(assetId, offeringId, actualOfferingId);
        }
    }

    function _requireContract(address account) private view {
        if (account.code.length == 0) revert InvalidProgramContract(account);
    }
}
