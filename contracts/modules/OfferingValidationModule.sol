// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {LicenseRevenueToken} from "../LicenseRevenueToken.sol";
import {IAllocationEscrow} from "../interfaces/IAllocationEscrow.sol";
import {IIPAssetRegistry} from "../interfaces/IIPAssetRegistry.sol";
import {IOfferingEscrow} from "../interfaces/IOfferingEscrow.sol";
import {IRevenueProgramRegistry} from "../interfaces/IRevenueProgramRegistry.sol";
import {IRevenueVault} from "../interfaces/IRevenueVault.sol";

interface IOfferingIssuerEligibility {
    function isEligibleIssuer(address issuer) external view returns (bool);
}

/// @title OfferingValidationModule
/// @notice Stateless validation boundary for offering creation and token-custody preparation.
/// @dev Deployed once by its immutable Manager. It owns no protocol state and has no asset-moving entrypoint.
contract OfferingValidationModule {
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

    uint8 private constant REQUIRED_USDC_DECIMALS = 6;
    uint256 private constant TOKEN_UNIT = 1e18;
    uint16 private constant MAX_BPS = 10_000;

    address private immutable _manager;
    IIPAssetRegistry private immutable _assetRegistry;
    IOfferingIssuerEligibility private immutable _issuerEligibility;
    IRevenueProgramRegistry private immutable _revenueProgramRegistry;

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
    error InvalidAllocationLot(uint256 allocationLot, uint256 finalSupply);
    error ZeroFeeRecipient();
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
    error TokenDistributionEscrowMismatch(address expected, address actual);
    error VaultActivationControllerMismatch(address expected, address actual);
    error VaultDepositLifecycleMismatch(IRevenueVault.DepositLifecycle expected, IRevenueVault.DepositLifecycle actual);
    error EscrowManagerMismatch(address expected, address actual);
    error EscrowOfferingMismatch(bytes32 expected, bytes32 actual);
    error EscrowTokenMismatch(address expected, address actual);
    error EscrowFinalSupplyMismatch(uint256 expected, uint256 actual);
    error OfferingEscrowManagerMismatch(address expected, address actual);
    error OfferingEscrowOfferingMismatch(bytes32 expected, bytes32 actual);
    error OfferingEscrowSettlementMismatch(address expected, address actual);
    error OfferingEscrowTreasuryMismatch(address expected, address actual);
    error OfferingEscrowFeeRecipientMismatch(address expected, address actual);
    error OfferingEscrowFeeMismatch(uint16 expected, uint16 actual);
    error RevenueProgramBindingMismatch(bytes32 offeringId);
    error RevenueProgramStateMismatch(
        bytes32 offeringId, IRevenueProgramRegistry.ProgramStatus expected, IRevenueProgramRegistry.ProgramStatus actual
    );

    constructor(address assetRegistry_, address issuerEligibility_, address revenueProgramRegistry_) {
        _manager = msg.sender;
        _assetRegistry = IIPAssetRegistry(assetRegistry_);
        _issuerEligibility = IOfferingIssuerEligibility(issuerEligibility_);
        _revenueProgramRegistry = IRevenueProgramRegistry(revenueProgramRegistry_);
    }

    function validateCreationConfig(bytes calldata encodedConfig) external view {
        OfferingConfig memory config = abi.decode(encodedConfig, (OfferingConfig));
        if (!_issuerEligibility.isEligibleIssuer(config.issuer)) revert InvalidIssuer(config.issuer);
        if (
            config.issuerTreasury == address(0) || config.revenueToken == address(0)
                || config.revenueVault == address(0) || config.allocationEscrow == address(0)
                || config.offeringEscrow == address(0) || config.investorEligibility == address(0)
                || config.recoveryManager == address(0) || config.settlementToken == address(0)
        ) revert ZeroConfigurationAddress();
        if (config.feeRecipient == address(0)) revert ZeroFeeRecipient();

        _validateDependencyContracts(config);

        if (config.finalSupply == 0) revert InvalidFinalSupply();
        if (config.allocationLot == 0 || config.finalSupply % config.allocationLot != 0) {
            revert InvalidAllocationLot(config.allocationLot, config.finalSupply);
        }
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

    function validateRevenueProgramBinding(bytes32 offeringId, bytes calldata encodedConfig) external view {
        OfferingConfig memory config = abi.decode(encodedConfig, (OfferingConfig));
        IRevenueProgramRegistry.RevenueProgram memory program = _revenueProgramRegistry.getProgram(offeringId);
        if (program.status != IRevenueProgramRegistry.ProgramStatus.Reserved) {
            revert RevenueProgramStateMismatch(
                offeringId, IRevenueProgramRegistry.ProgramStatus.Reserved, program.status
            );
        }
        if (
            program.offeringId != offeringId || program.assetId != config.assetId || program.issuer != config.issuer
                || program.revenueToken != config.revenueToken || program.revenueVault != config.revenueVault
                || program.settlementToken != config.settlementToken
                || _revenueProgramRegistry.liveOfferingByAsset(config.assetId) != offeringId
        ) {
            revert RevenueProgramBindingMismatch(offeringId);
        }
    }

    function validateOpenBundle(bytes32 offeringId, bytes calldata encodedConfig) external view {
        OfferingConfig memory config = abi.decode(encodedConfig, (OfferingConfig));
        if (!_issuerEligibility.isEligibleIssuer(config.issuer)) revert InvalidIssuer(config.issuer);
        _validateDependencyContracts(config);

        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);
        address tokenRegistry = address(revenueToken.ipAssetRegistry());
        if (tokenRegistry != address(_assetRegistry)) {
            revert TokenRegistryMismatch(address(_assetRegistry), tokenRegistry);
        }

        uint256 tokenAssetId = revenueToken.assetId();
        if (tokenAssetId != config.assetId) revert TokenAssetMismatch(config.assetId, tokenAssetId);

        uint256 tokenFinalSupply = revenueToken.finalSupply();
        if (tokenFinalSupply != config.finalSupply) {
            revert TokenFinalSupplyMismatch(config.finalSupply, tokenFinalSupply);
        }

        address tokenEligibility = address(revenueToken.eligibilityPolicy());
        if (tokenEligibility != config.investorEligibility) {
            revert TokenEligibilityMismatch(config.investorEligibility, tokenEligibility);
        }
        if (!revenueToken.hasRole(revenueToken.TOKEN_CONTROLLER_ROLE(), _manager)) {
            revert OfferingManagerNotTokenController(config.revenueToken);
        }

        LicenseRevenueToken.Lifecycle lifecycle = revenueToken.lifecycle();
        if (lifecycle != LicenseRevenueToken.Lifecycle.Created) revert TokenNotReadyForMinting(uint8(lifecycle));

        uint256 actualSupply = revenueToken.totalSupply();
        if (actualSupply != 0) revert InitialTokenSupplyNotZero(actualSupply);

        uint256 escrowBalance = revenueToken.balanceOf(config.allocationEscrow);
        if (escrowBalance != 0) revert InitialEscrowBalanceNotZero(escrowBalance);

        address boundVault = address(revenueToken.revenueVault());
        if (boundVault != address(0) && boundVault != config.revenueVault) {
            revert TokenVaultMismatch(config.revenueVault, boundVault);
        }
        _validateRevenueVaultBundle(config.revenueVault);

        address boundRecoveryManager = address(revenueToken.recoveryManager());
        if (boundRecoveryManager != address(0) && boundRecoveryManager != config.recoveryManager) {
            revert TokenRecoveryManagerMismatch(config.recoveryManager, boundRecoveryManager);
        }
        address boundDistributionEscrow = revenueToken.primaryDistributionEscrow();
        if (boundDistributionEscrow != address(0) && boundDistributionEscrow != config.allocationEscrow) {
            revert TokenDistributionEscrowMismatch(config.allocationEscrow, boundDistributionEscrow);
        }

        _validateAllocationEscrowBundle(offeringId, config);
        _validateOfferingEscrowBundle(offeringId, config);
    }

    function _validateRevenueVaultBundle(address revenueVault) private view {
        IRevenueVault configuredVault = IRevenueVault(revenueVault);
        address vaultController = configuredVault.activationController();
        if (vaultController != _manager) revert VaultActivationControllerMismatch(_manager, vaultController);

        IRevenueVault.DepositLifecycle vaultLifecycle = configuredVault.depositLifecycle();
        if (vaultLifecycle != IRevenueVault.DepositLifecycle.Disabled) {
            revert VaultDepositLifecycleMismatch(IRevenueVault.DepositLifecycle.Disabled, vaultLifecycle);
        }
    }

    function _validateAllocationEscrowBundle(bytes32 offeringId, OfferingConfig memory config) private view {
        IAllocationEscrow allocationEscrow = IAllocationEscrow(config.allocationEscrow);
        address escrowManager = allocationEscrow.offeringManager();
        if (escrowManager != _manager) revert EscrowManagerMismatch(_manager, escrowManager);

        bytes32 escrowOfferingId = allocationEscrow.offeringId();
        if (escrowOfferingId != offeringId) revert EscrowOfferingMismatch(offeringId, escrowOfferingId);

        address escrowToken = allocationEscrow.revenueToken();
        if (escrowToken != config.revenueToken) revert EscrowTokenMismatch(config.revenueToken, escrowToken);

        uint256 escrowFinalSupply = allocationEscrow.finalSupply();
        if (escrowFinalSupply != config.finalSupply) {
            revert EscrowFinalSupplyMismatch(config.finalSupply, escrowFinalSupply);
        }
    }

    function _validateOfferingEscrowBundle(bytes32 offeringId, OfferingConfig memory config) private view {
        IOfferingEscrow offeringEscrow = IOfferingEscrow(config.offeringEscrow);
        address escrowManager = offeringEscrow.offeringManager();
        if (escrowManager != _manager) revert OfferingEscrowManagerMismatch(_manager, escrowManager);

        bytes32 escrowOfferingId = offeringEscrow.offeringId();
        if (escrowOfferingId != offeringId) {
            revert OfferingEscrowOfferingMismatch(offeringId, escrowOfferingId);
        }

        address settlement = offeringEscrow.settlementToken();
        if (settlement != config.settlementToken) {
            revert OfferingEscrowSettlementMismatch(config.settlementToken, settlement);
        }

        address treasury = offeringEscrow.issuerTreasury();
        if (treasury != config.issuerTreasury) {
            revert OfferingEscrowTreasuryMismatch(config.issuerTreasury, treasury);
        }

        address feeRecipient = offeringEscrow.feeRecipient();
        if (feeRecipient != config.feeRecipient) {
            revert OfferingEscrowFeeRecipientMismatch(config.feeRecipient, feeRecipient);
        }

        uint16 fee = offeringEscrow.protocolFeeBps();
        if (fee != config.protocolFeeBps) revert OfferingEscrowFeeMismatch(config.protocolFeeBps, fee);
    }

    function _validateDependencyContracts(OfferingConfig memory config) private view {
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
}
