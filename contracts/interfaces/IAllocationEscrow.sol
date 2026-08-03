// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAllocationEscrow
/// @notice Minimal token-custody interface used when an offering is opened.
interface IAllocationEscrow {
    function offeringManager() external view returns (address);

    function offeringId() external view returns (bytes32);

    function revenueToken() external view returns (address);

    function finalSupply() external view returns (uint256);

    function legalHoldEscrow() external view returns (address);

    function depositConfirmed() external view returns (bool);

    function confirmTokenDeposit() external;

    function totalAllocated() external view returns (uint256);

    function totalReleased() external view returns (uint256);

    function tombstoned() external view returns (bool);

    function tombstone() external;

    function releaseAllocation(bytes32 subscriptionId) external;

    function holdAllocation(bytes32 subscriptionId) external returns (address position);

    function legalHoldTransferred() external view returns (uint256);

    function totalDelivered() external view returns (uint256);

    function registerAllocation(
        bytes32 subscriptionId,
        bytes32 investorCommitment,
        address destination,
        uint256 amount,
        uint64 sequence
    ) external;
}
