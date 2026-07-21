// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {IdentityRegistry} from "../contracts/IdentityRegistry.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @title Demo
/// @notice Runs the full IP Breaker RWA v0.1 demo flow on already deployed contracts.
/// @dev Required roles:
///      - PRIVATE_KEY: contract admin / deployer, used to approve reviewer
///      - ALICE_PRIVATE_KEY: IP asset owner / licensor
///      - REVIEWER_PRIVATE_KEY: due-diligence reviewer
///      - BOB_PRIVATE_KEY: license buyer
contract Demo is Script {
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

    uint256 private constant LICENSE_PRICE = 0.001 ether; // testing with a smaller price for demo purposes
    uint64 private constant LICENSE_DURATION = 365 days;

    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");

    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    function run() external {
        uint256 adminPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 alicePrivateKey = vm.envUint("ALICE_PRIVATE_KEY");
        uint256 reviewerPrivateKey = vm.envUint("REVIEWER_PRIVATE_KEY");
        uint256 bobPrivateKey = vm.envUint("BOB_PRIVATE_KEY");

        address admin = vm.addr(adminPrivateKey);
        address alice = vm.addr(alicePrivateKey);
        address reviewer = vm.addr(reviewerPrivateKey);
        address bob = vm.addr(bobPrivateKey);

        IdentityRegistry identityRegistry = IdentityRegistry(vm.envAddress("IDENTITY_REGISTRY"));

        IPAssetRegistry assetRegistry = IPAssetRegistry(vm.envAddress("IP_ASSET_REGISTRY"));

        EvidenceRegistry evidenceRegistry = EvidenceRegistry(vm.envAddress("EVIDENCE_REGISTRY"));

        LicenseEscrow licenseEscrow = LicenseEscrow(vm.envAddress("LICENSE_ESCROW"));

        console2.log("Running IP Breaker RWA demo");
        console2.log("Admin:", admin);
        console2.log("Alice / IP owner:", alice);
        console2.log("Reviewer:", reviewer);
        console2.log("Bob / license buyer:", bob);
        console2.log("IdentityRegistry:", address(identityRegistry));
        console2.log("IPAssetRegistry:", address(assetRegistry));
        console2.log("EvidenceRegistry:", address(evidenceRegistry));
        console2.log("LicenseEscrow:", address(licenseEscrow));

        // 1. Alice applies for the ASSET_OWNER role.
        vm.startBroadcast(alicePrivateKey);

        identityRegistry.registerIdentity("ipfs://encrypted-alice-kyc", identityRegistry.ROLE_ASSET_OWNER());

        vm.stopBroadcast();

        // 2. Admin verifies Alice and approves the evidence reviewer.
        vm.startBroadcast(adminPrivateKey);

        identityRegistry.verifyIdentity(alice, identityRegistry.ROLE_ASSET_OWNER(), 0);
        evidenceRegistry.setReviewer(reviewer, true);

        vm.stopBroadcast();

        console2.log("Reviewer approved");

        // 3. Alice registers an IP asset.
        vm.startBroadcast(alicePrivateKey);

        uint256 assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);

        console2.log("IP Asset registered");
        console2.log("assetId:", assetId);

        // 4. Alice adds ordinary technical evidence: GitHub commit proof.
        uint256 githubEvidenceId =
            evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        console2.log("GitHub evidence added");
        console2.log("githubEvidenceId:", githubEvidenceId);

        vm.stopBroadcast();

        // 5. Reviewer adds due-diligence evidence: FTO report.
        vm.startBroadcast(reviewerPrivateKey);

        uint256 ftoEvidenceId =
            evidenceRegistry.addEvidence(assetId, FTO_REPORT, FTO_REPORT_HASH, FTO_REPORT_URI, FTO_ATTESTATION_UID);

        vm.stopBroadcast();

        console2.log("FTO report evidence added");
        console2.log("ftoEvidenceId:", ftoEvidenceId);

        // 6. Alice creates a non-transferable commercial license offer.
        vm.startBroadcast(alicePrivateKey);

        uint256 offerId =
            licenseEscrow.createLicenseOffer(assetId, LICENSE_PRICE, LICENSE_DURATION, TERMS_HASH, TERMS_URI, false);

        vm.stopBroadcast();

        console2.log("License offer created");
        console2.log("offerId:", offerId);
        console2.log("license price:", LICENSE_PRICE);
        console2.log("transferable: false");

        // 7. Bob buys the license and receives a License Certificate NFT.
        vm.startBroadcast(bobPrivateKey);

        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        vm.stopBroadcast();

        console2.log("License purchased");
        console2.log("licenseId:", licenseId);
        console2.log("license owner:", licenseEscrow.ownerOf(licenseId));
        console2.log("total revenue by asset:", licenseEscrow.totalRevenueByAsset(assetId));

        LicenseEscrow.License memory licenseData = licenseEscrow.getLicense(licenseId);

        console2.log("License certificate details");
        console2.log("license assetId:", licenseData.assetId);
        console2.log("license offerId:", licenseData.offerId);
        console2.log("licensee:", licenseData.licensee);
        console2.log("issuedAt:", licenseData.issuedAt);
        console2.log("expiresAt:", licenseData.expiresAt);
        console2.log("termsURI:", licenseData.termsURI);
        console2.log("transferable:", licenseData.transferable);

        console2.log("Demo completed successfully");
    }
}
