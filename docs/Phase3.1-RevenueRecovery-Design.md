# Phase 3.1-B2-B Revenue Recovery Design Freeze

**Status:** Design freeze (pre-implementation)  
**Date:** 2026-07-21  
**Scope:** Revenue Token account recovery and RevenueVault ledger migration  
**Implementation:** No Solidity changes in Phase 3.1-B2-B Design Freeze

## 1. Purpose and boundary

Revenue recovery preserves one verified beneficial holder's economic position
when their original on-chain address is lost, compromised, permanently
inaccessible, or no longer legally usable.

Recovery moves two linked forms of state:

```text
old holder address
    |
    +---- full LicenseRevenueToken balance
    +---- all accrued but unclaimed RevenueVault rewards
    |
    v
verified replacement address for the same beneficial holder
```

It does not create a sale, redemption, confiscation, inheritance process,
sanctions seizure, or administrative reallocation. Those actions require
separate legal and protocol designs.

This phase freezes behavior only. It does not modify `LicenseRevenueToken`,
`RevenueVault`, their interfaces, or any test.

## 2. Decisions at a glance

| Topic | Frozen decision |
|---|---|
| Economic meaning | Recovery is identity/account continuity, not a transfer between different beneficial owners. |
| Execution authority | A dedicated recovery authority executes an approved recovery record; default admin or token controller alone is insufficient. |
| Holder scope | The source may be inaccessible or identity-invalid; the replacement must be currently verified and offering-eligible. |
| Token amount | Full source balance only. Partial recovery is not supported. |
| Reward amount | All accrued and stored unclaimed rewards move to the replacement. |
| Supply | Direct balance movement with zero net supply change; no burn/re-mint supply window. |
| Accounting | A dedicated vault recovery checkpoint replaces the ordinary transfer checkpoint. |
| Failure policy | Identity, authorization, vault accounting, and token movement are atomic and fail closed. |
| Replay protection | Every approved recovery has a unique, single-use recovery identifier. |

## 3. Why recovery is not transfer

### 3.1 Different beneficial ownership semantics

An ordinary transfer changes which beneficial holder owns future token
participation:

```text
Alice sells/transfers tokens to Bob

Alice keeps historical accrued rewards
Bob receives token balance and only future participation
```

Recovery preserves the same beneficial holder while changing the technical
address used to exercise their rights:

```text
Alice's lost address -> Alice's verified replacement address

replacement receives the full token balance
replacement also receives Alice's unclaimed historical rewards
```

Therefore, applying ordinary transfer accounting to recovery is incorrect. The
B2-A transfer checkpoint deliberately leaves historical `pendingReward` with
the sender. A recovery using that path would strand the exact rewards that the
recovery is intended to preserve.

### 3.2 Different authorization

Ordinary transfer authorization comes from the source address through
`transfer` or allowance. Recovery exists precisely because that authorization
may be unavailable or untrustworthy.

Recovery authorization instead comes from a governed identity-continuity
process. It must prove that the replacement represents the same beneficial
holder; possession of a protocol role is not by itself sufficient evidence.

### 3.3 Different accounting outcome

| Result | Ordinary transfer | Recovery |
|---|---|---|
| Token balance | Requested amount moves | Entire source balance moves |
| Source historical pending rewards | Remain at source | Move to replacement |
| Destination historical entitlement | Does not receive source history | Receives source unclaimed history |
| Beneficial owner | Changes | Remains the same |
| Source signature | Required | May be unavailable |
| Execution authority | Holder/approved spender | Approved recovery executor |

Recovery must use a dedicated method and event. It must not disguise itself as
an ordinary privileged transfer.

## 4. Who can initiate and execute recovery

### 4.1 Request initiation

A recovery case may be initiated by:

- the verified holder through an accessible identity-linked channel;
- a previously designated recovery contact or institutional custodian;
- an authorized identity verifier acting on documented holder evidence; or
- a legally recognized representative under an off-chain process defined by
  the offering terms.

Request initiation does not move tokens or rewards. It creates a case for
verification and produces a unique `recoveryId` plus a non-sensitive evidence
commitment.

### 4.2 Approval and execution separation

The baseline separates three responsibilities:

| Responsibility | Intended authority |
|---|---|
| Verify same beneficial identity | Approved identity/KYC verifier |
| Approve the recovery case | Governed RecoveryManager or multisig policy |
| Execute the on-chain migration | Dedicated `RECOVERY_EXECUTOR_ROLE` held by the RecoveryManager |

The `TOKEN_CONTROLLER_ROLE`, `DEFAULT_ADMIN_ROLE`, asset owner, depositor, and
Revenue Token holders do not automatically receive recovery authority.

