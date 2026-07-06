// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";

contract EvidenceRegistryTest is Test {
    IPAssetRegistry private assetRegistry;
    EvidenceRegistry private evidenceRegistry;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private reviewer = makeAddr("reviewer");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN"; //要注意一下各种法域
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";

    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    string private constant GITHUB_COMMIT = "GITHUB_COMMIT";
    string private constant OWNERSHIP_CLAIM = "OWNERSHIP_CLAIM";
    string private constant FTO_REPORT = "FTO_REPORT";
    string private constant RISK_REPORT = "RISK_REPORT";

    string private constant GITHUB_EVIDENCE_URI = "ipfs://github-commit-proof";
    string private constant FTO_REPORT_URI = "ipfs://fto-report";
    string private constant RISK_REPORT_URI = "ipfs://ip-risk-report";

    bytes32 private constant GITHUB_EVIDENCE_HASH = keccak256("github commit hash proof");

    bytes32 private constant FTO_REPORT_HASH = keccak256("freedom to operate report v1");

    bytes32 private constant RISK_REPORT_HASH = keccak256("risk report v1");

    bytes32 private constant ATTESTATION_UID = keccak256("mock-eas-attestation-uid");

    event ReviewerUpdated(address indexed reviewer, bool approved);

    event EvidenceAdded(
        uint256 indexed assetId,
        uint256 indexed evidenceId,
        address indexed submittedBy,
        string evidenceType,
        bytes32 evidenceHash,
        string evidenceURI,
        bytes32 attestationUID
    );

    function setUp() public {
        assetRegistry = new IPAssetRegistry();
        evidenceRegistry = new EvidenceRegistry(address(assetRegistry));
    }

    function testConstructorStoresAssetRegistry() public view {
        assertEq(address(evidenceRegistry.assetRegistry()), address(assetRegistry));
    }

    function testConstructorRevertsWhenAssetRegistryIsZero() public {
        vm.expectRevert(EvidenceRegistry.ZeroAssetRegistry.selector);
        new EvidenceRegistry(address(0));
    }

    function testSetReviewerApprovesReviewer() public {
        vm.expectEmit(true, false, false, true, address(evidenceRegistry));
        emit ReviewerUpdated(reviewer, true);

        evidenceRegistry.setReviewer(reviewer, true);

        assertTrue(evidenceRegistry.reviewers(reviewer));
    }

    function testSetReviewerCanRemoveReviewer() public {
        evidenceRegistry.setReviewer(reviewer, true);
        assertTrue(evidenceRegistry.reviewers(reviewer));

        vm.expectEmit(true, false, false, true, address(evidenceRegistry));
        emit ReviewerUpdated(reviewer, false);

        evidenceRegistry.setReviewer(reviewer, false);

        assertFalse(evidenceRegistry.reviewers(reviewer));
    }

    function testSetReviewerRevertsWhenReviewerIsZero() public {
        vm.expectRevert(EvidenceRegistry.ZeroReviewer.selector);
        evidenceRegistry.setReviewer(address(0), true);
    }

    function testAssetOwnerCanAddOrdinaryEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 evidenceId =
            evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        assertEq(evidenceId, 1);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);

        assertEq(evidence.assetId, assetId);
        assertEq(evidence.evidenceType, GITHUB_COMMIT);
        assertEq(evidence.evidenceHash, GITHUB_EVIDENCE_HASH);
        assertEq(evidence.evidenceURI, GITHUB_EVIDENCE_URI);
        assertEq(evidence.attestationUID, bytes32(0));
        assertEq(evidence.submittedBy, alice);
        assertEq(evidence.submittedAt, block.timestamp);
    }

    function testAddEvidenceStoresEvidenceIdUnderAsset() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 firstEvidenceId =
            evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        vm.prank(alice);
        uint256 secondEvidenceId = evidenceRegistry.addEvidence(
            assetId, OWNERSHIP_CLAIM, keccak256("ownership claim document"), "ipfs://ownership-claim", ATTESTATION_UID
        );

        uint256[] memory evidenceIds = evidenceRegistry.getEvidenceIds(assetId);

        assertEq(evidenceIds.length, 2);
        assertEq(evidenceIds[0], firstEvidenceId);
        assertEq(evidenceIds[1], secondEvidenceId);
    }

    function testReviewerCanAddFTOReport() public {
        uint256 assetId = _registerDefaultAsset(alice);

        evidenceRegistry.setReviewer(reviewer, true);

        vm.prank(reviewer);
        uint256 evidenceId =
            evidenceRegistry.addEvidence(assetId, FTO_REPORT, FTO_REPORT_HASH, FTO_REPORT_URI, ATTESTATION_UID);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);

        assertEq(evidence.assetId, assetId);
        assertEq(evidence.evidenceType, FTO_REPORT);
        assertEq(evidence.evidenceHash, FTO_REPORT_HASH);
        assertEq(evidence.evidenceURI, FTO_REPORT_URI);
        assertEq(evidence.attestationUID, ATTESTATION_UID);
        assertEq(evidence.submittedBy, reviewer);
    }

    function testReviewerCanAddRiskReport() public {
        uint256 assetId = _registerDefaultAsset(alice);

        evidenceRegistry.setReviewer(reviewer, true);

        vm.prank(reviewer);
        uint256 evidenceId =
            evidenceRegistry.addEvidence(assetId, RISK_REPORT, RISK_REPORT_HASH, RISK_REPORT_URI, ATTESTATION_UID);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);

        assertEq(evidence.evidenceType, RISK_REPORT);
        assertEq(evidence.submittedBy, reviewer);
    }

    function testNonOwnerCannotAddOrdinaryEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotAssetOwner.selector, assetId, bob));

        vm.prank(bob);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testReviewerCannotAddOrdinaryEvidenceForAssetTheyDoNotOwn() public {
        uint256 assetId = _registerDefaultAsset(alice);

        evidenceRegistry.setReviewer(reviewer, true);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotAssetOwner.selector, assetId, reviewer));

        vm.prank(reviewer);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testAssetOwnerCannotAddReviewerEvidenceUnlessReviewer() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotReviewer.selector, alice));

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, RISK_REPORT, RISK_REPORT_HASH, RISK_REPORT_URI, ATTESTATION_UID);
    }

    function testUnauthorizedAddressCannotAddReviewerEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotReviewer.selector, bob));

        vm.prank(bob);
        evidenceRegistry.addEvidence(assetId, FTO_REPORT, FTO_REPORT_HASH, FTO_REPORT_URI, ATTESTATION_UID);
    }

    function testAddEvidenceRevertsWhenAssetDoesNotExist() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.AssetDoesNotExist.selector, missingAssetId));

        vm.prank(alice);
        evidenceRegistry.addEvidence(
            missingAssetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0)
        );
    }

    function testAddEvidenceRevertsWhenEvidenceTypeIsEmpty() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(EvidenceRegistry.EmptyEvidenceType.selector);

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, "", GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testAddEvidenceRevertsWhenEvidenceHashIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(EvidenceRegistry.ZeroEvidenceHash.selector);

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, bytes32(0), GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testAddEvidenceRevertsWhenEvidenceURIIsEmpty() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(EvidenceRegistry.EmptyEvidenceURI.selector);

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, "", bytes32(0));
    }

    function testAddEvidenceEmitsEvent() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectEmit(true, true, true, true, address(evidenceRegistry));
        emit EvidenceAdded(assetId, 1, alice, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testGetEvidenceRevertsWhenEvidenceDoesNotExist() public {
        uint256 missingEvidenceId = 999;

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.EvidenceDoesNotExist.selector, missingEvidenceId));

        evidenceRegistry.getEvidence(missingEvidenceId);
    }

    function testGetEvidenceIdsRevertsWhenAssetDoesNotExist() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.AssetDoesNotExist.selector, missingAssetId));

        evidenceRegistry.getEvidenceIds(missingAssetId);
    }

    function testNextEvidenceIdStartsAtOne() public view {
        assertEq(evidenceRegistry.nextEvidenceId(), 1);
    }

    function testNextEvidenceIdIncrementsAfterEvidenceAdded() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));

        assertEq(evidenceRegistry.nextEvidenceId(), 2);
    }

    function testIsReviewerEvidenceReturnsTrueForFTOAndRiskReports() public view {
        assertTrue(evidenceRegistry.isReviewerEvidence(FTO_REPORT));
        assertTrue(evidenceRegistry.isReviewerEvidence(RISK_REPORT));
    }

    function testIsReviewerEvidenceReturnsFalseForOrdinaryEvidence() public view {
        assertFalse(evidenceRegistry.isReviewerEvidence(GITHUB_COMMIT));
        assertFalse(evidenceRegistry.isReviewerEvidence(OWNERSHIP_CLAIM));
    }

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }
}
