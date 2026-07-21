# Phase 2.0: IdentityRegistry Business Modeling

**Status:** Design Phase (Pre-Implementation)  
**Author:** Phase 2 Design Sprint  
**Date:** 2026-07-21  
**Objective:** Map real-world compliance requirements to on-chain permission models

---

## Executive Summary

This document defines the **IdentityRegistry** contract's business model before writing any Solidity code. The goal is to answer:

1. **Who needs identity verification?** (Role taxonomy)
2. **What compliance requirements apply?** (Real-world constraints)
3. **How do permissions map to on-chain logic?** (State machine design)
4. **What are the integration points?** (Existing contract modifications)

This is **NOT a technical spec** yet—this is business modeling to ensure we understand the problem space before jumping to code.

---

## 1. Problem Statement

### 1.1 Current State (Phase 1)

The v0.2 protocol operates with **zero identity validation**:

```solidity
// LicenseEscrow.sol - Current Implementation
function createAgreement(...) external returns (uint256) {
    licensor = msg.sender;  // ❌ No verification
    // Anyone with an address can create agreements
}
```

**Limitations:**
- No KYC/AML compliance
- Cannot distinguish legitimate IP owners from bad actors
- No role-based access control
- Cannot enforce different permission levels

### 1.2 Real-World Requirements

For IP-RWA protocols to be legally compliant, they need:

| Requirement | Why |
|-------------|-----|
| **IP Owner Verification** | Prove ownership rights to tokenized IP assets |
| **Licensee KYC** | Anti-money laundering compliance for commercial transactions |
| **Investor Accreditation** | Securities law compliance for fractional ownership (Phase 5) |
| **Verifier Authorization** | Trusted entities that can approve identities |
| **Revocation Mechanism** | Handle fraud, sanctions, or legal disputes |

### 1.3 Design Goal

Create an **identity registry** that:
- ✅ Supports multiple role types with different verification requirements
- ✅ Allows modular integration with existing contracts
- ✅ Uses efficient on-chain storage (bit masks instead of multiple booleans)
- ✅ Provides clear state transitions (None → Pending → Verified → Suspended/Revoked)
- ✅ Enables future extensions without breaking changes

---

## 2. Role Taxonomy

### 2.1 Core Roles (Business Identity Layer)

**IMPORTANT:** This registry manages **business identities**, NOT system permissions. Platform admin/governance uses OpenZeppelin AccessControl separately.

| Role | Code | Bit Position | Description | Verification Requirements |
|------|------|--------------|-------------|---------------------------|
| **Asset Owner** | `ASSET_OWNER` | 0 (0x01) | Can tokenize IP and create license agreements | KYC + IP ownership proof |
| **Licensee** | `LICENSEE` | 1 (0x02) | Can purchase licenses and use IP | KYC + legal entity verification |
| **Investor** | `INVESTOR` | 2 (0x04) | Can invest in fractional IP ownership (Phase 5) | KYC (accreditation deferred to Phase 5) |
| **Verifier** | `VERIFIER` | 3 (0x08) | Can approve/reject identity applications | Platform authorization via AccessControl |
| **Arbitrator** | `ARBITRATOR` | 4 (0x10) | Can resolve disputes in LicenseEscrow | Platform authorization + dispute resolution expertise |

**Note:** `INVESTOR` role is intentionally broad in Phase 2. Accredited vs Retail investor distinction will be introduced in Phase 5 (Offering Manager) to avoid premature securities compliance complexity.

### 2.2 System Permission Layer (Separate from Business Identity)

**IMPORTANT:** Platform administration uses **OpenZeppelin AccessControl**, NOT the identity roleMask.

```solidity
// Managed by AccessControl.sol (separate contract)
bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
bytes32 public constant VERIFIER_MANAGER_ROLE = keccak256("VERIFIER_MANAGER");
bytes32 public constant IDENTITY_MANAGER_ROLE = keccak256("IDENTITY_MANAGER");
```

**Why Separate?**
- **Business Identity** (ASSET_OWNER, LICENSEE, etc.) represents real-world compliance status
- **System Permission** (ADMIN, MANAGER) represents platform governance control
- Mixing them causes: governance changes pollute identity data
- Example: Platform admin replacement should NOT affect "Alice is an Asset Owner"

**Architecture:**
```text
IdentityRegistry.sol
  ├─ Business Roles: roleMask (ASSET_OWNER | LICENSEE | INVESTOR | VERIFIER | ARBITRATOR)
  └─ System Permissions: AccessControl (DEFAULT_ADMIN_ROLE, VERIFIER_MANAGER_ROLE)
```