Production governance should require verifier approval plus a multisig or
RecoveryManager decision. No single EOA should be able to seize an account by
calling recovery directly.

### 4.3 Recovery record

Before execution, an approved record must bind at least:

```text
recoveryId
revenueToken
revenueVault
source address
replacement address
identity/evidence commitment
approval timestamp
earliest execution timestamp
expiry timestamp
status
```

The record is single use. Cancellation, expiry, rejection, or prior execution
must make it unusable.

### 4.4 Delay and source quarantine

After approval, a bounded challenge delay should allow detection of a mistaken
or malicious request. Once an approved recovery enters that delay, the source
account is quarantined from:

- ordinary Revenue Token transfers;
- new approvals or allowance use, where enforceable by the token;
- claims to a source-controlled payout address; and
- concurrent recovery execution.

Deposits may continue. Revenue accruing during quarantine belongs to the same
holder and migrates at execution.

Quarantine must be time-bounded, case-specific, auditable, and removable after
rejection or expiry. It is not a general administrator freeze power.

## 5. Identity verification flow

### 5.1 Source identity

Recovery cannot require a valid source signature or currently valid source
identity, because loss, compromise, suspension, expiration, or revocation may
be the reason recovery is necessary.

Instead, the verifier establishes that:

1. the source was the recorded holder of the position;
2. the claimant is the same beneficial person or legal entity;
3. the stated recovery reason satisfies the offering policy; and
4. no conflicting recovery or ownership dispute is active.

An identity revocation caused by fraud, sanctions, court order, or disputed
ownership must not automatically qualify for account recovery. Such cases enter
a separate legal hold or adjudication process.

### 5.2 Replacement identity

At both approval and execution time, the replacement must:

- be nonzero and different from the source;
- have a currently verified identity;
- have active `ROLE_INVESTOR`;
- pass `IInvestorEligibility.canHold(replacement, assetId)`;
- represent the same verified beneficial holder as the source recovery case;
- not be quarantined, sanctioned, revoked, or bound to a conflicting identity;
  and
- satisfy offering-specific jurisdiction and concentration constraints after
  receiving the balance.

Execution-time revalidation is mandatory because eligibility can change during
the challenge delay.

### 5.3 Privacy boundary

Personally identifiable information must remain off-chain. On-chain state and
events contain only hashes, opaque verifier references, status, timestamps, and
addresses required for auditability.

The evidence commitment must not be reversible PII and must be domain-separated
by chain, program, token, source, replacement, and recovery ID to prevent reuse
across offerings.

### 5.4 Frozen verification sequence

```text
holder/representative submits request
              |
              v
identity verifier checks continuity and evidence
              |
              v
RecoveryManager approves exact source -> replacement pair
              |
              v
challenge delay + source quarantine
              |
              v
execution-time identity and eligibility revalidation
              |
              v
atomic token + reward-ledger migration
```

Any failed check leaves balances, rewards, supply, and global vault accounting
unchanged.

## 6. Balance migration

### 6.1 Full balance only

The source's entire token balance moves in one operation:

```text
amount = token.balanceOf(source)

source post-balance      = 0
replacement post-balance = replacement pre-balance + amount
```

The amount must be nonzero. A caller cannot supply an arbitrary smaller amount.
Full migration avoids ambiguous allocation of account-level pending rewards and
ensures the recovered identity has no residual economic state at the old
address.

Partial seizure, estate division, divorce allocation, or court-directed split
is not recovery and is outside this design.

### 6.2 Direct movement, not burn/re-mint

Recovery should produce a direct ERC-20 balance movement and standard
`Transfer(source, replacement, amount)` event. It must not expose an
intermediate reduction or increase in `totalSupply`.

Using burn followed by mint would complicate supply invariants, event semantics,
and future integrations that react to mint/burn. If an implementation internally
uses equivalent primitives, the entire operation must remain atomic and every
external observation must preserve zero net supply change. Direct movement is
the frozen baseline.

### 6.3 Destination with an existing balance

The replacement may already hold tokens if identity and offering policy permit
it. Its existing balance and rewards remain intact; recovered amounts are
additive. Post-recovery concentration limits are evaluated against the combined
balance.

## 7. Pending reward migration

### 7.1 Settle both accounts first

Let:

```text
A = accumulatedRewardPerShare at execution
P = accumulator precision
oldBalance = balanceOf(source)
newBalance = balanceOf(replacement)
```

Before moving balances, the vault crystallizes current accrual for both
accounts:

```text
sourceAccrued = floor(oldBalance * A / P) - rewardDebt[source]
replacementAccrued = floor(newBalance * A / P) - rewardDebt[replacement]

pendingReward[source] += sourceAccrued
pendingReward[replacement] += replacementAccrued
```

