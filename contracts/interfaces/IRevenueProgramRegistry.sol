// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRevenueProgramRegistry {
    enum ProgramStatus {
        None,
        Reserved,
        Active,
        Failed
    }

    struct RevenueProgram {
        uint256 assetId;
        bytes32 offeringId;
        address issuer;
        address revenueToken;
        address revenueVault;
        address settlementToken;
        ProgramStatus status;
        uint64 reservedAt;
        uint64 activatedAt;
        uint64 failedAt;
    }

    function reserveProgram(
        bytes32 offeringId,
        uint256 assetId,
        address issuer,
        address revenueToken,
        address revenueVault,
        address settlementToken
    ) external;

    function activateProgram(bytes32 offeringId) external;

    function failProgram(bytes32 offeringId) external;

    function getProgram(bytes32 offeringId) external view returns (RevenueProgram memory);

    function liveOfferingByAsset(uint256 assetId) external view returns (bytes32);

    function activeOfferingByAsset(uint256 assetId) external view returns (bytes32);
}
