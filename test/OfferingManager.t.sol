// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AllocationEscrow} from "../contracts/AllocationEscrow.sol";
import {OfferingEscrow} from "../contracts/OfferingEscrow.sol";
import {OfferingManager, IIssuerEligibility} from "../contracts/OfferingManager.sol";
import {RevenueProgramRegistry} from "../contracts/RevenueProgramRegistry.sol";
import {RevenueVault} from "../contracts/RevenueVault.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {IAllocationEscrow} from "../contracts/interfaces/IAllocationEscrow.sol";
import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IInvestorEligibility} from "../contracts/interfaces/IInvestorEligibility.sol";
import {IIPAssetRegistry} from "../contracts/interfaces/IIPAssetRegistry.sol";
import {ILegalHoldEscrow} from "../contracts/interfaces/ILegalHoldEscrow.sol";
import {IRecoveryManager} from "../contracts/interfaces/IRecoveryManager.sol";
import {IRevenueVault} from "../contracts/interfaces/IRevenueVault.sol";
import {IRevenueProgramRegistry} from "../contracts/interfaces/IRevenueProgramRegistry.sol";

contract OfferingManagerTest is Test {
    OfferingManager private manager;
    OfferingIdentityMock private identityRegistry;
    OfferingAssetRegistryMock private assetRegistry;
    IssuerEligibilityMock private issuerEligibility;
    RevenueProgramRegistry private programRegistry;
    SixDecimalUSDCMock private usdc;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private assetOwner = makeAddr("asset-owner");
    address private outsider = makeAddr("outsider");
    address private issuer = makeAddr("issuer");
    address private issuerTreasury = makeAddr("issuer-treasury");
    address private feeRecipient = makeAddr("fee-recipient");
    address private investor = makeAddr("investor");
    address private destination = makeAddr("destination");
    address private secondInvestor = makeAddr("second-investor");
    address private secondDestination = makeAddr("second-destination");

    uint256 private constant ASSET_ID = 1;
    uint256 private constant FINAL_SUPPLY = 10_000 ether;
    uint256 private constant PRICE = 1_000_000;

    LicenseRevenueToken private revenueToken;
    OfferingRevenueVaultMock private revenueVault;
    AllocationEscrow private allocationEscrow;
    OfferingEscrow private offeringEscrow;
    OfferingInvestorEligibilityMock private investorEligibility;
    OfferingRecoveryManagerMock private recoveryManager;

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
    event OfferingFinalized(bytes32 indexed offeringId, address indexed caller);
    event OfferingStatusChanged(
        bytes32 indexed offeringId,
        OfferingManager.OfferingStatus indexed previousStatus,
        OfferingManager.OfferingStatus indexed newStatus
    );

    function setUp() public {
        identityRegistry = new OfferingIdentityMock();
        assetRegistry = new OfferingAssetRegistryMock();
        issuerEligibility = new IssuerEligibilityMock();
        usdc = new SixDecimalUSDCMock();

        investorEligibility = new OfferingInvestorEligibilityMock();
        recoveryManager = new OfferingRecoveryManagerMock();
        programRegistry = new RevenueProgramRegistry(admin);

        manager = new OfferingManager(
            admin,
            address(identityRegistry),
            address(assetRegistry),
            address(issuerEligibility),
            address(programRegistry)
        );
        bytes32 operatorRole = manager.OFFERING_OPERATOR_ROLE();
        vm.startPrank(admin);
        manager.grantRole(operatorRole, operator);
        programRegistry.grantRole(programRegistry.PROGRAM_MANAGER_ROLE(), address(manager));
        vm.stopPrank();

        assetRegistry.setAsset(ASSET_ID, assetOwner);
        identityRegistry.setAssetOwner(assetOwner, true);
        issuerEligibility.setEligible(issuer, true);

        revenueToken = new LicenseRevenueToken(
            "Offering Revenue",
            "OFFREV",
            address(assetRegistry),
            ASSET_ID,
            FINAL_SUPPLY,
            address(investorEligibility),
            address(manager)
        );
        revenueVault = new OfferingRevenueVaultMock(address(revenueToken), address(manager));
        bytes32 expectedOfferingId = keccak256(
            abi.encode(
                block.chainid,
                address(manager),
                address(assetRegistry),
                ASSET_ID,
                assetOwner,
                issuer,
                uint256(0),
                keccak256("offering-terms")
            )
        );
        allocationEscrow =
            new AllocationEscrow(address(manager), expectedOfferingId, address(revenueToken), FINAL_SUPPLY);
        offeringEscrow =
            new OfferingEscrow(address(manager), expectedOfferingId, address(usdc), issuerTreasury, feeRecipient, 250);
        investorEligibility.setEligible(address(allocationEscrow), ASSET_ID, true);
    }

    function testUnauthorizedCreationRejected() public {
        OfferingManager.OfferingConfig memory config = _validConfig();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.UnauthorizedAssetOwner.selector, outsider, assetOwner));
        manager.createOffering(config);

        assertEq(manager.creatorNonce(outsider), 0);
    }

    function testInvalidAssetRejected() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.assetId = 999;

        vm.prank(assetOwner);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.AssetDoesNotExist.selector, 999));
        manager.createOffering(config);
    }

    function testInvalidIssuerRejected() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        issuerEligibility.setEligible(issuer, false);

        vm.prank(assetOwner);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidIssuer.selector, issuer));
        manager.createOffering(config);
    }

    function testInvalidTransitionRejected() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        manager.openOffering(offeringId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Open,
                OfferingManager.OfferingStatus.Draft
            )
        );
        manager.openOffering(offeringId);
    }

    function testImmutableConfigurationSnapshot() public {
        OfferingManager.OfferingConfig memory original = _validConfig();

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(original);

        original.issuerTreasury = outsider;
        original.finalSupply = 1;
        original.pricePerWholeTokenUSDC = 99;
        original.termsHash = keccak256("mutated");

        OfferingManager.Offering memory beforeOpen = manager.getOffering(offeringId);
        assertEq(beforeOpen.config.issuerTreasury, issuerTreasury);
        assertEq(beforeOpen.config.finalSupply, FINAL_SUPPLY);
        assertEq(beforeOpen.config.pricePerWholeTokenUSDC, PRICE);
        assertEq(beforeOpen.config.termsHash, keccak256("offering-terms"));

        vm.warp(beforeOpen.config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);

        OfferingManager.Offering memory afterOpen = manager.getOffering(offeringId);
        assertEq(afterOpen.config.issuerTreasury, beforeOpen.config.issuerTreasury);
        assertEq(afterOpen.config.finalSupply, beforeOpen.config.finalSupply);
        assertEq(afterOpen.config.pricePerWholeTokenUSDC, beforeOpen.config.pricePerWholeTokenUSDC);
        assertEq(afterOpen.config.termsHash, beforeOpen.config.termsHash);
        assertEq(afterOpen.targetUSDC, 10_000 * 1_000_000);
    }

    function testCreateAndOpenEventsAreCorrect() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 offeringId = _expectedOfferingId(config, 0);
        uint256 targetUSDC = 10_000 * 1_000_000;

        vm.expectEmit(true, true, true, true, address(manager));
        emit OfferingCreated(
            offeringId,
            ASSET_ID,
            assetOwner,
            issuer,
            address(revenueToken),
            FINAL_SUPPLY,
            PRICE,
            targetUSDC,
            config.termsHash
        );
        vm.expectEmit(true, true, true, true, address(manager));
        emit OfferingStatusChanged(
            offeringId, OfferingManager.OfferingStatus.None, OfferingManager.OfferingStatus.Draft
        );

        vm.prank(assetOwner);
        bytes32 actualId = manager.createOffering(config);
        assertEq(actualId, offeringId);
        IRevenueProgramRegistry.RevenueProgram memory reservedProgram = programRegistry.getProgram(offeringId);
        assertEq(uint256(reservedProgram.status), uint256(IRevenueProgramRegistry.ProgramStatus.Reserved));
        assertEq(reservedProgram.assetId, ASSET_ID);
        assertEq(reservedProgram.issuer, issuer);
        assertEq(reservedProgram.revenueToken, address(revenueToken));
        assertEq(reservedProgram.revenueVault, address(revenueVault));
        assertEq(reservedProgram.settlementToken, address(usdc));
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);

        vm.warp(config.opensAt);
        vm.expectEmit(true, true, false, true, address(manager));
        emit OfferingOpened(offeringId, operator, config.opensAt);
        vm.expectEmit(true, true, true, true, address(manager));
        emit OfferingStatusChanged(
            offeringId, OfferingManager.OfferingStatus.Draft, OfferingManager.OfferingStatus.Open
        );

        vm.prank(operator);
        manager.openOffering(offeringId);
    }

    function testOnlyOperatorCanOpen() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);

        vm.prank(outsider);
        vm.expectRevert();
        manager.openOffering(offeringId);
    }

    function testDraftCannotExpireBeforeClose() public {
        bytes32 offeringId = _createOffering();
        uint64 closesAt = manager.getOffering(offeringId).config.closesAt;

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.DraftNotExpired.selector, block.timestamp, closesAt));
        manager.expireDraft(offeringId);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(uint256(offering.failureReason), uint256(OfferingManager.OfferingFailureReason.None));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);
    }

    function testExpiredDraftCanBePermissionlesslyClosedWithoutTouchingEscrows() public {
        bytes32 offeringId = _createOffering();
        uint64 closesAt = manager.getOffering(offeringId).config.closesAt;
        vm.warp(closesAt);

        vm.expectEmit(true, true, false, true, address(manager));
        emit DraftExpired(offeringId, outsider, closesAt);
        vm.expectEmit(true, true, true, true, address(manager));
        emit OfferingStatusChanged(
            offeringId, OfferingManager.OfferingStatus.Draft, OfferingManager.OfferingStatus.Failed
        );
        vm.prank(outsider);
        manager.expireDraft(offeringId);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Failed));
        assertEq(uint256(offering.failureReason), uint256(OfferingManager.OfferingFailureReason.DraftExpired));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Failed)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), bytes32(0));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(offeringEscrow)), 0);
        assertEq(offeringEscrow.totalContributed(), 0);
        assertFalse(offeringEscrow.refundable());
        assertFalse(allocationEscrow.depositConfirmed());
        assertFalse(allocationEscrow.tombstoned());
    }

    function testExpiredDraftCannotOpenSubscribeOrExpireTwice() public {
        bytes32 offeringId = _createOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.expireDraft(offeringId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Draft
            )
        );
        manager.openOffering(offeringId);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Open
            )
        );
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("expired-draft"));

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Draft
            )
        );
        manager.expireDraft(offeringId);
    }

    function testDraftExpiryReleasesAssetForReplacementOffering() public {
        bytes32 expiredOfferingId = _createOffering();
        vm.warp(manager.getOffering(expiredOfferingId).config.closesAt);
        manager.expireDraft(expiredOfferingId);

        OfferingManager.OfferingConfig memory replacement = _validConfig();
        replacement.opensAt = uint64(block.timestamp + 1 days);
        replacement.closesAt = uint64(block.timestamp + 8 days);
        replacement.termsHash = keccak256("replacement-terms");
        bytes32 replacementOfferingId = _expectedOfferingId(replacement, 1);
        LicenseRevenueToken replacementToken = new LicenseRevenueToken(
            "Replacement Revenue",
            "RPLREV",
            address(assetRegistry),
            ASSET_ID,
            FINAL_SUPPLY,
            address(investorEligibility),
            address(manager)
        );
        OfferingRevenueVaultMock replacementVault =
            new OfferingRevenueVaultMock(address(replacementToken), address(manager));
        AllocationEscrow replacementAllocationEscrow =
            new AllocationEscrow(address(manager), replacementOfferingId, address(replacementToken), FINAL_SUPPLY);
        OfferingEscrow replacementOfferingEscrow = new OfferingEscrow(
            address(manager), replacementOfferingId, address(usdc), issuerTreasury, feeRecipient, 250
        );
        investorEligibility.setEligible(address(replacementAllocationEscrow), ASSET_ID, true);
        replacement.revenueToken = address(replacementToken);
        replacement.revenueVault = address(replacementVault);
        replacement.allocationEscrow = address(replacementAllocationEscrow);
        replacement.offeringEscrow = address(replacementOfferingEscrow);

        vm.prank(assetOwner);
        bytes32 actualReplacementId = manager.createOffering(replacement);

        assertEq(actualReplacementId, replacementOfferingId);
        assertEq(
            uint256(manager.getOfferingStatus(replacementOfferingId)), uint256(OfferingManager.OfferingStatus.Draft)
        );
        assertEq(
            uint256(programRegistry.getProgram(expiredOfferingId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Failed)
        );
        assertEq(
            uint256(programRegistry.getProgram(replacementOfferingId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), replacementOfferingId);
    }

    function testRegistryFailureRollsBackDraftExpiry() public {
        bytes32 offeringId = _createOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        bytes32 programManagerRole = programRegistry.PROGRAM_MANAGER_ROLE();
        vm.prank(admin);
        programRegistry.revokeRole(programManagerRole, address(manager));

        vm.expectRevert();
        manager.expireDraft(offeringId);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(uint256(offering.failureReason), uint256(OfferingManager.OfferingFailureReason.None));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(offeringEscrow.totalContributed(), 0);
    }

    function testSuccessfulOpenMintsExactSupplyIntoAllocationEscrow() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Open));
        assertEq(revenueToken.totalSupply(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), FINAL_SUPPLY);
        assertTrue(allocationEscrow.depositConfirmed());
        assertFalse(revenueToken.hasRole(revenueToken.MINTER_ROLE(), address(manager)));
        assertEq(revenueToken.primaryDistributionEscrow(), address(allocationEscrow));
    }

    function testMintFailureRollsBackEntireOpen() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        investorEligibility.setEligible(address(allocationEscrow), ASSET_ID, false);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert();
        manager.openOffering(offeringId);

        _assertOpenRolledBack(offeringId);
    }

    function testEscrowFailureRollsBackMintAndBindings() public {
        bytes32 expectedOfferingId = _expectedOfferingId(_validConfig(), 0);
        FaultingAllocationEscrow faultingEscrow = new FaultingAllocationEscrow(
            address(manager), expectedOfferingId, address(revenueToken), FINAL_SUPPLY, true, false
        );
        investorEligibility.setEligible(address(faultingEscrow), ASSET_ID, true);
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.allocationEscrow = address(faultingEscrow);
        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(FaultingAllocationEscrow.ConfirmationFailed.selector);
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(revenueToken.balanceOf(address(faultingEscrow)), 0);
        assertEq(address(revenueToken.revenueVault()), address(0));
        assertEq(address(revenueToken.recoveryManager()), address(0));
        assertEq(revenueToken.primaryDistributionEscrow(), address(0));
    }

    function testEscrowCustodyConfirmationInvariantEnforced() public {
        bytes32 expectedOfferingId = _expectedOfferingId(_validConfig(), 0);
        FaultingAllocationEscrow faultingEscrow = new FaultingAllocationEscrow(
            address(manager), expectedOfferingId, address(revenueToken), FINAL_SUPPLY, false, true
        );
        investorEligibility.setEligible(address(faultingEscrow), ASSET_ID, true);
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.allocationEscrow = address(faultingEscrow);
        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.EscrowCustodyNotConfirmed.selector, offeringId));
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(revenueToken.balanceOf(address(faultingEscrow)), 0);
    }

    function testVaultDependencyFailureRollsBackEntireOpen() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        revenueVault.setCheckpointFailure(true);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(OfferingRevenueVaultMock.CheckpointFailed.selector);
        manager.openOffering(offeringId);

        _assertOpenRolledBack(offeringId);
    }

    function testSupplyInvariantRemainsExactAfterOpen() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        manager.openOffering(offeringId);

        assertEq(revenueToken.totalSupply(), revenueToken.finalSupply());
        assertEq(revenueToken.totalSupply(), manager.getOffering(offeringId).config.finalSupply);
    }

    function testOpenRevalidatesAssetOwnership() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assetRegistry.setAsset(ASSET_ID, outsider);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.AssetOwnershipChanged.selector, assetOwner, outsider));
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
    }

    function testOpenRevalidatesAssetOwnerIdentity() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        identityRegistry.setAssetOwner(assetOwner, false);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.AssetOwnerIdentityInvalid.selector, assetOwner));
        manager.openOffering(offeringId);

        _assertOpenRolledBack(offeringId);
    }

    function testOpenRevalidatesIssuer() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        issuerEligibility.setEligible(issuer, false);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidIssuer.selector, issuer));
        manager.openOffering(offeringId);
    }

    function testOpenCannotBypassTokenController() public {
        LicenseRevenueToken foreignControlledToken = new LicenseRevenueToken(
            "Foreign Controlled Revenue",
            "FCREV",
            address(assetRegistry),
            ASSET_ID,
            FINAL_SUPPLY,
            address(investorEligibility),
            outsider
        );
        OfferingRevenueVaultMock foreignVault =
            new OfferingRevenueVaultMock(address(foreignControlledToken), address(manager));
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.revenueToken = address(foreignControlledToken);
        config.revenueVault = address(foreignVault);

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.OfferingManagerNotTokenController.selector, address(foreignControlledToken)
            )
        );
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(foreignControlledToken.totalSupply(), 0);
        assertEq(uint256(foreignControlledToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
    }

    function testOpenRejectsPreboundWrongDistributionEscrow() public {
        bytes32 offeringId = _createOffering();
        vm.prank(address(manager));
        revenueToken.bindPrimaryDistributionEscrow(outsider);
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.TokenDistributionEscrowMismatch.selector, address(allocationEscrow), outsider
            )
        );
        manager.openOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(revenueToken.totalSupply(), 0);
    }

    function testOpenRejectsWrongAllocationEscrowManagerBinding() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 expectedOfferingId = _expectedOfferingId(config, 0);
        AllocationEscrow wrongEscrow =
            new AllocationEscrow(outsider, expectedOfferingId, address(revenueToken), FINAL_SUPPLY);
        config.allocationEscrow = address(wrongEscrow);

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.EscrowManagerMismatch.selector, address(manager), outsider)
        );
        manager.openOffering(offeringId);

        assertEq(revenueToken.totalSupply(), 0);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
    }

    function testOpenRejectsWrongAllocationEscrowOfferingBinding() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 wrongOfferingId = keccak256("wrong-offering");
        AllocationEscrow wrongEscrow =
            new AllocationEscrow(address(manager), wrongOfferingId, address(revenueToken), FINAL_SUPPLY);
        config.allocationEscrow = address(wrongEscrow);

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.EscrowOfferingMismatch.selector, offeringId, wrongOfferingId)
        );
        manager.openOffering(offeringId);

        assertEq(revenueToken.totalSupply(), 0);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
    }

    function testOpenRejectsWrongAllocationEscrowTokenBinding() public {
        LicenseRevenueToken otherToken = new LicenseRevenueToken(
            "Other Revenue",
            "OTHER",
            address(assetRegistry),
            ASSET_ID,
            FINAL_SUPPLY,
            address(investorEligibility),
            address(manager)
        );
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 expectedOfferingId = _expectedOfferingId(config, 0);
        AllocationEscrow wrongEscrow =
            new AllocationEscrow(address(manager), expectedOfferingId, address(otherToken), FINAL_SUPPLY);
        config.allocationEscrow = address(wrongEscrow);

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.EscrowTokenMismatch.selector, address(revenueToken), address(otherToken)
            )
        );
        manager.openOffering(offeringId);

        assertEq(revenueToken.totalSupply(), 0);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
    }

    function testSubscribeSuccessfulFullFill() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        (bytes32 subscriptionId, uint256 filled, uint256 requiredUSDC) =
            manager.subscribe(offeringId, FINAL_SUPPLY, FINAL_SUPPLY, destination, keccak256("payment-full"));

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        assertEq(filled, FINAL_SUPPLY);
        assertEq(requiredUSDC, 10_000 * 1_000_000);
        assertEq(subscription.filledAllocation, FINAL_SUPPLY);
        assertEq(offering.soldSupply, FINAL_SUPPLY);
        assertEq(offering.committedUSDC, requiredUSDC);
        assertEq(allocationEscrow.totalAllocated(), FINAL_SUPPLY);
        assertEq(offeringEscrow.totalContributed(), requiredUSDC);
        assertEq(usdc.balanceOf(address(offeringEscrow)), requiredUSDC);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(usdc.balanceOf(address(allocationEscrow)), 0);
    }

    function testSubscribePartialFCFSFillSatisfyingMinFill() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        vm.startPrank(investor);
        manager.subscribe(offeringId, 9_000 ether, 9_000 ether, destination, keccak256("payment-1"));
        (, uint256 filled, uint256 requiredUSDC) =
            manager.subscribe(offeringId, 2_000 ether, 1_000 ether, destination, keccak256("payment-2"));
        vm.stopPrank();

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(filled, 1_000 ether);
        assertEq(requiredUSDC, 1_000 * 1_000_000);
        assertEq(offering.soldSupply, FINAL_SUPPLY);
        assertEq(offering.nextSequence, 2);
    }

    function testSubscribePartialFillBelowMinFillRollsBack() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        vm.startPrank(investor);
        manager.subscribe(offeringId, 9_000 ether, 9_000 ether, destination, keccak256("payment-1"));
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.FillBelowMinimum.selector, 1_000 ether, 1_500 ether));
        manager.subscribe(offeringId, 2_000 ether, 1_500 ether, destination, keccak256("payment-failed"));
        vm.stopPrank();

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(offering.soldSupply, 9_000 ether);
        assertEq(offering.nextSequence, 1);
        assertEq(offeringEscrow.totalContributed(), 9_000 * 1_000_000);
    }

    function testSubscribeZeroRequestedAllocationRejected() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        vm.expectRevert(OfferingManager.ZeroRequestedAllocation.selector);
        manager.subscribe(offeringId, 0, 0, destination, keccak256("payment"));
    }

    function testSubscribeZeroMinFillAcceptsAvailableLot() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        (, uint256 filled,) = manager.subscribe(offeringId, 2 ether, 0, destination, keccak256("zero-min-fill"));

        assertEq(filled, 2 ether);
        assertEq(manager.getOffering(offeringId).nextSequence, 1);
    }

    function testSubscribeBeforeOfferingOpenRejected() public {
        bytes32 offeringId = _createOffering();
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Draft,
                OfferingManager.OfferingStatus.Open
            )
        );
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("before-open"));
    }

    function testSubscribeInvalidAllocationLotRejected() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.allocationLot = 2 ether;
        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.FillNotAlignedToLot.selector, 3 ether, 2 ether));
        manager.subscribe(offeringId, 3 ether, 0, destination, keccak256("bad-lot"));
    }

    function testSubscribeRejectsIneligibleOrRevokedPayerAndDestination() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);

        investorEligibility.setEligible(investor, ASSET_ID, false);
        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.IneligibleSubscriber.selector, investor));
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("payment-ineligible"));

        investorEligibility.setEligible(investor, ASSET_ID, true);
        investorEligibility.setEligible(destination, ASSET_ID, false);
        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.IneligibleDestination.selector, destination));
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("payment-destination"));

        investorEligibility.setEligible(destination, ASSET_ID, true);
        identityRegistry.setLicensee(investor, false);
        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidSubscriberIdentity.selector, investor));
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("payment-revoked"));
    }

    function testSubscribeAfterFundingDeadlineRejected() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.closesAt);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.SubscriptionWindowClosed.selector, offering.config.closesAt, offering.config.closesAt
            )
        );
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("late"));
    }

    function testSubscribeDuplicatePaymentReferenceRejected() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        bytes32 paymentReference = keccak256("duplicate-payment");

        vm.startPrank(investor);
        manager.subscribe(offeringId, 1 ether, 0, destination, paymentReference);
        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.PaymentReferenceAlreadyUsed.selector, offeringId, paymentReference)
        );
        manager.subscribe(offeringId, 1 ether, 0, destination, paymentReference);
        vm.stopPrank();
    }

    function testSubscribeInexactUSDCConversionRejectedWithoutConsumingSequence() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.allocationLot = 1;
        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
        _prepareInvestor(investor, destination);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InexactSubscriptionPrice.selector, uint256(1), PRICE));
        manager.subscribe(offeringId, 1, 0, destination, keccak256("inexact"));

        assertEq(manager.getOffering(offeringId).nextSequence, 0);
        assertEq(offeringEscrow.totalContributed(), 0);
        assertEq(allocationEscrow.totalAllocated(), 0);
    }

    function testOfferingEscrowFailureRollsBackManagerAndAllocation() public {
        bytes32 offeringId = _openOffering();
        identityRegistry.setLicensee(investor, true);
        investorEligibility.setEligible(investor, ASSET_ID, true);
        investorEligibility.setEligible(destination, ASSET_ID, true);

        vm.prank(investor);
        vm.expectRevert();
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("no-funds"));

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(offering.soldSupply, 0);
        assertEq(offering.committedUSDC, 0);
        assertEq(offering.nextSequence, 0);
        assertEq(allocationEscrow.totalAllocated(), 0);
        assertEq(offeringEscrow.totalContributed(), 0);
    }

    function testAllocationEscrowFailureRollsBackUSDCAndManagerState() public {
        (bytes32 offeringId, SubscriptionAllocationEscrowFault faultEscrow) =
            _openWithSubscriptionAllocationFault(true, false);
        _prepareInvestor(investor, destination);
        uint256 payerBalanceBefore = usdc.balanceOf(investor);

        vm.prank(investor);
        vm.expectRevert(SubscriptionAllocationEscrowFault.RegistrationFailed.selector);
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("allocation-failure"));

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(usdc.balanceOf(investor), payerBalanceBefore);
        assertEq(usdc.balanceOf(address(offeringEscrow)), 0);
        assertEq(offeringEscrow.totalContributed(), 0);
        assertEq(faultEscrow.totalAllocated(), 0);
        assertEq(offering.soldSupply, 0);
        assertEq(offering.committedUSDC, 0);
        assertEq(offering.nextSequence, 0);
    }

    function testManagerAccountingFailureRollsBackBothEscrows() public {
        (bytes32 offeringId, SubscriptionAllocationEscrowFault faultEscrow) =
            _openWithSubscriptionAllocationFault(false, true);
        _prepareInvestor(investor, destination);
        uint256 payerBalanceBefore = usdc.balanceOf(investor);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.AllocationAccountingMismatch.selector, 1 ether, 1 ether + 1)
        );
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("accounting-failure"));

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(usdc.balanceOf(investor), payerBalanceBefore);
        assertEq(offeringEscrow.totalContributed(), 0);
        assertEq(faultEscrow.totalAllocated(), 0);
        assertEq(offering.soldSupply, 0);
        assertEq(offering.committedUSDC, 0);
        assertEq(offering.nextSequence, 0);
    }

    function testReconciliationRejectedBeforeFundingClose() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        vm.prank(investor);
        manager.subscribe(offeringId, 1 ether, 0, destination, keccak256("reconcile-too-early"));

        vm.prank(outsider);
        vm.expectRevert();
        manager.reconcileSubscription(offeringId, 0);

        assertEq(manager.getOffering(offeringId).reconciledCount, 0);
    }

    function testPermissionlessReconciliationFullValidOfferingBecomesSuccessful() public {
        bytes32 offeringId = _subscribeFullOffering();
        OfferingManager.Offering memory beforeReconciliation = manager.getOffering(offeringId);
        uint256 usdcBalance = usdc.balanceOf(address(offeringEscrow));
        uint256 tokenBalance = revenueToken.balanceOf(address(allocationEscrow));
        vm.warp(beforeReconciliation.config.closesAt);

        vm.prank(outsider);
        manager.reconcileSubscription(offeringId, 0);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Successful));
        assertEq(uint256(subscription.status), uint256(OfferingManager.SubscriptionStatus.Valid));
        assertEq(offering.soldSupply, FINAL_SUPPLY);
        assertEq(offering.validSoldSupply, FINAL_SUPPLY);
        assertEq(offering.validCommittedUSDC, offering.committedUSDC);
        assertEq(usdc.balanceOf(address(offeringEscrow)), usdcBalance);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), tokenBalance);
        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);
    }

    function testReconciliationMustProcessInSequenceAndCannotRepeat() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        vm.startPrank(investor);
        manager.subscribe(offeringId, 5_000 ether, 0, destination, keccak256("sequence-0"));
        manager.subscribe(offeringId, 5_000 ether, 0, destination, keccak256("sequence-1"));
        vm.stopPrank();
        vm.warp(manager.getOffering(offeringId).config.closesAt);

        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.InvalidReconciliationSequence.selector, uint64(0), uint64(1))
        );
        manager.reconcileSubscription(offeringId, 1);

        manager.reconcileSubscription(offeringId, 0);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Open));

        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.InvalidReconciliationSequence.selector, uint64(1), uint64(0))
        );
        manager.reconcileSubscription(offeringId, 0);

        manager.reconcileSubscription(offeringId, 1);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Successful));
    }

    function testRevokedPayerBeforeReconciliationMakesOfferingFailed() public {
        bytes32 offeringId = _subscribeFullOffering();
        identityRegistry.setLicensee(investor, false);
        vm.warp(manager.getOffering(offeringId).config.closesAt);

        manager.reconcileSubscription(offeringId, 0);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        OfferingManager.Subscription memory subscription =
            manager.getSubscription(manager.subscriptionIdBySequence(offeringId, 0));
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Failed));
        assertEq(uint256(offering.failureReason), uint256(OfferingManager.OfferingFailureReason.FundingOutcome));
        assertEq(offering.soldSupply, FINAL_SUPPLY);
        assertEq(offering.validSoldSupply, 0);
        assertEq(offering.validCommittedUSDC, 0);
        assertEq(subscription.invalidReason, manager.INVALID_PAYER_IDENTITY());
        assertTrue(offeringEscrow.refundable());
        assertTrue(allocationEscrow.tombstoned());
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), FINAL_SUPPLY);
        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Failed)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), bytes32(0));
    }

    function testDestinationOrPayerEligibilityLossMakesSubscriptionInvalid() public {
        bytes32 offeringId = _subscribeFullOffering();
        investorEligibility.setEligible(destination, ASSET_ID, false);
        investorEligibility.setEligible(investor, ASSET_ID, false);
        vm.warp(manager.getOffering(offeringId).config.closesAt);

        manager.reconcileSubscription(offeringId, 0);

        OfferingManager.Subscription memory subscription =
            manager.getSubscription(manager.subscriptionIdBySequence(offeringId, 0));
        uint8 expectedReason = manager.INVALID_PAYER_ELIGIBILITY() | manager.INVALID_DESTINATION_ELIGIBILITY();
        assertEq(subscription.invalidReason, expectedReason);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Failed));
    }

    function testIncompleteReconciliationCannotResolveOutcome() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        vm.startPrank(investor);
        manager.subscribe(offeringId, 5_000 ether, 0, destination, keccak256("incomplete-0"));
        manager.subscribe(offeringId, 5_000 ether, 0, destination, keccak256("incomplete-1"));
        vm.stopPrank();
        vm.warp(manager.getOffering(offeringId).config.closesAt);

        manager.reconcileSubscription(offeringId, 0);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.ReconciliationIncomplete.selector, uint64(1), uint64(2)));
        manager.resolveOfferingOutcome(offeringId);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Open));
        assertEq(offering.validSoldSupply, 5_000 ether);
        assertEq(offering.soldSupply, FINAL_SUPPLY);
    }

    function testUndersubscribedOfferingBecomesFailedAfterCompleteReconciliation() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        vm.prank(investor);
        manager.subscribe(offeringId, 9_000 ether, 0, destination, keccak256("undersubscribed"));
        vm.warp(manager.getOffering(offeringId).config.closesAt);

        manager.reconcileSubscription(offeringId, 0);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(offering.validSoldSupply, 9_000 ether);
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Failed));
    }

    function testSuccessfulOutcomeIsIrreversibleAndLateFailureUsesRemediation() public {
        bytes32 offeringId = _subscribeFullOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        uint256 validSupply = manager.getOffering(offeringId).validSoldSupply;

        identityRegistry.setLicensee(investor, false);
        vm.prank(outsider);
        manager.flagSubscriptionRemediation(subscriptionId);

        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        assertEq(uint256(subscription.status), uint256(OfferingManager.SubscriptionStatus.Remediation));
        assertEq(uint256(offering.status), uint256(OfferingManager.OfferingStatus.Successful));
        assertEq(offering.validSoldSupply, validSupply);

        vm.expectRevert();
        manager.resolveOfferingOutcome(offeringId);
        vm.expectRevert();
        manager.reconcileSubscription(offeringId, 0);
    }

    function testTerminalFailedOutcomeIsIrreversible() public {
        bytes32 offeringId = _openOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.resolveOfferingOutcome(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Failed));
        vm.expectRevert();
        manager.resolveOfferingOutcome(offeringId);
    }

    function testPayerCanClaimFullRefundAfterFailedOutcome() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        identityRegistry.setLicensee(investor, false);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);

        uint256 balanceBefore = usdc.balanceOf(investor);
        vm.prank(investor);
        offeringEscrow.claimRefund(subscriptionId);

        assertEq(usdc.balanceOf(investor), balanceBefore + 10_000 * 1_000_000);
        assertEq(offeringEscrow.totalRefunded(), 10_000 * 1_000_000);
        assertEq(usdc.balanceOf(address(offeringEscrow)), 0);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertTrue(offeringEscrow.getContribution(subscriptionId).refunded);
    }

    function testMultipleInvestorsRefundIndependentlyInAnyOrder() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        _prepareInvestor(secondInvestor, secondDestination);
        vm.prank(investor);
        manager.subscribe(offeringId, 4_000 ether, 0, destination, keccak256("refund-first"));
        vm.prank(secondInvestor);
        manager.subscribe(offeringId, 5_000 ether, 0, secondDestination, keccak256("refund-second"));
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        manager.reconcileSubscription(offeringId, 1);

        bytes32 firstId = manager.subscriptionIdBySequence(offeringId, 0);
        bytes32 secondId = manager.subscriptionIdBySequence(offeringId, 1);
        uint256 firstBefore = usdc.balanceOf(investor);
        uint256 secondBefore = usdc.balanceOf(secondInvestor);

        vm.prank(secondInvestor);
        offeringEscrow.claimRefund(secondId);
        vm.prank(investor);
        offeringEscrow.claimRefund(firstId);

        assertEq(usdc.balanceOf(investor), firstBefore + 4_000 * 1_000_000);
        assertEq(usdc.balanceOf(secondInvestor), secondBefore + 5_000 * 1_000_000);
        assertEq(offeringEscrow.totalRefunded(), 9_000 * 1_000_000);
        assertEq(offeringEscrow.totalRefunded(), offeringEscrow.totalContributed());
        assertEq(usdc.balanceOf(address(offeringEscrow)), 0);
    }

    function testSuccessfulOfferingCannotRefund() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);

        assertFalse(offeringEscrow.refundable());
        assertFalse(allocationEscrow.tombstoned());
        vm.prank(investor);
        vm.expectRevert(OfferingEscrow.RefundsNotEnabled.selector);
        offeringEscrow.claimRefund(subscriptionId);
    }

    function testPermissionlessSuccessfulDeliveryPreservesUSDCAndMintingLifecycle() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        uint256 contributedBefore = offeringEscrow.totalContributed();
        uint256 escrowUSDCBefore = usdc.balanceOf(address(offeringEscrow));

        vm.prank(outsider);
        manager.deliverAllocation(offeringId, 0);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        AllocationEscrow.Allocation memory allocation = allocationEscrow.getAllocation(subscriptionId);
        assertEq(offering.deliveredCount, 1);
        assertTrue(subscription.deliveryProcessed);
        assertGt(subscription.deliveredAt, 0);
        assertEq(uint256(subscription.status), uint256(OfferingManager.SubscriptionStatus.Valid));
        assertTrue(allocation.released);
        assertEq(allocation.destination, destination);
        assertEq(allocation.amount, FINAL_SUPPLY);
        assertEq(allocationEscrow.totalReleased(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(destination), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertEq(revenueToken.totalSupply(), FINAL_SUPPLY);
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(offeringEscrow.totalContributed(), contributedBefore);
        assertEq(usdc.balanceOf(address(offeringEscrow)), escrowUSDCBefore);
        assertEq(usdc.balanceOf(address(manager)), 0);

        investorEligibility.setEligible(secondDestination, ASSET_ID, true);
        vm.prank(destination);
        vm.expectRevert(LicenseRevenueToken.TransfersNotActive.selector);
        revenueToken.transfer(secondDestination, 1 ether);
    }

    function testPermissionlessAtomicFinalizationActivatesAllDependenciesWithoutMovingUSDC() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        uint256 escrowUSDCBefore = usdc.balanceOf(address(offeringEscrow));
        uint256 treasuryBefore = usdc.balanceOf(issuerTreasury);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        vm.expectEmit(true, true, false, true, address(manager));
        emit OfferingFinalized(offeringId, outsider);
        vm.expectEmit(true, true, true, true, address(manager));
        emit OfferingStatusChanged(
            offeringId, OfferingManager.OfferingStatus.Successful, OfferingManager.OfferingStatus.Finalized
        );
        vm.prank(outsider);
        manager.finalizeOffering(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Finalized));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Activated));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Active)
        );
        assertEq(programRegistry.activeOfferingByAsset(ASSET_ID), offeringId);
        assertEq(uint256(revenueVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Enabled));
        assertTrue(offeringEscrow.proceedsEnabled());

        uint256 expectedFee = offeringEscrow.totalContributed() * 250 / 10_000;
        assertEq(offeringEscrow.protocolFee(), expectedFee);
        assertEq(offeringEscrow.issuerProceeds(), offeringEscrow.totalContributed() - expectedFee);
        assertEq(offeringEscrow.issuerProceeds() + offeringEscrow.protocolFee(), offeringEscrow.totalContributed());
        assertEq(allocationEscrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(allocationEscrow.totalReleased() + allocationEscrow.legalHoldTransferred(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertEq(revenueToken.balanceOf(address(manager)), 0);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(usdc.balanceOf(address(offeringEscrow)), escrowUSDCBefore);
        assertEq(usdc.balanceOf(issuerTreasury), treasuryBefore);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore);
    }

    function testAtomicFinalizationEnablesProductionRevenueVault() public {
        RevenueVault productionVault =
            new RevenueVault(address(revenueToken), address(usdc), admin, outsider, address(manager));
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.revenueVault = address(productionVault);

        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
        _prepareInvestor(investor, destination);
        vm.prank(investor);
        manager.subscribe(offeringId, FINAL_SUPPLY, FINAL_SUPPLY, destination, keccak256("production-vault"));
        vm.warp(config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        manager.deliverAllocation(offeringId, 0);
        manager.finalizeOffering(offeringId);

        assertEq(uint256(productionVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Enabled));
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Finalized));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Activated));
        assertTrue(offeringEscrow.proceedsEnabled());
    }

    function testFinalizedIssuerAndFeePullClaimsPreserveFinalEconomicInvariants() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        manager.finalizeOffering(offeringId);
        uint256 totalContributed = offeringEscrow.totalContributed();
        uint256 issuerAmount = offeringEscrow.issuerProceeds();
        uint256 feeAmount = offeringEscrow.protocolFee();

        vm.prank(feeRecipient);
        assertEq(offeringEscrow.claimProtocolFee(), feeAmount);
        assertEq(usdc.balanceOf(address(offeringEscrow)), issuerAmount);

        vm.prank(issuerTreasury);
        assertEq(offeringEscrow.claimIssuerProceeds(), issuerAmount);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Finalized));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Activated));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Active)
        );
        assertEq(uint256(revenueVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Enabled));
        assertEq(issuerAmount + feeAmount, totalContributed);
        assertEq(offeringEscrow.totalProceedsClaimed(), totalContributed);
        assertEq(usdc.balanceOf(issuerTreasury), issuerAmount);
        assertEq(usdc.balanceOf(feeRecipient), feeAmount);
        assertEq(usdc.balanceOf(address(offeringEscrow)), 0);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(revenueToken.balanceOf(address(manager)), 0);
    }

    function testFinalizationRequiresCompleteDeliveryAndCannotReplay() public {
        bytes32 offeringId = _subscribeFullOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.FinalizationDeliveryIncomplete.selector, uint64(0), uint64(1))
        );
        manager.finalizeOffering(offeringId);

        manager.deliverAllocation(offeringId, 0);
        manager.finalizeOffering(offeringId);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Finalized,
                OfferingManager.OfferingStatus.Successful
            )
        );
        manager.finalizeOffering(offeringId);
    }

    function testOfferingFailedCannotFinalize() public {
        bytes32 offeringId = _openOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.resolveOfferingOutcome(offeringId);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Successful
            )
        );
        manager.finalizeOffering(offeringId);
    }

    function testDraftExpiredOfferingCannotFinalize() public {
        bytes32 offeringId = _createOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.expireDraft(offeringId);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                offeringId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Successful
            )
        );
        manager.finalizeOffering(offeringId);
    }

    function testOfferingFailedCannotClaimProceeds() public {
        bytes32 offeringId = _openOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.resolveOfferingOutcome(offeringId);

        vm.prank(issuerTreasury);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.OfferingNotFinalized.selector, uint8(4)));
        offeringEscrow.claimIssuerProceeds();

        assertTrue(offeringEscrow.refundable());
        assertFalse(offeringEscrow.proceedsEnabled());
        assertEq(offeringEscrow.totalProceedsClaimed(), 0);
    }

    function testDraftExpiredOfferingCannotClaimProceeds() public {
        bytes32 offeringId = _createOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.expireDraft(offeringId);

        vm.prank(feeRecipient);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.OfferingNotFinalized.selector, uint8(4)));
        offeringEscrow.claimProtocolFee();

        assertFalse(offeringEscrow.refundable());
        assertFalse(offeringEscrow.proceedsEnabled());
        assertEq(offeringEscrow.totalProceedsClaimed(), 0);
    }

    function testTokenActivationFailureRollsBackFinalization() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        bytes32 controllerRole = revenueToken.TOKEN_CONTROLLER_ROLE();
        vm.prank(address(manager));
        revenueToken.revokeRole(controllerRole, address(manager));

        vm.expectRevert();
        manager.finalizeOffering(offeringId);

        _assertFinalizationRolledBack(offeringId);
    }

    function testProgramActivationFailureRollsBackFinalization() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        bytes32 programManagerRole = programRegistry.PROGRAM_MANAGER_ROLE();
        vm.prank(admin);
        programRegistry.revokeRole(programManagerRole, address(manager));

        vm.expectRevert();
        manager.finalizeOffering(offeringId);

        _assertFinalizationRolledBack(offeringId);
    }

    function testVaultEnableFailureRollsBackFinalization() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        revenueVault.setEnableFailure(true);

        vm.expectRevert(OfferingRevenueVaultMock.EnableFailed.selector);
        manager.finalizeOffering(offeringId);

        _assertFinalizationRolledBack(offeringId);
    }

    function testOfferingEscrowEnableFailureRollsBackFinalization() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        vm.mockCallRevert(
            address(offeringEscrow),
            abi.encodeWithSelector(OfferingEscrow.enableProceeds.selector),
            abi.encodeWithSelector(OfferingEscrow.ProceedsAlreadyEnabled.selector)
        );

        vm.expectRevert(OfferingEscrow.ProceedsAlreadyEnabled.selector);
        manager.finalizeOffering(offeringId);

        _assertFinalizationRolledBack(offeringId);
    }

    function testFinalCrossCheckFailureRollsBackEveryActivation() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        revenueVault.setMisreportLifecycle(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.VaultDepositLifecycleMismatch.selector,
                IRevenueVault.DepositLifecycle.Enabled,
                IRevenueVault.DepositLifecycle.Disabled
            )
        );
        manager.finalizeOffering(offeringId);

        revenueVault.setMisreportLifecycle(false);
        _assertFinalizationRolledBack(offeringId);
    }

    function testFinalizationCustodyCrossChecksRejectInconsistentDependencies() public {
        bytes32 offeringId = _prepareFinalizableOffering();
        vm.mockCall(
            address(allocationEscrow),
            abi.encodeWithSelector(IAllocationEscrow.totalDelivered.selector),
            abi.encode(FINAL_SUPPLY - 1)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.FinalizationDeliveredSupplyMismatch.selector, FINAL_SUPPLY, FINAL_SUPPLY - 1
            )
        );
        manager.finalizeOffering(offeringId);

        vm.clearMockedCalls();
        _assertFinalizationRolledBack(offeringId);
    }

    function testDeliveryRejectedBeforeSuccessfulAndAfterFailed() public {
        bytes32 openOfferingId = _subscribeFullOffering();

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                openOfferingId,
                OfferingManager.OfferingStatus.Open,
                OfferingManager.OfferingStatus.Successful
            )
        );
        manager.deliverAllocation(openOfferingId, 0);

        identityRegistry.setLicensee(investor, false);
        vm.warp(manager.getOffering(openOfferingId).config.closesAt);
        manager.reconcileSubscription(openOfferingId, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.InvalidOfferingStatus.selector,
                openOfferingId,
                OfferingManager.OfferingStatus.Failed,
                OfferingManager.OfferingStatus.Successful
            )
        );
        manager.deliverAllocation(openOfferingId, 0);

        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), FINAL_SUPPLY);
    }

    function testDeliveryIsStrictlySequentialAndCannotRepeat() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        _prepareInvestor(secondInvestor, secondDestination);
        vm.prank(investor);
        manager.subscribe(offeringId, 4_000 ether, 0, destination, keccak256("delivery-sequence-0"));
        vm.prank(secondInvestor);
        manager.subscribe(offeringId, 6_000 ether, 0, secondDestination, keccak256("delivery-sequence-1"));
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        manager.reconcileSubscription(offeringId, 1);

        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidDeliverySequence.selector, uint64(0), uint64(1)));
        manager.deliverAllocation(offeringId, 1);

        manager.deliverAllocation(offeringId, 0);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidDeliverySequence.selector, uint64(1), uint64(0)));
        manager.deliverAllocation(offeringId, 0);
        manager.deliverAllocation(offeringId, 1);

        assertEq(manager.getOffering(offeringId).deliveredCount, 2);
        assertEq(allocationEscrow.totalReleased(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(destination), 4_000 ether);
        assertEq(revenueToken.balanceOf(secondDestination), 6_000 ether);
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
    }

    function testDirectAndLegalHoldDeliveryConserveFinalSupply() public {
        bytes32 offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        _prepareInvestor(secondInvestor, secondDestination);
        vm.prank(investor);
        manager.subscribe(offeringId, 4_000 ether, 0, destination, keccak256("direct-allocation"));
        vm.prank(secondInvestor);
        manager.subscribe(offeringId, 6_000 ether, 0, secondDestination, keccak256("held-allocation"));
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        manager.reconcileSubscription(offeringId, 1);
        investorEligibility.setEligible(secondDestination, ASSET_ID, false);
        uint256 contributedBefore = offeringEscrow.totalContributed();

        manager.deliverAllocation(offeringId, 0);
        manager.deliverAllocation(offeringId, 1);

        bytes32 heldSubscription = manager.subscriptionIdBySequence(offeringId, 1);
        address position = manager.getSubscription(heldSubscription).legalHoldPosition;
        assertEq(allocationEscrow.totalReleased(), 4_000 ether);
        assertEq(allocationEscrow.legalHoldTransferred(), 6_000 ether);
        assertEq(allocationEscrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertEq(revenueToken.balanceOf(destination), 4_000 ether);
        assertEq(revenueToken.balanceOf(position), 6_000 ether);
        assertEq(revenueToken.totalSupply(), FINAL_SUPPLY);
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(offeringEscrow.totalContributed(), contributedBefore);
        assertEq(usdc.balanceOf(address(manager)), 0);

        manager.finalizeOffering(offeringId);
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Finalized));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Activated));
        assertEq(revenueToken.balanceOf(position), 6_000 ether);

        investorEligibility.setEligible(secondDestination, ASSET_ID, true);
        manager.releaseLegalHold(offeringId, 1);
        assertEq(revenueToken.balanceOf(position), 0);
        assertEq(revenueToken.balanceOf(secondDestination), 6_000 ether);
    }

    function testIneligibleDestinationEntersRemediationWithoutAddressReplacement() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        investorEligibility.setEligible(destination, ASSET_ID, false);

        manager.deliverAllocation(offeringId, 0);

        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        AllocationEscrow.Allocation memory allocation = allocationEscrow.getAllocation(subscriptionId);
        assertEq(uint256(subscription.status), uint256(OfferingManager.SubscriptionStatus.Remediation));
        assertEq(subscription.invalidReason, manager.INVALID_DESTINATION_ELIGIBILITY());
        assertTrue(subscription.deliveryProcessed);
        assertEq(subscription.destination, destination);
        assertEq(allocation.destination, destination);
        assertFalse(allocation.released);
        assertTrue(allocation.legalHeld);
        assertEq(
            subscription.legalHoldPosition,
            ILegalHoldEscrow(allocationEscrow.legalHoldEscrow()).positionOf(subscriptionId)
        );
        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(allocationEscrow.legalHoldTransferred(), FINAL_SUPPLY);
        assertEq(allocationEscrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertEq(revenueToken.balanceOf(subscription.legalHoldPosition), FINAL_SUPPLY);

        (bool replacementSuccess,) = address(manager)
            .call(
                abi.encodeWithSignature(
                    "deliverAllocation(bytes32,uint64,address)", offeringId, uint64(0), secondDestination
                )
            );
        assertFalse(replacementSuccess);
        assertEq(revenueToken.balanceOf(secondDestination), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.LegalHoldReleaseEligibilityInvalid.selector,
                subscriptionId,
                manager.INVALID_DESTINATION_ELIGIBILITY()
            )
        );
        manager.releaseLegalHold(offeringId, 0);

        uint256 contributedBefore = offeringEscrow.totalContributed();
        uint256 usdcBefore = usdc.balanceOf(address(offeringEscrow));
        investorEligibility.setEligible(destination, ASSET_ID, true);
        vm.prank(outsider);
        manager.releaseLegalHold(offeringId, 0);

        subscription = manager.getSubscription(subscriptionId);
        ILegalHoldEscrow.LegalHoldPosition memory releasedPosition =
            ILegalHoldEscrow(allocationEscrow.legalHoldEscrow()).getPosition(subscriptionId);
        assertGt(subscription.legalHoldReleasedAt, 0);
        assertEq(uint256(releasedPosition.status), uint256(ILegalHoldEscrow.PositionStatus.Released));
        assertEq(revenueToken.balanceOf(subscription.legalHoldPosition), 0);
        assertEq(revenueToken.balanceOf(destination), FINAL_SUPPLY);
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(offeringEscrow.totalContributed(), contributedBefore);
        assertEq(usdc.balanceOf(address(offeringEscrow)), usdcBefore);

        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.LegalHoldPositionAlreadyReleased.selector, subscriptionId)
        );
        manager.releaseLegalHold(offeringId, 0);
    }

    function testLegalHoldRewardMigrationFailureRollsBackTokenAndPosition() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        investorEligibility.setEligible(destination, ASSET_ID, false);
        manager.deliverAllocation(offeringId, 0);
        address position = manager.getSubscription(subscriptionId).legalHoldPosition;

        investorEligibility.setEligible(destination, ASSET_ID, true);
        revenueVault.setCheckpointFailure(true);
        vm.expectRevert(OfferingRevenueVaultMock.CheckpointFailed.selector);
        manager.releaseLegalHold(offeringId, 0);

        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        ILegalHoldEscrow.LegalHoldPosition memory heldPosition =
            ILegalHoldEscrow(allocationEscrow.legalHoldEscrow()).getPosition(subscriptionId);
        assertEq(subscription.legalHoldReleasedAt, 0);
        assertEq(uint256(heldPosition.status), uint256(ILegalHoldEscrow.PositionStatus.Held));
        assertEq(revenueToken.balanceOf(position), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(destination), 0);
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
    }

    function testTokenTransferFailureRollsBackEntireDelivery() public {
        bytes32 offeringId = _subscribeFullOffering();
        bytes32 subscriptionId = manager.subscriptionIdBySequence(offeringId, 0);
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        uint256 contributedBefore = offeringEscrow.totalContributed();
        revenueVault.setCheckpointFailure(true);

        vm.expectRevert(OfferingRevenueVaultMock.CheckpointFailed.selector);
        manager.deliverAllocation(offeringId, 0);

        OfferingManager.Subscription memory subscription = manager.getSubscription(subscriptionId);
        assertEq(manager.getOffering(offeringId).deliveredCount, 0);
        assertFalse(subscription.deliveryProcessed);
        assertEq(subscription.deliveredAt, 0);
        assertFalse(allocationEscrow.getAllocation(subscriptionId).released);
        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(destination), 0);
        assertEq(offeringEscrow.totalContributed(), contributedBefore);
    }

    function testTombstonePropagationFailureRollsBackOutcomeAndRefundGate() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 expectedOfferingId = _expectedOfferingId(config, 0);
        TombstoneFailAllocationEscrow faultEscrow = new TombstoneFailAllocationEscrow(
            address(manager), expectedOfferingId, address(revenueToken), FINAL_SUPPLY
        );
        investorEligibility.setEligible(address(faultEscrow), ASSET_ID, true);
        config.allocationEscrow = address(faultEscrow);
        vm.prank(assetOwner);
        bytes32 offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
        vm.warp(config.closesAt);

        vm.expectRevert(TombstoneFailAllocationEscrow.TombstoneFailed.selector);
        manager.resolveOfferingOutcome(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Open));
        assertFalse(offeringEscrow.refundable());
        assertFalse(faultEscrow.tombstoned());
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
    }

    function testProgramFailureDependencyRollbackRestoresManagerAndEscrows() public {
        bytes32 offeringId = _openOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        bytes32 programManagerRole = programRegistry.PROGRAM_MANAGER_ROLE();
        vm.prank(admin);
        programRegistry.revokeRole(programManagerRole, address(manager));

        vm.expectRevert();
        manager.resolveOfferingOutcome(offeringId);

        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Open));
        assertFalse(offeringEscrow.refundable());
        assertFalse(allocationEscrow.tombstoned());
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);
    }

    function testProgramBindingMismatchRollsBackDraftAndCreatorNonce() public {
        MismatchedRevenueProgramRegistry mismatchedRegistry = new MismatchedRevenueProgramRegistry(outsider);
        OfferingManager mismatchedManager = new OfferingManager(
            admin,
            address(identityRegistry),
            address(assetRegistry),
            address(issuerEligibility),
            address(mismatchedRegistry)
        );
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 expectedOfferingId = keccak256(
            abi.encode(
                block.chainid,
                address(mismatchedManager),
                address(assetRegistry),
                config.assetId,
                assetOwner,
                config.issuer,
                uint256(0),
                config.termsHash
            )
        );

        vm.prank(assetOwner);
        vm.expectRevert(
            abi.encodeWithSelector(OfferingManager.RevenueProgramBindingMismatch.selector, expectedOfferingId)
        );
        mismatchedManager.createOffering(config);

        assertEq(mismatchedManager.creatorNonce(assetOwner), 0);
        assertEq(mismatchedRegistry.liveOfferingByAsset(ASSET_ID), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.OfferingNotFound.selector, expectedOfferingId));
        mismatchedManager.getOffering(expectedOfferingId);
    }

    function testReconciliationDependencyFailureDoesNotConsumeState() public {
        bytes32 offeringId = _subscribeFullOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        investorEligibility.setReconciliationFailure(true);

        vm.expectRevert(OfferingInvestorEligibilityMock.EligibilityCheckFailed.selector);
        manager.reconcileSubscription(offeringId, 0);

        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        OfferingManager.Subscription memory subscription =
            manager.getSubscription(manager.subscriptionIdBySequence(offeringId, 0));
        assertEq(offering.reconciledCount, 0);
        assertEq(offering.validSoldSupply, 0);
        assertEq(uint256(subscription.status), uint256(OfferingManager.SubscriptionStatus.Committed));
    }

    function testInvalidAllocationLotRejectedAtCreation() public {
        OfferingManager.OfferingConfig memory config = _validConfig();
        config.allocationLot = 3 ether;

        vm.prank(assetOwner);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidAllocationLot.selector, 3 ether, FINAL_SUPPLY));
        manager.createOffering(config);
    }

    function testCannotOpenBeforeWindow() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                OfferingManager.OfferingNotOpenYet.selector, block.timestamp, offering.config.opensAt
            )
        );
        manager.openOffering(offeringId);
    }

    function _createOffering() private returns (bytes32 offeringId) {
        OfferingManager.OfferingConfig memory config = _validConfig();
        vm.prank(assetOwner);
        offeringId = manager.createOffering(config);
    }

    function _openOffering() private returns (bytes32 offeringId) {
        offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        vm.warp(offering.config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
    }

    function _prepareInvestor(address payer, address tokenDestination) private {
        identityRegistry.setLicensee(payer, true);
        investorEligibility.setEligible(payer, ASSET_ID, true);
        investorEligibility.setEligible(tokenDestination, ASSET_ID, true);
        usdc.mint(payer, 100_000 * 1_000_000);
        vm.prank(payer);
        usdc.approve(address(offeringEscrow), type(uint256).max);
    }

    function _openWithSubscriptionAllocationFault(bool failRegistration, bool misreportTotal)
        private
        returns (bytes32 offeringId, SubscriptionAllocationEscrowFault faultEscrow)
    {
        OfferingManager.OfferingConfig memory config = _validConfig();
        bytes32 expectedOfferingId = _expectedOfferingId(config, 0);
        faultEscrow = new SubscriptionAllocationEscrowFault(
            address(manager), expectedOfferingId, address(revenueToken), FINAL_SUPPLY, failRegistration, misreportTotal
        );
        investorEligibility.setEligible(address(faultEscrow), ASSET_ID, true);
        config.allocationEscrow = address(faultEscrow);
        vm.prank(assetOwner);
        offeringId = manager.createOffering(config);
        vm.warp(config.opensAt);
        vm.prank(operator);
        manager.openOffering(offeringId);
    }

    function _subscribeFullOffering() private returns (bytes32 offeringId) {
        offeringId = _openOffering();
        _prepareInvestor(investor, destination);
        vm.prank(investor);
        manager.subscribe(offeringId, FINAL_SUPPLY, FINAL_SUPPLY, destination, keccak256("full"));
    }

    function _prepareFinalizableOffering() private returns (bytes32 offeringId) {
        offeringId = _subscribeFullOffering();
        vm.warp(manager.getOffering(offeringId).config.closesAt);
        manager.reconcileSubscription(offeringId, 0);
        manager.deliverAllocation(offeringId, 0);
    }

    function _assertFinalizationRolledBack(bytes32 offeringId) private view {
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Successful));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
        assertEq(
            uint256(programRegistry.getProgram(offeringId).status),
            uint256(IRevenueProgramRegistry.ProgramStatus.Reserved)
        );
        assertEq(programRegistry.liveOfferingByAsset(ASSET_ID), offeringId);
        assertEq(uint256(revenueVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Disabled));
        assertFalse(offeringEscrow.proceedsEnabled());
        assertEq(offeringEscrow.issuerProceeds(), 0);
        assertEq(offeringEscrow.protocolFee(), 0);
        assertEq(usdc.balanceOf(address(offeringEscrow)), offeringEscrow.totalContributed());
        assertEq(allocationEscrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertEq(revenueToken.balanceOf(address(manager)), 0);
        assertEq(usdc.balanceOf(address(manager)), 0);
    }

    function _assertOpenRolledBack(bytes32 offeringId) private view {
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertFalse(revenueToken.hasRole(revenueToken.MINTER_ROLE(), address(manager)));
        assertEq(revenueToken.primaryDistributionEscrow(), address(0));
    }

    function _validConfig() private view returns (OfferingManager.OfferingConfig memory config) {
        config = OfferingManager.OfferingConfig({
            assetId: ASSET_ID,
            issuer: issuer,
            issuerTreasury: issuerTreasury,
            revenueToken: address(revenueToken),
            revenueVault: address(revenueVault),
            allocationEscrow: address(allocationEscrow),
            offeringEscrow: address(offeringEscrow),
            investorEligibility: address(investorEligibility),
            recoveryManager: address(recoveryManager),
            settlementToken: address(usdc),
            finalSupply: FINAL_SUPPLY,
            allocationLot: 1 ether,
            pricePerWholeTokenUSDC: PRICE,
            protocolFeeBps: 250,
            feeRecipient: feeRecipient,
            opensAt: uint64(block.timestamp + 1 days),
            closesAt: uint64(block.timestamp + 8 days),
            termsHash: keccak256("offering-terms"),
            disclosureHash: keccak256("offering-disclosure")
        });
    }

    function _expectedOfferingId(OfferingManager.OfferingConfig memory config, uint256 nonce)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                block.chainid,
                address(manager),
                address(assetRegistry),
                config.assetId,
                assetOwner,
                config.issuer,
                nonce,
                config.termsHash
            )
        );
    }
}

