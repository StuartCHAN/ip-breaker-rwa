// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {RevenueVault} from "../contracts/RevenueVault.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockInvestorEligibility} from "./mocks/MockInvestorEligibility.sol";

contract RevenueVaultCheckpointTest is Test {
    IPAssetRegistry private assetRegistry;
    LicenseRevenueToken private revenueToken;
    RevenueVault private vault;
    ERC20Mock private settlementToken;
    MockInvestorEligibility private eligibility;

    address private controller = makeAddr("controller");
    address private minter = makeAddr("minter");
    address private depositor = makeAddr("depositor");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    uint256 private constant FINAL_SUPPLY = 1_000 ether;
    uint256 private assetId;

    function setUp() public {
        assetRegistry = new IPAssetRegistry(address(new MockIdentityRegistry()));
        vm.prank(alice);
        assetId = assetRegistry.registerAsset(
            "Checkpointed IP", "SOFTWARE", "US", keccak256("checkpointed-ip"), "ipfs://checkpointed-ip"
        );

        eligibility = new MockInvestorEligibility();
        eligibility.setEligible(assetId, alice, true);
        eligibility.setEligible(assetId, bob, true);

        revenueToken = new LicenseRevenueToken(
            "Checkpoint Revenue Token",
            "CRT",
            address(assetRegistry),
            assetId,
            FINAL_SUPPLY,
            address(eligibility),
            controller
        );
        settlementToken = new ERC20Mock();
        vault = new RevenueVault(address(revenueToken), address(settlementToken), controller, depositor);

        vm.startPrank(controller);
        revenueToken.bindRevenueVault(address(vault));
        revenueToken.beginMinting();
        revenueToken.grantRole(revenueToken.MINTER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        revenueToken.mint(alice, FINAL_SUPPLY);

        vm.prank(controller);
        revenueToken.activate();

        settlementToken.mint(depositor, 10_000 ether);
        vm.prank(depositor);
        settlementToken.approve(address(vault), type(uint256).max);
    }

    function testTransferPreservesHistoricalRewardAndChangesFutureDistribution() public {
        _deposit(1_000 ether);

        vm.prank(alice);
        revenueToken.transfer(bob, 500 ether);

        assertEq(vault.pendingReward(alice), 1_000 ether);
        assertEq(vault.pendingReward(bob), 0);
        assertEq(vault.rewardDebt(alice), 500 ether);
        assertEq(vault.rewardDebt(bob), 500 ether);
        assertEq(vault.claimable(alice), 1_000 ether);
        assertEq(vault.claimable(bob), 0);

        vm.prank(alice);
        assertEq(vault.claim(), 1_000 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.NothingToClaim.selector, bob));
        vault.claim();

        _deposit(1_000 ether);

        assertEq(vault.claimable(alice), 500 ether);
        assertEq(vault.claimable(bob), 500 ether);

        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();

        assertEq(settlementToken.balanceOf(alice), 1_500 ether);
        assertEq(settlementToken.balanceOf(bob), 500 ether);
        assertEq(vault.totalClaimed(), vault.totalDeposited());
        assertTrue(vault.isSolvent());
    }

    function testOnlyBoundRevenueTokenCanCheckpoint() public {
        vm.expectRevert(abi.encodeWithSelector(RevenueVault.OnlyRevenueToken.selector, address(this)));
        vault.checkpointTransfer(alice, bob, 1 ether);
    }

    function _deposit(uint256 amount) private {
        vm.prank(depositor);
        vault.depositRevenue(amount);
    }
}
