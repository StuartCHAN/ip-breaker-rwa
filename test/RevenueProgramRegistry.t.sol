// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RevenueProgramRegistry} from "../contracts/RevenueProgramRegistry.sol";
import {IRevenueProgramRegistry} from "../contracts/interfaces/IRevenueProgramRegistry.sol";

contract RevenueProgramRegistryTest is Test {
    RevenueProgramRegistry private registry;
    ProgramDependencyMock private revenueToken;
    ProgramDependencyMock private revenueVault;
    ProgramSettlementMock private settlementToken;

    address private admin = makeAddr("admin");
    address private manager = makeAddr("manager");
    address private outsider = makeAddr("outsider");
    address private issuer = makeAddr("issuer");

    uint256 private constant ASSET_ID = 42;
    bytes32 private constant OFFERING_ID = keccak256("offering-42");

    function setUp() public {
        registry = new RevenueProgramRegistry(admin);
        revenueToken = new ProgramDependencyMock();
        revenueVault = new ProgramDependencyMock();
        settlementToken = new ProgramSettlementMock();

        bytes32 programManagerRole = registry.PROGRAM_MANAGER_ROLE();
        vm.prank(admin);
        registry.grantRole(programManagerRole, manager);
    }

    function testAuthorizedReservationCreatesImmutableBindingAndLiveSlot() public {
        vm.warp(1_000);
        _reserve(OFFERING_ID, ASSET_ID);

        IRevenueProgramRegistry.RevenueProgram memory program = registry.getProgram(OFFERING_ID);
        assertEq(program.assetId, ASSET_ID);
        assertEq(program.offeringId, OFFERING_ID);
        assertEq(program.issuer, issuer);
        assertEq(program.revenueToken, address(revenueToken));
        assertEq(program.revenueVault, address(revenueVault));
        assertEq(program.settlementToken, address(settlementToken));
        assertEq(uint256(program.status), uint256(IRevenueProgramRegistry.ProgramStatus.Reserved));
        assertEq(program.reservedAt, 1_000);
        assertEq(program.activatedAt, 0);
        assertEq(program.failedAt, 0);
        assertEq(registry.liveOfferingByAsset(ASSET_ID), OFFERING_ID);
        assertEq(registry.activeOfferingByAsset(ASSET_ID), bytes32(0));
    }

    function testUnauthorizedReservationAndTransitionsRejected() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.reserveProgram(
            OFFERING_ID, ASSET_ID, issuer, address(revenueToken), address(revenueVault), address(settlementToken)
        );

        _reserve(OFFERING_ID, ASSET_ID);

        vm.prank(outsider);
        vm.expectRevert();
        registry.activateProgram(OFFERING_ID);

        vm.prank(outsider);
        vm.expectRevert();
        registry.failProgram(OFFERING_ID);
    }

    function testDuplicateOfferingAndDuplicateLiveReservationRejected() public {
        _reserve(OFFERING_ID, ASSET_ID);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(RevenueProgramRegistry.ProgramAlreadyExists.selector, OFFERING_ID));
        registry.reserveProgram(
            OFFERING_ID, ASSET_ID + 1, issuer, address(revenueToken), address(revenueVault), address(settlementToken)
        );

        bytes32 secondOfferingId = keccak256("second-offering");
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(RevenueProgramRegistry.AssetHasLiveReservation.selector, ASSET_ID, OFFERING_ID)
        );
        registry.reserveProgram(
            secondOfferingId, ASSET_ID, issuer, address(revenueToken), address(revenueVault), address(settlementToken)
        );
    }

    function testProgramMarkedFailedIsPermanentAndReleasesAssetLiveSlot() public {
        _reserve(OFFERING_ID, ASSET_ID);
        vm.warp(2_000);

        vm.prank(manager);
        registry.failProgram(OFFERING_ID);

        IRevenueProgramRegistry.RevenueProgram memory failed = registry.getProgram(OFFERING_ID);
        assertEq(uint256(failed.status), uint256(IRevenueProgramRegistry.ProgramStatus.Failed));
        assertEq(failed.failedAt, 2_000);
        assertEq(failed.activatedAt, 0);
        assertEq(registry.liveOfferingByAsset(ASSET_ID), bytes32(0));
        assertEq(registry.activeOfferingByAsset(ASSET_ID), bytes32(0));

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                RevenueProgramRegistry.InvalidProgramStatus.selector,
                OFFERING_ID,
                IRevenueProgramRegistry.ProgramStatus.Failed,
                IRevenueProgramRegistry.ProgramStatus.Reserved
            )
        );
        registry.activateProgram(OFFERING_ID);

        bytes32 replacementOfferingId = keccak256("replacement-offering");
        _reserve(replacementOfferingId, ASSET_ID);
        assertEq(registry.liveOfferingByAsset(ASSET_ID), replacementOfferingId);
    }

    function testActivationPermanentlyOccupiesAssetAndBindingsRemainUnchanged() public {
        _reserve(OFFERING_ID, ASSET_ID);
        IRevenueProgramRegistry.RevenueProgram memory beforeActivation = registry.getProgram(OFFERING_ID);
        vm.warp(3_000);

        vm.prank(manager);
        registry.activateProgram(OFFERING_ID);

        IRevenueProgramRegistry.RevenueProgram memory active = registry.getProgram(OFFERING_ID);
        assertEq(uint256(active.status), uint256(IRevenueProgramRegistry.ProgramStatus.Active));
        assertEq(active.activatedAt, 3_000);
        assertEq(active.failedAt, 0);
        assertEq(active.assetId, beforeActivation.assetId);
        assertEq(active.issuer, beforeActivation.issuer);
        assertEq(active.revenueToken, beforeActivation.revenueToken);
        assertEq(active.revenueVault, beforeActivation.revenueVault);
        assertEq(active.settlementToken, beforeActivation.settlementToken);
        assertEq(registry.liveOfferingByAsset(ASSET_ID), bytes32(0));
        assertEq(registry.activeOfferingByAsset(ASSET_ID), OFFERING_ID);

        bytes32 secondOfferingId = keccak256("second-active");
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(RevenueProgramRegistry.AssetHasActiveProgram.selector, ASSET_ID, OFFERING_ID)
        );
        registry.reserveProgram(
            secondOfferingId, ASSET_ID, issuer, address(revenueToken), address(revenueVault), address(settlementToken)
        );

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                RevenueProgramRegistry.InvalidProgramStatus.selector,
                OFFERING_ID,
                IRevenueProgramRegistry.ProgramStatus.Active,
                IRevenueProgramRegistry.ProgramStatus.Reserved
            )
        );
        registry.failProgram(OFFERING_ID);
    }

    function testWrongOfferingActivationAndDependencyMismatchRejected() public {
        bytes32 unknownOfferingId = keccak256("unknown");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(RevenueProgramRegistry.ProgramNotFound.selector, unknownOfferingId));
        registry.activateProgram(unknownOfferingId);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(RevenueProgramRegistry.InvalidProgramContract.selector, outsider));
        registry.reserveProgram(
            OFFERING_ID, ASSET_ID, issuer, outsider, address(revenueVault), address(settlementToken)
        );

        vm.expectRevert(abi.encodeWithSelector(RevenueProgramRegistry.ProgramNotFound.selector, OFFERING_ID));
        registry.getProgram(OFFERING_ID);
        assertEq(registry.liveOfferingByAsset(ASSET_ID), bytes32(0));
    }

    function testInvalidLifecycleTransitionsDoNotMutateState() public {
        _reserve(OFFERING_ID, ASSET_ID);
        vm.prank(manager);
        registry.activateProgram(OFFERING_ID);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                RevenueProgramRegistry.InvalidProgramStatus.selector,
                OFFERING_ID,
                IRevenueProgramRegistry.ProgramStatus.Active,
                IRevenueProgramRegistry.ProgramStatus.Reserved
            )
        );
        registry.activateProgram(OFFERING_ID);

        IRevenueProgramRegistry.RevenueProgram memory program = registry.getProgram(OFFERING_ID);
        assertEq(uint256(program.status), uint256(IRevenueProgramRegistry.ProgramStatus.Active));
        assertEq(registry.activeOfferingByAsset(ASSET_ID), OFFERING_ID);
    }

    function _reserve(bytes32 offeringId, uint256 assetId) private {
        vm.prank(manager);
        registry.reserveProgram(
            offeringId, assetId, issuer, address(revenueToken), address(revenueVault), address(settlementToken)
        );
    }
}

contract ProgramDependencyMock {}

contract ProgramSettlementMock is ERC20 {
    constructor() ERC20("Program Settlement", "PSET") {}
}
