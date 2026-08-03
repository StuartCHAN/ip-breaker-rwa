# Phase 3.1-B2-B2 RecoveryManager Design Freeze

**Status:** Design freeze (pre-implementation)  
**Date:** 2026-07-21  
**Scope:** Governed recovery requests, identity approval, challenge, isolation, and execution authorization  
**Implementation:** No Solidity changes in Phase 3.1-B2-B2 Design Freeze

## 1. Purpose and boundaries

`RecoveryManager` is the governance and authorization layer above the atomic
Token/Vault recovery accounting implemented in Phase 3.1-B2-B1.

```text
recovery intake
      |
      v
identity continuity verification
      |
      v
approval -> old-wallet isolation -> challenge period
      |
      v
authorized execution
      |
      v
LicenseRevenueToken + RevenueVault atomic migration
```

The manager decides whether a recovery request is authorized and executable. It
does not calculate rewards, custody settlement assets, mint tokens, change
offering terms, or resolve disputed beneficial ownership.

This document freezes the orchestration layer only. It does not implement a
contract or modify `LicenseRevenueToken`, `RevenueVault`, `IdentityRegistry`, or
their tests.

## 2. Decisions at a glance

| Topic | Frozen decision |
|---|---|
| Trusted recovery caller | The Token trusts only its registered RecoveryManager contract, not an EOA or TokenController. |
| Authority model | Request intake, identity verification, approval, challenge response, and execution are separate capabilities. |
| Identity | A verifier attests source-to-replacement beneficial identity continuity; the replacement is revalidated at execution. |
| Request scope | One immutable token/source/replacement/evidence tuple per request. |
| Challenge | Approval starts a mandatory delay; no emergency bypass may shorten an active request. |
| Replay protection | Domain-separated recovery ID plus per-token/source nonce and terminal-status checks. |
| Isolation | Approved source wallet is quarantined; successful source wallet is permanently retired for that token. |
| Execution | Executor chooses only a ready request ID; addresses and amounts are derived from frozen state. |
| Accounting | Manager invokes the existing full-balance Token/Vault atomic migration and never edits reward state directly. |

## 3. RecoveryManager role

### 3.1 Core responsibility

The manager is a recovery state machine and policy gate. It must:

- register supported Token/Vault program pairs;
- accept bounded recovery requests;
- record identity-continuity verification;
- obtain independent recovery approval;
- enforce the challenge period and request expiry;
- expose old-wallet isolation status to the Token and Vault;
- authorize exactly one full-balance execution;
- call the Token's controlled recovery entry point; and
- retain an auditable, non-PII request history.

It must not:

- custody Revenue Tokens or settlement assets;
- mutate `pendingReward`, `rewardDebt`, or vault totals directly;
- select a partial recovery amount;
- mint, burn, activate, pause, or reconfigure a Revenue Token;
- change the bound RevenueVault;
- classify an ownership dispute as ordinary recovery; or
- bypass identity, challenge, isolation, or replay checks.

### 3.2 Proposed system permissions

The exact names may change during implementation, but capability separation is
frozen:

| Permission | Capability |
|---|---|
| `RECOVERY_ADMIN_ROLE` | Register supported programs and manage bounded role assignments. No request approval or execution by default. |
| `RECOVERY_REQUESTER_ROLE` | Submit a case after completing approved intake. Cannot verify or approve it. |
| `IDENTITY_VERIFIER_ROLE` | Attest same-beneficial-holder continuity and replacement identity. Cannot execute. |
| `RECOVERY_APPROVER_ROLE` | Approve a verified case and start isolation/challenge. Cannot provide its identity attestation. |
| `RECOVERY_EXECUTOR_ROLE` | Execute a ready request exactly as stored. Cannot change its parameters. |
| `RECOVERY_GUARDIAN_ROLE` | Raise/record emergency challenges and pause new executions. Cannot migrate assets. |

One address should not hold verifier, approver, and executor capabilities. In
production, verifier authority belongs to an approved identity service;
approver/admin authority belongs to separate multisigs or governed contracts;
executor authority may be an operations multisig or automation contract.

### 3.3 Token-facing authority

For each supported Revenue Token, the RecoveryManager contract receives a
dedicated token-side permission such as `RECOVERY_ROLE`. Individual manager role
holders do not receive permissions directly on the Token.

```text
authorized executor EOA/automation
          |
          v
RecoveryManager.executeRecovery(recoveryId)
          |
          v
LicenseRevenueToken.recoverTokens(...)
```

