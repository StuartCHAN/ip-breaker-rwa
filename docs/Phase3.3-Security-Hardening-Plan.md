# Phase 3.3 Security Hardening Plan

## 1. Purpose and Scope

Phase 3.2 completed the end-to-end offering lifecycle. Phase 3.3 now converts
the repository-wide security review into a bounded hardening program before an
external audit or production deployment.

This document freezes the remediation direction for three confirmed
engineering risks:

1. settlement-token dust can permanently block offering finalization;
2. generic wallet recovery can cross the Legal-Hold custody boundary;
3. `OfferingManager` runtime code exceeds the EIP-170 deployment limit.

This is a design and implementation plan only. It does not change Solidity,
contract interfaces, deployment scripts, or protocol state.

## 2. Security Baseline

The review covered the first-party identity, licensing, offering, custody,
token, revenue, recovery, frontend, and deployment surfaces. The local
verification baseline is:

- 400 regular Foundry tests passed;
- two bounded invariant suites passed with 800 calls each;
- the frontend production build passed;
- `forge lint` found no security defect in production contracts;
- `forge build --sizes` measured `OfferingManager` runtime at approximately
  30,118 bytes, 5,542 bytes above the 24,576-byte EIP-170 limit;
- Slither was not available in the review environment.

The principal invariant for Phase 3.3 is:

> Protocol lifecycle progress and custody authorization must depend only on
> protocol-owned accounting and explicit custody type, never on ambient token
> balances or a broader role intended for a different asset class.

## 3. Priority and Sequencing

| Workstream | Class | Priority | Dependency |
| --- | --- | --- | --- |
| Settlement Dust Finalization DoS | Protocol availability | P1 | None |
| Recovery / Legal-Hold Isolation | Custody authorization | P1 | Custody classification design |
| `OfferingManager` Modularization | Deployment blocker | P1 release blocker | Preserve the first two fixes and all lifecycle invariants |

Recommended execution order:

```text
3.3-A1  Finalization dust hardening
    ↓
3.3-A2  Recovery / Legal-Hold isolation
    ↓
3.3-B   OfferingManager modularization
    ↓
3.3-C   Full regression, invariant, size, and static-analysis gate
```

The two security fixes should land before modularization so their regression
tests become constraints on the split. Modularization must not silently alter
the already-frozen offering lifecycle.

## 4. Finding 1 — Settlement Token Dust Finalization DoS

### 4.1 Problem

`OfferingManager` is intentionally non-custodial, but finalization currently
uses the Manager's absolute settlement-token balance as a postcondition:

```text
settlementToken.balanceOf(OfferingManager) == 0
```

An ERC-20 recipient cannot reject an ordinary transfer. Any holder can send one
base unit of the configured settlement asset directly to the Manager. Every
later finalization attempt then reverts, atomically rolling back:

- Revenue Token activation;
- Revenue Program activation;
- RevenueVault deposit enablement;
- OfferingEscrow proceeds enablement;
- the final `Finalized` status transition.

The unsolicited balance remains after rollback, so retrying does not restore
liveness. One balance can affect every offering using the same Manager and
settlement token.

### 4.2 Frozen Remediation Invariant

The desired invariant is:

> `OfferingManager` must never intentionally receive or account for offering
> settlement assets, but unsolicited ERC-20 balances must not control offering
> lifecycle progress.

Finalization must validate offering-specific authoritative accounting:

```text
OfferingEscrow.totalContributed
    ==
issuerProceeds + protocolFee
```

It must not treat this ambient value as authoritative:

```text
IERC20(settlementToken).balanceOf(OfferingManager)
```

### 4.3 Preferred Design

Remove the absolute settlement-balance finalization gate. Keep the existing
escrow contribution, entitlement, delivery, token supply, and lifecycle
postconditions.

The Manager should continue to have no protocol path that:

- calls `transferFrom()` for a settlement token;
- receives subscription funds;
- receives issuer proceeds;
- temporarily routes protocol fees;
- withdraws or rescues offering-accounted USDC.

An optional unaccounted-token sweep is not required to restore finalization.
If introduced later for operational hygiene, it must:

- transfer only from the Manager's ambient, non-accounted balance;
- use one immutable or tightly governed treasury destination;
- emit a dedicated event;
- remain independent from `finalizeOffering()`;
- never become a prerequisite for lifecycle progress.

A generic owner withdrawal or arbitrary rescue function is not acceptable.

