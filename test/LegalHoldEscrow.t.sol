// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AllocationEscrow} from "../contracts/AllocationEscrow.sol";
import {LegalHoldEscrow} from "../contracts/LegalHoldEscrow.sol";
import {ILegalHoldEscrow} from "../contracts/interfaces/ILegalHoldEscrow.sol";
import {IIPAssetRegistry} from "../contracts/interfaces/IIPAssetRegistry.sol";
import {IInvestorEligibility} from "../contracts/interfaces/IInvestorEligibility.sol";
import {IRecoveryManager} from "../contracts/interfaces/IRecoveryManager.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {RevenueVault} from "../contracts/RevenueVault.sol";

contract LegalHoldEscrowTest is Test {
    uint256 private constant ASSET_ID = 1;
    uint256 private constant FINAL_SUPPLY = 1_000 ether;
    bytes32 private constant OFFERING_ID = keccak256("legal-hold-offering");

    LegalHoldManagerHarness private manager;
    LegalHoldAssetRegistryMock private assetRegistry;
    LegalHoldEligibilityMock private eligibility;
    LegalHoldRecoveryManagerMock private recoveryManager;
    LegalHoldSettlementToken private settlementToken;
    LicenseRevenueToken private revenueToken;
    RevenueVault private revenueVault;
    AllocationEscrow private allocationEscrow;
    ILegalHoldEscrow private legalHoldEscrow;

    address private depositor = makeAddr("depositor");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private outsider = makeAddr("outsider");

    function setUp() public {
        manager = new LegalHoldManagerHarness();
        assetRegistry = new LegalHoldAssetRegistryMock();
        eligibility = new LegalHoldEligibilityMock();
        recoveryManager = new LegalHoldRecoveryManagerMock();
        settlementToken = new LegalHoldSettlementToken();
        assetRegistry.setExists(ASSET_ID, true);

        revenueToken = new LicenseRevenueToken(
            "Legal Hold Revenue",
            "LHREV",
            address(assetRegistry),
            ASSET_ID,
            FINAL_SUPPLY,
            address(eligibility),
            address(manager)
        );
        revenueVault = new RevenueVault(address(revenueToken), address(settlementToken), address(this), depositor);
        allocationEscrow = new AllocationEscrow(address(manager), OFFERING_ID, address(revenueToken), FINAL_SUPPLY);
        legalHoldEscrow = ILegalHoldEscrow(allocationEscrow.legalHoldEscrow());

        eligibility.setEligible(address(allocationEscrow), ASSET_ID, true);
        manager.prepareToken(
            revenueToken, address(revenueVault), address(recoveryManager), address(allocationEscrow), FINAL_SUPPLY
        );
        manager.setOfferingStatus(OFFERING_ID, 1);
        manager.confirmDeposit(allocationEscrow);
        manager.setOfferingStatus(OFFERING_ID, 2);
    }

    function testHistoricalRevenueEntitlementMigratesWithReleasedPosition() public {
        bytes32 subscriptionId = keccak256("alice-full-position");
        manager.registerAllocation(allocationEscrow, subscriptionId, alice, FINAL_SUPPLY, 0);
        manager.setOfferingStatus(OFFERING_ID, 3);
        address position = manager.holdAllocation(allocationEscrow, subscriptionId);
        _depositRevenue(100 ether);

        assertEq(revenueVault.claimable(position), 100 ether);
        assertEq(revenueVault.claimable(alice), 0);
        uint256 vaultBalanceBefore = settlementToken.balanceOf(address(revenueVault));

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(LegalHoldEscrow.UnauthorizedOfferingManager.selector, outsider));
        legalHoldEscrow.releasePosition(subscriptionId);

        vm.expectRevert(abi.encodeWithSelector(LicenseRevenueToken.IneligibleInvestor.selector, alice));
        manager.releasePosition(legalHoldEscrow, subscriptionId);

        assertEq(
            uint256(legalHoldEscrow.getPosition(subscriptionId).status), uint256(ILegalHoldEscrow.PositionStatus.Held)
        );
        assertEq(revenueToken.balanceOf(position), FINAL_SUPPLY);

        eligibility.setEligible(alice, ASSET_ID, true);
        manager.releasePosition(legalHoldEscrow, subscriptionId);

        ILegalHoldEscrow.LegalHoldPosition memory released = legalHoldEscrow.getPosition(subscriptionId);
        assertEq(uint256(released.status), uint256(ILegalHoldEscrow.PositionStatus.Released));
        assertEq(released.beneficialOwner, alice);
        assertEq(revenueToken.balanceOf(position), 0);
        assertEq(revenueToken.balanceOf(alice), FINAL_SUPPLY);
        assertEq(revenueVault.pendingReward(position), 0);
        assertEq(revenueVault.rewardDebt(position), 0);
        assertEq(revenueVault.claimable(position), 0);
        assertEq(revenueVault.claimable(alice), 100 ether);
        assertEq(settlementToken.balanceOf(address(revenueVault)), vaultBalanceBefore);
        assertEq(revenueVault.totalDeposited(), 100 ether);
        assertEq(revenueVault.totalClaimed(), 0);
        assertTrue(revenueVault.isSolvent());
        assertEq(uint256(revenueToken.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));

        vm.expectRevert(
            abi.encodeWithSelector(
                LegalHoldEscrow.PositionNotHeld.selector, subscriptionId, ILegalHoldEscrow.PositionStatus.Released
            )
        );
        manager.releasePosition(legalHoldEscrow, subscriptionId);
    }

    function testMultiplePositionsRemainEconomicallyIsolated() public {
        bytes32 aliceSubscription = keccak256("alice-half");
        bytes32 bobSubscription = keccak256("bob-half");
        manager.registerAllocation(allocationEscrow, aliceSubscription, alice, FINAL_SUPPLY / 2, 0);
        manager.registerAllocation(allocationEscrow, bobSubscription, bob, FINAL_SUPPLY / 2, 1);
        manager.setOfferingStatus(OFFERING_ID, 3);
        address alicePosition = manager.holdAllocation(allocationEscrow, aliceSubscription);
        address bobPosition = manager.holdAllocation(allocationEscrow, bobSubscription);
        _depositRevenue(100 ether);

        assertTrue(alicePosition != bobPosition);
        assertEq(revenueVault.claimable(alicePosition), 50 ether);
        assertEq(revenueVault.claimable(bobPosition), 50 ether);
        assertEq(allocationEscrow.totalReleased(), 0);
        assertEq(allocationEscrow.legalHoldTransferred(), FINAL_SUPPLY);
        assertEq(allocationEscrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(revenueToken.balanceOf(address(allocationEscrow)), 0);

        eligibility.setEligible(alice, ASSET_ID, true);
        manager.releasePosition(legalHoldEscrow, aliceSubscription);

        assertEq(revenueToken.balanceOf(alice), FINAL_SUPPLY / 2);
        assertEq(revenueVault.claimable(alice), 50 ether);
        assertEq(revenueVault.claimable(alicePosition), 0);
        assertEq(revenueToken.balanceOf(bobPosition), FINAL_SUPPLY / 2);
        assertEq(revenueVault.claimable(bobPosition), 50 ether);
        assertEq(
            uint256(legalHoldEscrow.getPosition(bobSubscription).status), uint256(ILegalHoldEscrow.PositionStatus.Held)
        );
        assertEq(revenueVault.totalDeposited(), 100 ether);
        assertEq(revenueVault.totalClaimed(), 0);
        assertTrue(revenueVault.isSolvent());
    }

    function testPositionMetadataCannotBeReplacedOrDuplicated() public {
        bytes32 subscriptionId = keccak256("immutable-position");
        manager.registerAllocation(allocationEscrow, subscriptionId, alice, 100 ether, 0);
        manager.setOfferingStatus(OFFERING_ID, 3);
        address position = manager.holdAllocation(allocationEscrow, subscriptionId);

        ILegalHoldEscrow.LegalHoldPosition memory held = legalHoldEscrow.getPosition(subscriptionId);
        assertEq(held.offeringId, OFFERING_ID);
        assertEq(held.subscriptionId, subscriptionId);
        assertEq(held.beneficialOwner, alice);
        assertEq(held.position, position);
        assertEq(held.amount, 100 ether);
        assertEq(held.sequence, 0);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationAlreadyHeld.selector, subscriptionId));
        manager.holdAllocation(allocationEscrow, subscriptionId);

        (bool replacementSuccess,) = address(legalHoldEscrow)
            .call(abi.encodeWithSignature("replaceBeneficialOwner(bytes32,address)", subscriptionId, bob));
        assertFalse(replacementSuccess);
        assertEq(legalHoldEscrow.getPosition(subscriptionId).beneficialOwner, alice);
    }

    function _depositRevenue(uint256 amount) private {
        settlementToken.mint(depositor, amount);
        vm.prank(depositor);
        settlementToken.approve(address(revenueVault), amount);
        vm.prank(depositor);
        revenueVault.depositRevenue(amount);
    }
}