contract OfferingIdentityMock is IIdentityRegistry {
    uint256 public constant ROLE_ASSET_OWNER = 1 << 0;
    uint256 public constant ROLE_LICENSEE = 1 << 1;
    uint256 public constant ROLE_VERIFIER = 1 << 3;
    uint256 public constant ROLE_ARBITRATOR = 1 << 4;

    mapping(address account => bool validAssetOwner) private _assetOwners;
    mapping(address account => bool validLicensee) private _licensees;

    function setAssetOwner(address account, bool valid) external {
        _assetOwners[account] = valid;
    }

    function setLicensee(address account, bool valid) external {
        _licensees[account] = valid;
    }

    function hasBusinessRole(address account, uint256 roleMask) external view returns (bool) {
        if (roleMask == ROLE_ASSET_OWNER) return _assetOwners[account];
        if (roleMask == ROLE_LICENSEE) return _licensees[account];
        return false;
    }
}

contract OfferingAssetRegistryMock is IIPAssetRegistry {
    mapping(uint256 assetId => address owner) private _owners;

    function setAsset(uint256 assetId, address owner) external {
        _owners[assetId] = owner;
    }

    function ownerOf(uint256 assetId) external view returns (address) {
        return _owners[assetId];
    }

    function exists(uint256 assetId) external view returns (bool) {
        return _owners[assetId] != address(0);
    }
}

