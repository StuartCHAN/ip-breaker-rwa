// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAllocationEscrow
/// @notice Minimal token-custody interface used when an offering is opened.
interface IAllocationEscrow {
    function offeringManager() external view returns (address);

    function offeringId() external view returns (bytes32);

    function revenueToken() external view returns (address);

    function finalSupply() external view returns (uint256);

    function depositConfirmed() external view returns (bool);

    function confirmTokenDeposit() external;
}