If either subtraction is invalid, recovery fails closed. The implementation
must not repair an inconsistent ledger by discarding or guessing rewards.

### 7.2 Migrate the complete unclaimed amount

After settlement:

```text
migratedPending = pendingReward[source]

pendingReward[source] = 0
pendingReward[replacement] += migratedPending
```

This includes:

- rewards already crystallized before the request;
- rewards accrued but not yet checkpointed;
- revenue deposited during quarantine; and
- rounding results already attributable under the vault formula.

Already claimed revenue does not migrate and cannot be claimed again.
Replacement rewards that existed before recovery are preserved and added to,
never overwritten.

### 7.3 Global reward state is unchanged

Recovery must not change:

- `accumulatedRewardPerShare`;
- `precisionRemainder`;
- `totalDeposited`;
- `totalClaimed`; or
- the vault's settlement-asset balance.

It only reallocates existing per-account unclaimed entitlement between two
addresses representing the same holder.

## 8. `rewardDebt` handling

After pending rewards are settled and migrated, debt is based on projected
post-recovery balances at the same accumulator:

```text
rewardDebt[source] = 0

rewardDebt[replacement]
  = floor((newBalance + oldBalance) * A / P)
```

This is necessary for two reasons:

1. the empty source must not retain debt that later causes underflow; and
2. the replacement's recovered balance must not earn the same historical
   accumulator interval a second time.

The migrated historical value lives in `pendingReward[replacement]`. The new
`rewardDebt` establishes the starting index for future deposits against the
combined balance.

At successful completion:

```text
claimable(source) = 0

claimable(replacement)
  = replacement's prior unclaimed reward
  + source's migrated unclaimed reward
```

Future deposits accrue entirely to the replacement's combined token balance.

## 9. Atomic recovery sequence

The future token and vault integration must use a dedicated recovery interface,
semantically equivalent to `checkpointRecovery`, rather than
`checkpointTransfer`.

```text
1. validate unique approved recoveryId and execution authority
2. revalidate source quarantine and replacement identity/eligibility
3. read and require the full nonzero source balance
4. token invokes the bound vault's dedicated recovery checkpoint
5. vault settles source and replacement at the current accumulator
6. vault migrates all source pendingReward to replacement
7. vault writes projected post-recovery rewardDebt values
8. token moves the full balance through its centralized _update path
9. mark recoveryId executed
10. emit correlated token, vault, and recovery events
```

Steps 1-10 occur in one transaction. If the vault callback, balance update,
identity check, or event-path state update fails, every preceding change reverts.

The token-vault callback must retain B2-A's checkpoint reentrancy protections.
Only the bound token may call the vault recovery checkpoint, and only the
authorized recovery execution path may cause the token to classify a movement
as recovery.

## 10. `totalSupply` invariant

Recovery changes ownership, not supply:

```text
totalSupplyBefore == totalSupplyAfter == finalSupply

balanceOf(source)Before
  + balanceOf(replacement)Before
  == balanceOf(source)After
  + balanceOf(replacement)After
```

It must never:

- reopen minting;
- call a public burn function;
- change `finalSupply`;
- create replacement tokens without removing the same source amount;
- remove source tokens without crediting the replacement; or
- use recovery as redemption.

Supply and pair-balance equality should be asserted by the implementation and
covered by stateful invariant tests.

## 11. Event design

### 11.1 Case lifecycle events

A future RecoveryManager should emit events equivalent to:

```text
RecoveryRequested(
  recoveryId,
  token,
  source,
  replacement,
  evidenceCommitment,
  requester
)

RecoveryApproved(recoveryId, verifier, earliestExecution, expiry)
RecoveryCancelled(recoveryId, reasonCode, authority)
RecoveryExpired(recoveryId)
```

No event includes names, government identifiers, documents, or other plaintext
PII.

### 11.2 Execution events

Successful execution must emit:

```text
RevenueRecoveryExecuted(
  recoveryId,
  source,
  replacement,
  tokenAmount,
  pendingRewardMigrated,
  executor
)
```

The vault should also emit a correlated reward-ledger migration event containing
the same `recoveryId`, source, replacement, and migrated pending amount.

The Revenue Token emits the standard:

```text
Transfer(source, replacement, tokenAmount)
```

It must not emit synthetic burn and mint `Transfer` events for a direct recovery.
All events must be sufficient to reconstruct case status, token movement, and
reward migration without revealing private evidence.

### 11.3 Failed recoveries

A reverted execution emits no success event and changes no state. Operational
systems may record failed attempts off-chain, but an on-chain failure must not
mark the recovery ID as consumed.

## 12. Security constraints

