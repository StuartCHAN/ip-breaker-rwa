// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {IdentityRegistry} from "../contracts/IdentityRegistry.sol";

contract EvidenceRegistryTest is Test {
    IPAssetRegistry private assetRegistry;
    EvidenceRegistry private evidenceRegistry;
    IdentityRegistry private identityRegistry;

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

    event EvidenceAdded(
        uint256 indexed assetId,
        uint256 indexed evidenceId,
        address indexed submittedBy,
        string evidenceType,
        bytes32 evidenceHash,
        string evidenceURI,
        bytes32 attestationUID
    );

    event EvidenceStatusChanged(
        uint256 indexed evidenceId,
        EvidenceRegistry.EvidenceStatus indexed previousStatus,
        EvidenceRegistry.EvidenceStatus indexed newStatus,
        address reviewedBy
    );

    function setUp() public {
        identityRegistry = new IdentityRegistry();
        identityRegistry.grantVerifierRole(address(this));
        assetRegistry = new IPAssetRegistry(address(identityRegistry));
        evidenceRegistry = new EvidenceRegistry(address(assetRegistry), address(identityRegistry));

        _verifyIdentity(alice, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(bob, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(reviewer, identityRegistry.ROLE_VERIFIER(), 0);
    }

    function testConstructorStoresDependencies() public view {
        assertEq(address(evidenceRegistry.assetRegistry()), address(assetRegistry));
        assertEq(address(evidenceRegistry.identityRegistry()), address(identityRegistry));
    }

    function testConstructorRevertsWhenAssetRegistryIsZero() public {
        vm.expectRevert(EvidenceRegistry.ZeroAssetRegistry.selector);
        new EvidenceRegistry(address(0), address(identityRegistry));
    }

    function testConstructorRevertsWhenIdentityRegistryIsZero() public {
        vm.expectRevert(EvidenceRegistry.ZeroIdentityRegistry.selector);
        new EvidenceRegistry(address(assetRegistry), address(0));
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
        assertEq(uint256(evidence.status), uint256(EvidenceRegistry.EvidenceStatus.Submitted));
        assertEq(evidence.reviewedBy, address(0));
        assertEq(evidence.reviewedAt, 0);
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

    function testVerifiedAssetOwnerCanSubmitFTOReport() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 evidenceId =
            evidenceRegistry.addEvidence(assetId, FTO_REPORT, FTO_REPORT_HASH, FTO_REPORT_URI, ATTESTATION_UID);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);

        assertEq(evidence.assetId, assetId);
        assertEq(evidence.evidenceType, FTO_REPORT);
        assertEq(evidence.evidenceHash, FTO_REPORT_HASH);
        assertEq(evidence.evidenceURI, FTO_REPORT_URI);
        assertEq(evidence.attestationUID, ATTESTATION_UID);
        assertEq(evidence.submittedBy, alice);
    }

    function testUnverifiedOwnerCannotSubmitEvidence() public {
        address unverifiedOwner = makeAddr("unverifiedOwner");
        _verifyIdentity(unverifiedOwner, identityRegistry.ROLE_ASSET_OWNER(), 0);
        uint256 assetId = _registerDefaultAsset(unverifiedOwner);
        identityRegistry.revokeIdentity(unverifiedOwner, "identity revoked");

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedAssetOwner.selector, unverifiedOwner));
        vm.prank(unverifiedOwner);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testExpiredAssetOwnerCannotSubmitEvidence() public {
        address expiredOwner = makeAddr("expiredOwner");
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        _verifyIdentity(expiredOwner, identityRegistry.ROLE_ASSET_OWNER(), expiresAt);
        uint256 assetId = _registerDefaultAsset(expiredOwner);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedAssetOwner.selector, expiredOwner));
        vm.prank(expiredOwner);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testNonVerifierCannotApproveEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 evidenceId = _addDefaultEvidence(assetId, alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedVerifier.selector, bob));
        vm.prank(bob);
        evidenceRegistry.verifyEvidence(evidenceId);
    }

    function testVerifiedVerifierCanApproveEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 evidenceId = _addDefaultEvidence(assetId, alice);

        vm.expectEmit(true, true, true, true, address(evidenceRegistry));
        emit EvidenceStatusChanged(
            evidenceId, EvidenceRegistry.EvidenceStatus.Submitted, EvidenceRegistry.EvidenceStatus.Verified, reviewer
        );

        vm.prank(reviewer);
        evidenceRegistry.verifyEvidence(evidenceId);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);
        assertEq(uint256(evidence.status), uint256(EvidenceRegistry.EvidenceStatus.Verified));
        assertEq(evidence.reviewedBy, reviewer);
        assertEq(evidence.reviewedAt, block.timestamp);
    }

    function testExpiredVerifierCannotApproveEvidence() public {
        address expiredVerifier = makeAddr("expiredVerifier");
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        _verifyIdentity(expiredVerifier, identityRegistry.ROLE_VERIFIER(), expiresAt);
        uint256 evidenceId = _addDefaultEvidence(_registerDefaultAsset(alice), alice);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedVerifier.selector, expiredVerifier));
        vm.prank(expiredVerifier);
        evidenceRegistry.verifyEvidence(evidenceId);
    }

    function testRevokedVerifierCannotApproveEvidence() public {
        uint256 evidenceId = _addDefaultEvidence(_registerDefaultAsset(alice), alice);
        identityRegistry.revokeIdentity(reviewer, "verifier revoked");

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedVerifier.selector, reviewer));
        vm.prank(reviewer);
        evidenceRegistry.verifyEvidence(evidenceId);
    }

    function testVerifierCanRejectSubmittedEvidence() public {
        uint256 evidenceId = _addDefaultEvidence(_registerDefaultAsset(alice), alice);

        vm.prank(reviewer);
        evidenceRegistry.rejectEvidence(evidenceId);

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);
        assertEq(uint256(evidence.status), uint256(EvidenceRegistry.EvidenceStatus.Rejected));
    }

    function testVerifierCanRevokeVerifiedEvidence() public {
        uint256 evidenceId = _addDefaultEvidence(_registerDefaultAsset(alice), alice);

        vm.startPrank(reviewer);
        evidenceRegistry.verifyEvidence(evidenceId);
        evidenceRegistry.revokeEvidence(evidenceId);
        vm.stopPrank();

        EvidenceRegistry.Evidence memory evidence = evidenceRegistry.getEvidence(evidenceId);
        assertEq(uint256(evidence.status), uint256(EvidenceRegistry.EvidenceStatus.Revoked));
    }

    function testCannotApproveEvidenceTwice() public {
        uint256 evidenceId = _addDefaultEvidence(_registerDefaultAsset(alice), alice);

        vm.startPrank(reviewer);
        evidenceRegistry.verifyEvidence(evidenceId);
        vm.expectRevert(
            abi.encodeWithSelector(
                EvidenceRegistry.InvalidEvidenceStatus.selector,
                evidenceId,
                EvidenceRegistry.EvidenceStatus.Verified,
                EvidenceRegistry.EvidenceStatus.Submitted
            )
        );
        evidenceRegistry.verifyEvidence(evidenceId);
        vm.stopPrank();
    }

    function testNonOwnerCannotAddOrdinaryEvidence() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotAssetOwner.selector, assetId, bob));

        vm.prank(bob);
        evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function testVerifierCannotSubmitEvidenceForAssetTheyDoNotOwn() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(abi.encodeWithSelector(EvidenceRegistry.NotVerifiedAssetOwner.selector, reviewer));

        vm.prank(reviewer);
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

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }

    function _addDefaultEvidence(uint256 assetId, address submitter) private returns (uint256 evidenceId) {
        vm.prank(submitter);
        evidenceId =
            evidenceRegistry.addEvidence(assetId, GITHUB_COMMIT, GITHUB_EVIDENCE_HASH, GITHUB_EVIDENCE_URI, bytes32(0));
    }

    function _verifyIdentity(address account, uint256 roles, uint64 expiresAt) private {
        vm.prank(account);
        identityRegistry.registerIdentity("ipfs://encrypted-kyc", roles);
        identityRegistry.verifyIdentity(account, roles, expiresAt);
    }
}
