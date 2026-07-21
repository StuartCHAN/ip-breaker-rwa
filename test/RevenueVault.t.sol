// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {RevenueVault} from "../contracts/RevenueVault.sol";

contract RevenueVaultTest is Test {
    ERC20Mock private revenueToken;
    ERC20Mock private settlementToken;
    RevenueVault private vault;

    address private admin = makeAddr("admin");
    address private depositor = makeAddr("depositor");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private outsider = makeAddr("outsider");

    uint256 private constant ALICE_SHARES = 600 ether;
    uint256 private constant BOB_SHARES = 400 ether;

    function setUp() public {
        revenueToken = new ERC20Mock();
        settlementToken = new ERC20Mock();

        revenueToken.mint(alice, ALICE_SHARES);
        revenueToken.mint(bob, BOB_SHARES);

        vault = new RevenueVault(address(revenueToken), address(settlementToken), admin, depositor);

        settlementToken.mint(depositor, 1_000_000 ether);
        vm.prank(depositor);
        settlementToken.approve(address(vault), type(uint256).max);
    }

    function testConstructorBindsTokenPairAndRoles() public view {
        assertEq(address(vault.revenueToken()), address(revenueToken));
        assertEq(address(vault.settlementToken()), address(settlementToken));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.REVENUE_DEPOSITOR_ROLE(), depositor));
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(RevenueVault.ZeroRevenueToken.selector);
        new RevenueVault(address(0), address(settlementToken), admin, depositor);

        vm.expectRevert(RevenueVault.ZeroSettlementToken.selector);
        new RevenueVault(address(revenueToken), address(0), admin, depositor);

        vm.expectRevert(RevenueVault.ZeroAdmin.selector);
        new RevenueVault(address(revenueToken), address(settlementToken), address(0), depositor);

        vm.expectRevert(RevenueVault.ZeroDepositor.selector);
        new RevenueVault(address(revenueToken), address(settlementToken), admin, address(0));
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
        ERC20Mock emptyRevenueToken = new ERC20Mock();
        RevenueVault emptyVault =
            new RevenueVault(address(emptyRevenueToken), address(settlementToken), admin, depositor);

        vm.prank(depositor);
        settlementToken.approve(address(emptyVault), 1 ether);

        vm.prank(depositor);
        vm.expectRevert(RevenueVault.ZeroRevenueTokenSupply.selector);
        emptyVault.depositRevenue(1 ether);
    }

    function testPrecisionRemainderCarriesAcrossDeposits() public {
        ERC20Mock sevenShareToken = new ERC20Mock();
        sevenShareToken.mint(alice, 7);
        RevenueVault remainderVault =
            new RevenueVault(address(sevenShareToken), address(settlementToken), admin, depositor);

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
}
