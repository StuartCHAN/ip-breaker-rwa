// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @notice Covers the escrow + arbitration flow (LicenseAgreement / LicenseStatus)
///         added on top of the existing offer/license NFT flow. See LicenseEscrow.t.sol
///         for the original offer/license NFT tests, which remain unaffected.
contract LicenseEscrowAgreementTest is Test {
    IPAssetRegistry private assetRegistry;
    LicenseEscrow private licenseEscrow;

    address private alice = makeAddr("alice"); // licensor
    address private bob = makeAddr("bob"); // licensee
    address private carol = makeAddr("carol"); // unrelated third party
    address private dave = makeAddr("dave"); // arbiter

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";
    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    uint256 private constant LICENSE_FEE = 0.01 ether;

    event LicenseAgreementCreated(
        uint256 indexed agreementId,
        uint256 indexed assetId,
        address indexed licensor,
        address licensee,
        uint256 licenseFee
    );
    event LicenseStatusChanged(uint256 indexed agreementId, LicenseEscrow.LicenseStatus from, LicenseEscrow.LicenseStatus to);
    event LicenseFunded(uint256 indexed agreementId, address indexed licensee, uint256 amount);
    event PerformanceConfirmed(uint256 indexed agreementId, address indexed licensor);
    event FundsReleased(uint256 indexed agreementId, address indexed to, uint256 amount);
    event DisputeRaised(uint256 indexed agreementId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed agreementId, bool paidToLicensor, uint256 amount);
    event AgreementCancelled(uint256 indexed agreementId);
    event ArbiterUpdated(address indexed previousArbiter, address indexed newArbiter);

    function setUp() public {
        assetRegistry = new IPAssetRegistry();
        licenseEscrow = new LicenseEscrow(address(assetRegistry));

        // Test contract is the deployer -> owner -> default arbiter. Reassign to `dave`
        // so arbitration tests exercise a distinct third party, like a real deployment would.
        licenseEscrow.setArbiter(dave);

        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    // ======================================================================
    // Rule 1 & 2: only the licensor can create; assetId/fee/licensee set at creation
    // ======================================================================

    function testCreateLicenseAgreementStoresAgreement() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE);

        assertEq(agreementId, 1);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(agreement.assetId, assetId);
        assertEq(agreement.licensor, alice);
        assertEq(agreement.licensee, bob);
        assertEq(agreement.licenseFee, LICENSE_FEE);
        assertEq(agreement.escrowedAmount, 0);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Created));
        assertEq(agreement.createdAt, block.timestamp);
        assertEq(agreement.fundedAt, 0);
    }

    function testCreateLicenseAgreementEmitsCreatedEvent() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectEmit(true, true, true, true, address(licenseEscrow));
        emit LicenseAgreementCreated(1, assetId, alice, bob, LICENSE_FEE);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE);
    }

    function testCreateLicenseAgreementRevertsWhenAssetDoesNotExist() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AssetDoesNotExist.selector, missingAssetId));

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(missingAssetId, bob, LICENSE_FEE);
    }

    function testCreateLicenseAgreementRevertsWhenCallerIsNotAssetOwner() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotAssetOwner.selector, assetId, bob));

        vm.prank(bob);
        licenseEscrow.createLicenseAgreement(assetId, carol, LICENSE_FEE);
    }

    function testCreateLicenseAgreementRevertsWhenLicenseeIsZeroAddress() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidLicensee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, address(0), LICENSE_FEE);
    }

    function testCreateLicenseAgreementRevertsWhenLicenseeIsLicensor() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidLicensee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, alice, LICENSE_FEE);
    }

    function testCreateLicenseAgreementRevertsWhenFeeIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.ZeroLicenseFee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, 0);
    }

    // ======================================================================
    // Rule 3 & 4: only the named licensee can pay, and only the exact fee
    // ======================================================================

    function testFundLicenseTransitionsToFundedAndEscrowsAmount() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Funded));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertEq(agreement.fundedAt, block.timestamp);
        assertEq(address(licenseEscrow).balance, LICENSE_FEE);
    }

    function testFundLicenseEmitsFundedAndStatusChangedEvents() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectEmit(true, true, true, true, address(licenseEscrow));
        emit LicenseFunded(agreementId, bob, LICENSE_FEE);

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        // TODO: also assert LicenseStatusChanged(agreementId, Created, Funded) was emitted
        // (split into its own vm.expectEmit + call if you want both checked independently).
    }

    function testFundLicenseRevertsWhenCallerIsNotLicensee() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotLicensee.selector, agreementId, carol));

        vm.prank(carol);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    function testFundLicenseRevertsWhenAmountTooLow() public {
        uint256 agreementId = _createDefaultAgreement();
        uint256 wrongAmount = LICENSE_FEE - 1;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.IncorrectLicenseFee.selector, LICENSE_FEE, wrongAmount));

        vm.prank(bob);
        licenseEscrow.fundLicense{value: wrongAmount}(agreementId);
    }

    function testFundLicenseRevertsWhenAmountTooHigh() public {
        uint256 agreementId = _createDefaultAgreement();
        uint256 wrongAmount = LICENSE_FEE + 1;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.IncorrectLicenseFee.selector, LICENSE_FEE, wrongAmount));

        vm.prank(bob);
        licenseEscrow.fundLicense{value: wrongAmount}(agreementId);
    }

    // ======================================================================
    // Rule 5: no double payment
    // ======================================================================

    function testFundLicenseRevertsOnSecondPayment() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Funded,
                LicenseEscrow.LicenseStatus.Funded
            )
        );

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    // ======================================================================
    // Cancel: only before funding
    // ======================================================================

    function testCancelAgreementByLicensorFromCreated() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectEmit(true, false, false, true, address(licenseEscrow));
        emit AgreementCancelled(agreementId);

        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Cancelled));
    }

    function testCancelAgreementRevertsWhenCallerIsNotLicensor() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotLicensor.selector, agreementId, bob));

        vm.prank(bob);
        licenseEscrow.cancelAgreement(agreementId);
    }

    function testCancelAgreementRevertsAfterFunding() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Funded,
                LicenseEscrow.LicenseStatus.Cancelled
            )
        );

        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);
    }

    // ======================================================================
    // confirmPerformance: Funded -> Active, licensor only
    // ======================================================================

    function testConfirmPerformanceTransitionsToActive() public {
        uint256 agreementId = _fundedAgreement();

        vm.expectEmit(true, true, false, true, address(licenseEscrow));
        emit PerformanceConfirmed(agreementId, alice);

        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Active));
    }

    function testConfirmPerformanceRevertsWhenCallerIsNotLicensor() public {
        uint256 agreementId = _fundedAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotLicensor.selector, agreementId, bob));

        vm.prank(bob);
        licenseEscrow.confirmPerformance(agreementId);
    }

    function testConfirmPerformanceRevertsBeforeFunding() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Created,
                LicenseEscrow.LicenseStatus.Active
            )
        );

        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);
    }

    // ======================================================================
    // Rule 6: release() -> Completed, licensee only, pays licensor
    // ======================================================================

    function testReleasePaysLicensorAndCompletesAgreement() public {
        uint256 agreementId = _activeAgreement();
        uint256 aliceBalanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(licenseEscrow));
        emit FundsReleased(agreementId, alice, LICENSE_FEE);

        vm.prank(bob);
        licenseEscrow.release(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Completed));
        assertEq(agreement.escrowedAmount, 0);
        assertEq(alice.balance, aliceBalanceBefore + LICENSE_FEE);
    }

    function testReleaseRevertsWhenCallerIsNotLicensee() public {
        uint256 agreementId = _activeAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotLicensee.selector, agreementId, carol));

        vm.prank(carol);
        licenseEscrow.release(agreementId);
    }

    function testReleaseRevertsWhenNotYetActive() public {
        uint256 agreementId = _fundedAgreement();

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Funded,
                LicenseEscrow.LicenseStatus.Completed
            )
        );

        vm.prank(bob);
        licenseEscrow.release(agreementId);
    }

    // ======================================================================
    // Rule 7: disputes freeze the escrow — release() must fail while Disputed
    // ======================================================================

    function testRaiseDisputeFromFundedByEitherParty() public {
        uint256 agreementId = _fundedAgreement();

        vm.expectEmit(true, true, false, true, address(licenseEscrow));
        emit DisputeRaised(agreementId, bob);

        vm.prank(bob);
        licenseEscrow.raiseDispute(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Disputed));
    }

    function testRaiseDisputeFromActiveByEitherParty() public {
        uint256 agreementId = _activeAgreement();

        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Disputed));
    }

    function testRaiseDisputeRevertsWhenCallerIsNeitherParty() public {
        uint256 agreementId = _fundedAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotLicensorOrLicensee.selector, agreementId, carol));

        vm.prank(carol);
        licenseEscrow.raiseDispute(agreementId);
    }

    function testRaiseDisputeRevertsBeforeFunding() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Created,
                LicenseEscrow.LicenseStatus.Disputed
            )
        );

        vm.prank(alice);
        licenseEscrow.raiseDispute(agreementId);
    }

    /// @dev This is the regression test for the bug caught during implementation:
    ///      release() must NOT succeed while Disputed, even though Disputed -> Completed
    ///      is a topologically valid edge (it's resolveDispute()'s edge, not release()'s).
    function testReleaseRevertsWhileDisputed() public {
        uint256 agreementId = _activeAgreement();

        vm.prank(bob);
        licenseEscrow.raiseDispute(agreementId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Disputed,
                LicenseEscrow.LicenseStatus.Completed
            )
        );

        vm.prank(bob);
        licenseEscrow.release(agreementId);
    }

    // ======================================================================
    // Rule 8: arbiter resolves disputes either way
    // ======================================================================

    function testResolveDisputePaysLicensorWhenTrue() public {
        uint256 agreementId = _disputedAgreement();
        uint256 aliceBalanceBefore = alice.balance;

        vm.expectEmit(true, false, false, true, address(licenseEscrow));
        emit DisputeResolved(agreementId, true, LICENSE_FEE);

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Completed));
        assertEq(agreement.escrowedAmount, 0);
        assertEq(alice.balance, aliceBalanceBefore + LICENSE_FEE);
    }

    function testResolveDisputeRefundsLicenseeWhenFalse() public {
        uint256 agreementId = _disputedAgreement();
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Refunded));
        assertEq(agreement.escrowedAmount, 0);
        assertEq(bob.balance, bobBalanceBefore + LICENSE_FEE);
    }

    function testResolveDisputeRevertsWhenCallerIsNotArbiter() public {
        uint256 agreementId = _disputedAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotArbiter.selector, alice));

        vm.prank(alice);
        licenseEscrow.resolveDispute(agreementId, true);
    }

    /// @dev Regression test mirroring testReleaseRevertsWhileDisputed: an arbiter must not be
    ///      able to force-complete an agreement that was never disputed, even though
    ///      Active -> Completed is a topologically valid edge (it's release()'s edge).
    function testResolveDisputeRevertsWhenNotDisputed() public {
        uint256 agreementId = _activeAgreement();

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Active,
                LicenseEscrow.LicenseStatus.Completed
            )
        );

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);
    }

    // ======================================================================
    // Rule 10: terminal states reject any further transition
    // ======================================================================

    function testCompletedAgreementRejectsFurtherActions() public {
        uint256 agreementId = _activeAgreement();

        vm.prank(bob);
        licenseEscrow.release(agreementId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Completed,
                LicenseEscrow.LicenseStatus.Disputed
            )
        );
        vm.prank(bob);
        licenseEscrow.raiseDispute(agreementId);
    }

    function testCancelledAgreementRejectsFunding() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.prank(alice);
        licenseEscrow.cancelAgreement(agreementId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Cancelled,
                LicenseEscrow.LicenseStatus.Funded
            )
        );
        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    // TODO: testRefundedAgreementRejectsFurtherActions — same pattern as
    // testCompletedAgreementRejectsFurtherActions but starting from _disputedAgreement()
    // + resolveDispute(id, false), then assert any further call reverts.

    // ======================================================================
    // Arbiter admin
    // ======================================================================

    function testSetArbiterByOwner() public {
        address newArbiter = makeAddr("newArbiter");

        vm.expectEmit(true, true, false, true, address(licenseEscrow));
        emit ArbiterUpdated(dave, newArbiter);

        licenseEscrow.setArbiter(newArbiter); // test contract is the owner
        assertEq(licenseEscrow.arbiter(), newArbiter);
    }

    function testSetArbiterRevertsWhenCallerIsNotOwner() public {
        vm.expectRevert(); // Ownable's own custom error; not re-declared on LicenseEscrow
        vm.prank(alice);
        licenseEscrow.setArbiter(alice);
    }

    function testSetArbiterRevertsWhenZeroAddress() public {
        vm.expectRevert(LicenseEscrow.ZeroArbiter.selector);
        licenseEscrow.setArbiter(address(0));
    }

    // ======================================================================
    // Views
    // ======================================================================

    function testGetAgreementRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        licenseEscrow.getAgreement(missingAgreementId);
    }

    function testNextAgreementIdStartsAtOneAndIncrements() public {
        assertEq(licenseEscrow.nextAgreementId(), 1);

        _createDefaultAgreement();
        assertEq(licenseEscrow.nextAgreementId(), 2);
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }

    function _createDefaultAgreement() private returns (uint256 agreementId) {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE);
    }

    function _fundedAgreement() private returns (uint256 agreementId) {
        agreementId = _createDefaultAgreement();

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    function _activeAgreement() private returns (uint256 agreementId) {
        agreementId = _fundedAgreement();

        vm.prank(alice);
        licenseEscrow.confirmPerformance(agreementId);
    }

    function _disputedAgreement() private returns (uint256 agreementId) {
        agreementId = _activeAgreement();

        vm.prank(bob);
        licenseEscrow.raiseDispute(agreementId);
    }
}
