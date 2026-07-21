// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice Completeness check for the LicenseAgreement state graph, organized by STARTING
///         STATE rather than by function. LicenseEscrowAgreement.t.sol already checks
///         individual illegal edges (one test per function, one wrong-state example each);
///         this file instead picks each of the 7 reachable states in turn and, from a single
///         agreement instance parked in that state, attempts every action that should be
///         illegal from there and asserts each one reverts. The point is completeness: proving
///         no edge was overlooked, not just spot-checking the edges someone thought to write a
///         test for. Some overlap with LicenseEscrowAgreement.t.sol is intentional — verifying
///         the same property from two independent organizing axes is standard practice for a
///         state machine this central to fund safety.
///
/// @dev Every action here is called by the correct role (the licensee for fundLicense/release,
///      the licensor for confirmPerformance/cancelAgreement, the arbiter for resolveDispute,
///      either party for raiseDispute) specifically so the assertion isolates the STATE gate
///      rather than accidentally testing a permission check instead. Since a reverted call
///      never mutates state, the same agreement instance can be reused across every invalid
///      action within one test function without needing a fresh agreement per assertion.
contract LicenseEscrowStateMachineTest is Test {
    IPAssetRegistry private assetRegistry;
    LicenseEscrow private licenseEscrow;

    address private alice = makeAddr("alice"); // licensor
    address private bob = makeAddr("bob"); // licensee
    address private dave = makeAddr("dave"); // arbiter

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";
    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    uint256 private constant LICENSE_FEE = 0.01 ether;
    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");
    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    function setUp() public {
        assetRegistry = new IPAssetRegistry(address(new MockIdentityRegistry()));
        licenseEscrow = new LicenseEscrow(address(assetRegistry));
        licenseEscrow.setArbiter(dave);

        vm.deal(bob, 10 ether);
    }

    // ======================================================================
    // From Created: only fund() and cancelAgreement() are legal.
    // ======================================================================

    function testFromCreatedOnlyFundAndCancelAreLegal() public {
        uint256 agreementId = _driveToCreated();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Created;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Disputed);
        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);
    }

    // ======================================================================
    // From Funded: only confirmPerformance() and raiseDispute() are legal.
    // ======================================================================

    function testFromFundedOnlyConfirmAndDisputeAreLegal() public {
        uint256 agreementId = _driveToFunded();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Funded;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // From Active: only release() and raiseDispute() are legal.
    // ======================================================================

    function testFromActiveOnlyReleaseAndDisputeAreLegal() public {
        uint256 agreementId = _driveToActive();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Active;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // From Disputed: only resolveDispute(true) and resolveDispute(false) are legal.
    // ======================================================================

    function testFromDisputedOnlyResolveIsLegal() public {
        uint256 agreementId = _driveToDisputed();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Disputed;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Disputed);
        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // From Completed: terminal — nothing is legal.
    // ======================================================================

    function testFromCompletedNothingIsLegal() public {
        uint256 agreementId = _driveToCompleted();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Completed;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Disputed);
        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // From Refunded: terminal — nothing is legal.
    // ======================================================================

    function testFromRefundedNothingIsLegal() public {
        uint256 agreementId = _driveToRefunded();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Refunded;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Disputed);
        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // From Cancelled: terminal — nothing is legal.
    // ======================================================================

    function testFromCancelledNothingIsLegal() public {
        uint256 agreementId = _driveToCancelled();
        LicenseEscrow.LicenseStatus s = LicenseEscrow.LicenseStatus.Cancelled;

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Funded);
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Active);
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Disputed);
        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Completed);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Refunded);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        _expectInvalid(s, LicenseEscrow.LicenseStatus.Cancelled);
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    function _expectInvalid(LicenseEscrow.LicenseStatus from, LicenseEscrow.LicenseStatus to) private {
        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.InvalidStatusTransition.selector, from, to));
    }

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }

    function _driveToCreated() private returns (uint256 agreementId) {
        uint256 assetId = _registerDefaultAsset(alice);
        vm.prank(alice);
        agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function _driveToFunded() private returns (uint256 agreementId) {
        agreementId = _driveToCreated();
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    function _driveToActive() private returns (uint256 agreementId) {
        agreementId = _driveToFunded();
        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);
    }

    function _driveToDisputed() private returns (uint256 agreementId) {
        agreementId = _driveToActive();
        vm.prank(bob);
        licenseEscrow.raiseDispute(agreementId);
    }

    function _driveToCompleted() private returns (uint256 agreementId) {
        agreementId = _driveToActive();
        vm.prank(bob);
        licenseEscrow.release(agreementId);
    }

    function _driveToRefunded() private returns (uint256 agreementId) {
        agreementId = _driveToDisputed();
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);
    }

    function _driveToCancelled() private returns (uint256 agreementId) {
        agreementId = _driveToCreated();
        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }
}