The Token verifies `msg.sender == registeredRecoveryManager` or the equivalent
dedicated role. This prevents an executor, verifier, approver, TokenController,
or default admin from bypassing manager state.

## 4. Separation from TokenController

### 4.1 Different responsibilities

`TOKEN_CONTROLLER_ROLE` manages the token program lifecycle: vault binding,
pre-activation allocation control, and activation. Recovery governs identity
continuity after token ownership exists.

| TokenController | RecoveryManager |
|---|---|
| Binds the initial RevenueVault | Cannot replace the vault |
| Opens allocation/minting | Cannot mint |
| Activates and permanently freezes supply | Cannot activate or reopen supply |
| Manages token-program setup | Manages approved wallet-continuity cases |
| Does not prove investor identity continuity | Requires independent verifier evidence |

### 4.2 Frozen authorization change

The production recovery function must not remain callable solely through
`TOKEN_CONTROLLER_ROLE`. When RecoveryManager is implemented:

- recovery authority moves to the registered RecoveryManager;
- TokenController cannot invoke full-balance migration directly;
- granting/revoking the manager follows delayed governance and emits events;
- replacing a manager cannot affect an active request silently; and
- manager replacement cannot change Token/Vault balances or reward state.

The current B2-B1 controller-authorized recovery is an implementation staging
mechanism, not the final production authority model.

### 4.3 No admin aggregation

Possession of `DEFAULT_ADMIN_ROLE` must not automatically confer verifier,
approver, executor, or token-side recovery capability. Role administration may
assign narrowly scoped roles, but a completed recovery still requires the full
request lifecycle.

## 5. Identity verification flow

### 5.1 Required proof

The verifier attests that:

1. the source address is the recorded holder being recovered;
2. the claimant and replacement address represent the same beneficial person or
   legal entity as the source recovery record;
3. the recovery reason is permitted by offering policy;
4. no competing beneficial-ownership claim or legal hold is known;
5. the replacement has a currently verified identity;
6. the replacement has active `ROLE_INVESTOR`; and
7. the replacement passes the offering-specific
   `IInvestorEligibility.canHold(replacement, assetId)` policy.

The source identity or signature need not remain valid. Loss, compromise,
suspension, or expiry may be why recovery is requested. Revocation due to fraud,
sanctions, disputed ownership, insolvency, inheritance, or court action does not
automatically qualify and must enter a separate adjudication path.

### 5.2 Verification artifact

The manager stores only a domain-separated commitment, not personal data:

```text
identityAttestationHash = hash(
  chainId,
  recoveryManager,
  revenueToken,
  source,
  replacement,
  recoveryNonce,
  evidenceCommitment,
  verifier,
  attestationExpiry
)
```

Plaintext names, identification numbers, documents, addresses, or KYC results
must remain off-chain. The attestation has an expiry and cannot be reused for a
different program or destination.

### 5.3 Destination consent

The replacement must consent to receiving the recovered position. Consent may
be an on-chain acknowledgement or an EIP-712 signature bound to the exact
request ID, token, source, nonce, and deadline.

This prevents a recovery from forcing regulated assets and associated
obligations onto an unrelated wallet.

### 5.4 Execution-time revalidation

Immediately before execution, RecoveryManager rechecks:

- attestation validity and verifier authorization;
- destination consent and deadline;
- active replacement identity and `ROLE_INVESTOR`;
- offering eligibility and post-migration holding limits;
- Token/Vault binding;
- source isolation and request status; and
- absence of a conflicting active recovery or legal hold.

Approval-time validation alone is insufficient because identity and compliance
state can change during the challenge period.

## 6. Request lifecycle

### 6.1 Frozen states

```text
None
  |
  v
Requested
  |
  | identity verifier attests exact request
  v
Verified
  |
  | independent approver accepts
  v
Approved / ChallengePeriod
  |                |
  | deadline       | valid challenge
  v                v
Ready          Challenged
  |                |
  | execute        +---- Cancelled
  v                |
Executed           +---- re-approved with a new full challenge period

Requested / Verified / Approved may also become Cancelled or Expired.
```

`Ready` may be a derived state rather than stored state:

```text
status == Approved
AND block.timestamp >= challengeDeadline
AND block.timestamp <= executionExpiry
AND no unresolved challenge
```

### 6.2 Request creation

Creation freezes:

- supported Revenue Token and its bound Vault;
- source and replacement addresses;
- current per-token/source nonce;
- evidence commitment;
- requester and creation timestamp;
- attestation/consent deadlines; and
- request expiry policy.

Creation requires nonzero distinct addresses, nonzero source balance, no active
request for the same token/source, and a destination that is not isolated or
retired. It does not move balances, migrate rewards, or isolate the source.

### 6.3 Verification

Only an authorized identity verifier may move `Requested -> Verified`. The
verifier signs/records the exact immutable request. Changing source,
replacement, token, vault, nonce, or evidence requires cancelling the request
and creating a new one.

The same actor cannot satisfy both identity verification and independent
approval for a request.

### 6.4 Approval

Only an authorized approver may move `Verified -> Approved`. Approval:

- records the approver and approval timestamp;
- begins the complete challenge period;
- sets an execution expiry later than the challenge deadline; and
- atomically activates source-wallet isolation.

If isolation cannot be activated, approval reverts and the request remains
Verified.

### 6.5 Terminal states

- `Executed`: migration succeeded and the recovery ID is permanently consumed.
- `Cancelled`: an authorized resolution rejected or withdrew the request.
- `Expired`: the applicable verification, approval, challenge, or execution
  deadline passed without successful execution.

Cancelled and expired requests cannot be revived. A new request uses a new
nonce and repeats identity verification and the complete challenge period.

## 7. Challenge period

### 7.1 Purpose

The challenge period protects against mistaken identity, forged evidence,
compromised verifier credentials, malicious insiders, and attempts to recover a
wallet that remains under legitimate control.

It begins only after both verification and independent approval. Starting it at
request creation would let an unreviewed request consume the safety delay before
governance accepts the evidence.

### 7.2 Duration

Each manager deployment or registered program has a public, governance-bounded
`challengePeriod`. The production baseline should be no shorter than 72 hours,
subject to legal and operational review.

The period for an already approved request is immutable. Governance may lengthen
future requests through a timelocked update, but cannot shorten, skip, or
emergency-bypass an active request.

### 7.3 Who may challenge

A challenge may be submitted by:

- the source wallet, if still controlled;
- the replacement wallet;
- the requester or identity verifier;
- an authorized compliance/legal guardian; or
- another actor permitted by a documented bonded-challenge policy.

Challenges include an opaque reason code and evidence commitment, never PII.
Submitting a valid challenge immediately blocks execution but does not
automatically transfer assets or unlock the source.

### 7.4 Challenge resolution

A challenged request can only:

- be cancelled and the temporary source isolation released; or
- be re-approved after independent review, starting a new complete challenge
  period.

An approver cannot simply delete the challenge or preserve the old deadline.
The challenger cannot redirect the destination or execute recovery.

## 8. Nonce and replay protection

### 8.1 Per-source nonce

RecoveryManager maintains a monotonic nonce for each `(revenueToken, source)`:

```text
recoveryNonce[revenueToken][source]
```

The nonce is allocated and incremented when a request is successfully created.
Cancellation, expiry, challenge, or failed execution never permits nonce reuse.

### 8.2 Recovery identifier

The canonical request ID is domain-separated:

```text
recoveryId = keccak256(
  chainId,
  recoveryManager,
  revenueToken,
  revenueVault,
  source,
  replacement,
  nonce,
  evidenceCommitment
)
```

Including chain and manager prevents cross-chain and cross-manager replay.
Including the exact Token/Vault pair prevents reuse across revenue programs.

### 8.3 Single-use enforcement

Execution requires:

- the recovery ID exists;
- its stored status is Ready/Approved-after-deadline;
- it has never executed or reached another terminal state;
- it matches the current active request for the token/source;
- the stored nonce and all immutable fields match; and
- attestation, consent, challenge, and execution deadlines remain valid.

The manager marks the request as executing/consumed before the external Token
call under checks-effects-interactions. If the Token/Vault migration reverts,
the status update reverts atomically. On success, the ID can never execute again.

Signed verifier and destination messages use EIP-712 domain separation and
include the recovery ID, nonce, and deadline.

## 9. Old wallet isolation

### 9.1 Temporary quarantine

Approval atomically marks the source isolated for the specific Revenue Token.
While isolated, the source cannot:

- send or receive ordinary Revenue Token transfers;
- be used through an existing allowance or `transferFrom`;
- create an effective new approval or permit;
- claim RevenueVault settlement assets;
- start or complete another recovery; or
- be used as a replacement destination.

