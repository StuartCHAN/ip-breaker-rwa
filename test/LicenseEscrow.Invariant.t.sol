// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice Foundry invariant tests for the escrow flow. Unlike the example-based unit tests
///         in LicenseEscrowAgreement.t.sol (which each check one specific scenario), these run
///         long random sequences of calls through the Handler below and check that certain
///         properties hold no matter what sequence of legal-or-illegal actions was attempted.
///
/// @dev Ground truth for these invariants is read directly from the contract's own storage
///      via getAgreement() after every fuzz run — deliberately NOT duplicated into separate
///      handler-side "ghost" counters. Ghost-variable bookkeeping is itself code that can have
///      bugs, and a mismatch between ghost state and real state proves nothing about the
///      contract if the ghost tracking itself drifted. Reading the contract's own view
///      functions means every invariant failure points at the contract, not at the test's own
///      bookkeeping.
contract LicenseEscrowInvariantTest is Test {
    IPAssetRegistry internal assetRegistry;
    LicenseEscrow internal licenseEscrow;
    Handler internal handler;

    function setUp() public {
        assetRegistry = new IPAssetRegistry(address(new MockIdentityRegistry()));
        licenseEscrow = new LicenseEscrow(address(assetRegistry));
        handler = new Handler(assetRegistry, licenseEscrow);

        // Only fuzz calls through the Handler's bounded entry points — not arbitrary calls
        // directly into LicenseEscrow or IPAssetRegistry with fully random calldata, which
        // would mostly just hit input-validation reverts and never exercise the state machine.
        targetContract(address(handler));
    }

    /// @dev Core solvency invariant: the contract can never hold more or less ETH than the
    ///      sum of what every still-open agreement believes is escrowed. If this ever breaks,
    ///      either funds are stuck unaccounted for, or an agreement's bookkeeping promises
    ///      money that isn't actually in the contract.
    function invariant_ContractBalanceEqualsSumOfEscrowedAmounts() public view {
        uint256 sum = 0;
        uint256 count = handler.agreementIdsLength();

        for (uint256 i = 0; i < count; i++) {
            uint256 agreementId = handler.agreementIds(i);
            LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
            sum += agreement.escrowedAmount;
        }

        assertEq(address(licenseEscrow).balance, sum, "contract balance must equal total escrowed across agreements");
    }

    /// @dev Per-agreement invariant tying escrowedAmount to status, regardless of which path
    ///      (normal release, dispute+resolve either way, or never funded) the agreement took
    ///      to get there.
    function invariant_EscrowedAmountMatchesStatus() public view {
        uint256 count = handler.agreementIdsLength();

        for (uint256 i = 0; i < count; i++) {
            uint256 agreementId = handler.agreementIds(i);
            LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);

            if (agreement.status == LicenseEscrow.LicenseStatus.Created) {
                assertEq(agreement.escrowedAmount, 0, "Created agreement must have zero escrow");
            } else if (
                agreement.status == LicenseEscrow.LicenseStatus.Funded
                    || agreement.status == LicenseEscrow.LicenseStatus.Active
                    || agreement.status == LicenseEscrow.LicenseStatus.Disputed
            ) {
                assertEq(
                    agreement.escrowedAmount,
                    agreement.licenseFee,
                    "Funded/Active/Disputed agreement must escrow exactly its license fee"
                );
            } else {
                // Completed, Refunded, Cancelled are terminal and must be fully settled.
                assertEq(agreement.escrowedAmount, 0, "terminal-state agreement must have zero escrow left");
            }
        }
    }
}