contract IssuerEligibilityMock is IIssuerEligibility {
    mapping(address issuer => bool eligible) private _eligibility;

    function setEligible(address issuer, bool eligible) external {
        _eligibility[issuer] = eligible;
    }

    function isEligibleIssuer(address issuer) external view returns (bool) {
        return _eligibility[issuer];
    }
}

contract SixDecimalUSDCMock is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OfferingInvestorEligibilityMock is IInvestorEligibility {
    mapping(uint256 assetId => mapping(address account => bool eligible)) private _eligibility;
    bool private _reconciliationFailure;

    error EligibilityCheckFailed();

    function setEligible(address account, uint256 assetId, bool eligible) external {
        _eligibility[assetId][account] = eligible;
    }

    function setReconciliationFailure(bool shouldFail) external {
        _reconciliationFailure = shouldFail;
    }

    function canHold(address account, uint256 assetId) external view returns (bool) {
        if (_reconciliationFailure) revert EligibilityCheckFailed();
        return _eligibility[assetId][account];
    }
}

contract OfferingRevenueVaultMock is IRevenueVault {
    IERC20 public immutable revenueToken;
    address public immutable activationController;
    DepositLifecycle private _depositLifecycle;
    bool private _checkpointFailure;
    bool private _enableFailure;
    bool private _misreportLifecycle;

    error UnauthorizedToken();
    error UnauthorizedActivationController();
    error CheckpointFailed();
    error EnableFailed();
    error TokenNotActivated();

    constructor(address revenueToken_, address activationController_) {
        revenueToken = IERC20(revenueToken_);
        activationController = activationController_;
    }

    function enableDeposits() external {
        if (_enableFailure) revert EnableFailed();
        if (msg.sender != activationController) revert UnauthorizedActivationController();
        if (LicenseRevenueToken(address(revenueToken)).lifecycle() != LicenseRevenueToken.Lifecycle.Activated) {
            revert TokenNotActivated();
        }
        _depositLifecycle = DepositLifecycle.Enabled;
    }

    function depositLifecycle() external view returns (DepositLifecycle) {
        if (_misreportLifecycle) return DepositLifecycle.Disabled;
        return _depositLifecycle;
    }

    function setEnableFailure(bool shouldFail) external {
        _enableFailure = shouldFail;
    }

    function setMisreportLifecycle(bool shouldMisreport) external {
        _misreportLifecycle = shouldMisreport;
    }

    function setCheckpointFailure(bool shouldFail) external {
        _checkpointFailure = shouldFail;
    }

    function checkpointTransfer(address, address, uint256) external view {
        if (msg.sender != address(revenueToken)) revert UnauthorizedToken();
        if (_checkpointFailure) revert CheckpointFailed();
    }

    function checkpointRecovery(address, address, uint256) external view {
        if (msg.sender != address(revenueToken)) revert UnauthorizedToken();
    }

    function checkpointLegalHoldRelease(address, address, uint256) external view {
        if (msg.sender != address(revenueToken)) revert UnauthorizedToken();
        if (_checkpointFailure) revert CheckpointFailed();
    }
}

