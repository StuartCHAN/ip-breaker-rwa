// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OfferingManager, IIssuerEligibility} from "../contracts/OfferingManager.sol";
import {IIdentityRegistry} from "../contracts/interfaces/IIdentityRegistry.sol";
import {IIPAssetRegistry} from "../contracts/interfaces/IIPAssetRegistry.sol";

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

    uint256 private constant ASSET_ID = 1;
    uint256 private constant FINAL_SUPPLY = 10_000 ether;
    uint256 private constant PRICE = 1_000_000;

    DependencyMock private revenueToken;
    DependencyMock private revenueVault;
    DependencyMock private allocationEscrow;
    DependencyMock private offeringEscrow;
    DependencyMock private investorEligibility;
    DependencyMock private recoveryManager;

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

        revenueToken = new DependencyMock();
        revenueVault = new DependencyMock();
        allocationEscrow = new DependencyMock();
        offeringEscrow = new DependencyMock();
        investorEligibility = new DependencyMock();
        recoveryManager = new DependencyMock();

        manager =
            new OfferingManager(admin, address(identityRegistry), address(assetRegistry), address(issuerEligibility));
        bytes32 operatorRole = manager.OFFERING_OPERATOR_ROLE();
        vm.prank(admin);
        manager.grantRole(operatorRole, operator);

        assetRegistry.setAsset(ASSET_ID, assetOwner);
        identityRegistry.setAssetOwner(assetOwner, true);
        issuerEligibility.setEligible(issuer, true);
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

    function testOpenRevalidatesIssuer() public {
        bytes32 offeringId = _createOffering();
        OfferingManager.Offering memory offering = manager.getOffering(offeringId);
        issuerEligibility.setEligible(issuer, false);
        vm.warp(offering.config.opensAt);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OfferingManager.InvalidIssuer.selector, issuer));
        manager.openOffering(offeringId);
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
            pricePerWholeTokenUSDC: PRICE,
            protocolFeeBps: 250,
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

    function setAssetOwner(address account, bool valid) external {
        _assetOwners[account] = valid;
    }

    function hasBusinessRole(address account, uint256 roleMask) external view returns (bool) {
        return roleMask == ROLE_ASSET_OWNER && _assetOwners[account];
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
}

contract DependencyMock {}
