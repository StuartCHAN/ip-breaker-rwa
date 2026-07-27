// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AllocationEscrow} from "../contracts/AllocationEscrow.sol";
import {OfferingEscrow} from "../contracts/OfferingEscrow.sol";
import {OfferingManager, IIssuerEligibility} from "../contracts/OfferingManager.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {IAllocationEscrow} from "../contracts/interfaces/IAllocationEscrow.sol";
import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IInvestorEligibility} from "../contracts/interfaces/IInvestorEligibility.sol";
import {IIPAssetRegistry} from "../contracts/interfaces/IIPAssetRegistry.sol";
import {IRecoveryManager} from "../contracts/interfaces/IRecoveryManager.sol";
import {IRevenueVault} from "../contracts/interfaces/IRevenueVault.sol";

contract OfferingManagerTest is Test {
    OfferingManager private manager;
    OfferingIdentityMock private identityRegistry;
    OfferingAssetRegistryMock private assetRegistry;
    IssuerEligibilityMock private issuerEligibility;
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

        manager =
            new OfferingManager(admin, address(identityRegistry), address(assetRegistry), address(issuerEligibility));
        bytes32 operatorRole = manager.OFFERING_OPERATOR_ROLE();
        vm.prank(admin);
        manager.grantRole(operatorRole, operator);

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
        revenueVault = new OfferingRevenueVaultMock(address(revenueToken));
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
        OfferingRevenueVaultMock foreignVault = new OfferingRevenueVaultMock(address(foreignControlledToken));
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
        assertEq(offering.soldSupply, FINAL_SUPPLY);
        assertEq(offering.validSoldSupply, 0);
        assertEq(offering.validCommittedUSDC, 0);
        assertEq(subscription.invalidReason, manager.INVALID_PAYER_IDENTITY());
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

    function _assertOpenRolledBack(bytes32 offeringId) private view {
        assertEq(uint256(manager.getOfferingStatus(offeringId)), uint256(OfferingManager.OfferingStatus.Draft));
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
        assertEq(revenueToken.totalSupply(), 0);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);
        assertFalse(revenueToken.hasRole(revenueToken.MINTER_ROLE(), address(manager)));
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
    bool private _checkpointFailure;

    error UnauthorizedToken();
    error CheckpointFailed();

    constructor(address revenueToken_) {
        revenueToken = IERC20(revenueToken_);
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
    uint256 public totalAllocated;
    uint256 public totalReleased;
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
}

contract SubscriptionAllocationEscrowFault is IAllocationEscrow {
    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;
    bool public depositConfirmed;
    uint256 public totalAllocated;
    uint256 public totalReleased;

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
}

contract DependencyMock {}
