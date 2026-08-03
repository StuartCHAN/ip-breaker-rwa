// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LicenseRevenueToken} from "./LicenseRevenueToken.sol";
import {IAllocationEscrow} from "./interfaces/IAllocationEscrow.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IInvestorEligibility} from "./interfaces/IInvestorEligibility.sol";
import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";
import {ILegalHoldEscrow} from "./interfaces/ILegalHoldEscrow.sol";
import {IOfferingEscrow} from "./interfaces/IOfferingEscrow.sol";
import {IRevenueProgramRegistry} from "./interfaces/IRevenueProgramRegistry.sol";
import {IRevenueVault} from "./interfaces/IRevenueVault.sol";
import {OfferingFinalizationModule} from "./modules/OfferingFinalizationModule.sol";
import {OfferingValidationModule} from "./modules/OfferingValidationModule.sol";

/// @notice Issuer/SPV verification boundary; deliberately separate from investor and asset-owner roles.
interface IIssuerEligibility {
    function isEligibleIssuer(address issuer) external view returns (bool);
}

/// @title OfferingManager
/// @notice Non-custodial core state machine for immutable primary-offering configuration.
/// @dev Phase 3.2-2B atomically prepares and escrows the frozen token supply when opening.
contract OfferingManager is AccessControl, ReentrancyGuard {
    enum OfferingStatus {
        None,
        Draft,
        Open,
        Successful,
        Failed,
        Finalized
    }

    enum SubscriptionStatus {
        None,
        Committed,
        Valid,
        Invalid,
        Remediation
    }

    enum OfferingFailureReason {
        None,
        FundingOutcome,
        DraftExpired
    }

    struct OfferingConfig {
        uint256 assetId;
        address issuer;
        address issuerTreasury;
        address revenueToken;
        address revenueVault;
        address allocationEscrow;
        address offeringEscrow;
        address investorEligibility;
        address recoveryManager;
        address settlementToken;
        uint256 finalSupply;
        uint256 allocationLot;
        uint256 pricePerWholeTokenUSDC;
        uint16 protocolFeeBps;
        address feeRecipient;
        uint64 opensAt;
        uint64 closesAt;
        bytes32 termsHash;
        bytes32 disclosureHash;
    }

    struct Offering {
        OfferingStatus status;
        OfferingFailureReason failureReason;
        address creator;
        address assetOwner;
        uint64 createdAt;
        uint64 openedAt;
        uint256 targetUSDC;
        uint256 soldSupply;
        uint256 committedUSDC;
        uint256 validSoldSupply;
        uint256 validCommittedUSDC;
        uint64 nextSequence;
        uint64 reconciledCount;
        uint64 deliveredCount;
        OfferingConfig config;
    }

    struct Subscription {
        bytes32 subscriptionId;
        bytes32 offeringId;
        bytes32 paymentReference;
        address payer;
        address destination;
        uint256 requestedAllocation;
        uint256 filledAllocation;
        uint256 usdcAmount;
        uint64 sequence;
        uint64 subscribedAt;
        uint64 reconciledAt;
        uint64 deliveredAt;
        uint64 legalHoldReleasedAt;
        uint8 invalidReason;
        bool deliveryProcessed;
        address legalHoldPosition;
        SubscriptionStatus status;
    }

    bytes32 public constant OFFERING_OPERATOR_ROLE = keccak256("OFFERING_OPERATOR");
    uint8 public constant REQUIRED_USDC_DECIMALS = 6;
    uint256 public constant TOKEN_UNIT = 1e18;
    uint16 public constant MAX_BPS = 10_000;
    uint8 public constant INVALID_PAYER_IDENTITY = 1 << 0;
    uint8 public constant INVALID_PAYER_ELIGIBILITY = 1 << 1;
    uint8 public constant INVALID_DESTINATION_ELIGIBILITY = 1 << 2;

    IIdentityRegistry public immutable identityRegistry;
    IIPAssetRegistry public immutable assetRegistry;
    IIssuerEligibility public immutable issuerEligibility;
    IRevenueProgramRegistry public immutable revenueProgramRegistry;
    OfferingValidationModule private immutable _validationModule;
    OfferingFinalizationModule private immutable _finalizationModule;

    mapping(bytes32 offeringId => Offering offering) private _offerings;
    mapping(address creator => uint256 nonce) public creatorNonce;
    mapping(bytes32 subscriptionId => Subscription subscription) private _subscriptions;
    mapping(bytes32 offeringId => mapping(uint64 sequence => bytes32 subscriptionId)) public subscriptionIdBySequence;
    mapping(bytes32 offeringId => mapping(bytes32 paymentReference => bool used)) public paymentReferenceUsed;

    error ZeroAdmin();
    error ZeroIdentityRegistry();
    error ZeroAssetRegistry();
    error ZeroIssuerEligibility();
    error ZeroRevenueProgramRegistry();
    error AssetDoesNotExist(uint256 assetId);
    error UnauthorizedAssetOwner(address caller, address currentOwner);
    error AssetOwnerIdentityInvalid(address account);
    error InvalidIssuer(address issuer);
    error ZeroConfigurationAddress();
    error InvalidConfigurationContract(address account);
    error InvalidFinalSupply();
    error InvalidTokenPrice();
    error InvalidProtocolFee(uint16 feeBps);
    error InvalidOfferingWindow(uint64 opensAt, uint64 closesAt);
    error ZeroTermsHash();
    error ZeroDisclosureHash();
    error UnsupportedSettlementDecimals(uint8 actual, uint8 required);
    error InexactTargetUSDC(uint256 finalSupply, uint256 pricePerWholeTokenUSDC);
    error OfferingAlreadyExists(bytes32 offeringId);
    error OfferingNotFound(bytes32 offeringId);
    error InvalidOfferingStatus(bytes32 offeringId, OfferingStatus current, OfferingStatus required);
    error OfferingNotOpenYet(uint256 currentTime, uint64 opensAt);
    error OfferingWindowClosed(uint256 currentTime, uint64 closesAt);
    error DraftNotExpired(uint256 currentTime, uint64 closesAt);
    error AssetOwnershipChanged(address expectedOwner, address currentOwner);
    error TokenRegistryMismatch(address expected, address actual);
    error TokenAssetMismatch(uint256 expected, uint256 actual);
    error TokenFinalSupplyMismatch(uint256 expected, uint256 actual);
    error TokenEligibilityMismatch(address expected, address actual);
    error TokenVaultMismatch(address expected, address actual);
    error TokenRecoveryManagerMismatch(address expected, address actual);
    error OfferingManagerNotTokenController(address revenueToken);
    error TokenNotReadyForMinting(uint8 lifecycle);
    error InitialTokenSupplyNotZero(uint256 actualSupply);
    error InitialEscrowBalanceNotZero(uint256 actualBalance);
    error TokenSupplyInvariantViolation(uint256 expected, uint256 actual);
    error EscrowCustodyInvariantViolation(uint256 expected, uint256 actual);
    error EscrowCustodyNotConfirmed(bytes32 offeringId);
    error EscrowManagerMismatch(address expected, address actual);
    error EscrowOfferingMismatch(bytes32 expected, bytes32 actual);
    error EscrowTokenMismatch(address expected, address actual);
    error EscrowFinalSupplyMismatch(uint256 expected, uint256 actual);
    error InvalidAllocationLot(uint256 allocationLot, uint256 finalSupply);
    error ZeroFeeRecipient();
    error OfferingEscrowManagerMismatch(address expected, address actual);
    error OfferingEscrowOfferingMismatch(bytes32 expected, bytes32 actual);
    error OfferingEscrowSettlementMismatch(address expected, address actual);
    error OfferingEscrowTreasuryMismatch(address expected, address actual);
    error OfferingEscrowFeeRecipientMismatch(address expected, address actual);
    error OfferingEscrowFeeMismatch(uint16 expected, uint16 actual);
    error SubscriptionWindowClosed(uint256 currentTime, uint64 closesAt);
    error InvalidSubscriberIdentity(address payer);
    error IneligibleSubscriber(address payer);
    error IneligibleDestination(address destination);
    error ZeroRequestedAllocation();
    error InvalidMinFill(uint256 minFill, uint256 requestedAllocation);
    error OfferingSoldOut(bytes32 offeringId);
    error FillBelowMinimum(uint256 filledAllocation, uint256 minFill);
    error FillNotAlignedToLot(uint256 filledAllocation, uint256 allocationLot);
    error InexactSubscriptionPrice(uint256 filledAllocation, uint256 price);
    error ZeroPaymentReference();
    error PaymentReferenceAlreadyUsed(bytes32 offeringId, bytes32 paymentReference);
    error SubscriptionAlreadyExists(bytes32 subscriptionId);
    error AllocationAccountingMismatch(uint256 expected, uint256 actual);
    error ContributionAccountingMismatch(uint256 expected, uint256 actual);
    error ReconciliationNotStarted(uint256 currentTime, uint64 closesAt);
    error InvalidReconciliationSequence(uint64 expected, uint64 actual);
    error ReconciliationSequenceOutOfBounds(uint64 sequence, uint64 subscriptionCount);
    error SubscriptionAlreadyReconciled(bytes32 subscriptionId);
    error ReconciliationIncomplete(uint64 reconciledCount, uint64 subscriptionCount);
    error NoRemediationRequired(bytes32 subscriptionId);
    error SubscriptionNotValid(bytes32 subscriptionId, SubscriptionStatus status);
    error InvalidDeliverySequence(uint64 expected, uint64 actual);
    error DeliverySequenceOutOfBounds(uint64 sequence, uint64 subscriptionCount);
    error SubscriptionDeliveryAlreadyProcessed(bytes32 subscriptionId);
    error TokenDistributionEscrowMismatch(address expected, address actual);
    error LegalHoldPositionMissing(bytes32 subscriptionId);
    error LegalHoldPositionAlreadyReleased(bytes32 subscriptionId);
    error LegalHoldReleaseEligibilityInvalid(bytes32 subscriptionId, uint8 reason);
    error RevenueProgramBindingMismatch(bytes32 offeringId);
    error RevenueProgramStateMismatch(
        bytes32 offeringId, IRevenueProgramRegistry.ProgramStatus expected, IRevenueProgramRegistry.ProgramStatus actual
    );
    error FinalizationDeliveryIncomplete(uint64 deliveredCount, uint64 subscriptionCount);
    error FinalizationDeliveredSupplyMismatch(uint256 expected, uint256 actual);
    error FinalizationDeliveryAccountingMismatch(uint256 expected, uint256 direct, uint256 legalHold);
    error FinalizationAllocationBalanceNotZero(uint256 balance);
    error FinalizationContributionMismatch(uint256 expected, uint256 actual);
    error VaultActivationControllerMismatch(address expected, address actual);
    error VaultDepositLifecycleMismatch(IRevenueVault.DepositLifecycle expected, IRevenueVault.DepositLifecycle actual);
    error FinalizationTokenLifecycleMismatch(LicenseRevenueToken.Lifecycle actual);
    error FinalizationProgramMismatch(bytes32 offeringId);
    error FinalizationProceedsMismatch(uint256 contributed, uint256 issuerAmount, uint256 feeAmount);
    error FinalizationManagerAssetBalanceNotZero(address asset, uint256 balance);

    event OfferingCreated(
        bytes32 indexed offeringId,
        uint256 indexed assetId,
        address indexed creator,
        address issuer,
        address revenueToken,
        uint256 finalSupply,
        uint256 pricePerWholeTokenUSDC,
        uint256 targetUSDC,
        bytes32 termsHash
    );
    event OfferingOpened(bytes32 indexed offeringId, address indexed operator, uint64 openedAt);
    event DraftExpired(bytes32 indexed offeringId, address indexed caller, uint64 expiredAt);
    event OfferingStatusChanged(
        bytes32 indexed offeringId, OfferingStatus indexed previousStatus, OfferingStatus indexed newStatus
    );
    event SubscriptionAccepted(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed payer,
        address destination,
        uint256 requestedAllocation,
        uint256 filledAllocation,
        uint256 usdcAmount,
        bytes32 paymentReference,
        uint64 sequence
    );
    event SubscriptionReconciled(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        uint64 indexed sequence,
        SubscriptionStatus status,
        uint8 invalidReason,
        uint256 validSoldSupply,
        uint256 validCommittedUSDC
    );
    event SubscriptionRemediationFlagged(bytes32 indexed offeringId, bytes32 indexed subscriptionId, uint8 reason);
    event OfferingSuccessful(bytes32 indexed offeringId, uint256 validSoldSupply, uint256 validCommittedUSDC);
    event OfferingFailed(bytes32 indexed offeringId, uint256 validSoldSupply, uint256 validCommittedUSDC);
    event OfferingFinalized(bytes32 indexed offeringId, address indexed caller);
    event AllocationDelivered(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        uint64 indexed sequence,
        address destination,
        uint256 amount
    );
    event AllocationDeliveryRemediation(
        bytes32 indexed offeringId, bytes32 indexed subscriptionId, uint64 indexed sequence, uint8 reason
    );
    event AllocationDeliveredToLegalHold(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        uint64 indexed sequence,
        address position,
        address beneficialOwner,
        uint256 amount,
        uint8 reason
    );
    event LegalHoldAllocationReleased(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed position,
        address beneficialOwner,
        uint256 amount
    );

    constructor(
        address admin_,
        address identityRegistry_,
        address assetRegistry_,
        address issuerEligibility_,
        address revenueProgramRegistry_
    ) {
        if (admin_ == address(0)) revert ZeroAdmin();
        if (identityRegistry_ == address(0)) revert ZeroIdentityRegistry();
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        if (issuerEligibility_ == address(0)) revert ZeroIssuerEligibility();
        if (revenueProgramRegistry_ == address(0)) revert ZeroRevenueProgramRegistry();
        _requireContract(revenueProgramRegistry_);

        identityRegistry = IIdentityRegistry(identityRegistry_);
        assetRegistry = IIPAssetRegistry(assetRegistry_);
        issuerEligibility = IIssuerEligibility(issuerEligibility_);
        revenueProgramRegistry = IRevenueProgramRegistry(revenueProgramRegistry_);
        _validationModule = new OfferingValidationModule(assetRegistry_, issuerEligibility_, revenueProgramRegistry_);
        _finalizationModule = new OfferingFinalizationModule(revenueProgramRegistry_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _setRoleAdmin(OFFERING_OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /// @notice Creates an immutable Draft snapshot for a verified asset owner and issuer.
    function createOffering(OfferingConfig calldata config) external returns (bytes32 offeringId) {
        _validateCreationAuthority(config.assetId, msg.sender);
        _validationModule.validateCreationConfig(abi.encode(config));

        uint256 nonce = creatorNonce[msg.sender];
        offeringId = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                address(assetRegistry),
                config.assetId,
                msg.sender,
                config.issuer,
                nonce,
                config.termsHash
            )
        );
        if (_offerings[offeringId].status != OfferingStatus.None) revert OfferingAlreadyExists(offeringId);

        revenueProgramRegistry.reserveProgram(
            offeringId, config.assetId, config.issuer, config.revenueToken, config.revenueVault, config.settlementToken
        );
        _validationModule.validateRevenueProgramBinding(offeringId, abi.encode(config));

        uint256 targetUSDC = Math.mulDiv(config.finalSupply, config.pricePerWholeTokenUSDC, TOKEN_UNIT);
        creatorNonce[msg.sender] = nonce + 1;

        Offering storage offering = _offerings[offeringId];
        offering.status = OfferingStatus.Draft;
        offering.creator = msg.sender;
        offering.assetOwner = msg.sender;
        offering.createdAt = uint64(block.timestamp);
        offering.targetUSDC = targetUSDC;
        offering.config = config;

        emit OfferingCreated(
            offeringId,
            config.assetId,
            msg.sender,
            config.issuer,
            config.revenueToken,
            config.finalSupply,
            config.pricePerWholeTokenUSDC,
            targetUSDC,
            config.termsHash
        );
        emit OfferingStatusChanged(offeringId, OfferingStatus.None, OfferingStatus.Draft);
    }

    /// @notice Opens a Draft after atomically minting its frozen supply into allocation custody.
    function openOffering(bytes32 offeringId) external onlyRole(OFFERING_OPERATOR_ROLE) {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Draft);

        OfferingConfig storage config = offering.config;
        if (block.timestamp < config.opensAt) revert OfferingNotOpenYet(block.timestamp, config.opensAt);
        if (block.timestamp >= config.closesAt) revert OfferingWindowClosed(block.timestamp, config.closesAt);

        if (!assetRegistry.exists(config.assetId)) revert AssetDoesNotExist(config.assetId);
        address currentOwner = assetRegistry.ownerOf(config.assetId);
        if (currentOwner != offering.assetOwner) {
            revert AssetOwnershipChanged(offering.assetOwner, currentOwner);
        }
        uint256 ownerRole = identityRegistry.ROLE_ASSET_OWNER();
        if (!identityRegistry.hasBusinessRole(currentOwner, ownerRole)) {
            revert AssetOwnerIdentityInvalid(currentOwner);
        }
        _validationModule.validateOpenBundle(offeringId, abi.encode(config));

        _prepareTokenCustody(offeringId, config);

        offering.status = OfferingStatus.Open;
        offering.openedAt = uint64(block.timestamp);

        emit OfferingOpened(offeringId, msg.sender, offering.openedAt);
        emit OfferingStatusChanged(offeringId, OfferingStatus.Draft, OfferingStatus.Open);
    }

    /// @notice Permissionlessly fails a Draft that was never opened before its final funding boundary.
    function expireDraft(bytes32 offeringId) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Draft);
        if (block.timestamp < offering.config.closesAt) {
            revert DraftNotExpired(block.timestamp, offering.config.closesAt);
        }

        offering.status = OfferingStatus.Failed;
        offering.failureReason = OfferingFailureReason.DraftExpired;
        _failRevenueProgram(offeringId, offering.config.assetId);

        uint64 expiredAt = uint64(block.timestamp);
        emit DraftExpired(offeringId, msg.sender, expiredAt);
        emit OfferingStatusChanged(offeringId, OfferingStatus.Draft, OfferingStatus.Failed);
    }

    function getOffering(bytes32 offeringId) external view returns (Offering memory) {
        Offering memory offering = _offerings[offeringId];
        if (offering.status == OfferingStatus.None) revert OfferingNotFound(offeringId);
        return offering;
    }

    function getOfferingStatus(bytes32 offeringId) external view returns (OfferingStatus) {
        OfferingStatus status = _offerings[offeringId].status;
        if (status == OfferingStatus.None) revert OfferingNotFound(offeringId);
        return status;
    }

    /// @notice Atomically records an FCFS allocation and pulls its exact USDC cost.
    function subscribe(
        bytes32 offeringId,
        uint256 requestedAllocation,
        uint256 minFill,
        address destination,
        bytes32 paymentReference
    ) external nonReentrant returns (bytes32 subscriptionId, uint256 filledAllocation, uint256 requiredUSDC) {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Open);

        OfferingConfig storage config = offering.config;
        if (block.timestamp >= config.closesAt) {
            revert SubscriptionWindowClosed(block.timestamp, config.closesAt);
        }
        if (requestedAllocation == 0) revert ZeroRequestedAllocation();
        if (minFill > requestedAllocation) {
            revert InvalidMinFill(minFill, requestedAllocation);
        }
        if (destination == address(0)) revert IneligibleDestination(destination);
        if (paymentReference == bytes32(0)) revert ZeroPaymentReference();
        if (paymentReferenceUsed[offeringId][paymentReference]) {
            revert PaymentReferenceAlreadyUsed(offeringId, paymentReference);
        }

        uint256 licenseeRole = identityRegistry.ROLE_LICENSEE();
        if (!identityRegistry.hasBusinessRole(msg.sender, licenseeRole)) {
            revert InvalidSubscriberIdentity(msg.sender);
        }
        IInvestorEligibility eligibility = IInvestorEligibility(config.investorEligibility);
        if (!eligibility.canHold(msg.sender, config.assetId)) {
            revert IneligibleSubscriber(msg.sender);
        }
        if (!eligibility.canHold(destination, config.assetId)) {
            revert IneligibleDestination(destination);
        }

        uint256 remainingSupply = config.finalSupply - offering.soldSupply;
        if (remainingSupply == 0) revert OfferingSoldOut(offeringId);
        filledAllocation = requestedAllocation < remainingSupply ? requestedAllocation : remainingSupply;
        if (filledAllocation < minFill) {
            revert FillBelowMinimum(filledAllocation, minFill);
        }
        if (filledAllocation % config.allocationLot != 0) {
            revert FillNotAlignedToLot(filledAllocation, config.allocationLot);
        }
        if (mulmod(filledAllocation, config.pricePerWholeTokenUSDC, TOKEN_UNIT) != 0) {
            revert InexactSubscriptionPrice(filledAllocation, config.pricePerWholeTokenUSDC);
        }
        requiredUSDC = Math.mulDiv(filledAllocation, config.pricePerWholeTokenUSDC, TOKEN_UNIT);

        uint64 sequence = offering.nextSequence;
        subscriptionId = _deriveSubscriptionId(offeringId, msg.sender, destination, paymentReference, sequence);
        if (_subscriptions[subscriptionId].subscriptionId != bytes32(0)) {
            revert SubscriptionAlreadyExists(subscriptionId);
        }

        Subscription memory acceptedSubscription;
        acceptedSubscription.subscriptionId = subscriptionId;
        acceptedSubscription.offeringId = offeringId;
        acceptedSubscription.paymentReference = paymentReference;
        acceptedSubscription.payer = msg.sender;
        acceptedSubscription.destination = destination;
        acceptedSubscription.requestedAllocation = requestedAllocation;
        acceptedSubscription.filledAllocation = filledAllocation;
        acceptedSubscription.usdcAmount = requiredUSDC;
        acceptedSubscription.sequence = sequence;
        acceptedSubscription.subscribedAt = uint64(block.timestamp);
        acceptedSubscription.status = SubscriptionStatus.Committed;
        _recordSubscriptionEscrows(config, acceptedSubscription);
        _commitSubscription(offeringId, offering, acceptedSubscription);
    }

    function getSubscription(bytes32 subscriptionId) external view returns (Subscription memory) {
        return _subscriptions[subscriptionId];
    }

    /// @notice Revalidates exactly the next committed subscription after Funding closes.
    function reconcileSubscription(bytes32 offeringId, uint64 sequence) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Open);
        if (block.timestamp < offering.config.closesAt) {
            revert ReconciliationNotStarted(block.timestamp, offering.config.closesAt);
        }
        if (sequence != offering.reconciledCount) {
            revert InvalidReconciliationSequence(offering.reconciledCount, sequence);
        }
        if (sequence >= offering.nextSequence) {
            revert ReconciliationSequenceOutOfBounds(sequence, offering.nextSequence);
        }

        bytes32 subscriptionId = subscriptionIdBySequence[offeringId][sequence];
        Subscription storage subscription = _subscriptions[subscriptionId];
        if (subscription.status != SubscriptionStatus.Committed) {
            revert SubscriptionAlreadyReconciled(subscriptionId);
        }

        uint8 invalidReason = _currentInvalidReason(offering.config, subscription);
        if (invalidReason == 0) {
            subscription.status = SubscriptionStatus.Valid;
            offering.validSoldSupply += subscription.filledAllocation;
            offering.validCommittedUSDC += subscription.usdcAmount;
        } else {
            subscription.status = SubscriptionStatus.Invalid;
            subscription.invalidReason = invalidReason;
        }
        subscription.reconciledAt = uint64(block.timestamp);
        offering.reconciledCount = sequence + 1;

        emit SubscriptionReconciled(
            offeringId,
            subscriptionId,
            sequence,
            subscription.status,
            invalidReason,
            offering.validSoldSupply,
            offering.validCommittedUSDC
        );

        if (offering.reconciledCount == offering.nextSequence) {
            _resolveOfferingOutcome(offeringId, offering);
        }
    }

    /// @notice Resolves an empty or fully reconciled offering after Funding closes.
    function resolveOfferingOutcome(bytes32 offeringId) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Open);
        if (block.timestamp < offering.config.closesAt) {
            revert ReconciliationNotStarted(block.timestamp, offering.config.closesAt);
        }
        if (offering.reconciledCount != offering.nextSequence) {
            revert ReconciliationIncomplete(offering.reconciledCount, offering.nextSequence);
        }
        _resolveOfferingOutcome(offeringId, offering);
    }

    /// @notice Flags post-success compliance deterioration without changing frozen economics.
    function flagSubscriptionRemediation(bytes32 subscriptionId) external nonReentrant {
        Subscription storage subscription = _subscriptions[subscriptionId];
        if (subscription.status != SubscriptionStatus.Valid) {
            revert SubscriptionNotValid(subscriptionId, subscription.status);
        }
        Offering storage offering = _getOffering(subscription.offeringId);
        _requireStatus(subscription.offeringId, offering.status, OfferingStatus.Successful);

        uint8 reason = _currentInvalidReason(offering.config, subscription);
        if (reason == 0) revert NoRemediationRequired(subscriptionId);

        subscription.status = SubscriptionStatus.Remediation;
        subscription.invalidReason = reason;
        emit SubscriptionRemediationFlagged(subscription.offeringId, subscriptionId, reason);
    }

    /// @notice Permissionlessly processes the next frozen primary allocation after a Successful outcome.
    function deliverAllocation(bytes32 offeringId, uint64 sequence) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Successful);
        if (sequence != offering.deliveredCount) {
            revert InvalidDeliverySequence(offering.deliveredCount, sequence);
        }
        if (sequence >= offering.nextSequence) {
            revert DeliverySequenceOutOfBounds(sequence, offering.nextSequence);
        }

        bytes32 subscriptionId = subscriptionIdBySequence[offeringId][sequence];
        Subscription storage subscription = _subscriptions[subscriptionId];
        if (subscription.deliveryProcessed) {
            revert SubscriptionDeliveryAlreadyProcessed(subscriptionId);
        }

        subscription.deliveryProcessed = true;
        subscription.deliveredAt = uint64(block.timestamp);
        offering.deliveredCount = sequence + 1;

        if (subscription.status == SubscriptionStatus.Remediation) {
            _holdRemediationAllocation(offering, subscription);
            emit AllocationDeliveryRemediation(offeringId, subscriptionId, sequence, subscription.invalidReason);
            return;
        }
        if (subscription.status != SubscriptionStatus.Valid) {
            revert SubscriptionNotValid(subscriptionId, subscription.status);
        }

        OfferingConfig storage config = offering.config;
        if (!IInvestorEligibility(config.investorEligibility).canHold(subscription.destination, config.assetId)) {
            subscription.status = SubscriptionStatus.Remediation;
            subscription.invalidReason |= INVALID_DESTINATION_ELIGIBILITY;
            _holdRemediationAllocation(offering, subscription);
            emit SubscriptionRemediationFlagged(offeringId, subscriptionId, subscription.invalidReason);
            emit AllocationDeliveryRemediation(offeringId, subscriptionId, sequence, subscription.invalidReason);
            return;
        }

        IAllocationEscrow(config.allocationEscrow).releaseAllocation(subscriptionId);
        emit AllocationDelivered(
            offeringId, subscriptionId, sequence, subscription.destination, subscription.filledAllocation
        );
    }

    /// @notice Atomically activates every successful-offering economic dependency after complete delivery.
    function finalizeOffering(bytes32 offeringId) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        _requireStatus(offeringId, offering.status, OfferingStatus.Successful);

        OfferingConfig storage config = offering.config;
        bytes memory encodedConfig = abi.encode(config);
        _finalizationModule.validatePreconditions(
            offering.deliveredCount, offering.nextSequence, offering.validCommittedUSDC, encodedConfig
        );

        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);
        IRevenueVault revenueVault = IRevenueVault(config.revenueVault);
        IOfferingEscrow offeringEscrow = IOfferingEscrow(config.offeringEscrow);
        revenueToken.activate();
        revenueProgramRegistry.activateProgram(offeringId);
        revenueVault.enableDeposits();
        offeringEscrow.enableProceeds();

        _finalizationModule.validatePostconditions(offeringId, encodedConfig);

        offering.status = OfferingStatus.Finalized;
        emit OfferingFinalized(offeringId, msg.sender);
        emit OfferingStatusChanged(offeringId, OfferingStatus.Successful, OfferingStatus.Finalized);
    }

    /// @notice Releases one isolated remediation position only to its original, currently eligible beneficiary.
    function releaseLegalHold(bytes32 offeringId, uint64 sequence) external nonReentrant {
        Offering storage offering = _getOffering(offeringId);
        if (offering.status != OfferingStatus.Successful && offering.status != OfferingStatus.Finalized) {
            revert InvalidOfferingStatus(offeringId, offering.status, OfferingStatus.Successful);
        }
        if (sequence >= offering.nextSequence) {
            revert DeliverySequenceOutOfBounds(sequence, offering.nextSequence);
        }

        bytes32 subscriptionId = subscriptionIdBySequence[offeringId][sequence];
        Subscription storage subscription = _subscriptions[subscriptionId];
        address position = subscription.legalHoldPosition;
        if (position == address(0)) revert LegalHoldPositionMissing(subscriptionId);
        if (subscription.legalHoldReleasedAt != 0) {
            revert LegalHoldPositionAlreadyReleased(subscriptionId);
        }

        uint8 reason = _currentInvalidReason(offering.config, subscription);
        if (reason != 0) revert LegalHoldReleaseEligibilityInvalid(subscriptionId, reason);

        subscription.legalHoldReleasedAt = uint64(block.timestamp);
        address holdEscrow = IAllocationEscrow(offering.config.allocationEscrow).legalHoldEscrow();
        ILegalHoldEscrow(holdEscrow).releasePosition(subscriptionId);

        emit LegalHoldAllocationReleased(
            offeringId, subscriptionId, position, subscription.destination, subscription.filledAllocation
        );
    }

    function _holdRemediationAllocation(Offering storage offering, Subscription storage subscription) private {
        address position =
            IAllocationEscrow(offering.config.allocationEscrow).holdAllocation(subscription.subscriptionId);
        subscription.legalHoldPosition = position;
        emit AllocationDeliveredToLegalHold(
            subscription.offeringId,
            subscription.subscriptionId,
            subscription.sequence,
            position,
            subscription.destination,
            subscription.filledAllocation,
            subscription.invalidReason
        );
    }

    function _currentInvalidReason(OfferingConfig storage config, Subscription storage subscription)
        private
        view
        returns (uint8 reason)
    {
        uint256 licenseeRole = identityRegistry.ROLE_LICENSEE();
        if (!identityRegistry.hasBusinessRole(subscription.payer, licenseeRole)) {
            reason |= INVALID_PAYER_IDENTITY;
        }

        IInvestorEligibility eligibility = IInvestorEligibility(config.investorEligibility);
        if (!eligibility.canHold(subscription.payer, config.assetId)) {
            reason |= INVALID_PAYER_ELIGIBILITY;
        }
        if (!eligibility.canHold(subscription.destination, config.assetId)) {
            reason |= INVALID_DESTINATION_ELIGIBILITY;
        }
    }

    function _resolveOfferingOutcome(bytes32 offeringId, Offering storage offering) private {
        if (offering.validSoldSupply == offering.config.finalSupply) {
            offering.status = OfferingStatus.Successful;
            emit OfferingStatusChanged(offeringId, OfferingStatus.Open, OfferingStatus.Successful);
            emit OfferingSuccessful(offeringId, offering.validSoldSupply, offering.validCommittedUSDC);
        } else {
            offering.status = OfferingStatus.Failed;
            offering.failureReason = OfferingFailureReason.FundingOutcome;
            IOfferingEscrow(offering.config.offeringEscrow).markRefundable();
            IAllocationEscrow(offering.config.allocationEscrow).tombstone();
            _failRevenueProgram(offeringId, offering.config.assetId);
            emit OfferingStatusChanged(offeringId, OfferingStatus.Open, OfferingStatus.Failed);
            emit OfferingFailed(offeringId, offering.validSoldSupply, offering.validCommittedUSDC);
        }
    }

    function _emitSubscriptionAccepted(bytes32 offeringId, Subscription storage subscription) private {
        emit SubscriptionAccepted(
            offeringId,
            subscription.subscriptionId,
            subscription.payer,
            subscription.destination,
            subscription.requestedAllocation,
            subscription.filledAllocation,
            subscription.usdcAmount,
            subscription.paymentReference,
            subscription.sequence
        );
    }

    function _deriveSubscriptionId(
        bytes32 offeringId,
        address payer,
        address destination,
        bytes32 paymentReference,
        uint64 sequence
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(block.chainid, address(this), offeringId, payer, destination, paymentReference, sequence)
        );
    }

    function _recordSubscriptionEscrows(OfferingConfig storage config, Subscription memory subscription) private {
        IOfferingEscrow(config.offeringEscrow)
            .recordContribution(
                subscription.subscriptionId,
                subscription.payer,
                subscription.destination,
                subscription.usdcAmount,
                subscription.filledAllocation,
                subscription.paymentReference,
                subscription.sequence
            );
        IAllocationEscrow(config.allocationEscrow)
            .registerAllocation(
                subscription.subscriptionId,
                keccak256(abi.encode(subscription.payer, subscription.destination, subscription.paymentReference)),
                subscription.destination,
                subscription.filledAllocation,
                subscription.sequence
            );
    }

    function _commitSubscription(bytes32 offeringId, Offering storage offering, Subscription memory subscription)
        private
    {
        _subscriptions[subscription.subscriptionId] = subscription;
        subscriptionIdBySequence[offeringId][subscription.sequence] = subscription.subscriptionId;
        paymentReferenceUsed[offeringId][subscription.paymentReference] = true;
        offering.soldSupply += subscription.filledAllocation;
        offering.committedUSDC += subscription.usdcAmount;
        offering.nextSequence = subscription.sequence + 1;

        uint256 escrowAllocated = IAllocationEscrow(offering.config.allocationEscrow).totalAllocated();
        if (escrowAllocated != offering.soldSupply) {
            revert AllocationAccountingMismatch(offering.soldSupply, escrowAllocated);
        }
        uint256 escrowContributed = IOfferingEscrow(offering.config.offeringEscrow).totalContributed();
        if (escrowContributed != offering.committedUSDC) {
            revert ContributionAccountingMismatch(offering.committedUSDC, escrowContributed);
        }

        _emitSubscriptionAccepted(offeringId, _subscriptions[subscription.subscriptionId]);
    }

    function _prepareTokenCustody(bytes32 offeringId, OfferingConfig storage config) private {
        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);

        // Bind only the dependencies already frozen in the Draft. If any later
        // preparation step fails, these bindings roll back with the transaction.
        if (address(revenueToken.revenueVault()) == address(0)) {
            revenueToken.bindRevenueVault(config.revenueVault);
        }
        if (address(revenueToken.recoveryManager()) == address(0)) {
            revenueToken.bindRecoveryManager(config.recoveryManager);
        }
        if (revenueToken.primaryDistributionEscrow() == address(0)) {
            revenueToken.bindPrimaryDistributionEscrow(config.allocationEscrow);
        }

        bytes32 minterRole = revenueToken.MINTER_ROLE();
        revenueToken.grantRole(minterRole, address(this));
        revenueToken.beginMinting();
        revenueToken.mint(config.allocationEscrow, config.finalSupply);
        revenueToken.revokeRole(minterRole, address(this));

        IAllocationEscrow allocationEscrow = IAllocationEscrow(config.allocationEscrow);
        allocationEscrow.confirmTokenDeposit();

        uint256 actualSupply = revenueToken.totalSupply();
        if (actualSupply != config.finalSupply) {
            revert TokenSupplyInvariantViolation(config.finalSupply, actualSupply);
        }

        uint256 escrowBalance = revenueToken.balanceOf(config.allocationEscrow);
        if (escrowBalance != config.finalSupply) {
            revert EscrowCustodyInvariantViolation(config.finalSupply, escrowBalance);
        }

        if (!allocationEscrow.depositConfirmed()) {
            revert EscrowCustodyNotConfirmed(offeringId);
        }
    }

    function _validateCreationAuthority(uint256 assetId, address caller) private view {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        address currentOwner = assetRegistry.ownerOf(assetId);
        if (caller != currentOwner) revert UnauthorizedAssetOwner(caller, currentOwner);

        uint256 ownerRole = identityRegistry.ROLE_ASSET_OWNER();
        if (!identityRegistry.hasBusinessRole(caller, ownerRole)) revert AssetOwnerIdentityInvalid(caller);
    }

    function _failRevenueProgram(bytes32 offeringId, uint256 assetId) private {
        revenueProgramRegistry.failProgram(offeringId);
        IRevenueProgramRegistry.RevenueProgram memory program = revenueProgramRegistry.getProgram(offeringId);
        if (program.status != IRevenueProgramRegistry.ProgramStatus.Failed) {
            revert RevenueProgramStateMismatch(offeringId, IRevenueProgramRegistry.ProgramStatus.Failed, program.status);
        }
        if (revenueProgramRegistry.liveOfferingByAsset(assetId) != bytes32(0)) {
            revert RevenueProgramBindingMismatch(offeringId);
        }
    }

    function _requireContract(address account) private view {
        if (account.code.length == 0) revert InvalidConfigurationContract(account);
    }

    function _getOffering(bytes32 offeringId) private view returns (Offering storage offering) {
        offering = _offerings[offeringId];
        if (offering.status == OfferingStatus.None) revert OfferingNotFound(offeringId);
    }

    function _requireStatus(bytes32 offeringId, OfferingStatus current, OfferingStatus required) private pure {
        if (current != required) revert InvalidOfferingStatus(offeringId, current, required);
    }
}
