// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LicenseRevenueToken} from "../LicenseRevenueToken.sol";
import {IAllocationEscrow} from "../interfaces/IAllocationEscrow.sol";
import {IOfferingEscrow} from "../interfaces/IOfferingEscrow.sol";
import {IRevenueProgramRegistry} from "../interfaces/IRevenueProgramRegistry.sol";
import {IRevenueVault} from "../interfaces/IRevenueVault.sol";

/// @title OfferingFinalizationModule
/// @notice Stateless pre- and postcondition engine for atomic offering finalization.
/// @dev It can only inspect state. The immutable Manager remains the sole activation caller and state owner.
contract OfferingFinalizationModule {
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

    address private immutable _manager;
    IRevenueProgramRegistry private immutable _revenueProgramRegistry;

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

    constructor(address revenueProgramRegistry_) {
        _manager = msg.sender;
        _revenueProgramRegistry = IRevenueProgramRegistry(revenueProgramRegistry_);
    }

    function validatePreconditions(
        uint64 deliveredCount,
        uint64 subscriptionCount,
        uint256 validCommittedUSDC,
        bytes calldata encodedConfig
    ) external view {
        OfferingConfig memory config = abi.decode(encodedConfig, (OfferingConfig));
        if (deliveredCount != subscriptionCount) {
            revert FinalizationDeliveryIncomplete(deliveredCount, subscriptionCount);
        }

        IAllocationEscrow allocationEscrow = IAllocationEscrow(config.allocationEscrow);
        uint256 totalDelivered = allocationEscrow.totalDelivered();
        if (totalDelivered != config.finalSupply) {
            revert FinalizationDeliveredSupplyMismatch(config.finalSupply, totalDelivered);
        }

        uint256 directReleased = allocationEscrow.totalReleased();
        uint256 legalHoldDelivered = allocationEscrow.legalHoldTransferred();
        if (directReleased + legalHoldDelivered != config.finalSupply) {
            revert FinalizationDeliveryAccountingMismatch(config.finalSupply, directReleased, legalHoldDelivered);
        }

        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);
        uint256 allocationBalance = revenueToken.balanceOf(config.allocationEscrow);
        if (allocationBalance != 0) revert FinalizationAllocationBalanceNotZero(allocationBalance);

        IOfferingEscrow offeringEscrow = IOfferingEscrow(config.offeringEscrow);
        uint256 contributed = offeringEscrow.totalContributed();
        if (contributed != validCommittedUSDC) {
            revert FinalizationContributionMismatch(validCommittedUSDC, contributed);
        }

        IRevenueVault revenueVault = IRevenueVault(config.revenueVault);
        address vaultController = revenueVault.activationController();
        if (vaultController != _manager) revert VaultActivationControllerMismatch(_manager, vaultController);

        IRevenueVault.DepositLifecycle vaultLifecycle = revenueVault.depositLifecycle();
        if (vaultLifecycle != IRevenueVault.DepositLifecycle.Disabled) {
            revert VaultDepositLifecycleMismatch(IRevenueVault.DepositLifecycle.Disabled, vaultLifecycle);
        }
    }

    function validatePostconditions(bytes32 offeringId, bytes calldata encodedConfig) external view {
        OfferingConfig memory config = abi.decode(encodedConfig, (OfferingConfig));
        LicenseRevenueToken revenueToken = LicenseRevenueToken(config.revenueToken);
        IRevenueVault revenueVault = IRevenueVault(config.revenueVault);
        IOfferingEscrow offeringEscrow = IOfferingEscrow(config.offeringEscrow);

        LicenseRevenueToken.Lifecycle tokenLifecycle = revenueToken.lifecycle();
        if (tokenLifecycle != LicenseRevenueToken.Lifecycle.Activated) {
            revert FinalizationTokenLifecycleMismatch(tokenLifecycle);
        }

        IRevenueProgramRegistry.RevenueProgram memory program = _revenueProgramRegistry.getProgram(offeringId);
        if (
            program.status != IRevenueProgramRegistry.ProgramStatus.Active
                || _revenueProgramRegistry.activeOfferingByAsset(config.assetId) != offeringId
                || program.assetId != config.assetId || program.issuer != config.issuer
                || program.revenueToken != config.revenueToken || program.revenueVault != config.revenueVault
                || program.settlementToken != config.settlementToken
        ) {
            revert FinalizationProgramMismatch(offeringId);
        }

        IRevenueVault.DepositLifecycle vaultLifecycle = revenueVault.depositLifecycle();
        if (vaultLifecycle != IRevenueVault.DepositLifecycle.Enabled) {
            revert VaultDepositLifecycleMismatch(IRevenueVault.DepositLifecycle.Enabled, vaultLifecycle);
        }

        uint256 contributed = offeringEscrow.totalContributed();
        uint256 issuerAmount = offeringEscrow.issuerProceeds();
        uint256 feeAmount = offeringEscrow.protocolFee();
        if (
            !offeringEscrow.proceedsEnabled() || offeringEscrow.refundable() || offeringEscrow.totalRefunded() != 0
                || issuerAmount + feeAmount != contributed
        ) {
            revert FinalizationProceedsMismatch(contributed, issuerAmount, feeAmount);
        }

        uint256 tokenBalance = revenueToken.balanceOf(_manager);
        if (tokenBalance != 0) {
            revert FinalizationManagerAssetBalanceNotZero(config.revenueToken, tokenBalance);
        }
    }
}
