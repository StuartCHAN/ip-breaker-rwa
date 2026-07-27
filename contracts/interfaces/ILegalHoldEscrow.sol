// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ILegalHoldEscrow
/// @notice Offering-scoped registry for isolated remediation custody positions.
interface ILegalHoldEscrow {
    enum PositionStatus {
        None,
        Held,
        Released
    }

    struct LegalHoldPosition {
        bytes32 offeringId;
        bytes32 subscriptionId;
        address beneficialOwner;
        address position;
        uint256 amount;
        uint64 sequence;
        PositionStatus status;
    }

    function offeringManager() external view returns (address);

    function offeringId() external view returns (bytes32);

    function allocationEscrow() external view returns (address);

    function revenueToken() external view returns (address);

    function createPosition(bytes32 subscriptionId, address beneficialOwner, uint256 amount, uint64 sequence)
        external
        returns (address position);

    function releasePosition(bytes32 subscriptionId) external;

    function positionOf(bytes32 subscriptionId) external view returns (address);

    function isHeldPosition(bytes32 subscriptionId, address position, address beneficialOwner, uint256 amount)
        external
        view
        returns (bool);

    function getPosition(bytes32 subscriptionId) external view returns (LegalHoldPosition memory);
}
