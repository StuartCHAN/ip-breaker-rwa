// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOfferingEscrow {
    function offeringManager() external view returns (address);

    function offeringId() external view returns (bytes32);

    function settlementToken() external view returns (address);

    function issuerTreasury() external view returns (address);

    function feeRecipient() external view returns (address);

    function protocolFeeBps() external view returns (uint16);

    function totalContributed() external view returns (uint256);

    function recordContribution(
        bytes32 subscriptionId,
        address payer,
        address destination,
        uint256 usdcAmount,
        uint256 allocationAmount,
        bytes32 paymentReference,
        uint64 sequence
    ) external;
}
