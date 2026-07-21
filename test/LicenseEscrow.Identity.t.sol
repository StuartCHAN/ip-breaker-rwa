// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IdentityRegistry} from "../contracts/IdentityRegistry.sol";
import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @notice Phase 2.2-C1 identity checks for escrow agreement creation only.
contract LicenseEscrowIdentityTest is Test {
    IdentityRegistry private identityRegistry;
    IPAssetRegistry private assetRegistry;
    LicenseEscrow private licenseEscrow;

    address private licensor = makeAddr("licensor");
    address private licensee = makeAddr("licensee");
    address private newOwner = makeAddr("newOwner");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";
    bytes32 private constant DOCUMENT_HASH = keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    uint256 private constant LICENSE_FEE = 0.01 ether;
    bytes32 private constant TERMS_HASH = keccak256("commercial internal use, no resale, no sublicensing");
    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

    function setUp() public {
        identityRegistry = new IdentityRegistry();
        identityRegistry.grantVerifierRole(address(this));
        assetRegistry = new IPAssetRegistry(address(identityRegistry));
        licenseEscrow = new LicenseEscrow(address(assetRegistry), address(identityRegistry));
        vm.deal(licensee, 10 ether);
    }

    function testConstructorStoresIdentityRegistry() public view {
        assertEq(address(licenseEscrow.identityRegistry()), address(identityRegistry));
    }

    function testConstructorRevertsWhenIdentityRegistryIsZero() public {
        vm.expectRevert(LicenseEscrow.ZeroIdentityRegistry.selector);
        new LicenseEscrow(address(assetRegistry), address(0));
    }

    function testUnverifiedLicensorRejected() public {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        uint256 assetId = _registerAsset(licensor);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), 0);
        identityRegistry.revokeIdentity(licensor, "licensor revoked");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensor.selector, licensor));
        vm.prank(licensor);
        _createAgreement(assetId, licensee);
    }

    function testUnverifiedLicenseeRejected() public {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        uint256 assetId = _registerAsset(licensor);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensor);
        _createAgreement(assetId, licensee);
    }

    function testExpiredLicensorRejected() public {
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), expiresAt);
        uint256 assetId = _registerAsset(licensor);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), 0);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensor.selector, licensor));
        vm.prank(licensor);
        _createAgreement(assetId, licensee);
    }

    function testExpiredLicenseeRejected() public {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        uint256 assetId = _registerAsset(licensor);
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), expiresAt);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensor);
        _createAgreement(assetId, licensee);
    }

    function testVerifiedOwnerAndLicenseeCanCreateAgreement() public {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), 0);
        uint256 assetId = _registerAsset(licensor);

        vm.prank(licensor);
        uint256 agreementId = _createAgreement(assetId, licensee);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(agreement.licensor, licensor);
        assertEq(agreement.licensee, licensee);
        assertEq(uint256(agreement.status), uint256(LicenseEscrow.LicenseStatus.Created));
    }

    function testNftTransferredAwayPreviousOwnerRejected() public {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(newOwner, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), 0);
        uint256 assetId = _registerAsset(licensor);

        vm.prank(licensor);
        assetRegistry.transferFrom(licensor, newOwner, assetId);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotAssetOwner.selector, assetId, licensor));
        vm.prank(licensor);
        _createAgreement(assetId, licensee);
    }

    function testUnverifiedLicenseeCannotFund() public {
        uint256 agreementId = _createAgreementWithVerifiedParties(0);
        identityRegistry.suspendIdentity(licensee, "licensee suspended");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _assertAgreementUnchangedAfterFailedFunding(agreementId);
    }

    function testExpiredLicenseeCannotFund() public {
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        uint256 agreementId = _createAgreementWithVerifiedParties(expiresAt);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _assertAgreementUnchangedAfterFailedFunding(agreementId);
    }

    function testRevokedLicenseeCannotFund() public {
        uint256 agreementId = _createAgreementWithVerifiedParties(0);
        identityRegistry.revokeIdentity(licensee, "licensee revoked");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        _assertAgreementUnchangedAfterFailedFunding(agreementId);
    }

    function testVerifiedLicenseeCanFund() public {
        uint256 agreementId = _createAgreementWithVerifiedParties(0);

        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LicenseEscrow.LicenseStatus.Funded));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertEq(agreement.fundedAt, block.timestamp);
        assertEq(address(licenseEscrow).balance, LICENSE_FEE);
    }

    function testRejectedFundingLeavesExistingAgreementUnchanged() public {
        uint256 agreementId = _createAgreementWithVerifiedParties(0);
        LicenseEscrow.LicenseAgreement memory beforeFailure = licenseEscrow.getAgreement(agreementId);
        identityRegistry.suspendIdentity(licensee, "licensee suspended");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensee.selector, licensee));
        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);

        LicenseEscrow.LicenseAgreement memory afterFailure = licenseEscrow.getAgreement(agreementId);
        assertEq(afterFailure.assetId, beforeFailure.assetId);
        assertEq(afterFailure.licensor, beforeFailure.licensor);
        assertEq(afterFailure.licensee, beforeFailure.licensee);
        assertEq(afterFailure.arbiter, beforeFailure.arbiter);
        assertEq(afterFailure.licenseFee, beforeFailure.licenseFee);
        assertEq(afterFailure.termsHash, beforeFailure.termsHash);
        assertEq(afterFailure.createdAt, beforeFailure.createdAt);
        assertEq(uint256(afterFailure.status), uint256(beforeFailure.status));
        assertEq(afterFailure.escrowedAmount, beforeFailure.escrowedAmount);
        assertEq(afterFailure.fundedAt, beforeFailure.fundedAt);
        assertEq(address(licenseEscrow).balance, 0);
    }

    function testSuspendedLicensorCannotConfirmPerformance() public {
        uint256 agreementId = _createFundedAgreement(0);
        identityRegistry.suspendIdentity(licensor, "licensor suspended");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensor.selector, licensor));
        vm.prank(licensor);
        licenseEscrow.confirmPerformance(agreementId);

        _assertFundedAgreementUnchanged(agreementId);
    }

    function testExpiredLicensorCannotConfirmPerformance() public {
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        uint256 agreementId = _createFundedAgreement(expiresAt);
        vm.warp(expiresAt);

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensor.selector, licensor));
        vm.prank(licensor);
        licenseEscrow.confirmPerformance(agreementId);

        _assertFundedAgreementUnchanged(agreementId);
    }

    function testRevokedLicensorCannotConfirmPerformance() public {
        uint256 agreementId = _createFundedAgreement(0);
        identityRegistry.revokeIdentity(licensor, "licensor revoked");

        vm.expectRevert(abi.encodeWithSelector(LicenseEscrow.NotVerifiedLicensor.selector, licensor));
        vm.prank(licensor);
        licenseEscrow.confirmPerformance(agreementId);

        _assertFundedAgreementUnchanged(agreementId);
    }

    function testValidLicensorCanConfirmPerformance() public {
        uint256 agreementId = _createFundedAgreement(0);

        vm.prank(licensor);
        licenseEscrow.confirmPerformance(agreementId);

        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LicenseEscrow.LicenseStatus.Active));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertGt(agreement.fundedAt, 0);
        assertEq(address(licenseEscrow).balance, LICENSE_FEE);
    }

    function _verifyIdentity(address account, uint256 roles, uint64 expiresAt) private {
        vm.prank(account);
        identityRegistry.registerIdentity("ipfs://encrypted-kyc", roles);
        identityRegistry.verifyIdentity(account, roles, expiresAt);
    }

    function _registerAsset(address owner) private returns (uint256 assetId) {
        vm.prank(owner);
        assetId = assetRegistry.registerAsset(TITLE, ASSET_TYPE, JURISDICTION, DOCUMENT_HASH, METADATA_URI);
    }

    function _createAgreement(uint256 assetId, address agreementLicensee) private returns (uint256 agreementId) {
        agreementId =
            licenseEscrow.createLicenseAgreement(assetId, agreementLicensee, LICENSE_FEE, TERMS_HASH, TERMS_URI);
    }

    function _createAgreementWithVerifiedParties(uint64 licenseeExpiresAt) private returns (uint256 agreementId) {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), 0);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), licenseeExpiresAt);
        uint256 assetId = _registerAsset(licensor);

        vm.prank(licensor);
        agreementId = _createAgreement(assetId, licensee);
    }

    function _createFundedAgreement(uint64 licensorExpiresAt) private returns (uint256 agreementId) {
        _verifyIdentity(licensor, identityRegistry.ROLE_ASSET_OWNER(), licensorExpiresAt);
        _verifyIdentity(licensee, identityRegistry.ROLE_LICENSEE(), 0);
        uint256 assetId = _registerAsset(licensor);

        vm.prank(licensor);
        agreementId = _createAgreement(assetId, licensee);

        vm.prank(licensee);
        licenseEscrow.fundLicense{value: LICENSE_FEE}(agreementId);
    }

    function _assertAgreementUnchangedAfterFailedFunding(uint256 agreementId) private view {
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LicenseEscrow.LicenseStatus.Created));
        assertEq(agreement.escrowedAmount, 0);
        assertEq(agreement.fundedAt, 0);
        assertEq(address(licenseEscrow).balance, 0);
    }

    function _assertFundedAgreementUnchanged(uint256 agreementId) private view {
        LicenseEscrow.LicenseAgreement memory agreement = licenseEscrow.getAgreement(agreementId);
        assertEq(uint256(agreement.status), uint256(LicenseEscrow.LicenseStatus.Funded));
        assertEq(agreement.escrowedAmount, LICENSE_FEE);
        assertGt(agreement.fundedAt, 0);
        assertEq(address(licenseEscrow).balance, LICENSE_FEE);
    }
}