/// @dev Bounded, revert-swallowing entry points for the invariant fuzzer to call. Each
///      function picks from a small fixed pool of actors and a small pool of already-created
///      agreements so the fuzzer spends its budget exploring realistic sequences (fund an
///      existing agreement, dispute it, resolve it, etc.) instead of mostly hitting
///      AgreementDoesNotExist on random uint256 values. Every call into LicenseEscrow is
///      wrapped in try/catch so that hitting an illegal transition (e.g. trying to fund an
///      already-Funded agreement) is treated as a no-op for the fuzzer, not a failed run —
///      illegal transitions failing IS the expected, correct behavior, not a bug to surface
///      here (that's what LicenseEscrowAgreement.t.sol and LicenseEscrow.StateMachine.t.sol
///      already check explicitly).
contract Handler is Test {
    IPAssetRegistry public immutable assetRegistry;
    LicenseEscrow public immutable licenseEscrow;

    address[] public actors;
    uint256[] public agreementIds;

    string private constant TITLE = "Invariant Fuzz Asset";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US";
    bytes32 private constant DOCUMENT_HASH = keccak256("invariant fuzz doc");
    string private constant METADATA_URI = "ipfs://invariant-fuzz-metadata";
    bytes32 private constant TERMS_HASH = keccak256("invariant-fuzz-terms");
    string private constant TERMS_URI = "ipfs://invariant-fuzz-terms";

    constructor(IPAssetRegistry assetRegistry_, LicenseEscrow licenseEscrow_) {
        assetRegistry = assetRegistry_;
        licenseEscrow = licenseEscrow_;

        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encodePacked("invariant-actor", i)))));
            vm.deal(actor, 1_000 ether);
            actors.push(actor);
        }
    }

    function agreementIdsLength() external view returns (uint256) {
        return agreementIds.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function createAgreement(uint256 licensorSeed, uint256 licenseeSeed, uint256 feeSeed) external {
        address licensor = _actor(licensorSeed);
        address licensee = _actor(licenseeSeed);

        if (licensee == licensor) {
            licensee = actors[(licenseeSeed + 1) % actors.length];
            if (licensee == licensor) return; // couldn't find a distinct actor, skip this run
        }

        uint256 fee = bound(feeSeed, 1, 100 ether);

        vm.prank(licensor);
        uint256 assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);

        vm.prank(licensor);
        try licenseEscrow.createLicenseAgreement(assetId, licensee, fee, TERMS_HASH, TERMS_URI) returns (
            uint256 agreementId
        ) {
            agreementIds.push(agreementId);
        } catch {}
    }

    function fund(uint256 idSeed) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        vm.deal(agreement.licensee, agreement.licenseFee + 1 ether);
        vm.prank(agreement.licensee);
        try licenseEscrow.fundLicense{value: agreement.licenseFee}(_idAt(idSeed)) {} catch {}
    }

    function confirmPerformance(uint256 idSeed) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        vm.prank(agreement.licensor);
        try licenseEscrow.confirmPerformance(_idAt(idSeed)) {} catch {}
    }

    function release(uint256 idSeed) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        vm.prank(agreement.licensee);
        try licenseEscrow.release(_idAt(idSeed)) {} catch {}
    }

    function raiseDispute(uint256 idSeed, bool asLicensor) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        address caller = asLicensor ? agreement.licensor : agreement.licensee;
        vm.prank(caller);
        try licenseEscrow.raiseDispute(_idAt(idSeed)) {} catch {}
    }

    function resolveDispute(uint256 idSeed, bool payToLicensor) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        vm.prank(agreement.arbiter);
        try licenseEscrow.resolveDispute(_idAt(idSeed), payToLicensor) {} catch {}
    }

    function cancelAgreement(uint256 idSeed) external {
        if (agreementIds.length == 0) return;
        LicenseEscrow.LicenseAgreement memory agreement = _agreementAt(idSeed);

        vm.prank(agreement.licensor);
        try licenseEscrow.cancelAgreement(_idAt(idSeed)) {} catch {}
    }

    function _idAt(uint256 seed) internal view returns (uint256) {
        return agreementIds[seed % agreementIds.length];
    }

    function _agreementAt(uint256 seed) internal view returns (LicenseEscrow.LicenseAgreement memory) {
        return licenseEscrow.getAgreement(_idAt(seed));
    }
}
