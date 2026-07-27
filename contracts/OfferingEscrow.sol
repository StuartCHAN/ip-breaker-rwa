// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOfferingEscrow} from "./interfaces/IOfferingEscrow.sol";

/// @title OfferingEscrow
/// @notice Exact USDC custody and immutable contribution ledger for one offering.
contract OfferingEscrow is IOfferingEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Contribution {
        bytes32 subscriptionId;
        address payer;
        address destination;
        uint256 usdcAmount;
        uint256 allocationAmount;
        bytes32 paymentReference;
        uint64 sequence;
        uint64 recordedAt;
        bytes32 contributionHash;
        bool refunded;
    }

    uint8 public constant REQUIRED_SETTLEMENT_DECIMALS = 6;
    uint16 public constant MAX_BPS = 10_000;

    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable settlementToken;
    address public immutable issuerTreasury;
    address public immutable feeRecipient;
    uint16 public immutable protocolFeeBps;

    uint256 public totalContributed;
    uint256 public totalRefunded;
    bool public refundable;
    bool public proceedsEnabled;
    uint256 public issuerProceeds;
    uint256 public protocolFee;
    mapping(bytes32 subscriptionId => Contribution contribution) private _contributions;
    mapping(bytes32 paymentReference => bool used) public paymentReferenceUsed;

    error ZeroOfferingManager();
    error ZeroOfferingId();
    error InvalidSettlementToken(address token);
    error InvalidSettlementDecimals(uint8 expected, uint8 actual);
    error ZeroIssuerTreasury();
    error ZeroFeeRecipient();
    error InvalidProtocolFee(uint16 feeBps);
    error UnauthorizedOfferingManager(address caller);
    error ZeroSubscriptionId();
    error ZeroPayer();
    error ZeroDestination();
    error ZeroUSDCAmount();
    error ZeroAllocationAmount();
    error ZeroPaymentReference();
    error ContributionAlreadyExists(bytes32 subscriptionId);
    error PaymentReferenceAlreadyUsed(bytes32 paymentReference);
    error IncorrectSettlementDelta(uint256 expected, uint256 actual);
    error RefundsAlreadyEnabled();
    error ProceedsAlreadyEnabled();
    error RefundPathActive();
    error ProceedsConservationViolation(uint256 issuerAmount, uint256 feeAmount, uint256 contributed);
    error RefundsNotEnabled();
    error UnknownContribution(bytes32 subscriptionId);
    error UnauthorizedRefundClaimant(address caller, address payer);
    error RefundAlreadyClaimed(bytes32 subscriptionId);
    error EscrowInsolvent(uint256 required, uint256 available);

    event ContributionRecorded(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed payer,
        address destination,
        uint256 usdcAmount,
        uint256 allocationAmount,
        bytes32 paymentReference,
        uint64 sequence,
        bytes32 contributionHash
    );
    event RefundsEnabled(bytes32 indexed offeringId);
    event ProceedsEnabled(bytes32 indexed offeringId, uint256 issuerProceeds, uint256 protocolFee);
    event RefundClaimed(
        bytes32 indexed offeringId, bytes32 indexed subscriptionId, address indexed payer, uint256 amount
    );

    modifier onlyOfferingManager() {
        if (msg.sender != offeringManager) {
            revert UnauthorizedOfferingManager(msg.sender);
        }
        _;
    }

    constructor(
        address offeringManager_,
        bytes32 offeringId_,
        address settlementToken_,
        address issuerTreasury_,
        address feeRecipient_,
        uint16 protocolFeeBps_
    ) {
        if (offeringManager_ == address(0)) revert ZeroOfferingManager();
        if (offeringId_ == bytes32(0)) revert ZeroOfferingId();
        if (settlementToken_.code.length == 0) {
            revert InvalidSettlementToken(settlementToken_);
        }
        uint8 decimals = IERC20Metadata(settlementToken_).decimals();
        if (decimals != REQUIRED_SETTLEMENT_DECIMALS) {
            revert InvalidSettlementDecimals(REQUIRED_SETTLEMENT_DECIMALS, decimals);
        }
        if (issuerTreasury_ == address(0)) revert ZeroIssuerTreasury();
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        if (protocolFeeBps_ > MAX_BPS) revert InvalidProtocolFee(protocolFeeBps_);

        offeringManager = offeringManager_;
        offeringId = offeringId_;
        settlementToken = settlementToken_;
        issuerTreasury = issuerTreasury_;
        feeRecipient = feeRecipient_;
        protocolFeeBps = protocolFeeBps_;
    }

    function recordContribution(
        bytes32 subscriptionId,
        address payer,
        address destination,
        uint256 usdcAmount,
        uint256 allocationAmount,
        bytes32 paymentReference,
        uint64 sequence
    ) external onlyOfferingManager nonReentrant {
        if (refundable) revert RefundsAlreadyEnabled();
        if (proceedsEnabled) revert ProceedsAlreadyEnabled();
        if (subscriptionId == bytes32(0)) revert ZeroSubscriptionId();
        if (payer == address(0)) revert ZeroPayer();
        if (destination == address(0)) revert ZeroDestination();
        if (usdcAmount == 0) revert ZeroUSDCAmount();
        if (allocationAmount == 0) revert ZeroAllocationAmount();
        if (paymentReference == bytes32(0)) revert ZeroPaymentReference();
        if (_contributions[subscriptionId].subscriptionId != bytes32(0)) {
            revert ContributionAlreadyExists(subscriptionId);
        }
        if (paymentReferenceUsed[paymentReference]) {
            revert PaymentReferenceAlreadyUsed(paymentReference);
        }

        IERC20 token = IERC20(settlementToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(payer, address(this), usdcAmount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 actualDelta = balanceAfter - balanceBefore;
        if (actualDelta != usdcAmount) {
            revert IncorrectSettlementDelta(usdcAmount, actualDelta);
        }

        bytes32 recordHash = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                offeringId,
                subscriptionId,
                payer,
                destination,
                usdcAmount,
                allocationAmount,
                paymentReference,
                sequence
            )
        );
        _contributions[subscriptionId] = Contribution({
            subscriptionId: subscriptionId,
            payer: payer,
            destination: destination,
            usdcAmount: usdcAmount,
            allocationAmount: allocationAmount,
            paymentReference: paymentReference,
            sequence: sequence,
            recordedAt: uint64(block.timestamp),
            contributionHash: recordHash,
            refunded: false
        });
        paymentReferenceUsed[paymentReference] = true;
        totalContributed += usdcAmount;

        emit ContributionRecorded(
            offeringId,
            subscriptionId,
            payer,
            destination,
            usdcAmount,
            allocationAmount,
            paymentReference,
            sequence,
            recordHash
        );
    }

    function markRefundable() external onlyOfferingManager {
        if (refundable) revert RefundsAlreadyEnabled();
        if (proceedsEnabled) revert ProceedsAlreadyEnabled();
        refundable = true;
        emit RefundsEnabled(offeringId);
    }

    /// @notice Freezes successful-offering proceeds entitlements without transferring settlement funds.
    function enableProceeds() external onlyOfferingManager {
        if (proceedsEnabled) revert ProceedsAlreadyEnabled();
        if (refundable || totalRefunded != 0) revert RefundPathActive();

        uint256 feeAmount = Math.mulDiv(totalContributed, protocolFeeBps, MAX_BPS);
        uint256 issuerAmount = totalContributed - feeAmount;
        if (issuerAmount + feeAmount != totalContributed) {
            revert ProceedsConservationViolation(issuerAmount, feeAmount, totalContributed);
        }

        uint256 available = IERC20(settlementToken).balanceOf(address(this));
        if (available < totalContributed) revert EscrowInsolvent(totalContributed, available);

        issuerProceeds = issuerAmount;
        protocolFee = feeAmount;
        proceedsEnabled = true;

        emit ProceedsEnabled(offeringId, issuerAmount, feeAmount);
    }

    function claimRefund(bytes32 subscriptionId) external nonReentrant {
        if (!refundable) revert RefundsNotEnabled();
        Contribution storage contribution = _contributions[subscriptionId];
        if (contribution.subscriptionId == bytes32(0)) {
            revert UnknownContribution(subscriptionId);
        }
        if (msg.sender != contribution.payer) {
            revert UnauthorizedRefundClaimant(msg.sender, contribution.payer);
        }
        if (contribution.refunded) revert RefundAlreadyClaimed(subscriptionId);

        IERC20 token = IERC20(settlementToken);
        uint256 available = token.balanceOf(address(this));
        if (available < contribution.usdcAmount) {
            revert EscrowInsolvent(contribution.usdcAmount, available);
        }

        contribution.refunded = true;
        totalRefunded += contribution.usdcAmount;
        token.safeTransfer(contribution.payer, contribution.usdcAmount);

        emit RefundClaimed(offeringId, subscriptionId, contribution.payer, contribution.usdcAmount);
    }

    function getContribution(bytes32 subscriptionId) external view returns (Contribution memory) {
        return _contributions[subscriptionId];
    }
}