### 4.4 Acceptance Tests

- An unprivileged account transfers one settlement base unit to the Manager;
  an otherwise valid offering still finalizes.
- Dust does not change `totalContributed`, issuer proceeds, protocol fee, or
  escrow solvency.
- Multiple offerings sharing one settlement token cannot block one another
  through the Manager's ambient balance.
- A genuine finalization postcondition failure still rolls back Token,
  ProgramRegistry, Vault, Escrow, and Offering status atomically.
- No Manager call path pulls or pushes offering settlement funds.
- Existing successful and failed offering tests remain unchanged.

## 5. Finding 2 — Recovery / Legal-Hold Isolation

### 5.1 Problem

A Legal-Hold position is not an ordinary token holder. It is an isolated
custody account whose immutable release authority is:

```text
original beneficialOwner
    +
current eligibility
    +
OfferingManager-orchestrated LegalHold release
```

The generic recovery path currently accepts an arbitrary nonzero source
balance. If recovery governance targets a registered Legal-Hold position, the
Token and historical RevenueVault state can migrate to the recovery
destination without using the Legal-Hold release path.

That creates a privilege expansion:

```text
generic wallet-recovery authority
    →
position-level legal custody authority
```

Role separation, destination consent, nonce checks, and the challenge period
remain meaningful controls, but none proves that the source belongs to the
`NormalHolder` custody class. A completed migration can leave the Legal-Hold
record marked `Held` while its position balance has moved elsewhere.

### 5.2 Frozen Custody Classes

Phase 3.3 should make custody type explicit:

```solidity
enum CustodyType {
    NormalHolder,
    AllocationEscrow,
    LegalHoldPosition
}
```

This enum is conceptual; implementation may use immutable bindings, registry
queries, dedicated entry points, or another representation. The required
behavior is:

| Custody type | Generic wallet recovery | Authorized movement |
| --- | --- | --- |
| `NormalHolder` | Allowed after the full RecoveryManager lifecycle | Full-balance Token + RevenueVault migration |
| `AllocationEscrow` | Forbidden | OfferingManager primary delivery or failure tombstone rules |
| `LegalHoldPosition` | Forbidden | Beneficial-owner-bound LegalHold release only |

### 5.3 Preferred Design

The narrowest safe change is Token-side enforcement because
`LicenseRevenueToken.executeRecoveryMigration()` is the final authority that
moves both Token and Vault state.

Before generic recovery migration, the Token should reject a source registered
as an active Legal-Hold position by its bound `LegalHoldEscrow`.

Required invariant:

> A Legal-Hold position can leave custody only through
> `executeLegalHoldRelease()` using the position's immutable
> `subscriptionId`, `beneficialOwner`, and `amount`.

The design must avoid a caller-supplied custody flag. Custody classification
must come from an immutable, protocol-owned binding or authoritative position
registry.

### 5.4 State Consistency Requirements

For a rejected generic recovery:

- RecoveryManager request state must roll back or remain safely retryable;
- Token balance must remain on the Legal-Hold position;
- `pendingReward` and `rewardDebt` must remain unchanged;
- Legal-Hold position status must remain `Held`;
- `totalSupply`, `totalDeposited`, and `totalClaimed` must remain unchanged.

For an authorized Legal-Hold release:

- destination remains the original `beneficialOwner`;
- current eligibility is revalidated;
- Token balance and historical pending revenue migrate atomically;
- position status changes to `Released` exactly once;
- the generic RecoveryManager is not involved.

### 5.5 Acceptance Tests

- Generic recovery of a normal holder still succeeds.
- Generic recovery rejects a registered `LegalHoldPosition`.
- Rejection preserves RecoveryManager, Token, Vault, and LegalHold state.
- No requester, verifier, approver, executor, guardian, Token controller, or
  Manager role can override the custody-class check.
- A valid Legal-Hold release still migrates the exact amount and historical
  revenue to the immutable beneficial owner.
- A released position cannot be recovered or released again.
- A forged or unrelated contract cannot self-identify as a protected position.
- Recovery and Legal-Hold invariant suites cover zero double claim and exact
  conservation.

## 6. Finding 3 — `OfferingManager` EIP-170 Deployment Blocker

### 6.1 Problem

The measured runtime is approximately:

```text
30,118 bytes
```

The standard EIP-170 runtime limit is:

```text
24,576 bytes
```