contract OfferingRecoveryManagerMock is IRecoveryManager {
    function isExecutionAuthorized(bytes32, address, address, address) external pure returns (bool) {
        return false;
    }
}

contract FaultingAllocationEscrow is IAllocationEscrow {
    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;
    bool public depositConfirmed;
    bool public tombstoned;
    uint256 public totalAllocated;
    uint256 public totalReleased;
    uint256 public legalHoldTransferred;
    address public legalHoldEscrow;
    bool private immutable _confirmationFailure;
    bool private immutable _refuseConfirmation;

    error ConfirmationFailed();

    constructor(
        address offeringManager_,
        bytes32 offeringId_,
        address revenueToken_,
        uint256 finalSupply_,
        bool confirmationFailure_,
        bool refuseConfirmation_
    ) {
        offeringManager = offeringManager_;
        offeringId = offeringId_;
        revenueToken = revenueToken_;
        finalSupply = finalSupply_;
        _confirmationFailure = confirmationFailure_;
        _refuseConfirmation = refuseConfirmation_;
    }

    function confirmTokenDeposit() external {
        if (_confirmationFailure) revert ConfirmationFailed();
        if (!_refuseConfirmation) {
            depositConfirmed = true;
        }
    }

    function registerAllocation(bytes32, bytes32, address, uint256, uint64) external {}

    function releaseAllocation(bytes32) external {}

    function holdAllocation(bytes32) external pure returns (address position) {
        return address(0);
    }

    function totalDelivered() external view returns (uint256) {
        return totalReleased + legalHoldTransferred;
    }

    function tombstone() external {
        tombstoned = true;
    }
}