Blocking incoming transfers prevents unrelated balances from contaminating the
full-balance recovery. Blocking claims ensures all unclaimed value remains
available for atomic migration.

Revenue deposits continue, and the isolated balance continues accruing revenue.
That accrual migrates with the account at execution.

### 9.2 Enforcement points

Isolation must be enforced by every relevant state-changing path:

| Component | Required check |
|---|---|
| LicenseRevenueToken `_update()` | Reject ordinary movements from or to an isolated account. |
| Allowance/permit handling | Prevent effective spending from an isolated source. |
| RevenueVault `claim()` | Reject payout for an isolated source. |
| RecoveryManager | Allow only the exact active request to use the isolated source. |

No component may rely solely on frontend hiding or off-chain monitoring.

### 9.3 Unlock and retirement

- Cancellation or expiry releases temporary isolation only after request state
  reaches its terminal status.
- A challenged request remains isolated until cancellation, expiry, or valid
  re-approval resolution.
- Successful recovery changes the old wallet from `Isolated` to permanently
  `Retired` for that Revenue Token.

A retired wallet cannot receive new Revenue Tokens, claim migrated rewards, or
serve as a future replacement. Permanent retirement prevents accidental reuse
of a compromised address after its state has moved.

Isolation is token/program-specific and must not freeze unrelated assets.

## 10. Execution authorization

### 10.1 Executor limitations

An address with `RECOVERY_EXECUTOR_ROLE` may submit only:

```text
executeRecovery(recoveryId)
```

It cannot supply or override source, replacement, Token, Vault, amount,
evidence, nonce, challenge deadline, or expiry. All values come from the frozen
request, and the token amount is read as the source's complete current balance.

### 10.2 Atomic execution sequence

```text
1. load immutable request by recoveryId
2. verify executor role and exact Ready status
3. verify challenge deadline passed and execution has not expired
4. revalidate identity, consent, eligibility, isolation, and program binding
5. require full nonzero source balance
6. mark request Executing under reentrancy protection
7. call registered LicenseRevenueToken controlled recovery
8. Token calls bound RevenueVault checkpointRecovery
9. Token moves the full balance; Vault migrates pending rewards/debt
10. mark Executed and old wallet Retired
11. emit correlated completion event
```

Steps 1-11 are one transaction. Any failure restores request status, isolation,
Token balances, Vault accounting, and reward state.

### 10.3 Registered-program constraint

The manager executes only against a pre-registered Token/Vault pair that still
matches both contracts' bindings. It cannot accept an arbitrary target contract
from an executor or recovery request.

### 10.4 Pausing

An emergency guardian may pause new approvals and executions after a verifier
or manager compromise. Pausing:

- does not approve, cancel, execute, or redirect a request;
- does not unlock isolated wallets automatically;
- does not alter deadlines silently;
- does not change Token/Vault accounting; and
- cannot bypass the challenge period when unpaused.

Governance must define how deadlines are extended during a manager-wide pause
so isolated holders do not lose execution opportunity through no fault of their
own.

## 11. Events

Events must allow an auditor to reconstruct each request without exposing PII.

### 11.1 Configuration events

```text
RecoveryProgramRegistered(token, vault, managerVersion)
RecoveryProgramDisabled(token, vault, reasonCode)
ChallengePeriodUpdated(oldPeriod, newPeriod, effectiveTime)
RecoveryManagerPaused(authority)
RecoveryManagerUnpaused(authority)
```

Disabling a program cannot silently cancel or execute active requests. Their
treatment must be explicit and separately emitted.

### 11.2 Lifecycle events

```text
RecoveryRequested(
  recoveryId,
  token,
  source,
  replacement,
  nonce,
  evidenceCommitment,
  requester
)

RecoveryIdentityVerified(
  recoveryId,
  verifier,
  attestationHash,
  attestationExpiry
)

RecoveryApproved(
  recoveryId,
  approver,
  challengeDeadline,
  executionExpiry
)

RecoveryChallenged(recoveryId, challenger, reasonCode, evidenceCommitment)
RecoveryCancelled(recoveryId, authority, reasonCode)
RecoveryExpired(recoveryId)
```

### 11.3 Isolation and execution events

```text
RecoveryIsolationChanged(token, source, isolated, recoveryId)
RecoverySourceRetired(token, source, recoveryId)

RecoveryExecuted(
  recoveryId,
  token,
  vault,
  source,
  replacement,
  tokenAmount,
  executor
)
```

