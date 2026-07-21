// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/IdentityRegistry.sol";

contract IdentityRegistryTest is Test {
    IdentityRegistry public registry;

    address public admin;
    address public verifier;
    address public user1;
    address public user2;

    // Cache role constants to avoid consuming vm.prank
    uint256 public ROLE_ASSET_OWNER;
    uint256 public ROLE_LICENSEE;
    uint256 public ROLE_INVESTOR;
    uint256 public ROLE_VERIFIER;
    uint256 public ROLE_ARBITRATOR;

    string constant METADATA_URI = "ipfs://QmTest123";
    string constant REJECTION_REASON = "Incomplete KYC documents";
    string constant SUSPENSION_REASON = "KYC expired";
    string constant REVOCATION_REASON = "Fraudulent activity detected";

    event IdentityRegistered(address indexed account, uint256 timestamp, uint256 requestedRoles);
    event IdentityVerified(address indexed account, address indexed verifier, uint256 grantedRoles, uint64 expiresAt);
    event IdentityRejected(address indexed account, address indexed verifier, string reason);
    event IdentitySuspended(address indexed account, address indexed actor, string reason);
    event IdentityRestored(address indexed account, address indexed actor);
    event IdentityRevoked(address indexed account, address indexed admin, string reason);

    function setUp() public {
        admin = address(this);
        verifier = makeAddr("verifier");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        registry = new IdentityRegistry();

        // Cache role constants
        ROLE_ASSET_OWNER = registry.ROLE_ASSET_OWNER();
        ROLE_LICENSEE = registry.ROLE_LICENSEE();
        ROLE_INVESTOR = registry.ROLE_INVESTOR();
        ROLE_VERIFIER = registry.ROLE_VERIFIER();
        ROLE_ARBITRATOR = registry.ROLE_ARBITRATOR();

        // Grant VERIFIER_MANAGER_ROLE to verifier
        registry.grantVerifierRole(verifier);
    }

    /*//////////////////////////////////////////////////////////////
                        REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegisterIdentity() public {
        vm.expectEmit(true, false, false, true);
        emit IdentityRegistered(user1, block.timestamp, ROLE_ASSET_OWNER);

        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Pending));
        assertEq(identity.createdAt, block.timestamp);
        assertEq(identity.metadataURI, METADATA_URI);
    }

    function testRegisterWithMultipleRoles() public {
        uint256 multiRoles = ROLE_ASSET_OWNER | ROLE_LICENSEE;

        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, multiRoles);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Pending));
    }

    function testCannotRegisterTwiceFromPending() public {
        vm.startPrank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.expectRevert(IdentityRegistry.AlreadyRegistered.selector);
        registry.registerIdentity(METADATA_URI, ROLE_LICENSEE);
        vm.stopPrank();
    }

    function testCannotRegisterTwiceFromVerified() public {
        // Register and verify
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        // Try to register again
        vm.prank(user1);
        vm.expectRevert(IdentityRegistry.AlreadyRegistered.selector);
        registry.registerIdentity(METADATA_URI, ROLE_LICENSEE);
    }

    function testCannotRegisterWithZeroRoles() public {
        vm.prank(user1);
        vm.expectRevert(IdentityRegistry.InvalidRoleMask.selector);
        registry.registerIdentity(METADATA_URI, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        VERIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testVerifyIdentity() public {
        // Register
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        uint64 expiresAt = uint64(block.timestamp + 365 days);

        vm.expectEmit(true, true, false, true);
        emit IdentityVerified(user1, verifier, ROLE_ASSET_OWNER, expiresAt);

        // Verify
        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, expiresAt);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Verified));
        assertEq(identity.verifiedAt, block.timestamp);
        assertEq(identity.expiresAt, expiresAt);
        assertEq(identity.roleMask, ROLE_ASSET_OWNER);
        assertEq(identity.verifier, verifier);
    }

    function testVerifyWithDifferentRolesThanRequested() public {
        // User requests ASSET_OWNER + LICENSEE
        uint256 multiRoles = ROLE_ASSET_OWNER | ROLE_LICENSEE;

        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, multiRoles);

        // Verifier only grants LICENSEE
        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_LICENSEE, 0);

        assertTrue(registry.hasBusinessRole(user1, ROLE_LICENSEE));
        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    function testOnlyVerifierCanVerify() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(user2);
        vm.expectRevert();
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);
    }

    function testCannotVerifyNonPendingIdentity() public {
        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.NotInPendingStatus.selector);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);
    }

    function testCannotVerifyWithZeroRoles() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.InvalidRoleMask.selector);
        registry.verifyIdentity(user1, 0, 0);
    }

    function testConflictOfInterest_VerifierCannotBeAssetOwner() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_VERIFIER);

        uint256 conflictingRoles = ROLE_VERIFIER | ROLE_ASSET_OWNER;

        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.ConflictOfInterest.selector);
        registry.verifyIdentity(user1, conflictingRoles, 0);
    }

    function testConflictOfInterest_ArbitratorCannotBeAssetOwner() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ARBITRATOR);

        uint256 conflictingRoles = ROLE_ARBITRATOR | ROLE_ASSET_OWNER;

        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.ConflictOfInterest.selector);
        registry.verifyIdentity(user1, conflictingRoles, 0);
    }

    function testNoConflictOfInterest_LicenseeCanBeAssetOwner() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_LICENSEE);

        uint256 roles = ROLE_LICENSEE | ROLE_ASSET_OWNER;

        vm.prank(verifier);
        registry.verifyIdentity(user1, roles, 0);

        assertTrue(registry.hasBusinessRole(user1, ROLE_LICENSEE));
        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    /*//////////////////////////////////////////////////////////////
                        REJECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRejectIdentity() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.expectEmit(true, true, false, true);
        emit IdentityRejected(user1, verifier, REJECTION_REASON);

        vm.prank(verifier);
        registry.rejectIdentity(user1, REJECTION_REASON);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Rejected));
    }

    function testCanReapplyAfterRejection() public {
        // Register and get rejected
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.rejectIdentity(user1, REJECTION_REASON);

        // Reapply with updated documents
        string memory newMetadataURI = "ipfs://QmUpdated456";

        vm.prank(user1);
        registry.registerIdentity(newMetadataURI, ROLE_ASSET_OWNER);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Pending));
        assertEq(identity.metadataURI, newMetadataURI);
    }

    function testOnlyVerifierCanReject() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(user2);
        vm.expectRevert();
        registry.rejectIdentity(user1, REJECTION_REASON);
    }

    function testCannotRejectNonPendingIdentity() public {
        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.NotInPendingStatus.selector);
        registry.rejectIdentity(user1, REJECTION_REASON);
    }

    /*//////////////////////////////////////////////////////////////
                        SUSPENSION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSuspendIdentity() public {
        // Register and verify
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        // Suspend
        vm.expectEmit(true, true, false, true);
        emit IdentitySuspended(user1, verifier, SUSPENSION_REASON);

        vm.prank(verifier);
        registry.suspendIdentity(user1, SUSPENSION_REASON);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Suspended));

        assertFalse(registry.isVerified(user1));
        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    function testRestoreIdentity() public {
        // Register, verify, and suspend
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(verifier);
        registry.suspendIdentity(user1, SUSPENSION_REASON);

        // Restore
        vm.expectEmit(true, true, false, false);
        emit IdentityRestored(user1, verifier);

        vm.prank(verifier);
        registry.restoreIdentity(user1);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Verified));

        assertTrue(registry.isVerified(user1));
        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    function testOnlyVerifierCanSuspend() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(user2);
        vm.expectRevert();
        registry.suspendIdentity(user1, SUSPENSION_REASON);
    }

    function testOnlyVerifierCanRestore() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(verifier);
        registry.suspendIdentity(user1, SUSPENSION_REASON);

        vm.prank(user2);
        vm.expectRevert();
        registry.restoreIdentity(user1);
    }

    function testCannotSuspendNonVerifiedIdentity() public {
        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.NotInVerifiedStatus.selector);
        registry.suspendIdentity(user1, SUSPENSION_REASON);
    }

    function testCannotRestoreNonSuspendedIdentity() public {
        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.NotInSuspendedStatus.selector);
        registry.restoreIdentity(user1);
    }

    /*//////////////////////////////////////////////////////////////
                        REVOCATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevokeVerifiedIdentity() public {
        // Register and verify
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        // Revoke (only admin)
        vm.expectEmit(true, true, false, true);
        emit IdentityRevoked(user1, admin, REVOCATION_REASON);

        registry.revokeIdentity(user1, REVOCATION_REASON);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Revoked));

        assertFalse(registry.isVerified(user1));
        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    function testRevokeSuspendedIdentity() public {
        // Register, verify, and suspend
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(verifier);
        registry.suspendIdentity(user1, SUSPENSION_REASON);

        // Revoke
        registry.revokeIdentity(user1, REVOCATION_REASON);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Revoked));
    }

    function testOnlyAdminCanRevoke() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(verifier);
        vm.expectRevert();
        registry.revokeIdentity(user1, REVOCATION_REASON);
    }

    function testCannotRevokeAlreadyRevokedIdentity() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        registry.revokeIdentity(user1, REVOCATION_REASON);

        vm.expectRevert(IdentityRegistry.CannotEscapeRevokedStatus.selector);
        registry.revokeIdentity(user1, "Second revocation");
    }

    function testCannotRevokeNonExistentIdentity() public {
        vm.expectRevert(IdentityRegistry.NotInVerifiedStatus.selector);
        registry.revokeIdentity(user1, REVOCATION_REASON);
    }

    function testCannotRevokePendingIdentity() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.expectRevert(IdentityRegistry.NotInVerifiedStatus.selector);
        registry.revokeIdentity(user1, REVOCATION_REASON);
    }

    function testRevokedIdentityCannotBeRestored() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        registry.revokeIdentity(user1, REVOCATION_REASON);

        // Try to restore (should fail)
        vm.prank(verifier);
        vm.expectRevert(IdentityRegistry.NotInSuspendedStatus.selector);
        registry.restoreIdentity(user1);
    }

    function testRevokedIdentityCannotReapply() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        registry.revokeIdentity(user1, REVOCATION_REASON);

        // Try to register again (should fail)
        vm.prank(user1);
        vm.expectRevert(IdentityRegistry.AlreadyRegistered.selector);
        registry.registerIdentity(METADATA_URI, ROLE_LICENSEE);
    }

    /*//////////////////////////////////////////////////////////////
                        EXPIRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testExpiredIdentityNotVerified() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        uint64 expiresAt = uint64(block.timestamp + 365 days);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, expiresAt);

        // Before expiration
        assertTrue(registry.isVerified(user1));
        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));

        // After expiration
        vm.warp(block.timestamp + 366 days);

        assertFalse(registry.isVerified(user1));
        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));

        // Status is still Verified, but isVerified() returns false
        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);
        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Verified));
    }

    function testZeroExpiresAtMeansNoExpiry() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        // Fast forward 10 years
        vm.warp(block.timestamp + 3650 days);

        // Still verified
        assertTrue(registry.isVerified(user1));
        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    /*//////////////////////////////////////////////////////////////
                        ROLE CHECK TESTS
    //////////////////////////////////////////////////////////////*/

    function testHasRoleSingleRole() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
        assertFalse(registry.hasBusinessRole(user1, ROLE_LICENSEE));
    }

    function testHasRoleMultipleRoles() public {
        uint256 multiRoles = ROLE_ASSET_OWNER | ROLE_LICENSEE;

        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, multiRoles);

        vm.prank(verifier);
        registry.verifyIdentity(user1, multiRoles, 0);

        assertTrue(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
        assertTrue(registry.hasBusinessRole(user1, ROLE_LICENSEE));
        assertTrue(registry.hasBusinessRole(user1, multiRoles));
        assertFalse(registry.hasBusinessRole(user1, ROLE_INVESTOR));
    }

    function testHasRoleRequiresAllBits() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        // Has ASSET_OWNER but not LICENSEE
        uint256 combinedRoles = ROLE_ASSET_OWNER | ROLE_LICENSEE;
        assertFalse(registry.hasBusinessRole(user1, combinedRoles));
    }

    function testHasRoleFalseForNonVerified() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        // Still pending
        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    function testHasRoleFalseForSuspended() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);

        vm.prank(verifier);
        registry.suspendIdentity(user1, SUSPENSION_REASON);

        assertFalse(registry.hasBusinessRole(user1, ROLE_ASSET_OWNER));
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGrantVerifierRole() public {
        address newVerifier = makeAddr("newVerifier");

        registry.grantVerifierRole(newVerifier);

        assertTrue(registry.hasRole(registry.VERIFIER_MANAGER_ROLE(), newVerifier));
    }

    function testRevokeVerifierRole() public {
        registry.revokeVerifierRole(verifier);

        assertFalse(registry.hasRole(registry.VERIFIER_MANAGER_ROLE(), verifier));

        // Can no longer verify
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        vm.prank(verifier);
        vm.expectRevert();
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, 0);
    }

    function testOnlyAdminCanGrantVerifierRole() public {
        address newVerifier = makeAddr("newVerifier");

        vm.prank(user1);
        vm.expectRevert();
        registry.grantVerifierRole(newVerifier);
    }

    function testOnlyAdminCanRevokeVerifierRole() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.revokeVerifierRole(verifier);
    }

    /*//////////////////////////////////////////////////////////////
                        QUERY FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetIdentityReturnsCorrectData() public {
        vm.prank(user1);
        registry.registerIdentity(METADATA_URI, ROLE_ASSET_OWNER);

        uint64 expiresAt = uint64(block.timestamp + 365 days);

        vm.prank(verifier);
        registry.verifyIdentity(user1, ROLE_ASSET_OWNER, expiresAt);

        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);

        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.Verified));
        assertEq(identity.roleMask, ROLE_ASSET_OWNER);
        assertEq(identity.expiresAt, expiresAt);
        assertEq(identity.verifier, verifier);
        assertEq(identity.metadataURI, METADATA_URI);
    }

    function testGetIdentityForNonExistentAddress() public view {
        IdentityRegistry.Identity memory identity = registry.getIdentity(user1);

        assertEq(uint256(identity.status), uint256(IdentityRegistry.IdentityStatus.None));
        assertEq(identity.roleMask, 0);
        assertEq(identity.createdAt, 0);
    }
}