contract SubscriptionAllocationEscrowFault is IAllocationEscrow {
    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;
    bool public depositConfirmed;
    bool public tombstoned;
    uint256 public totalAllocated;
    uint256 public totalReleased;
    uint256 public legalHoldTransferred;
    address public legalHoldEscrow;

    bool private immutable _failRegistration;
    bool private immutable _misreportTotal;

    error RegistrationFailed();

    constructor(
        address offeringManager_,
        bytes32 offeringId_,
        address revenueToken_,
        uint256 finalSupply_,
        bool failRegistration_,
        bool misreportTotal_
    ) {
        offeringManager = offeringManager_;
        offeringId = offeringId_;
        revenueToken = revenueToken_;
        finalSupply = finalSupply_;
        _failRegistration = failRegistration_;
        _misreportTotal = misreportTotal_;
    }

    function confirmTokenDeposit() external {
        depositConfirmed = true;
    }

    function registerAllocation(bytes32, bytes32, address, uint256 amount, uint64) external {
        if (_failRegistration) revert RegistrationFailed();
        totalAllocated += amount;
        if (_misreportTotal) totalAllocated += 1;
    }

    function releaseAllocation(bytes32) external {}

    function holdAllocation(bytes32) external pure returns (address position) {
        return address(0);
    }

    function totalDelivered() external view returns (uint256) {
        return totalReleased + legalHoldTransferred;
    }

    function tombstone() external {
        tombstoned = true;
    }
}

