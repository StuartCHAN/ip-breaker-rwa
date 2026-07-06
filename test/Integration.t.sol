// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @title IP Breaker RWA Integration Test
/// @notice Runs the full v0.1 demo flow:
///         register IP asset -> attach evidence -> create license offer -> buy license certificate.
contract IntegrationTest is Test {
    IPAssetRegistry private assetRegistry;
    EvidenceRegistry private evidenceRegistry;
    LicenseEscrow private licenseEscrow;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private reviewer = makeAddr("reviewer");
    address private carol = makeAddr("carol");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";

    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    string private constant GITHUB_COMMIT = "GITHUB_COMMIT";
    string private constant FTO_REPORT = "FTO_REPORT";

    bytes32 private constant GITHUB_EVIDENCE_HASH = keccak256("github commit proof for ai patent drafting assistant");

    bytes32 private constant FTO_REPORT_HASH = keccak256("freedom to operate report for ai patent drafting assistant");

    string private constant GITHUB_EVIDENCE_URI = "ipfs://github-commit-proof";
    string private constant FTO_REPORT_URI = "ipfs://fto-report";

    bytes32 private constant FTO_ATTESTATION_UID = keccak256("mock-eas-attestation-uid-for-fto-report");

    uint256 private constant LICENSE_PRICE = 0.01 ether;
    uint64 private constant LICENSE_DURATION = 365 days;

    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");

    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    function setUp() public {
        assetRegistry = new IPAssetRegistry();
        evidenceRegistry = new EvidenceRegistry(address(assetRegistry));
        licenseEscrow = new LicenseEscrow(address(assetRegistry));

        vm.deal(bob, 1 ether);
        vm.deal(carol, 1 ether);

        evidenceRegistry.setReviewer(reviewer, true);
    }

    function testFullIPBreakerRWADemoFlow() public {
        // 1. Alice registers an IP asset.
        vm.prank(alice);
        uint256 assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);

        assertEq(assetId, 1);
        assertEq(assetRegistry.ownerOf(assetId), alice);
        assertTrue(assetRegistry.exists(assetId));

        IPAssetRegistry.IPAsset memory asset = assetRegistry.getAsset(assetId);

        assertEq(asset.title, TITLE);
        assertEq(asset.assetType, ASSET_TYPE);
        assertEq(asset.jurisdiction, JURISDICTION);
        assertEq(asset.documentHash, DOCUMENT_HASH);
        assertEq(asset.metadataURI, METADATA_URI);

        // 2. Alice adds ordinary technical evidence: GitHub commit proof.
        vm.prank(alice);
        uint256 githubEvidenceId =
            evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        assertEq(githubEvidenceId, 1);

        EvidenceRegistry.Evidence memory githubEvidence = evidenceRegistry.getEvidence(githubEvidenceId);

        assertEq(githubEvidence.assetId, assetId);
        assertEq(githubEvidence.evidenceType, GITHUB_COMMIT);
        assertEq(githubEvidence.evidenceHash, GITHUB_EVIDENCE_HASH);
        assertEq(githubEvidence.evidenceURI, GITHUB_EVIDENCE_URI);
        assertEq(githubEvidence.submittedBy, alice);

        // 3. Authorized reviewer adds due-diligence evidence: FTO report.
        vm.prank(reviewer);
        uint256 ftoEvidenceId =
            evidenceRegistry.addEvidence(assetId, FTO_REPORT, FTO_REPORT_HASH, FTO_REPORT_URI, FTO_ATTESTATION_UID);

        assertEq(ftoEvidenceId, 2);

        EvidenceRegistry.Evidence memory ftoEvidence = evidenceRegistry.getEvidence(ftoEvidenceId);

        assertEq(ftoEvidence.assetId, assetId);
        assertEq(ftoEvidence.evidenceType, FTO_REPORT);
        assertEq(ftoEvidence.evidenceHash, FTO_REPORT_HASH);
        assertEq(ftoEvidence.evidenceURI, FTO_REPORT_URI);
        assertEq(ftoEvidence.attestationUID, FTO_ATTESTATION_UID);
        assertEq(ftoEvidence.submittedBy, reviewer);

        uint256[] memory evidenceIds = evidenceRegistry.getEvidenceIds(assetId);

        assertEq(evidenceIds.length, 2);
        assertEq(evidenceIds[0], githubEvidenceId);
        assertEq(evidenceIds[1], ftoEvidenceId);

        // 4. Alice creates a non-transferable commercial license offer.
        bool transferable = false;

        vm.prank(alice);
        uint256 offerId = licenseEscrow.createLicenseOffer(
            assetId, LICENSE_PRICE, LICENSE_DURATION, TERMS_HASH, TERMS_URI, transferable
        );

        assertEq(offerId, 1);

        LicenseEscrow.LicenseOffer memory offer = licenseEscrow.getLicenseOffer(offerId);

        assertEq(offer.assetId, assetId);
        assertEq(offer.licensor, alice);
        assertEq(offer.price, LICENSE_PRICE);
        assertEq(offer.duration, LICENSE_DURATION);
        assertEq(offer.termsHash, TERMS_HASH);
        assertEq(offer.termsURI, TERMS_URI);
        assertFalse(offer.transferable);
        assertTrue(offer.active);

        // 5. Bob buys the license and receives a License Certificate NFT.
        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertEq(licenseId, 1);
        assertEq(licenseEscrow.ownerOf(licenseId), bob);
        assertEq(alice.balance, aliceBalanceBefore + LICENSE_PRICE);
        assertEq(bob.balance, bobBalanceBefore - LICENSE_PRICE);
        assertEq(licenseEscrow.totalRevenueByAsset(assetId), LICENSE_PRICE);

        LicenseEscrow.License memory licenseData = licenseEscrow.getLicense(licenseId);

        assertEq(licenseData.assetId, assetId);
        assertEq(licenseData.offerId, offerId);
        assertEq(licenseData.licensee, bob);
        assertEq(licenseData.issuedAt, block.timestamp);
        assertEq(licenseData.expiresAt, block.timestamp + LICENSE_DURATION);
        assertEq(licenseData.termsHash, TERMS_HASH);
        assertEq(licenseData.termsURI, TERMS_URI);
        assertFalse(licenseData.transferable);

        assertTrue(licenseEscrow.isLicenseValid(licenseId));
        assertEq(licenseEscrow.tokenURI(licenseId), TERMS_URI);

        // 6. Because this license is non-transferable, Bob cannot trade it away.
        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NonTransferableLicense.selector, licenseId));

        vm.prank(bob);
        licenseEscrow.transferFrom(bob, carol, licenseId);
    }

    function testFullDemoLicenseExpiresAfterDuration() public {
        uint256 assetId = _registerAssetAsAlice();
        uint256 offerId = _createNonTransferableOfferAsAlice(assetId);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertTrue(licenseEscrow.isLicenseValid(licenseId));

        vm.warp(block.timestamp + LICENSE_DURATION + 1);

        assertFalse(licenseEscrow.isLicenseValid(licenseId));
    }

    function _registerAssetAsAlice() private returns (uint256 assetId) {
        vm.prank(alice);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }

    function _createNonTransferableOfferAsAlice(uint256 assetId) private returns (uint256 offerId) {
        vm.prank(alice);
        offerId =
            licenseEscrow.createLicenseOffer(assetId, LICENSE_PRICE, LICENSE_DURATION, TERMS_HASH, TERMS_URI, false);
    }
}
