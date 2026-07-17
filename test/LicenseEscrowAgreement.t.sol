// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");
    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    event LicenseAgreementCreated(
        uint256 indexed agreementId,
        uint256 indexed assetId,
        address indexed licensor,
        address licensee,
        address arbiter,
        uint256 licenseFee,
        bytes32 termsHash,
        string termsURI
    );
    event LicenseStatusChanged(
        uint256 indexed agreementId, LicenseEscrow.LicenseStatus from, LicenseEscrow.LicenseStatus to
    );
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
        uint256 agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        assertEq(agreementId, 1);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(agreement.assetId, assetId);
        assertEq(agreement.licensor, alice);
        assertEq(agreement.licensee, bob);
        assertEq(agreement.arbiter, dave);
        assertEq(agreement.licenseFee, LICENSE_FEE);
        assertEq(agreement.escrowedAmount, 0);
        assertEq(agreement.termsHash, TERMS_HASH);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Created));
        assertEq(agreement.createdAt, block.timestamp);
        assertEq(agreement.fundedAt, 0);
    }

    function testCreateLicenseAgreementEmitsCreatedEvent() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectEmit(true, true, true, true, address(licenseEscrow));
        emit LicenseAgreementCreated(1, assetId, alice, bob, dave, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenAssetDoesNotExist() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AssetDoesNotExist.selector, missingAssetId));

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(missingAssetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenCallerIsNotAssetOwner() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotAssetOwner.selector, assetId, bob));

        vm.prank(bob);
        licenseEscrow.createLicenseAgreement(assetId, carol, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenLicenseeIsZeroAddress() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidLicensee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, address(0), LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenLicenseeIsLicensor() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidLicensee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, alice, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenFeeIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.ZeroLicenseFee.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, 0, TERMS_HASH, TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenTermsHashIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.ZeroTermsHash.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, bytes32(0), TERMS_URI);
    }

    function testCreateLicenseAgreementRevertsWhenTermsURIIsEmpty() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.EmptyTermsURI.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, "");
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

    /// @dev Explicitly checks BOTH events fundLicense() emits, in order — not just the
    ///      business-specific LicenseFunded event. Rule 9 requires every status change to
    ///      produce an event, and LicenseStatusChanged is the one that actually proves that;
    ///      asserting only LicenseFunded would silently pass even if _transition() never fired.
    function testFundLicenseEmitsStatusChangedAndFundedEventsInOrder() public {
        uint256 agreementId = _createDefaultAgreement();

        vm.expectEmit(true, false, false, true, address(licenseEscrow));
        emit LicenseStatusChanged(agreementId, LicenseEscrow.LicenseStatus.Created, LicenseEscrow.LicenseStatus.Funded);

        vm.expectEmit(true, true, false, true, address(licenseEscrow));
        emit LicenseFunded(agreementId, bob, LICENSE_FEE);

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
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

    /// @dev Regression test for the licensor/licensee consistency gap flagged in review:
    ///      buyLicense() already re-checks asset ownership before settling; fundLicense()
    ///      must do the same, or a licensor who sold the underlying IP Asset NFT after
    ///      creating an agreement could still collect a license fee for it.
    function testFundLicenseRevertsWhenLicensorNoLongerOwnsAsset() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        vm.prank(alice);
        assetRegistry.transferFrom(alice, carol, assetId);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.LicensorNoLongerAssetOwner.selector, assetId, alice));

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
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

    function testCancelAgreementRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        licenseEscrow.cancelAgreement(missingAgreementId);
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

    function testConfirmPerformanceRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        licenseEscrow.confirmPerformance(missingAgreementId);
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
        assertEq(address(licenseEscrow).balance, 0);
    }

    /// @dev totalRevenueByAsset previously only tracked buyLicense() revenue despite its
    ///      name — a settled escrow agreement is just as much "revenue" for the asset.
    function testReleaseUpdatesTotalRevenueByAsset() public {
        uint256 agreementId = _activeAgreement();
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);

        vm.prank(bob);
        licenseEscrow.release(agreementId);

        assertEq(licenseEscrow.totalRevenueByAsset(agreement.assetId), LICENSE_FEE);
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

    function testReleaseRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        licenseEscrow.release(missingAgreementId);
    }

    /// @dev Push-payment DoS check: if the licensor is a contract that rejects plain ETH
    ///      transfers, release() must revert cleanly and leave state untouched (still Active,
    ///      escrow still funded) rather than silently burning the funds or leaving the
    ///      agreement stuck half-transitioned.
    function testReleaseRevertsAndRollsBackWhenLicensorRejectsETH() public {
        RejectingReceiver rejectingLicensor = new RejectingReceiver();

        uint256 assetId = _registerDefaultAsset(address(rejectingLicensor));

        vm.prank(address(rejectingLicensor));
        uint256 agreementId =
            licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        vm.prank(address(rejectingLicensor));
        licenseEscrow.confirmPerformance(agreementId);

        uint256 contractBalanceBefore = address(licenseEscrow).balance;

        vm.expectRevert(LicenseEscrow.PaymentTransferFailed.selector);
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Active));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertEq(address(licenseEscrow).balance, contractBalanceBefore);
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

    function testRaiseDisputeRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        licenseEscrow.raiseDispute(missingAgreementId);
    }

    /// @dev Regression test for the bug caught during implementation: release() must NOT
    ///      succeed while Disputed, even though Disputed -> Completed is a topologically
    ///      valid edge (it's resolveDispute()'s edge, not release()'s).
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

    function testResolveDisputePayToLicensorUpdatesTotalRevenueByAsset() public {
        uint256 agreementId = _disputedAgreement();
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);

        assertEq(licenseEscrow.totalRevenueByAsset(agreement.assetId), LICENSE_FEE);
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

    /// @dev A refund is money going back to the licensee, not realized revenue — must NOT
    ///      be counted in totalRevenueByAsset (paired with the payToLicensor=true case above).
    function testResolveDisputeRefundDoesNotUpdateTotalRevenueByAsset() public {
        uint256 agreementId = _disputedAgreement();
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        assertEq(licenseEscrow.totalRevenueByAsset(agreement.assetId), 0);
    }

    function testResolveDisputeRevertsWhenCallerIsNotArbiter() public {
        uint256 agreementId = _disputedAgreement();

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotArbiter.selector, agreementId, alice));

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

    function testResolveDisputeRevertsWhenAgreementDoesNotExist() public {
        uint256 missingAgreementId = 999;

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.AgreementDoesNotExist.selector, missingAgreementId));
        vm.prank(dave);
        licenseEscrow.resolveDispute(missingAgreementId, true);
    }

    /// @dev Push-payment DoS check on the refund path: if the licensee is a contract that
    ///      rejects plain ETH transfers, resolveDispute() must revert cleanly and leave the
    ///      agreement Disputed with the escrow still intact, not silently lose the funds.
    function testResolveDisputeRevertsAndRollsBackWhenLicenseeRejectsETH() public {
        RejectingReceiver rejectingLicensee = new RejectingReceiver();
        vm.deal(address(rejectingLicensee), 10 ether);

        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 agreementId = licenseEscrow.createLicenseAgreement(
            assetId, address(rejectingLicensee), LICENSE_FEE, TERMS_HASH, TERMS_URI
        );

        vm.prank(address(rejectingLicensee));
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        vm.prank(address(rejectingLicensee));
        licenseEscrow.raiseDispute(agreementId);

        uint256 contractBalanceBefore = address(licenseEscrow).balance;

        vm.expectRevert(LicenseEscrow.PaymentTransferFailed.selector);
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Disputed));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertEq(address(licenseEscrow).balance, contractBalanceBefore);
    }

    // ======================================================================
    // Arbiter snapshot: changing the global default must not affect existing agreements
    // ======================================================================

    /// @dev Regression test for the trust-model issue flagged in review: the contract owner
    ///      reassigning the global arbiter must only affect agreements created afterwards.
    ///      An agreement already funded (and possibly disputed) keeps the arbiter it was
    ///      created with — otherwise an owner could swap in a favorable arbiter mid-dispute.
    function testArbiterChangeDoesNotAffectExistingAgreements() public {
        uint256 oldAgreementId = _disputedAgreement(); // created while arbiter == dave

        address eve = makeAddr("eve");
        licenseEscrow.setArbiter(eve); // owner reassigns the global default

        // The old agreement still only trusts dave.
        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotArbiter.selector, oldAgreementId, eve));
        vm.prank(eve);
        licenseEscrow.resolveDispute(oldAgreementId, true);

        vm.prank(dave);
        licenseEscrow.resolveDispute(oldAgreementId, true); // dave can still resolve it

        // A new agreement created after the reassignment picks up the new default.
        uint256 newAssetId = _registerDefaultAsset(alice);
        vm.prank(alice);
        uint256 newAgreementId =
            licenseEscrow.createLicenseAgreement(newAssetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        LicenseEscrow.LicenseAgreement memory newAgreement = licenseEscrow.getAgreement(newAgreementId);
        assertEq(newAgreement.arbiter, eve);
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

    /// @dev Fulfils the TODO from the previous round: Refunded is a terminal state too, and
    ///      needs the same "nothing further can happen" coverage as Completed and Cancelled.
    function testRefundedAgreementRejectsFurtherActions() public {
        uint256 agreementId = _disputedAgreement();

        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.InvalidStatusTransition.selector,
                LicenseEscrow.LicenseStatus.Refunded,
                LicenseEscrow.LicenseStatus.Completed
            )
        );
        vm.prank(dave);
        licenseEscrow.resolveDispute(agreementId, true);
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

    /// @dev Uses the precise OpenZeppelin v5 Ownable error instead of a bare vm.expectRevert(),
    ///      which would also (incorrectly) pass if the call reverted for an unrelated reason.
    function testSetArbiterRevertsWhenCallerIsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
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
        agreementId = licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);
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

/// @dev Minimal contract that rejects any plain ETH transfer, used to test that push-payment
///      failures in release()/resolveDispute() revert cleanly instead of corrupting state.
contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver: no thanks");
    }
}
