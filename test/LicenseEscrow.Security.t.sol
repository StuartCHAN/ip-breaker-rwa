// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @notice Dedicated attack-scenario tests for the escrow flow, separate from the ordinary
///         unit tests in LicenseEscrowAgreement.t.sol. These specifically try to break the
///         nonReentrant guard rather than just check "does a rejected transfer roll back" —
///         that rollback case is already covered by RejectingReceiver in the main test file.
contract LicenseEscrowSecurityTest is Test {
    IPAssetRegistry private assetRegistry;
    LicenseEscrow private licenseEscrow;

    address private bob = makeAddr("bob");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";
    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    uint256 private constant LICENSE_FEE = 0.01 ether;
    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");
    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    function setUp() public {
        assetRegistry = new IPAssetRegistry();
        licenseEscrow = new LicenseEscrow(address(assetRegistry));

        vm.deal(bob, 10 ether);
    }

    /// @dev Same-function reentrancy: the licensor is a contract that, upon receiving its
    ///      payout inside release(), tries to call release() again on the SAME agreement.
    ///      Unlike the RejectingReceiver tests (which prove a REJECTED transfer rolls back
    ///      cleanly), this proves a transfer that the attacker lets SUCCEED still can't be
    ///      used as a window to double-spend — the reentrant call itself must fail, and the
    ///      outer call must still complete normally with funds paid out exactly once.
    function testReentrancyAttackOnReleaseCannotDoubleSpend() public {
        ReentrantAttacker attacker = new ReentrantAttacker(licenseEscrow);

        vm.prank(address(attacker));
        uint256 assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);

        vm.prank(address(attacker));
        uint256 agreementId =
            licenseEscrow.createLicenseAgreement(assetId, bob, LICENSE_FEE, TERMS_HASH, TERMS_URI);

        vm.prank(bob);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        vm.prank(address(attacker));
        licenseEscrow.confirmPerformance(agreementId);

        attacker.armReentryIntoRelease(agreementId);

        uint256 contractBalanceBefore = address(licenseEscrow).balance;

        // The outer call is made by bob (the legitimate licensee) and is expected to
        // SUCCEED — the attack is fully contained inside the attacker's receive(), which
        // catches its own reentrant call failing and simply lets execution continue.
        vm.prank(bob);
        licenseEscrow.release(agreementId);

        // The reentrant call attempt must have been caught and must have failed.
        assertTrue(attacker.reentrantCallReverted(), "reentrant release() call should have reverted");

        // The agreement must be Completed exactly once, not "double completed" or corrupted.
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(LicenseEscrow.LicenseStatus.Completed));
        assertEq(agreement.escrowedAmount, 0);

        // Funds must have moved exactly once: contract balance drops by exactly LICENSE_FEE,
        // attacker's balance increases by exactly LICENSE_FEE (not 2x).
        assertEq(address(licenseEscrow).balance, contractBalanceBefore - LICENSE_FEE);
        assertEq(address(attacker).balance, LICENSE_FEE);
    }

    /// @dev Cross-function reentrancy: OpenZeppelin's ReentrancyGuard uses a single lock
    ///      shared across every nonReentrant-modified function in the contract, not one lock
    ///      per function. This proves that guarantee actually holds here — the attacker
    ///      receives a payout from resolveDispute() on one agreement and, from inside that
    ///      same receive(), tries to call release() on a COMPLETELY DIFFERENT agreement that
    ///      is otherwise perfectly legal to release. If the guard were somehow scoped
    ///      per-function instead of contract-wide, this second call would succeed and pay out
    ///      early/out of order; with the real shared-lock ReentrancyGuard, it must revert.
    function testCrossFunctionReentrancyFromResolveDisputeToReleaseReverts() public {
        ReentrantAttacker attacker = new ReentrantAttacker(licenseEscrow);

        // Agreement 1: will be disputed and refunded to the attacker (as licensee).
        vm.prank(bob);
        uint256 assetId1 = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
        vm.prank(bob);
        uint256 agreementId1 =
            licenseEscrow.createLicenseAgreement(assetId1, address(attacker), LICENSE_FEE, TERMS_HASH, TERMS_URI);
        vm.deal(address(attacker), 1 ether);
        vm.prank(address(attacker));
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId1);
        vm.prank(address(attacker));
        licenseEscrow.raiseDispute(agreementId1);

        // Agreement 2: fully independent, already Active and legally releasable.
        vm.prank(bob);
        uint256 assetId2 = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
        vm.prank(bob);
        uint256 agreementId2 =
            licenseEscrow.createLicenseAgreement(assetId2, address(attacker), LICENSE_FEE, TERMS_HASH, TERMS_URI);
        vm.prank(address(attacker));
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId2);
        vm.prank(bob);
        licenseEscrow.confirmPerformance(agreementId2);

        // Arm the attacker: when it receives ETH, try to release() agreement 2.
        attacker.armReentryIntoReleaseOf(agreementId2);

        // Trigger the payout on agreement 1 (this is the call the arbiter, `address(this)`
        // — the test contract itself, since it's the deployer/default arbiter — makes).
        licenseEscrow.resolveDispute(agreementId1, false);

        // The cross-function reentrant call must have been blocked by the shared guard.
        assertTrue(attacker.reentrantCallReverted(), "reentrant release() on a different agreement should revert");

        // Agreement 2 must be untouched — still Active, still fully escrowed — because the
        // reentrant attempt to release() it never actually went through.
        LicenseEscrow.LicenseAgreement memory agreement2 = licenseEscrow.getAgreement(agreementId2);
        assertEq(uint8(agreement2.status), uint8(LicenseEscrow.LicenseStatus.Active));
        assertEq(agreement2.escrowedAmount, LICENSE_FEE);
    }
}

/// @dev Attacker contract used to exercise reentrancy. It can be armed to attempt one of two
///      reentrant calls from inside its own receive() when it's paid out by release() or
///      resolveDispute(): re-entering release() on the SAME agreement, or release() on a
///      DIFFERENT one (to specifically test the guard is shared contract-wide, not per
///      function). It swallows the reentrant call's revert with try/catch so the outer
///      payout call — the one under test — is free to succeed or fail on its own merits,
///      rather than being masked by the attacker's own receive() reverting.
contract ReentrantAttacker is IERC721Receiver {
    LicenseEscrow public immutable target;

    uint256 private _agreementIdToReenterOn;
    bool private _armed;
    bool public reentrantCallReverted;

    constructor(LicenseEscrow target_) {
        target = target_;
    }

    function armReentryIntoRelease(uint256 agreementId) external {
        _agreementIdToReenterOn = agreementId;
        _armed = true;
    }

    function armReentryIntoReleaseOf(uint256 agreementId) external {
        _agreementIdToReenterOn = agreementId;
        _armed = true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (!_armed) return;
        _armed = false; // disarm so the payment itself isn't re-triggered recursively

        try target.release(_agreementIdToReenterOn) {
            // If this succeeds, the reentrancy guard failed to do its job.
        } catch {
            reentrantCallReverted = true;
        }
    }
}
