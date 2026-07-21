// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockInvestorEligibility} from "./mocks/MockInvestorEligibility.sol";
import {MockRevenueVault} from "./mocks/MockRevenueVault.sol";

contract LicenseRevenueTokenTest is Test {
    IPAssetRegistry private assetRegistry;
    MockInvestorEligibility private eligibility;
    LicenseRevenueToken private token;
    MockRevenueVault private revenueVault;

    address private controller = makeAddr("controller");
    address private minter = makeAddr("minter");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private outsider = makeAddr("outsider");

    uint256 private assetId;

    uint256 private constant FINAL_SUPPLY = 1_000_000 ether;
    string private constant NAME = "AI Patent Revenue Token";
    string private constant SYMBOL = "AIPR";

    event LifecycleChanged(
        LicenseRevenueToken.Lifecycle indexed previousLifecycle, LicenseRevenueToken.Lifecycle indexed newLifecycle
    );
    event TokensRecovered(address indexed from, address indexed to, uint256 amount, address indexed controller);

    function setUp() public {
        assetRegistry = new IPAssetRegistry(address(new MockIdentityRegistry()));
        vm.prank(alice);
        assetId = assetRegistry.registerAsset(
            "AI Patent Drafting Assistant",
            "SOFTWARE",
            "US / CN",
            keccak256("AI Patent Drafting Assistant technical whitepaper v1"),
            "ipfs://metadata-ai-patent-assistant"
        );

        eligibility = new MockInvestorEligibility();
        token = _deployToken(assetId, FINAL_SUPPLY, address(eligibility), controller);
        revenueVault = new MockRevenueVault(address(token));
        vm.prank(controller);
        token.bindRevenueVault(address(revenueVault));
    }

    function testImmutableBindingAndInitialLifecycle() public view {
        assertEq(address(token.ipAssetRegistry()), address(assetRegistry));
        assertEq(address(token.eligibilityPolicy()), address(eligibility));
        assertEq(token.assetId(), assetId);
        assertEq(token.finalSupply(), FINAL_SUPPLY);
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
        assertEq(uint256(token.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Created));
        assertEq(token.totalSupply(), 0);
        assertEq(address(token.revenueVault()), address(revenueVault));
    }

    function testRevenueVaultBindingIsOneTime() public {
        MockRevenueVault replacement = new MockRevenueVault(address(token));

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(LicenseRevenueToken.RevenueVaultAlreadyBound.selector, address(revenueVault))
        );
        token.bindRevenueVault(address(replacement));
    }

    function testRevenueVaultMustBindBackToToken() public {
        LicenseRevenueToken unbound = _deployToken(assetId, FINAL_SUPPLY, address(eligibility), controller);
        MockRevenueVault wrongVault = new MockRevenueVault(address(token));

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseRevenueToken.RevenueVaultTokenMismatch.selector, address(unbound), address(token)
            )
        );
        unbound.bindRevenueVault(address(wrongVault));
    }

    function testCannotBeginMintingBeforeRevenueVaultBinding() public {
        LicenseRevenueToken unbound = _deployToken(assetId, FINAL_SUPPLY, address(eligibility), controller);

        vm.prank(controller);
        vm.expectRevert(LicenseRevenueToken.RevenueVaultNotBound.selector);
        unbound.beginMinting();
    }

    function testConstructorRejectsMissingAsset() public {
        uint256 missingAssetId = 999;
        vm.expectRevert(abi.encodeWithSelector(LicenseRevenueToken.AssetDoesNotExist.selector, missingAssetId));
        _deployToken(missingAssetId, FINAL_SUPPLY, address(eligibility), controller);
    }

    function testConstructorRejectsZeroFinalSupply() public {
        vm.expectRevert(LicenseRevenueToken.InvalidFinalSupply.selector);
        _deployToken(assetId, 0, address(eligibility), controller);
    }

    function testControllerBeginsMinting() public {
        vm.expectEmit(true, true, false, false, address(token));
        emit LifecycleChanged(LicenseRevenueToken.Lifecycle.Created, LicenseRevenueToken.Lifecycle.Minting);

        vm.prank(controller);
        token.beginMinting();

        assertEq(uint256(token.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Minting));
    }

    function testUnauthorizedAccountCannotBeginMinting() public {
        vm.prank(outsider);
        vm.expectRevert();
        token.beginMinting();
    }

    function testUnauthorizedAccountCannotMint() public {
        _beginMintingAndAuthorizeMinter();
        eligibility.setEligible(assetId, outsider, true);

        vm.prank(outsider);
        vm.expectRevert();
        token.mint(outsider, 1 ether);
    }

    function testMinterCannotMintBeforeMintingLifecycle() public {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(controller);
        token.grantRole(minterRole, minter);
        eligibility.setEligible(assetId, alice, true);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseRevenueToken.InvalidLifecycle.selector,
                LicenseRevenueToken.Lifecycle.Created,
                LicenseRevenueToken.Lifecycle.Minting
            )
        );
        token.mint(alice, 1 ether);
    }

    function testMintRequiresEligibleRecipient() public {
        _beginMintingAndAuthorizeMinter();

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(LicenseRevenueToken.IneligibleInvestor.selector, alice));
        token.mint(alice, 1 ether);
    }

    function testMinterCanMintUpToFinalSupply() public {
        _beginMintingAndAuthorizeMinter();
        eligibility.setEligible(assetId, alice, true);

        vm.prank(minter);
        token.mint(alice, FINAL_SUPPLY);

        assertEq(token.balanceOf(alice), FINAL_SUPPLY);
        assertEq(token.totalSupply(), FINAL_SUPPLY);
        assertEq(revenueVault.checkpointCount(), 1);
    }

    function testMintCannotExceedFinalSupply() public {
        _beginMintingAndAuthorizeMinter();
        eligibility.setEligible(assetId, alice, true);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(LicenseRevenueToken.SupplyCapExceeded.selector, FINAL_SUPPLY + 1, FINAL_SUPPLY)
        );
        token.mint(alice, FINAL_SUPPLY + 1);
    }

    function testActivationRequiresFinalSupply() public {
        _beginMintingAndAuthorizeMinter();
        eligibility.setEligible(assetId, alice, true);

        vm.prank(minter);
        token.mint(alice, FINAL_SUPPLY - 1);

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(LicenseRevenueToken.FinalSupplyNotReached.selector, FINAL_SUPPLY - 1, FINAL_SUPPLY)
        );
        token.activate();
    }

    function testUnauthorizedAccountCannotActivate() public {
        _mintFinalSupplyToAlice();

        vm.prank(outsider);
        vm.expectRevert();
        token.activate();
    }

    function testControllerCanActivateAtFinalSupply() public {
        _mintFinalSupplyToAlice();

        vm.expectEmit(true, true, false, false, address(token));
        emit LifecycleChanged(LicenseRevenueToken.Lifecycle.Minting, LicenseRevenueToken.Lifecycle.Activated);

        vm.prank(controller);
        token.activate();

        assertEq(uint256(token.lifecycle()), uint256(LicenseRevenueToken.Lifecycle.Activated));
        assertEq(token.totalSupply(), FINAL_SUPPLY);
    }

    function testMintAfterActivationRejected() public {
        _activateWithAliceHoldingFinalSupply();

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseRevenueToken.InvalidLifecycle.selector,
                LicenseRevenueToken.Lifecycle.Activated,
                LicenseRevenueToken.Lifecycle.Minting
            )
        );
        token.mint(alice, 1);
    }

    function testTransfersDisabledBeforeActivation() public {
        _mintFinalSupplyToAlice();
        eligibility.setEligible(assetId, bob, true);

        vm.prank(alice);
        vm.expectRevert(LicenseRevenueToken.TransfersNotActive.selector);
        token.transfer(bob, 1 ether);
    }

    function testEligibleInvestorsCanTransferAfterActivation() public {
        _activateWithAliceHoldingFinalSupply();
        eligibility.setEligible(assetId, bob, true);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), FINAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), FINAL_SUPPLY);
        assertEq(revenueVault.checkpointCount(), 2);
    }

    function testCheckpointFailureRollsBackTransfer() public {
        _activateWithAliceHoldingFinalSupply();
        eligibility.setEligible(assetId, bob, true);
        revenueVault.setCheckpointShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert(MockRevenueVault.CheckpointFailed.selector);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), FINAL_SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(revenueVault.checkpointCount(), 1);
    }

    function testTransferToIneligibleReceiverRejected() public {
        _activateWithAliceHoldingFinalSupply();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LicenseRevenueToken.IneligibleInvestor.selector, bob));
        token.transfer(bob, 1 ether);
    }

    function testIneligibleSenderMustUseRecoveryPath() public {
        _activateWithAliceHoldingFinalSupply();
        eligibility.setEligible(assetId, alice, false);
        eligibility.setEligible(assetId, bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LicenseRevenueToken.IneligibleInvestor.selector, alice));
        token.transfer(bob, 1 ether);
    }

    function testControllerRecoveryPreservesTotalSupply() public {
        _activateWithAliceHoldingFinalSupply();
        eligibility.setEligible(assetId, alice, false);
        eligibility.setEligible(assetId, bob, true);
        uint256 amount = 250 ether;

        vm.expectEmit(true, true, true, true, address(token));
        emit TokensRecovered(alice, bob, amount, controller);

        vm.prank(controller);
        token.recoverTokens(alice, bob, amount);

        assertEq(token.balanceOf(alice), FINAL_SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), FINAL_SUPPLY);
        assertEq(revenueVault.checkpointCount(), 2);
    }

    function testUnauthorizedRecoveryRejected() public {
        _activateWithAliceHoldingFinalSupply();
        eligibility.setEligible(assetId, bob, true);

        vm.prank(outsider);
        vm.expectRevert();
        token.recoverTokens(alice, bob, 1 ether);
    }

    function testNoPublicBurnFunction() public {
        _activateWithAliceHoldingFinalSupply();

        vm.prank(alice);
        (bool success,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 1 ether));

        assertFalse(success);
        assertEq(token.totalSupply(), FINAL_SUPPLY);
        assertEq(token.balanceOf(alice), FINAL_SUPPLY);
    }

    function _deployToken(uint256 assetId_, uint256 finalSupply_, address policy, address controller_)
        private
        returns (LicenseRevenueToken deployed)
    {
        deployed = new LicenseRevenueToken(
            NAME, SYMBOL, address(assetRegistry), assetId_, finalSupply_, policy, controller_
        );
    }

    function _beginMintingAndAuthorizeMinter() private {
        vm.startPrank(controller);
        token.beginMinting();
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.stopPrank();
    }

    function _mintFinalSupplyToAlice() private {
        _beginMintingAndAuthorizeMinter();
        eligibility.setEligible(assetId, alice, true);

        vm.prank(minter);
        token.mint(alice, FINAL_SUPPLY);
    }

    function _activateWithAliceHoldingFinalSupply() private {
        _mintFinalSupplyToAlice();

        vm.prank(controller);
        token.activate();
    }
}
