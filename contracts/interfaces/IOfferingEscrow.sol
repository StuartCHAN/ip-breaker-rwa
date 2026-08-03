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

    function totalRefunded() external view returns (uint256);

    function refundable() external view returns (bool);

    function proceedsEnabled() external view returns (bool);

    function issuerProceeds() external view returns (uint256);

    function protocolFee() external view returns (uint256);

    function issuerClaimed() external view returns (bool);

    function feeClaimed() external view returns (bool);

    function totalProceedsClaimed() external view returns (uint256);

    function markRefundable() external;

    function enableProceeds() external;

    function claimIssuerProceeds() external returns (uint256 amount);

    function claimProtocolFee() external returns (uint256 amount);

    function claimRefund(bytes32 subscriptionId) external;

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