### 12.1 Authorization and anti-seizure controls

- Use a dedicated recovery role; do not reuse minter, depositor, asset-owner, or
  ordinary token-controller authority.
- Require an approved, unexpired, single-use recovery record in addition to the
  role check.
- Bind approval to the exact token, vault, source, replacement, chain, and
  offering.
- Use multisig/timelock governance and separation between identity verification
  and execution.
- Reject zero addresses, self-recovery, zero balances, partial balances, and
  replayed IDs.
- Recheck destination identity and eligibility immediately before execution.

### 12.2 Accounting safety

- The dedicated recovery checkpoint is callable only by the bound token.
- Settle both accounts before changing either balance.
- Never overwrite destination `pendingReward`.
- Zero all source reward state after its complete migration.
- Do not change global deposit, claim, accumulator, remainder, or settlement
  balances.
- Preserve solvency and `totalClaimed <= totalDeposited`.
- Any accounting inconsistency reverts; no fail-open or administrator repair is
  allowed inside recovery.

### 12.3 Atomicity and reentrancy

- Token balance migration and reward-ledger migration must share one atomic
  transaction.
- Maintain the token checkpoint reentrancy lock and vault `nonReentrant` guard.
- The vault checkpoint must not transfer settlement assets or call arbitrary
  recipient contracts.
- Claims, ordinary transfers, and another recovery cannot interleave with an
  active recovery execution.
- If the final token balance update fails, vault state and recovery status must
  revert automatically.

### 12.4 Race and lifecycle controls

- Quarantine the source after approval to prevent balance or claim races during
  the challenge period.
- Expired or cancelled cases must release quarantine without moving assets.
- A new recovery request cannot replace an active request for the same source.
- Recovery may execute while ordinary transfers are paused only if the pause
  policy explicitly permits governed recovery; pausing must not bypass identity
  or accounting checks.
- Recovery does not activate a token, reopen minting, change the bound vault, or
  alter offering terms.

### 12.5 Legal and identity disputes

Recovery is inappropriate when beneficial ownership itself is contested. Fraud,
inheritance, insolvency, sanctions, court orders, or competing claims require a
legal-hold/adjudication process. The recovery authority must not resolve those
disputes merely by selecting a destination address.

## 13. Recovery invariants

The implementation phase must prove at least:

```text
totalSupplyBefore == totalSupplyAfter

sourceBalanceAfter == 0

replacementBalanceAfter
  == sourceBalanceBefore + replacementBalanceBefore

sourcePendingAfter == 0
sourceRewardDebtAfter == 0

replacementUnclaimedAfter
  == sourceUnclaimedBefore + replacementUnclaimedBefore

accumulatedRewardPerShareBefore == accumulatedRewardPerShareAfter
precisionRemainderBefore == precisionRemainderAfter
totalDepositedBefore == totalDepositedAfter
totalClaimedBefore == totalClaimedAfter
vaultSettlementBalanceBefore == vaultSettlementBalanceAfter
```

Additional behavioral invariants:

- neither address can claim the same historical reward twice;
- the source cannot claim migrated rewards;
- the replacement receives all future revenue for the combined balance;
- destination pre-existing rewards survive recovery;
- failed recovery leaves every token, vault, identity, and case value unchanged;
  and
- the same recovery ID cannot execute twice.

## 14. Required implementation tests for the next phase

Before recovery can be enabled, tests must cover:

- unauthorized executor rejected;
- unapproved, expired, cancelled, and replayed recovery IDs rejected;
- zero, self, ineligible, suspended, expired, and revoked replacements rejected;
- full balance migrates and partial recovery is rejected;
- source historical pending reward migrates completely;
- replacement pre-existing balance and pending reward are preserved;
- source claimable and reward debt are zero after recovery;
- replacement cannot double claim historical revenue;
- future deposits follow the combined replacement balance;
- total supply and global vault totals remain unchanged;
- failed vault checkpoint rolls back token movement and case status;
- recovery cannot be reentered; and
- random deposit/claim/transfer/recovery sequences preserve conservation.

## 15. Non-goals

Phase 3.1-B2-B does not implement or define:

- Solidity changes;
- partial recovery;
- ordinary token transfers;
- inheritance or estate distribution;
- court-ordered seizure or sanctions confiscation;
- token redemption or buyback;
- RevenueVault migration;
- LicenseEscrow integration;
- OfferingManager; or
- recovery of unrelated ERC-20 tokens sent to the vault.

The current B2-A recovery behavior remains an interim implementation: it
checkpoints the balance movement as an ordinary transfer and leaves historical
`pendingReward` at the source. It must not be treated as production-complete
revenue recovery until the dedicated atomic migration described here is
implemented and verified.