contract TombstoneFailAllocationEscrow is IAllocationEscrow {
    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;
    bool public depositConfirmed;
    bool public tombstoned;
    uint256 public totalAllocated;
    uint256 public totalReleased;
    uint256 public legalHoldTransferred;
    address public legalHoldEscrow;

    error TombstoneFailed();

    constructor(address offeringManager_, bytes32 offeringId_, address revenueToken_, uint256 finalSupply_) {
        offeringManager = offeringManager_;
        offeringId = offeringId_;
        revenueToken = revenueToken_;
        finalSupply = finalSupply_;
    }

    function confirmTokenDeposit() external {
        depositConfirmed = true;
    }

    function registerAllocation(bytes32, bytes32, address, uint256 amount, uint64) external {
        totalAllocated += amount;
    }

    function releaseAllocation(bytes32) external {}

    function holdAllocation(bytes32) external pure returns (address position) {
        return address(0);
    }

    function totalDelivered() external view returns (uint256) {
        return totalReleased + legalHoldTransferred;
    }

    function tombstone() external pure {
        revert TombstoneFailed();
    }
}

contract MismatchedRevenueProgramRegistry is IRevenueProgramRegistry {
    address private immutable _wrongRevenueToken;
    RevenueProgram private _program;
    mapping(uint256 assetId => bytes32 offeringId) private _liveOfferings;

    constructor(address wrongRevenueToken_) {
        _wrongRevenueToken = wrongRevenueToken_;
    }

    function reserveProgram(
        bytes32 offeringId,
        uint256 assetId,
        address issuer,
        address,
        address revenueVault,
        address settlementToken
    ) external {
        _program = RevenueProgram({
            assetId: assetId,
            offeringId: offeringId,
            issuer: issuer,
            revenueToken: _wrongRevenueToken,
            revenueVault: revenueVault,
            settlementToken: settlementToken,
            status: ProgramStatus.Reserved,
            reservedAt: uint64(block.timestamp),
            activatedAt: 0,
            failedAt: 0
        });
        _liveOfferings[assetId] = offeringId;
    }

    function activateProgram(bytes32) external {}

    function failProgram(bytes32) external {}

    function getProgram(bytes32) external view returns (RevenueProgram memory) {
        return _program;
    }

    function liveOfferingByAsset(uint256 assetId) external view returns (bytes32) {
        return _liveOfferings[assetId];
    }

    function activeOfferingByAsset(uint256) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract DependencyMock {}
