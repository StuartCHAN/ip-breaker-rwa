// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title IdentityRegistry
 * @notice Manages verified identities and role-based permissions for IP-RWA protocol
 * @dev Separates business identity (ASSET_OWNER, LICENSEE, etc.) from system permissions (AccessControl)
 *
 * Key Design Principles:
 * - Business identity roles use bit masks for gas efficiency
 * - System permissions use OpenZeppelin AccessControl
 * - KYC expiration handled via timestamp checks, not status transitions
 * - Conflict-of-interest prevention: VERIFIER/ARBITRATOR cannot be ASSET_OWNER
 */
contract IdentityRegistry is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum IdentityStatus {
        None,       // 0: Not registered
        Pending,    // 1: Application submitted, awaiting verification
        Verified,   // 2: Active and compliant
        Suspended,  // 3: Temporarily disabled (expired KYC, investigation)
        Rejected,   // 4: Application denied (can reapply)
        Revoked     // 5: Permanently banned (terminal state)
    }

    struct Identity {
        IdentityStatus status;      // Current verification state
        uint64 createdAt;           // Registration timestamp
        uint64 verifiedAt;          // Verification timestamp (0 if not verified)
        uint64 expiresAt;           // KYC expiration (0 = no expiry)
        uint256 roleMask;           // Bit mask for business roles
        address verifier;           // Address of verifier who approved
        string metadataURI;         // IPFS/Arweave link to off-chain KYC docs
    }

    /*//////////////////////////////////////////////////////////////
                            ROLE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Business Identity Roles (bit mask)
    uint256 public constant ROLE_ASSET_OWNER = 1 << 0;  // 0x01
    uint256 public constant ROLE_LICENSEE    = 1 << 1;  // 0x02
    uint256 public constant ROLE_INVESTOR    = 1 << 2;  // 0x04
    uint256 public constant ROLE_VERIFIER    = 1 << 3;  // 0x08
    uint256 public constant ROLE_ARBITRATOR  = 1 << 4;  // 0x10

    // System Permission Roles (AccessControl)
    bytes32 public constant VERIFIER_MANAGER_ROLE = keccak256("VERIFIER_MANAGER");
    bytes32 public constant IDENTITY_MANAGER_ROLE = keccak256("IDENTITY_MANAGER");

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(address => Identity) public identities;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event IdentityRegistered(
        address indexed account,
        uint256 timestamp,
        uint256 requestedRoles
    );

    event IdentityVerified(
        address indexed account,
        address indexed verifier,
        uint256 grantedRoles,
        uint64 expiresAt
    );

    event IdentityRejected(
        address indexed account,
        address indexed verifier,
        string reason
    );

    event IdentitySuspended(
        address indexed account,
        address indexed actor,
        string reason
    );

    event IdentityRestored(
        address indexed account,
        address indexed actor
    );

    event IdentityRevoked(
        address indexed account,
        address indexed admin,
        string reason
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyRegistered();
    error NotInPendingStatus();
    error NotInVerifiedStatus();
    error NotInSuspendedStatus();
    error NotInRejectedStatus();
    error CannotEscapeRevokedStatus();
    error ConflictOfInterest();
    error InvalidRoleMask();
    error IdentityExpired();
    error IdentityNotVerified();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        REGISTRATION & VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register a new identity (self-service)
     * @param metadataURI IPFS link to encrypted KYC documents
     * @param requestedRoles Bit mask of roles being applied for
     */
    function registerIdentity(
        string calldata metadataURI,
        uint256 requestedRoles
    ) external {
        Identity storage identity = identities[msg.sender];

        // Allow re-registration only from Rejected status or first-time registration
        if (identity.status != IdentityStatus.None && identity.status != IdentityStatus.Rejected) {
            revert AlreadyRegistered();
        }

        if (requestedRoles == 0) {
            revert InvalidRoleMask();
        }

        identity.status = IdentityStatus.Pending;
        identity.createdAt = uint64(block.timestamp);
        identity.metadataURI = metadataURI;
        // Note: roleMask is set during verification, not registration

        emit IdentityRegistered(msg.sender, block.timestamp, requestedRoles);
    }

    /**
     * @notice Approve a pending identity (VERIFIER_MANAGER_ROLE only)
     * @param account Address to verify
     * @param grantedRoles Bit mask of roles to grant (may differ from requested)
     * @param expiresAt KYC expiration timestamp (0 = no expiry)
     */
    function verifyIdentity(
        address account,
        uint256 grantedRoles,
        uint64 expiresAt
    ) external onlyRole(VERIFIER_MANAGER_ROLE) {
        Identity storage identity = identities[account];

        if (identity.status != IdentityStatus.Pending) {
            revert NotInPendingStatus();
        }

        if (grantedRoles == 0) {
            revert InvalidRoleMask();
        }

        // Prevent conflict of interest: VERIFIER/ARBITRATOR cannot be ASSET_OWNER
        if ((grantedRoles & (ROLE_VERIFIER | ROLE_ARBITRATOR)) != 0) {
            if ((grantedRoles & ROLE_ASSET_OWNER) != 0) {
                revert ConflictOfInterest();
            }
        }

        identity.status = IdentityStatus.Verified;
        identity.verifiedAt = uint64(block.timestamp);
        identity.expiresAt = expiresAt;
        identity.roleMask = grantedRoles;
        identity.verifier = msg.sender;

        emit IdentityVerified(account, msg.sender, grantedRoles, expiresAt);
    }

    /**
     * @notice Reject a pending identity application (VERIFIER_MANAGER_ROLE only)
     * @param account Address to reject
     * @param reason Human-readable rejection reason
     */
    function rejectIdentity(
        address account,
        string calldata reason
    ) external onlyRole(VERIFIER_MANAGER_ROLE) {
        Identity storage identity = identities[account];

        if (identity.status != IdentityStatus.Pending) {
            revert NotInPendingStatus();
        }

        identity.status = IdentityStatus.Rejected;

        emit IdentityRejected(account, msg.sender, reason);
    }

    /*//////////////////////////////////////////////////////////////
                            STATUS MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Temporarily suspend an identity (VERIFIER_MANAGER_ROLE)
     * @param account Address to suspend
     * @param reason Suspension reason (expired KYC, investigation)
     */
    function suspendIdentity(
        address account,
        string calldata reason
    ) external onlyRole(VERIFIER_MANAGER_ROLE) {
        Identity storage identity = identities[account];

        if (identity.status != IdentityStatus.Verified) {
            revert NotInVerifiedStatus();
        }

        identity.status = IdentityStatus.Suspended;

        emit IdentitySuspended(account, msg.sender, reason);
    }

    /**
     * @notice Restore a suspended identity (VERIFIER_MANAGER_ROLE)
     * @param account Address to restore
     */
    function restoreIdentity(address account) external onlyRole(VERIFIER_MANAGER_ROLE) {
        Identity storage identity = identities[account];

        if (identity.status != IdentityStatus.Suspended) {
            revert NotInSuspendedStatus();
        }

        identity.status = IdentityStatus.Verified;

        emit IdentityRestored(account, msg.sender);
    }

    /**
     * @notice Permanently revoke an identity (DEFAULT_ADMIN_ROLE only)
     * @param account Address to revoke
     * @param reason Revocation reason (fraud, sanctions)
     * @dev Terminal state: cannot transition out of Revoked
     */
    function revokeIdentity(
        address account,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Identity storage identity = identities[account];

        // Can revoke from Verified or Suspended, but not from terminal state
        if (identity.status == IdentityStatus.Revoked) {
            revert CannotEscapeRevokedStatus();
        }

        if (identity.status == IdentityStatus.None || identity.status == IdentityStatus.Pending) {
            revert NotInVerifiedStatus();
        }

        identity.status = IdentityStatus.Revoked;

        emit IdentityRevoked(account, msg.sender, reason);
    }

    /*//////////////////////////////////////////////////////////////
                            QUERY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if an address has a specific role
     * @param account Address to check
     * @param role Role bit mask (can be combined: ROLE_ASSET_OWNER | ROLE_LICENSEE)
     * @return True if account has ALL specified roles AND is verified (not expired)
     */
    function hasRole(address account, uint256 role) external view returns (bool) {
        Identity storage identity = identities[account];

        // Must be in Verified status
        if (identity.status != IdentityStatus.Verified) {
            return false;
        }

        // Check expiration (0 = no expiry)
        if (identity.expiresAt != 0 && block.timestamp > identity.expiresAt) {
            return false;
        }

        // Check if account has ALL bits set in the role mask
        return (identity.roleMask & role) == role;
    }

    /**
     * @notice Check if an identity is verified and not expired
     * @param account Address to check
     * @return True if status is Verified and not expired
     */
    function isVerified(address account) external view returns (bool) {
        Identity storage identity = identities[account];

        if (identity.status != IdentityStatus.Verified) {
            return false;
        }

        // Check expiration (0 = no expiry)
        if (identity.expiresAt != 0 && block.timestamp > identity.expiresAt) {
            return false;
        }

        return true;
    }

    /**
     * @notice Get full identity data
     * @param account Address to query
     * @return Identity struct
     */
    function getIdentity(address account) external view returns (Identity memory) {
        return identities[account];
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Grant VERIFIER_MANAGER_ROLE (convenience wrapper)
     * @param verifier Address to authorize
     */
    function grantVerifierRole(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(VERIFIER_MANAGER_ROLE, verifier);
    }

    /**
     * @notice Revoke VERIFIER_MANAGER_ROLE (convenience wrapper)
     * @param verifier Address to deauthorize
     */
    function revokeVerifierRole(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(VERIFIER_MANAGER_ROLE, verifier);
    }
}