contract LegalHoldManagerHarness {
    mapping(bytes32 offeringId => uint8 status) private _statuses;

    function getOfferingStatus(bytes32 offeringId) external view returns (uint8) {
        return _statuses[offeringId];
    }

    function setOfferingStatus(bytes32 offeringId, uint8 status) external {
        _statuses[offeringId] = status;
    }

    function prepareToken(
        LicenseRevenueToken token,
        address vault,
        address recoveryManager,
        address allocationEscrow,
        uint256 finalSupply
    ) external {
        token.bindRevenueVault(vault);
        token.bindRecoveryManager(recoveryManager);
        token.bindPrimaryDistributionEscrow(allocationEscrow);
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.beginMinting();
        token.mint(allocationEscrow, finalSupply);
        token.revokeRole(token.MINTER_ROLE(), address(this));
    }

    function confirmDeposit(AllocationEscrow escrow) external {
        escrow.confirmTokenDeposit();
    }

    function registerAllocation(
        AllocationEscrow escrow,
        bytes32 subscriptionId,
        address beneficialOwner,
        uint256 amount,
        uint64 sequence
    ) external {
        escrow.registerAllocation(
            subscriptionId, keccak256(abi.encode(beneficialOwner, subscriptionId)), beneficialOwner, amount, sequence
        );
    }

    function holdAllocation(AllocationEscrow escrow, bytes32 subscriptionId) external returns (address position) {
        return escrow.holdAllocation(subscriptionId);
    }

    function releasePosition(ILegalHoldEscrow escrow, bytes32 subscriptionId) external {
        escrow.releasePosition(subscriptionId);
    }
}

contract LegalHoldAssetRegistryMock is IIPAssetRegistry {
    mapping(uint256 assetId => bool exists_) private _exists;

    function setExists(uint256 assetId, bool exists_) external {
        _exists[assetId] = exists_;
    }

    function exists(uint256 assetId) external view returns (bool) {
        return _exists[assetId];
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(1);
    }
}

contract LegalHoldEligibilityMock is IInvestorEligibility {
    mapping(uint256 assetId => mapping(address account => bool eligible)) private _eligible;

    function setEligible(address account, uint256 assetId, bool eligible) external {
        _eligible[assetId][account] = eligible;
    }

    function canHold(address account, uint256 assetId) external view returns (bool) {
        return _eligible[assetId][account];
    }
}

contract LegalHoldRecoveryManagerMock is IRecoveryManager {
    function isExecutionAuthorized(bytes32, address, address, address) external pure returns (bool) {
        return false;
    }
}

contract LegalHoldSettlementToken is ERC20 {
    constructor() ERC20("Legal Hold Settlement", "LHUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