### 2.3 Role Coexistence Rules

**Allowed Combinations:**
- ✅ `ASSET_OWNER + LICENSEE` (IP owner can also license others' IP)
- ✅ `LICENSEE + INVESTOR` (licensee can also invest in fractional IP)
- ✅ Multiple business roles per address are permitted

**Conflict of Interest Prevention:**
- ❌ `VERIFIER + ASSET_OWNER` (cannot verify own IP assets)
- ❌ `ARBITRATOR + ASSET_OWNER` (cannot arbitrate own disputes)

**Implementation:**
```solidity
function verifyIdentity(..., uint256 grantedRoles) external {
    // Prevent conflict of interest
    if ((grantedRoles & ROLE_VERIFIER) != 0 || (grantedRoles & ROLE_ARBITRATOR) != 0) {
        require(
            (grantedRoles & ROLE_ASSET_OWNER) == 0,
            "Verifier/Arbitrator cannot also be asset owner"
        );
    }
    // ...
}
```

### 2.4 Why Bit Masks?

**Inefficient Approach:**

```solidity
struct Identity {
    bool isAssetOwner;
    bool isLicensee;
    bool isInvestor;
    bool isVerifier;
}
// Storage: 4 slots (4 × 256 bits = 1024 bits for 4 booleans)
```

**Efficient Approach:**

```solidity
struct Identity {
    uint256 roleMask;  // 1 slot, supports 256 roles
}

// Usage:
hasRole(addr, ASSET_OWNER) → (roleMask & 0x01) != 0
hasRole(addr, LICENSEE)    → (roleMask & 0x02) != 0
hasRole(addr, BOTH)        → (roleMask & 0x03) == 0x03
```

**Benefits:**

- ✅ Gas efficient (single SLOAD instead of multiple)
- ✅ DeFi industry standard (Aave, Compound use this pattern)
- ✅ Extensible (can add roles without schema changes)

### 3.1 Status Lifecycle

```text
┌──────────┐
│   None   │  (Default: address not registered)
└────┬─────┘
     │ registerIdentity()
     ↓
┌──────────┐
│ Pending  │  (Application submitted, awaiting verification)
└────┬─────┘
     │
     ├─→ verifyIdentity() ──→ ┌──────────┐
     │                         │ Verified │  (Active, can use protocol)
     │                         └────┬─────┘
     │                              │
     │                              ├─→ suspendIdentity() ──→ ┌───────────┐
     │                              │                           │ Suspended │
     │                              │                           └─────┬─────┘
     │                              │                                 │ restoreIdentity()
     │                              │                                 ↓
     │                              │                           (back to Verified)
     │                              │
     │                              └─→ revokeIdentity() ──→ ┌──────────┐
     │                                                        │ Revoked  │ (Terminal)
     │                                                        └──────────┘
     └─→ rejectIdentity() ──→ ┌──────────┐
                               │ Rejected │  (Can reapply: Rejected → Pending)
                               └──────────┘
```

**Key Differences:**

- **Rejected**: Application denied (e.g., incomplete KYC docs). User can fix issues and re-apply: `Rejected → Pending → Verified`
- **Revoked**: Previously verified but now permanently banned (e.g., fraud, sanctions). **Terminal state**: cannot transition back.
- **Suspended**: Temporary disable (e.g., expired KYC, under investigation). **Reversible**: `Suspended ↔ Verified`

### 3.2 Status Definitions

| Status | Code | Description | Can Use Protocol? |
|--------|------|-------------|-------------------|
| `None` | 0 | Address never registered | ❌ |
| `Pending` | 1 | Application submitted, awaiting review | ❌ |
| `Verified` | 2 | Active, compliant identity | ✅ |
| `Suspended` | 3 | Temporarily disabled (investigation, expired KYC) | ❌ |
| `Rejected` | 4 | Application denied (can reapply) | ❌ |
| `Revoked` | 5 | Permanently banned (fraud, sanctions) | ❌ |

### 3.3 State Transition Rules

| From | To | Function | Who Can Call | Conditions |
|------|----|----|--------------|------------|
| None | Pending | `registerIdentity()` | Anyone | First-time registration |
| Pending | Verified | `verifyIdentity()` | VERIFIER_MANAGER_ROLE | Valid KYC documents |
| Pending | Rejected | `rejectIdentity()` | VERIFIER_MANAGER_ROLE | Invalid/incomplete documents |
| Rejected | Pending | `registerIdentity()` | Same user | Can reapply after fixing issues |
| Verified | Suspended | `suspendIdentity()` | VERIFIER_MANAGER_ROLE | Expired KYC, investigation |
| Suspended | Verified | `restoreIdentity()` | VERIFIER_MANAGER_ROLE | Issue resolved |
| Verified | Revoked | `revokeIdentity()` | DEFAULT_ADMIN_ROLE | Fraud, sanctions (permanent) |
| Suspended | Revoked | `revokeIdentity()` | DEFAULT_ADMIN_ROLE | Fraud, sanctions (permanent) |

**Critical Rules:**

- ❌ **Cannot transition FROM Revoked** (terminal state)
- ✅ **Can transition from Rejected to Pending** (reapply after fixing issues)
- ✅ **Suspended ↔ Verified** (reversible for temporary issues)
- ⚠️ **Only ADMIN can Revoke** (highest severity action)

---

## 4. State Variables Design

### 4.1 Core Storage

```solidity
// Identity data structure
struct Identity {
    IdentityStatus status;      // Current verification state
    uint64 createdAt;           // Registration timestamp
    uint64 verifiedAt;          // Verification timestamp (0 if not verified)
    uint64 expiresAt;           // KYC expiration (0 = no expiry)
    uint256 roleMask;           // Bit mask for roles (see section 2.4)
    address verifier;           // Address of verifier who approved
    string metadataURI;         // IPFS/Arweave link to off-chain KYC docs
}

// Status enum
enum IdentityStatus {
    None,       // 0: Not registered
    Pending,    // 1: Application submitted
    Verified,   // 2: Active and compliant
    Suspended,  // 3: Temporarily disabled
    Rejected,   // 4: Application denied (can reapply)
    Revoked     // 5: Permanently banned (terminal)
}

// Main storage
mapping(address => Identity) public identities;
```

**Note on Expiration:**
- `expiresAt` is NOT reflected in `status` enum
- `isVerified()` checks: `status == Verified && (expiresAt == 0 || block.timestamp < expiresAt)`
- Avoids daily `Verified → Expired` state transitions (gas inefficient)

### 4.2 Role Constants

```solidity
uint256 public constant ROLE_ASSET_OWNER = 1 << 0;  // 0x01
uint256 public constant ROLE_LICENSEE    = 1 << 1;  // 0x02
uint256 public constant ROLE_INVESTOR    = 1 << 2;  // 0x04
uint256 public constant ROLE_VERIFIER    = 1 << 3;  // 0x08
uint256 public constant ROLE_ARBITRATOR  = 1 << 4;  // 0x10
```

**Note:** Uses bit shift syntax (`1 << n`) for clarity. Equivalent to manual hex (0x01, 0x02, 0x04, ...).

### 4.3 Access Control Storage

```solidity
// Uses OpenZeppelin AccessControl for system permissions
import "@openzeppelin/contracts/access/AccessControl.sol";

contract IdentityRegistry is AccessControl {
    bytes32 public constant VERIFIER_MANAGER_ROLE = keccak256("VERIFIER_MANAGER");
    bytes32 public constant IDENTITY_MANAGER_ROLE = keccak256("IDENTITY_MANAGER");
    
    // Event log
    event IdentityRegistered(address indexed account, uint256 timestamp);
    event IdentityVerified(address indexed account, address indexed verifier, uint256 roleMask);
    event IdentitySuspended(address indexed account, string reason);
    event IdentityRestored(address indexed account);
    event IdentityRejected(address indexed account, string reason);
    event IdentityRevoked(address indexed account, string reason);
}
```

**Access Control Pattern:**

- `DEFAULT_ADMIN_ROLE`: Can grant/revoke manager roles, can revoke identities
- `VERIFIER_MANAGER_ROLE`: Can verify/reject/suspend/restore identities
- `IDENTITY_MANAGER_ROLE`: Reserved for future advanced operations

**Why Not Store `isVerifier` Separately?**

Because `AccessControl.hasRole(address, VERIFIER_MANAGER_ROLE)` already provides this functionality. No need to duplicate state.

---

## 5. Function Interface Design

### 5.1 Registration & Verification

```solidity
/// @notice Register a new identity (self-service)
/// @param metadataURI IPFS link to KYC documents
/// @param requestedRoles Bit mask of roles being applied for
function registerIdentity(
    string calldata metadataURI,
    uint256 requestedRoles
) external;

/// @notice Approve a pending identity (VERIFIER only)
/// @param account Address to verify
/// @param grantedRoles Bit mask of roles to grant (may differ from requested)
/// @param expiresAt KYC expiration timestamp (0 = no expiry)
function verifyIdentity(
    address account,
    uint256 grantedRoles,
    uint64 expiresAt
) external;

/// @notice Reject a pending identity application (VERIFIER only)
/// @param account Address to reject
/// @param reason Human-readable rejection reason
function rejectIdentity(
    address account,
    string calldata reason
) external;
```

### 5.2 Status Management

```solidity
/// @notice Temporarily suspend an identity (VERIFIER_MANAGER_ROLE)
/// @param account Address to suspend
/// @param reason Suspension reason (expired KYC, investigation)
function suspendIdentity(
    address account,
    string calldata reason
) external onlyRole(VERIFIER_MANAGER_ROLE);

/// @notice Restore a suspended identity (VERIFIER_MANAGER_ROLE)
/// @param account Address to restore
function restoreIdentity(address account) external onlyRole(VERIFIER_MANAGER_ROLE);

/// @notice Permanently revoke an identity (DEFAULT_ADMIN_ROLE only)
/// @param account Address to revoke
/// @param reason Revocation reason (fraud, sanctions)
function revokeIdentity(
    address account,
    string calldata reason
) external onlyRole(DEFAULT_ADMIN_ROLE);
```

### 5.3 Query Functions

```solidity
/// @notice Check if an address has a specific role
/// @param account Address to check
/// @param role Role bit mask (can be combined: ROLE_ASSET_OWNER | ROLE_LICENSEE)
/// @return True if account has ALL specified roles
function hasRole(address account, uint256 role) external view returns (bool);

/// @notice Check if an identity is verified and not expired
/// @param account Address to check
/// @return True if status is Verified and not expired
function isVerified(address account) external view returns (bool);

/// @notice Get full identity data
/// @param account Address to query
/// @return Identity struct (status, timestamps, roles, etc.)
function getIdentity(address account) external view returns (Identity memory);
```

### 5.4 Admin Functions

```solidity
/// @notice Grant VERIFIER_MANAGER_ROLE to an address (DEFAULT_ADMIN_ROLE only)
/// @param verifier Address to authorize
function grantVerifierRole(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
    grantRole(VERIFIER_MANAGER_ROLE, verifier);
}

/// @notice Revoke VERIFIER_MANAGER_ROLE (DEFAULT_ADMIN_ROLE only)
/// @param verifier Address to deauthorize
function revokeVerifierRole(address verifier) external onlyRole(DEFAULT_ADMIN_ROLE) {
    revokeRole(VERIFIER_MANAGER_ROLE, verifier);
}
```

**Note:** Uses OpenZeppelin AccessControl's built-in `grantRole()` and `revokeRole()`. Wrapper functions provided for clarity, but direct AccessControl calls also work.

---

## 6. Integration with Existing Contracts

### 6.1 Integration Strategy: Layered Verification

**NOT all functions require identity checks.** Apply verification strategically:

| Contract | Function | Requires Identity? | Role Required | Rationale |
|----------|----------|-------------------|---------------|-----------|
| **IPAssetRegistry** | `registerAsset()` | ✅ Yes | `ASSET_OWNER` | Claiming IP ownership requires proof |
| | `transferFrom()` | ❌ No | None | ERC721 standard transfer (open) |
| **EvidenceRegistry** | `addEvidence()` | ✅ Yes | `ASSET_OWNER` | Only verified owners submit evidence |
| | `setReviewer()` | ✅ Yes | `VERIFIER` | Only authorized verifiers can review |
| | `getEvidence()` | ❌ No | None | Public read access |
| **LicenseEscrow** | `createAgreement()` | ✅ Yes | `ASSET_OWNER` (licensor) | Only verified owners can license IP |
| | `fundAgreement()` | ✅ Yes | `LICENSEE` (licensee) | Only verified licensees can fund |
| | `resolveDispute()` | ✅ Yes | `ARBITRATOR` (arbiter) | Only authorized arbitrators resolve |
| | `isLicenseValid()` | ❌ No | None | Public query function |

**Design Principle:**

- ✅ **State-changing operations** that establish rights → require identity
- ❌ **Read operations** and standard transfers → no identity check
- ✅ **Critical roles** (arbiter, reviewer) → require identity

### 6.2 LicenseEscrow Integration Example

**Current Code:**

```solidity
// contracts/LicenseEscrow.sol
function createAgreement(...) external returns (uint256) {
    licensor = msg.sender;  // ❌ No verification
}
```

**Future Code (Phase 2):**

```solidity
import "./IdentityRegistry.sol";

contract LicenseEscrow {
    IdentityRegistry public immutable identityRegistry;
    
    constructor(address _identityRegistry, ...) {
        identityRegistry = IdentityRegistry(_identityRegistry);
    }
    
    function createAgreement(
        address licensee,
        uint256 licenseFee,
        ...
    ) external returns (uint256) {
        // Verify licensor has ASSET_OWNER role
        require(
            identityRegistry.hasRole(msg.sender, identityRegistry.ROLE_ASSET_OWNER()),
            "Licensor not verified as asset owner"
        );
        
        // Verify licensee has LICENSEE role
        require(
            identityRegistry.hasRole(licensee, identityRegistry.ROLE_LICENSEE()),
            "Licensee not verified"
        );
        
        // Rest of function...
        licensor = msg.sender;
        // ...
    }
    
    function resolveDispute(uint256 agreementId, bool favorLicensor) external {
        Agreement storage agreement = agreements[agreementId];
        
        // Verify arbiter has ARBITRATOR role
        require(
            identityRegistry.hasRole(msg.sender, identityRegistry.ROLE_ARBITRATOR()),
            "Only authorized arbitrators can resolve disputes"
        );
        
        require(msg.sender == agreement.arbiter, "Not the assigned arbiter");
        
        // Rest of function...
    }
}
```

### 6.2 IPAssetRegistry Integration

**Current Code:**
```solidity
// contracts/IPAssetRegistry.sol
function registerAsset(...) external returns (uint256) {
    _mint(msg.sender, tokenId);  // ❌ No verification
}
```

**Future Code (Phase 2):**
```solidity
contract IPAssetRegistry {
    IdentityRegistry public immutable identityRegistry;
    
    function registerAsset(...) external returns (uint256) {
        require(
            identityRegistry.hasRole(msg.sender, identityRegistry.ROLE_ASSET_OWNER()),
            "Only verified asset owners can register IP"
        );
        
        _mint(msg.sender, tokenId);
        // ...
    }
}
```

### 6.3 EvidenceRegistry Integration

**Current Code:**
```solidity
// contracts/EvidenceRegistry.sol
function addEvidence(...) external {
    assetOwner = msg.sender;  // ❌ No verification
}

function setReviewer(...) external {
    // ❌ Anyone can become reviewer
}
```

**Future Code (Phase 2):**
```solidity
contract EvidenceRegistry {
    IdentityRegistry public immutable identityRegistry;
    
    function addEvidence(...) external {
        require(
            identityRegistry.hasRole(msg.sender, identityRegistry.ROLE_ASSET_OWNER()),
            "Only verified asset owners can submit evidence"
        );
        // ...
    }
    
    function setReviewer(uint256 evidenceId, address reviewer) external {
        require(
            identityRegistry.hasRole(reviewer, identityRegistry.ROLE_VERIFIER()),
            "Reviewer must have verifier role"
        );
        // ...
    }
}
```

---

## 7. Permission Matrix

### 7.1 Who Can Do What?

| Action | DEFAULT_ADMIN | VERIFIER_MANAGER | ASSET_OWNER | LICENSEE | INVESTOR | ARBITRATOR | Anyone |
|--------|---------------|------------------|-------------|----------|----------|------------|--------|
| Register identity | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Verify identity | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Reject identity | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Suspend identity | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Restore identity | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Revoke identity | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Grant/revoke manager roles | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Register IP asset | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Create license agreement | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| Purchase license | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Resolve dispute | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |
| Invest in IP (Phase 5) | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |

### 7.2 Conflict of Interest Rules

**Disallowed Role Combinations:**

- ❌ `VERIFIER + ASSET_OWNER` (cannot verify own IP)
- ❌ `ARBITRATOR + ASSET_OWNER` (cannot arbitrate own disputes)

**Implementation:**

```solidity
function verifyIdentity(..., uint256 grantedRoles) external {
    require(hasRole(VERIFIER_MANAGER_ROLE, msg.sender), "Not authorized");
    
    // Prevent conflict of interest
    if ((grantedRoles & (ROLE_VERIFIER | ROLE_ARBITRATOR)) != 0) {
        require(
            (grantedRoles & ROLE_ASSET_OWNER) == 0,
            "Verifier/Arbitrator cannot also be asset owner"
        );
    }
    
    // ...
}
```

---

## 8. Edge Cases & Design Considerations

### 8.1 KYC Expiration

**Scenario:** User's KYC document expires after 1 year.

**Solution:**

```solidity
function isVerified(address account) external view returns (bool) {
    Identity storage id = identities[account];
    
    if (id.status != IdentityStatus.Verified) return false;
    
    // Check expiration (0 = no expiry)
    if (id.expiresAt != 0 && block.timestamp > id.expiresAt) {
        return false;  // Expired
    }
    
    return true;
}
```

**User Experience:**

- Protocol calls `isVerified()` before every sensitive operation
- If expired, transaction reverts with "KYC expired"
- User must resubmit documents and get re-verified
- **Status remains `Verified`**, expiration handled by timestamp check

**Why NOT add `Expired` status?**

- Avoids daily on-chain state transitions (gas inefficient)
- Blockchain doesn't auto-execute; someone must call a function to change state
- Timestamp check is cheaper and equally effective

### 8.2 Role Upgrades

**Scenario:** A user is already verified as `LICENSEE`, now wants to add `ASSET_OWNER` role.

**Solution:**
```solidity
function verifyIdentity(..., uint256 grantedRoles) external {
    Identity storage id = identities[account];
    
    // Additive: merge with existing roles
    id.roleMask |= grantedRoles;  // Bitwise OR
    
    id.status = IdentityStatus.Verified;
    id.verifiedAt = uint64(block.timestamp);
    // ...
}
```

**Alternative (Replace):**
```solidity
// If we want to REPLACE roles instead of ADD:
id.roleMask = grantedRoles;  // Overwrites previous roles
```

**Design Decision:** Use **additive model** (safer, preserves existing permissions).

### 8.3 Verifier Accountability

**Scenario:** A malicious verifier approves fake identities.

**Mitigation:**
1. **Event Logging:** Every verification emits `IdentityVerified(account, verifier, roleMask)`
2. **Admin Revocation:** Admin can `revokeIdentity()` for fraudulent accounts
3. **Verifier Removal:** Admin can `removeVerifier()` for bad actors
4. **Future Enhancement (Phase 7):** Slashing mechanism for verifiers who approve fraudulent identities

### 8.4 Privacy Considerations

**Problem:** KYC documents contain sensitive PII (name, passport, address).

**Solution:**
```solidity
struct Identity {
    // ...
    string metadataURI;  // ✅ IPFS hash, NOT raw data
}
```

**Off-Chain Storage:**
1. User uploads encrypted KYC docs to IPFS/Arweave
2. Only verifier has decryption key
3. On-chain: store only IPFS hash (`ipfs://Qm...`)
4. Blockchain sees: `0x1234...` has role `ASSET_OWNER` (binary status only)

**Privacy Guarantee:** Smart contract never stores names, passport numbers, or addresses.

---

## 9. Testing Strategy (Phase 2.1)

Once implementation begins, we need:

### 9.1 Unit Tests

**File:** `test/IdentityRegistry.t.sol`

```solidity
contract IdentityRegistryTest {
    // Registration tests
    - testRegisterIdentity()
    - testRegisterWithMultipleRoles()
    - testCannotRegisterTwice()
    
    // Verification tests
    - testVerifyIdentity()
    - testOnlyVerifierCanVerify()
    - testRoleConflictPrevention()
    
    // State transition tests
    - testSuspendAndRestore()
    - testRejectAndReapply()
    - testRevokeIsPermanent()
    
    // Query tests
    - testHasRole()
    - testIsVerified()
    - testExpiredKYCReturnsFalse()
}
```

### 9.2 Integration Tests

**File:** `test/IdentityRegistry.Integration.t.sol`

```solidity
contract IdentityRegistryIntegrationTest {
    // Test with LicenseEscrow
    - testCreateAgreementRequiresVerification()
    - testSuspendedUserCannotCreateAgreement()
    
    // Test with IPAssetRegistry
    - testRegisterAssetRequiresOwnerRole()
    - testRevokedUserCannotRegisterAsset()
}
```

### 9.3 Invariant Tests

**File:** `test/IdentityRegistry.Invariant.t.sol`

**Invariants to Test:**
1. **Status Integrity:** Revoked identities can never transition to other states
2. **Role Conflict:** No address has both `VERIFIER` and `ASSET_OWNER` roles
3. **Verifier Authorization:** All `Verified` identities were approved by an authorized verifier
4. **Timestamp Consistency:** `verifiedAt <= block.timestamp` for all verified identities

---

## 10. Migration Plan

### 10.1 Deployment Order

```text
1. Deploy IdentityRegistry.sol
2. Set platform admin
3. Add initial verifiers
4. Deploy new LicenseEscrow (with IdentityRegistry address in constructor)
5. Deploy new IPAssetRegistry (with IdentityRegistry address)
6. Deploy new EvidenceRegistry (with IdentityRegistry address)
```

### 10.2 Backward Compatibility

**Problem:** Existing Phase 1 contracts have no identity checks.

**Solution:**
- Phase 1 contracts remain on testnet for reference
- Phase 2 contracts are **NEW deployments** (not upgrades)
- Frontend switches to new contract addresses
- No data migration needed (fresh start with identity system)

---

## 11. Future Extensions (Post-Phase 2)

### 11.1 Phase 3: Evidence-Based Identity
- Link identity verification to evidence quality scores
- Require evidence submissions for asset owner verification

### 11.2 Phase 5: Investor Accreditation
- Add `ROLE_ACCREDITED_INVESTOR` with income/net worth verification
- Gate fractional ownership investment functions

### 11.3 Phase 7: Decentralized Verification
- Replace single VERIFIER role with multi-sig approval
- Reputation system for verifiers
- Slashing mechanism for fraudulent approvals

---

## 12. Design Decisions Summary (Approved for Phase 2.1)

Based on mentor review feedback (2026-07-21), the following design decisions are **APPROVED** for implementation:

### 12.1 Role Taxonomy ✅ APPROVED

**5 Business Identity Roles:**

- ✅ `ROLE_ASSET_OWNER` (0x01)
- ✅ `ROLE_LICENSEE` (0x02)
- ✅ `ROLE_INVESTOR` (0x04) - broad definition, accreditation deferred to Phase 5
- ✅ `ROLE_VERIFIER` (0x08)
- ✅ `ROLE_ARBITRATOR` (0x10) - NEW, required for LicenseEscrow dispute resolution

**System Permissions (Separate Layer):**

- ✅ OpenZeppelin AccessControl: `DEFAULT_ADMIN_ROLE`, `VERIFIER_MANAGER_ROLE`, `IDENTITY_MANAGER_ROLE`
- ❌ **REJECTED:** `ROLE_ADMIN` as a business identity (mixing governance with identity causes data pollution)

### 12.2 State Machine ✅ APPROVED

**6 States:**

- None → Pending → Verified → Suspended/Revoked
- Rejected (can reapply: Rejected → Pending)
- Revoked (terminal state, no transitions out)

**Key Design Choice:**

- ❌ **REJECTED:** `Expired` as a separate status
- ✅ **APPROVED:** Expiration handled via `expiresAt` timestamp check in `isVerified()`
- **Rationale:** Avoids daily on-chain state transitions; blockchain doesn't auto-execute

### 12.3 Integration Scope ✅ APPROVED

**Layered Verification Strategy:**

- ✅ IPAssetRegistry: `registerAsset()` requires `ASSET_OWNER`
- ✅ EvidenceRegistry: `addEvidence()` requires `ASSET_OWNER`, `setReviewer()` requires `VERIFIER`
- ✅ LicenseEscrow: `createAgreement()` requires `ASSET_OWNER` + `LICENSEE`, `resolveDispute()` requires `ARBITRATOR`
- ✅ Read operations remain permissionless

### 12.4 Privacy Model ✅ APPROVED

**Current Implementation:**

- ✅ On-chain: status + roleMask only (no PII)
- ✅ Off-chain: encrypted KYC docs on IPFS (metadataURI)

**Future Enhancement:**

- 🔮 Zero-knowledge proofs (Phase 7+)
- ✅ **APPROVED:** Reserve `IIdentityVerifier` interface for future ZKP integration
- ❌ **REJECTED:** ZKP implementation in Phase 2 (would shift learning focus to circuits/proofs)

---

## 13. Implementation Roadmap (Phase 2.1)

### Commit 1: Core Contract

**File:** `contracts/IdentityRegistry.sol`

**Scope:**

- [ ] Import OpenZeppelin AccessControl
- [ ] Define `IdentityStatus` enum (6 states)
- [ ] Define `Identity` struct
- [ ] Define role constants (5 roles, bit shift syntax)
- [ ] Define `VERIFIER_MANAGER_ROLE` and `IDENTITY_MANAGER_ROLE`
- [ ] Implement core functions: `registerIdentity()`, `verifyIdentity()`, `rejectIdentity()`, `suspendIdentity()`, `restoreIdentity()`, `revokeIdentity()`
- [ ] Implement query functions: `hasRole()`, `isVerified()`, `getIdentity()`
- [ ] Implement modifiers: conflict-of-interest checks
- [ ] Define events: 6 lifecycle events
- [ ] Define custom errors

**No integration with existing contracts yet.**

### Commit 2: Comprehensive Testing

**File:** `test/IdentityRegistry.t.sol`

**Coverage:**

- [ ] Registration flow (None → Pending)
- [ ] Verification flow (Pending → Verified)
- [ ] Rejection flow (Pending → Rejected, Rejected → Pending)
- [ ] Suspension flow (Verified → Suspended → Verified)
- [ ] Revocation flow (Verified/Suspended → Revoked, terminal state)
- [ ] KYC expiration (timestamp-based, not status-based)
- [ ] Role checks (`hasRole()` with bit masks)
- [ ] Conflict of interest (VERIFIER/ARBITRATOR cannot be ASSET_OWNER)
- [ ] Access control (only VERIFIER_MANAGER can verify, only ADMIN can revoke)
- [ ] Edge cases (reapply after rejection, cannot escape revoked state)

**Target:** 30+ tests, 100% line coverage

### Commit 3: Integration with Existing Contracts

**Files:**

- `contracts/IPAssetRegistry.sol`
- `contracts/EvidenceRegistry.sol`
- `contracts/LicenseEscrow.sol`
- `test/IdentityRegistry.Integration.t.sol`

**Changes:**

- [ ] Add `IdentityRegistry public immutable identityRegistry` to each contract
- [ ] Update constructors to accept `_identityRegistry` address
- [ ] Add identity checks to write operations (see section 6.1 table)
- [ ] Write integration tests: verify reverts when identity missing, passes when verified

---

## 14. Success Criteria

Phase 2.1 is complete when:

- ✅ `IdentityRegistry.sol` compiles without errors
- ✅ All 30+ unit tests pass
- ✅ Integration tests demonstrate cross-contract identity checks
- ✅ No conflict-of-interest violations possible
- ✅ AccessControl properly separates business identity from system permissions
- ✅ Gas cost per user onboarding < 150,000 gas
- ✅ Contract size < 24KB (EIP-170 limit)

**Estimated Effort:** ~500 LOC contract + ~800 LOC tests = 1,300 LOC total

---

## Appendix A: Gas Cost Estimates

| Operation | Estimated Gas | Notes |
|-----------|---------------|-------|
| `registerIdentity()` | ~80,000 | SSTORE for new identity |
| `verifyIdentity()` | ~50,000 | Update status + roleMask |
| `hasRole()` (view) | ~2,500 | Single SLOAD + bitwise AND |
| `isVerified()` (view) | ~3,000 | SLOAD + timestamp check |
| `suspendIdentity()` | ~30,000 | Status update only |
| `revokeIdentity()` | ~30,000 | Status update only |

**Total per user onboarding:** ~130,000 gas (register + verify)  
**At 30 gwei & $3000 ETH:** $11.70 per user

---

## Appendix B: Comparison with Other Protocols

| Protocol | Identity Model | Notes |
|----------|----------------|-------|
| **Aave** | No on-chain KYC, relies on wallet addresses | Permissionless DeFi |
| **Compound** | No identity system | Permissionless DeFi |
| **Polymath** | KYC via service providers, on-chain attestation | Security token standard (ST-20) |
| **Securitize** | Centralized KYC, whitelist model | Regulatory-focused |
| **Our Protocol** | On-chain status + off-chain encrypted docs | Hybrid: compliant but decentralized |

**Our Positioning:** More compliant than pure DeFi, more decentralized than Securitize.

---

**END OF DESIGN DOCUMENT**

**Status:** ✅ Design Approved (2026-07-21)  
**Next Action:** Begin Phase 2.1 Implementation (Commit 1: Core Contract)

**Key Learnings from Design Phase:**

1. **Business Identity ≠ System Permission**: Separated into two layers to avoid governance/identity data pollution
2. **ARBITRATOR Role Addition**: Essential for LicenseEscrow dispute resolution authorization
3. **No Expired Status**: Expiration handled via timestamp checks, not state machine transitions
4. **Layered Verification**: Not all functions require identity; strategic placement at state-changing operations
5. **ZKP Reserved for Future**: Phase 2 focuses on mapping/role/status/expiration; circuit complexity deferred

**This design represents the transition from address-based permission to identity-based permission—the defining characteristic of RWA protocols vs pure DeFi.**