The current margin is therefore approximately:

```text
-5,542 bytes
```

Passing local tests does not make the contract deployable on a standard EVM
chain. This is not an attacker-exploitable vulnerability, but it is a hard
production and demo-network release blocker.

### 6.2 Modularization Objective

Reduce the deployed runtime below 24,576 bytes with a safety margin while
preserving:

- one authoritative offering state machine;
- immutable offering configuration;
- exact sequence processing;
- custody contracts as the only asset holders;
- permissionless objective transitions;
- atomic failure and finalization propagation;
- no new admin bypass or arbitrary external call surface.

A target below 23,000 bytes is recommended to leave room for final audit fixes.

### 6.3 Candidate Boundary

The first design review should evaluate:

```text
OfferingManager
    ├── OfferingCore / canonical storage and state transitions
    ├── Subscription and Reconciliation module
    ├── Delivery and Legal-Hold controller
    └── Finalization controller
```

This diagram describes responsibilities, not a mandate to use
`delegatecall`. The preferred implementation should avoid proxy-style ambient
storage authority unless a separate design proves its storage layout, upgrade,
and authorization invariants.

Safer options to compare:

1. stateless helper libraries for validation and calculation;
2. dedicated controllers with narrow immutable Manager authorization;
3. a smaller Manager coordinating purpose-built Escrows that continue to own
   their own custody state.

### 6.4 Controls Against Semantic Drift

Before moving code, freeze black-box behavior through tests for:

- `Draft → Open → Successful/Failed → Finalized`;
- Draft expiry and Program reservation release;
- immutable token/escrow/vault/program bundle checks;
- sequence-only reconciliation and delivery;
- refund and proceeds mutual exclusion;
- direct release plus legal-hold transfer equals `finalSupply`;
- failure tombstones;
- finalization ordering and rollback;
- Manager zero intentional custody;
- every permission matrix row.

Every extracted component must use a narrow interface and fixed caller. It must
not accept arbitrary target addresses, generic calldata, or caller-selected
destinations.

### 6.5 Acceptance Tests and Release Gate

- `forge build --sizes` reports `OfferingManager` below 24,576 bytes, with a
  documented target margin.
- All existing unit, integration, fuzz, and invariant tests pass.
- New Dust DoS and Recovery/Legal-Hold isolation regressions pass.
- Full finalization remains atomic across all dependencies.
- Storage and event compatibility are documented if existing deployments or
  indexers must be supported.
- No new generic `delegatecall`, rescue, withdrawal, or arbitrary-call
  capability is introduced.
- Slither runs successfully in CI, with reviewed suppressions committed as
  configuration rather than hidden in command-line flags.

## 7. Phase 3.3-C Verification Matrix

| Gate | Required result |
| --- | --- |
| Unit and integration tests | All pass |
| Fuzz tests | No failing counterexample |
| Offering and Vault invariants | No invariant breach |
| Recovery / LegalHold invariants | Exact balance and reward conservation |
| Finalization rollback tests | All dependency failures remain atomic |
| `forge lint` | No unresolved production security warning |
| `forge build --sizes` | Every deployable contract under EIP-170 |
| Slither | Executed and triaged |
| Frontend build | Passes with updated ABIs if interfaces change |
| Deployment rehearsal | Complete role/binding receipt on the target testnet |

## 8. Non-Goals

Phase 3.3 hardening must not add:

- new offering economics;
- new investor rights;
- a new settlement asset model;
- arbitrary beneficiary replacement;
- direct USDC pushes during finalization;
- upgradeability without a separate design freeze;
- recovery challenge-policy changes unrelated to custody isolation;
- a second active Revenue Program for one asset.

## 9. Delivery Milestones

```text
Phase 3.2 Protocol Implementation
✅ Complete

Phase 3.3 Security Review
✅ Discovery, validation, and attack-path analysis complete

Phase 3.3-A Critical Hardening
⬅️ Next
    A1. Settlement Dust DoS
    A2. Recovery / Legal-Hold isolation

Phase 3.3-B Deployment Hardening
    OfferingManager modularization and size reduction

Phase 3.3-C Audit Simulation
    Full regression, fuzz, invariants, Slither, size, and deployment rehearsal

Phase 3.4 External Audit Preparation

Phase 4 Production Readiness
```

No Phase 3.3 item is considered closed until the original failure path has a
regression test and all conservation, lifecycle, and deployment gates pass.
