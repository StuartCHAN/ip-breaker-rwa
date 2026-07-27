// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {RevenueVault} from "../contracts/RevenueVault.sol";
import {ILicenseRevenueTokenLifecycle} from "../contracts/interfaces/ILicenseRevenueTokenLifecycle.sol";
import {IRevenueVault} from "../contracts/interfaces/IRevenueVault.sol";

contract RevenueVaultTest is Test {
    LifecycleERC20Mock private revenueToken;
    ERC20Mock private settlementToken;
    RevenueVault private vault;

    address private admin = makeAddr("admin");
    address private depositor = makeAddr("depositor");
    address private activationController = makeAddr("activation-controller");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private outsider = makeAddr("outsider");

    uint256 private constant ALICE_SHARES = 600 ether;
    uint256 private constant BOB_SHARES = 400 ether;

    event DepositsEnabled(address indexed activationController);

    function setUp() public {
        revenueToken = new LifecycleERC20Mock();
        settlementToken = new ERC20Mock();

        revenueToken.mint(alice, ALICE_SHARES);
        revenueToken.mint(bob, BOB_SHARES);

        vault =
            new RevenueVault(address(revenueToken), address(settlementToken), admin, depositor, activationController);
        revenueToken.setLifecycle(ILicenseRevenueTokenLifecycle.Lifecycle.Activated);
        vm.prank(activationController);
        vault.enableDeposits();

        settlementToken.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        settlementToken.approve(address(vault), type(uint256).max);
    }

    function testConstructorBindsTokenPairAndRoles() public view {
        assertEq(address(vault.revenueToken()), address(revenueToken));
        assertEq(address(vault.settlementToken()), address(settlementToken));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.REVENUE_DEPOSITOR_ROLE(), depositor));
        assertEq(vault.activationController(), activationController);
        assertEq(uint256(vault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Enabled));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(RevenueVault.ZeroRevenueToken.selector);
        new RevenueVault(address(0), address(settlementToken), admin, depositor, activationController);

        vm.expectRevert(RevenueVault.ZeroSettlementToken.selector);
        new RevenueVault(address(revenueToken), address(0), admin, depositor, activationController);

        vm.expectRevert(RevenueVault.ZeroAdmin.selector);
        new RevenueVault(address(revenueToken), address(settlementToken), address(0), depositor, activationController);

        vm.expectRevert(RevenueVault.ZeroDepositor.selector);
        new RevenueVault(address(revenueToken), address(settlementToken), admin, address(0), activationController);

        vm.expectRevert(RevenueVault.ZeroActivationController.selector);
        new RevenueVault(address(revenueToken), address(settlementToken), admin, depositor, address(0));
    }

    function testDepositRejectedWhileDisabled() public {
        RevenueVault disabledVault = _newDisabledVault();
        vm.prank(depositor);
        settlementToken.approve(address(disabledVault), 1 ether);

        vm.prank(depositor);
        vm.expectRevert(RevenueVault.DepositsDisabled.selector);
        disabledVault.depositRevenue(1 ether);

        assertEq(disabledVault.totalDeposited(), 0);
        assertEq(settlementToken.balanceOf(address(disabledVault)), 0);
    }

    function testUnauthorizedEnableAndAdminBypassRejected() public {
        RevenueVault disabledVault = _newDisabledVault();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.UnauthorizedActivationController.selector, outsider));
        disabledVault.enableDeposits();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.UnauthorizedActivationController.selector, admin));
        disabledVault.enableDeposits();

        assertEq(uint256(disabledVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Disabled));
    }

    function testEnableBeforeTokenActivationRejectedWithoutMutation() public {
        revenueToken.setLifecycle(ILicenseRevenueTokenLifecycle.Lifecycle.Minting);
        RevenueVault disabledVault = _newDisabledVault();

        vm.prank(activationController);
        vm.expectRevert(
            abi.encodeWithSelector(
                RevenueVault.RevenueTokenNotActivated.selector, ILicenseRevenueTokenLifecycle.Lifecycle.Minting
            )
        );
        disabledVault.enableDeposits();

        assertEq(uint256(disabledVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Disabled));
        assertEq(disabledVault.totalDeposited(), 0);
    }

    function testSuccessfulEnableIsOneWayAndAllowsDeposit() public {
        RevenueVault disabledVault = _newDisabledVault();
        vm.expectEmit(true, false, false, true, address(disabledVault));
        emit DepositsEnabled(activationController);
        vm.prank(activationController);
        disabledVault.enableDeposits();

        assertEq(uint256(disabledVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Enabled));

        vm.prank(activationController);
        vm.expectRevert(RevenueVault.DepositsAlreadyEnabled.selector);
        disabledVault.enableDeposits();

        vm.prank(depositor);
        settlementToken.approve(address(disabledVault), 100 ether);
        vm.prank(depositor);
        disabledVault.depositRevenue(100 ether);
        assertEq(disabledVault.totalDeposited(), 100 ether);
    }

    function testCheckpointsRemainUsableWhileDepositsDisabled() public {
        RevenueVault disabledVault = _newDisabledVault();

        revenueToken.checkpointTransfer(disabledVault, alice, bob, 1 ether);
        revenueToken.checkpointRecovery(disabledVault, alice, outsider, ALICE_SHARES);
        revenueToken.checkpointLegalHoldRelease(disabledVault, bob, outsider, BOB_SHARES);

        assertEq(disabledVault.rewardDebt(alice), 0);
        assertEq(disabledVault.rewardDebt(bob), 0);
        assertEq(disabledVault.pendingReward(alice), 0);
        assertEq(disabledVault.pendingReward(bob), 0);
        assertEq(uint256(disabledVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Disabled));
    }

    function testClaimRemainsUsableWhileDepositsDisabled() public {
        RevenueVaultHarness disabledVault = new RevenueVaultHarness(
            address(revenueToken), address(settlementToken), admin, depositor, activationController
        );
        disabledVault.seedClaim(alice, 25 ether);
        settlementToken.mint(address(disabledVault), 25 ether);

        vm.prank(alice);
        assertEq(disabledVault.claim(), 25 ether);

        assertEq(settlementToken.balanceOf(alice), 25 ether);
        assertEq(disabledVault.totalClaimed(), 25 ether);
        assertEq(uint256(disabledVault.depositLifecycle()), uint256(IRevenueVault.DepositLifecycle.Disabled));
    }

    function testAuthorizedDepositorUpdatesAccumulatorAndCustody() public {
        uint256 amount = 1_000 ether;
        _deposit(amount);

        uint256 expectedAccumulator = amount * vault.ACCUMULATOR_PRECISION() / revenueToken.totalSupply();
        assertEq(vault.accumulatedRewardPerShare(), expectedAccumulator);
        assertEq(vault.precisionRemainder(), 0);
        assertEq(vault.totalDeposited(), amount);
        assertEq(vault.totalClaimed(), 0);
        assertEq(settlementToken.balanceOf(address(vault)), amount);
        assertTrue(vault.isSolvent());
    }

    function testUnauthorizedDepositorRejected() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.depositRevenue(1 ether);
    }

    function testZeroDepositRejected() public {
        vm.prank(depositor);
        vm.expectRevert(RevenueVault.ZeroDeposit.selector);
        vault.depositRevenue(0);
    }

    function testDepositRejectedWhenRevenueSupplyIsZero() public {
        LifecycleERC20Mock emptyRevenueToken = new LifecycleERC20Mock();
        RevenueVault emptyVault = new RevenueVault(
            address(emptyRevenueToken), address(settlementToken), admin, depositor, activationController
        );
        emptyRevenueToken.setLifecycle(ILicenseRevenueTokenLifecycle.Lifecycle.Activated);
        vm.prank(activationController);
        emptyVault.enableDeposits();

        vm.prank(depositor);
        settlementToken.approve(address(emptyVault), 1 ether);

        vm.prank(depositor);
        vm.expectRevert(RevenueVault.ZeroRevenueTokenSupply.selector);
        emptyVault.depositRevenue(1 ether);
    }

    function testPrecisionRemainderCarriesAcrossDeposits() public {
        LifecycleERC20Mock sevenShareToken = new LifecycleERC20Mock();
        sevenShareToken.mint(alice, 7);
        RevenueVault remainderVault = new RevenueVault(
            address(sevenShareToken), address(settlementToken), admin, depositor, activationController
        );
        sevenShareToken.setLifecycle(ILicenseRevenueTokenLifecycle.Lifecycle.Activated);
        vm.prank(activationController);
        remainderVault.enableDeposits();

        vm.prank(depositor);
        settlementToken.approve(address(remainderVault), type(uint256).max);

        for (uint256 i; i < 7; ++i) {
            vm.prank(depositor);
            remainderVault.depositRevenue(1);
        }

        assertEq(remainderVault.accumulatedRewardPerShare(), remainderVault.ACCUMULATOR_PRECISION());
        assertEq(remainderVault.precisionRemainder(), 0);
        assertEq(remainderVault.claimable(alice), 7);
    }

    function testHoldersClaimProRataUsingPullPayments() public {
        _deposit(1_000 ether);

        assertEq(vault.claimable(alice), 600 ether);
        assertEq(vault.claimable(bob), 400 ether);

        vm.prank(alice);
        assertEq(vault.claim(), 600 ether);

        vm.prank(bob);
        assertEq(vault.claim(), 400 ether);

        assertEq(settlementToken.balanceOf(alice), 600 ether);
        assertEq(settlementToken.balanceOf(bob), 400 ether);
        assertEq(vault.totalClaimed(), vault.totalDeposited());
        assertEq(settlementToken.balanceOf(address(vault)), 0);
        assertTrue(vault.isSolvent());
    }

    function testCannotClaimSameRevenueTwice() public {
        _deposit(1_000 ether);

        vm.prank(alice);
        vault.claim();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.NothingToClaim.selector, alice));
        vault.claim();

        assertEq(vault.totalClaimed(), 600 ether);
        assertEq(vault.totalDeposited(), 1_000 ether);
        assertTrue(vault.isSolvent());
    }

    function testClaimAfterSecondDepositPaysOnlyNewAccrual() public {
        _deposit(1_000 ether);

        vm.prank(alice);
        vault.claim();

        _deposit(500 ether);

        assertEq(vault.claimable(alice), 300 ether);
        vm.prank(alice);
        assertEq(vault.claim(), 300 ether);

        assertEq(settlementToken.balanceOf(alice), 900 ether);
        assertEq(vault.rewardDebt(alice), 900 ether);
        assertEq(vault.pendingReward(alice), 0);
        assertLe(vault.totalClaimed(), vault.totalDeposited());
        assertTrue(vault.isSolvent());
    }

    function testUnsolicitedTransferDoesNotCreateAccountedRevenue() public {
        settlementToken.mint(outsider, 100 ether);
        vm.prank(outsider);
        settlementToken.transfer(address(vault), 100 ether);

        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.accumulatedRewardPerShare(), 0);
        assertEq(vault.claimable(alice), 0);
        assertEq(settlementToken.balanceOf(address(vault)), 100 ether);
        assertTrue(vault.isSolvent());
    }

    function testAccountingConservationDuringPartialClaims() public {
        _deposit(1_000 ether);

        vm.prank(alice);
        vault.claim();

        assertEq(vault.totalClaimed(), 600 ether);
        assertEq(vault.totalDeposited() - vault.totalClaimed(), 400 ether);
        assertEq(settlementToken.balanceOf(address(vault)), 400 ether);
        assertLe(vault.totalClaimed(), vault.totalDeposited());
        assertTrue(vault.isSolvent());
    }

    function _deposit(uint256 amount) private {
        vm.prank(depositor);
        vault.depositRevenue(amount);
    }

    function _newDisabledVault() private returns (RevenueVault) {
        return new RevenueVault(address(revenueToken), address(settlementToken), admin, depositor, activationController);
    }
}

contract LifecycleERC20Mock is ERC20Mock {
    ILicenseRevenueTokenLifecycle.Lifecycle public lifecycle;

    function setLifecycle(ILicenseRevenueTokenLifecycle.Lifecycle lifecycle_) external {
        lifecycle = lifecycle_;
    }

    function checkpointTransfer(RevenueVault vault, address from, address to, uint256 amount) external {
        vault.checkpointTransfer(from, to, amount);
    }

    function checkpointRecovery(RevenueVault vault, address source, address destination, uint256 amount) external {
        vault.checkpointRecovery(source, destination, amount);
    }

    function checkpointLegalHoldRelease(RevenueVault vault, address source, address destination, uint256 amount)
        external
    {
        vault.checkpointLegalHoldRelease(source, destination, amount);
    }
}

contract RevenueVaultHarness is RevenueVault {
    constructor(
        address revenueToken_,
        address settlementToken_,
        address admin_,
        address depositor_,
        address activationController_
    ) RevenueVault(revenueToken_, settlementToken_, admin_, depositor_, activationController_) {}

    function seedClaim(address account, uint256 amount) external {
        pendingReward[account] = amount;
        totalDeposited = amount;
    }
}