The Token's standard `Transfer`, Token recovery event, and Vault
`RevenueStateMigrated` event provide the correlated accounting evidence. All
events use the same recovery ID once the accounting interface is extended to
carry it.

Failed transactions emit no success event and do not consume the request.

## 12. Security invariants

### 12.1 Authority invariants

- TokenController cannot execute recovery.
- RecoveryManager cannot mint, activate, bind a vault, deposit revenue, or claim
  holder funds.
- Identity verifier cannot approve or execute its own attestation.
- Approver cannot alter request parameters or execute migration.
- Executor can execute only a fully verified, approved, unchallenged, unexpired
  request.
- Default admin alone cannot bypass lifecycle checks.
- Only the registered manager contract is trusted by the Token recovery entry
  point.

### 12.2 Request and replay invariants

```text
at most one active request per (token, source)
nonce never decreases or repeats
recoveryId uniquely commits to chain, manager, program, parties, nonce, evidence
terminal request can never return to a live state
executed recoveryId can never execute again
changed destination or evidence always requires a new nonce and challenge period
```

### 12.3 Challenge and isolation invariants

- Execution cannot occur before the complete challenge period ends.
- Active-request challenge period cannot be shortened or bypassed.
- A valid challenge blocks execution immediately.
- Approved source remains isolated until explicit cancellation/expiry or
  successful execution.
- Isolated source balance and unclaimed rewards cannot leave through ordinary
  transfer, allowance, claim, or another recovery.
- Successful source is permanently retired for that token.
- Cancellation/expiry never moves Token or Vault value.

### 12.4 Identity invariants

- Replacement consent is bound to the exact request and has not expired.
- Identity continuity is attested by an authorized verifier independent of the
  approver.
- Replacement identity and offering eligibility pass again at execution.
- Source invalidity alone is not proof of recovery entitlement.
- Disputed beneficial ownership enters legal hold, not automatic recovery.
- No on-chain event or state stores plaintext PII.

### 12.5 Economic and atomicity invariants

RecoveryManager preserves the B2-B1 accounting guarantees:

```text
source token balance after == 0
replacement token balance after == prior source + prior replacement
source pendingReward after == 0
source rewardDebt after == 0
replacement unclaimed after == prior source + prior replacement unclaimed
totalSupply before == totalSupply after
totalDeposited before == totalDeposited after
totalClaimed before == totalClaimed after
vault settlement balance before == vault settlement balance after
```

Additionally:

- Manager never touches holder balances or Vault accounting directly.
- Request execution status and Token/Vault migration succeed or revert together.
- Reentrancy cannot execute a second request or alter the active request.
- Failed identity, challenge, isolation, Token, or Vault checks leave all state
  unchanged.
- Recovery cannot create a double claim or make the Vault insolvent.

## 13. Required implementation tests for the next phase

Before deployment, tests must cover:

- TokenController and direct EOAs cannot recover;
- role separation for requester, verifier, approver, guardian, and executor;
- verifier cannot approve its own request;
- exact lifecycle transitions and invalid transition rejection;
- execution before challenge deadline rejected;
- active challenge blocks execution;
- re-approval starts a new full challenge period;
- expired/cancelled/executed requests cannot execute;
- per-source nonce uniqueness and cross-chain/cross-token replay resistance;
- source isolation blocks transfer, transferFrom, claim, inbound transfer, and
  competing recovery;
- cancellation/expiry unlocks temporary isolation;
- execution permanently retires the source;
- destination consent, identity, and eligibility are rechecked;
- executor cannot substitute destination or amount;
- manager pause cannot bypass or silently shorten deadlines;
- manager reentrancy fails closed; and
- all B2-B1 Token/Vault accounting and solvency invariants still hold.

## 14. Non-goals

Phase 3.1-B2-B2 does not implement or define:

- Solidity changes;
- RecoveryManager deployment or upgrade scripts;
- a legal dispute, inheritance, seizure, or sanctions adjudication system;
- off-chain KYC vendor selection;
- partial recovery;
- TokenController-managed recovery;
- RevenueVault or Token migration;
- LicenseEscrow integration;
- OfferingManager; or
- recovery for assets outside the registered Revenue Token program.

No production recovery should be enabled until manager authorization, old-wallet
isolation, challenge handling, identity revalidation, and B2-B1 accounting are
tested together as one fail-closed system.
