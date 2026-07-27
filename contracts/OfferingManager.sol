// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LicenseRevenueToken} from "./LicenseRevenueToken.sol";
import {IAllocationEscrow} from "./interfaces/IAllocationEscrow.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @notice Issuer/SPV verification boundary; deliberately separate from investor and asset-owner roles.
interface IIssuerEligibility {
    function isEligibleIssuer(address issuer) external view returns (bool);
}

/// @title OfferingManager
/// @notice Non-custodial core state machine for immutable primary-offering configuration.
/// @dev Phase 3.2-2B atomically prepares and escrows the frozen token supply when opening.
contract OfferingManager is AccessControl {
    enum OfferingStatus {
        None,
        Draft,
        Open,
        Successful,
        Failed,
        Finalized
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
        uint256 pricePerWholeTokenUSDC;
        uint16 protocolFeeBps;
        uint64 opensAt;
        uint64 closesAt;
        bytes32 termsHash;
        bytes32 disclosureHash;
    }

    struct Offering {
        OfferingStatus status;
        address creator;
        address assetOwner;
        uint64 createdAt;
        uint64 openedAt;
        uint256 targetUSDC;
        OfferingConfig config;
    }

    bytes32 public constant OFFERING_OPERATOR_ROLE = keccak256("OFFERING_OPERATOR");
    uint8 public constant REQUIRED_USDC_DECIMALS = 6;
    uint256 public constant TOKEN_UNIT = 1e18;
    uint16 public constant MAX_BPS = 10_000;

    IIdentityRegistry public immutable identityRegistry;
    IIPAssetRegistry public immutable assetRegistry;
    IIssuerEligibility public immutable issuerEligibility;

    mapping(bytes32 offeringId => Offering offering) private _offerings;
    mapping(address creator => uint256 nonce) public creatorNonce;

    error ZeroAdmin();
    error ZeroIdentityRegistry();
    error ZeroAssetRegistry();
    error ZeroIssuerEligibility();
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
    event OfferingStatusChanged(
        bytes32 indexed offeringId, OfferingStatus indexed previousStatus, OfferingStatus indexed newStatus
    );

    constructor(address admin_, address identityRegistry_, address assetRegistry_, address issuerEligibility_) {
        if (admin_ == address(0)) revert ZeroAdmin();
        if (identityRegistry_ == address(0)) revert ZeroIdentityRegistry();
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        if (issuerEligibility_ == address(0)) revert ZeroIssuerEligibility();

        identityRegistry = IIdentityRegistry(identityRegistry_);
        assetRegistry = IIPAssetRegistry(assetRegistry_);
        issuerEligibility = IIssuerEligibility(issuerEligibility_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _setRoleAdmin(OFFERING_OPERATOR_ROLE, DEFAULT_ADMIN_ROLE);
    }

    /// @notice Creates an immutable Draft snapshot for a verified asset owner and issuer.
    function createOffering(OfferingConfig calldata config) external returns (bytes32 offeringId) {
        _validateCreationAuthority(config.assetId, msg.sender);
        _validateConfig(config);

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
        if (!issuerEligibility.isEligibleIssuer(config.issuer)) revert InvalidIssuer(config.issuer);
        _validateDependencyContracts(config);

        _prepareTokenCustody(offeringId, config);

        offering.status = OfferingStatus.Open;
        offering.openedAt = uint64(block.timestamp);

        emit OfferingOpened(offeringId, msg.sender, offering.openedAt);
        emit OfferingStatusChanged(offeringId, OfferingStatus.Draft, OfferingStatus.Open);
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

    function _prepareTokenCustody(bytes32 offeringId, OfferingConfig storage config) private {
        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);
        _validateTokenBundle(offeringId, revenueToken, config);

        // Bind only the dependencies already frozen in the Draft. If any later
        // preparation step fails, these bindings roll back with the transaction.
        if (address(revenueToken.revenueVault()) == address(0)) {
            revenueToken.bindRevenueVault(config.revenueVault);
        }
        if (address(revenueToken.recoveryManager()) == address(0)) {
            revenueToken.bindRecoveryManager(config.recoveryManager);
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

    function _validateTokenBundle(bytes32 offeringId, LicenseRevenueToken revenueToken, OfferingConfig storage config)
        private
        view
    {
        address tokenRegistry = address(revenueToken.ipAssetRegistry());
        if (tokenRegistry != address(assetRegistry)) {
            revert TokenRegistryMismatch(address(assetRegistry), tokenRegistry);
        }

        uint256 tokenAssetId = revenueToken.assetId();
        if (tokenAssetId != config.assetId) {
            revert TokenAssetMismatch(config.assetId, tokenAssetId);
        }

        uint256 tokenFinalSupply = revenueToken.finalSupply();
        if (tokenFinalSupply != config.finalSupply) {
            revert TokenFinalSupplyMismatch(config.finalSupply, tokenFinalSupply);
        }

        address tokenEligibility = address(revenueToken.eligibilityPolicy());
        if (tokenEligibility != config.investorEligibility) {
            revert TokenEligibilityMismatch(config.investorEligibility, tokenEligibility);
        }

        if (!revenueToken.hasRole(revenueToken.TOKEN_CONTROLLER_ROLE(), address(this))) {
            revert OfferingManagerNotTokenController(config.revenueToken);
        }

        LicenseRevenueToken.Lifecycle lifecycle = revenueToken.lifecycle();
        if (lifecycle != LicenseRevenueToken.Lifecycle.Created) {
            revert TokenNotReadyForMinting(uint8(lifecycle));
        }

        uint256 actualSupply = revenueToken.totalSupply();
        if (actualSupply != 0) revert InitialTokenSupplyNotZero(actualSupply);

        uint256 escrowBalance = revenueToken.balanceOf(config.allocationEscrow);
        if (escrowBalance != 0) revert InitialEscrowBalanceNotZero(escrowBalance);

        address boundVault = address(revenueToken.revenueVault());
        if (boundVault != address(0) && boundVault != config.revenueVault) {
            revert TokenVaultMismatch(config.revenueVault, boundVault);
        }

        address boundRecoveryManager = address(revenueToken.recoveryManager());
        if (boundRecoveryManager != address(0) && boundRecoveryManager != config.recoveryManager) {
            revert TokenRecoveryManagerMismatch(config.recoveryManager, boundRecoveryManager);
        }

        IAllocationEscrow allocationEscrow = IAllocationEscrow(config.allocationEscrow);
        address escrowManager = allocationEscrow.offeringManager();
        if (escrowManager != address(this)) {
            revert EscrowManagerMismatch(address(this), escrowManager);
        }

        bytes32 escrowOfferingId = allocationEscrow.offeringId();
        if (escrowOfferingId != offeringId) {
            revert EscrowOfferingMismatch(offeringId, escrowOfferingId);
        }

        address escrowToken = allocationEscrow.revenueToken();
        if (escrowToken != config.revenueToken) {
            revert EscrowTokenMismatch(config.revenueToken, escrowToken);
        }

        uint256 escrowFinalSupply = allocationEscrow.finalSupply();
        if (escrowFinalSupply != config.finalSupply) {
            revert EscrowFinalSupplyMismatch(config.finalSupply, escrowFinalSupply);
        }
    }

    function _validateCreationAuthority(uint256 assetId, address caller) private view {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        address currentOwner = assetRegistry.ownerOf(assetId);
        if (caller != currentOwner) revert UnauthorizedAssetOwner(caller, currentOwner);

        uint256 ownerRole = identityRegistry.ROLE_ASSET_OWNER();
        if (!identityRegistry.hasBusinessRole(caller, ownerRole)) revert AssetOwnerIdentityInvalid(caller);
    }

    function _validateConfig(OfferingConfig calldata config) private view {
        if (!issuerEligibility.isEligibleIssuer(config.issuer)) revert InvalidIssuer(config.issuer);
        if (
            config.issuerTreasury == address(0) || config.revenueToken == address(0)
                || config.revenueVault == address(0) || config.allocationEscrow == address(0)
                || config.offeringEscrow == address(0) || config.investorEligibility == address(0)
                || config.recoveryManager == address(0) || config.settlementToken == address(0)
        ) revert ZeroConfigurationAddress();

        _validateDependencyContracts(config);

        if (config.finalSupply == 0) revert InvalidFinalSupply();
        if (config.pricePerWholeTokenUSDC == 0) revert InvalidTokenPrice();
        if (config.protocolFeeBps > MAX_BPS) revert InvalidProtocolFee(config.protocolFeeBps);
        if (config.opensAt <= block.timestamp || config.closesAt <= config.opensAt) {
            revert InvalidOfferingWindow(config.opensAt, config.closesAt);
        }
        if (config.termsHash == bytes32(0)) revert ZeroTermsHash();
        if (config.disclosureHash == bytes32(0)) revert ZeroDisclosureHash();

        uint8 decimals = IERC20Metadata(config.settlementToken).decimals();
        if (decimals != REQUIRED_USDC_DECIMALS) {
            revert UnsupportedSettlementDecimals(decimals, REQUIRED_USDC_DECIMALS);
        }
        if (mulmod(config.finalSupply, config.pricePerWholeTokenUSDC, TOKEN_UNIT) != 0) {
            revert InexactTargetUSDC(config.finalSupply, config.pricePerWholeTokenUSDC);
        }
    }

    function _validateDependencyContracts(OfferingConfig calldata config) private view {
        _requireContract(config.revenueToken);
        _requireContract(config.revenueVault);
        _requireContract(config.allocationEscrow);
        _requireContract(config.offeringEscrow);
        _requireContract(config.investorEligibility);
        _requireContract(config.recoveryManager);
        _requireContract(config.settlementToken);
    }

    function _validateDependencyContracts(OfferingConfig storage config) private view {
        _requireContract(config.revenueToken);
        _requireContract(config.revenueVault);
        _requireContract(config.allocationEscrow);
        _requireContract(config.offeringEscrow);
        _requireContract(config.investorEligibility);
        _requireContract(config.recoveryManager);
        _requireContract(config.settlementToken);
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
