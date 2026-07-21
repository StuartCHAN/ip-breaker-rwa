# Phase 3.1-B RevenueVault Design Freeze

**Status:** Design freeze (pre-implementation)  
**Date:** 2026-07-21  
**Scope:** Asset-level revenue custody, accounting, claims, and token checkpoints  
**Implementation:** No Solidity changes in Phase 3.1-B Design Freeze

## 1. Purpose and boundaries

`RevenueVault` holds and distributes realized license revenue for exactly one
`LicenseRevenueToken`. It is the funded accounting boundary behind the token's
revenue right.

```text
eligible license settlement
          |
          v
    Revenue Router
          |
          v
     RevenueVault  ---- immutable settlement asset
          |
          +---- accumulatedRewardPerShare
          +---- holder rewardDebt / pendingReward
          |
          v
eligible LicenseRevenueToken holders claim
```

The vault does not issue tokens, license IP, determine IP ownership, guarantee
revenue, convert currencies, or create a claim from an unpaid invoice. A holder
has a funded claim only after an authorized deposit has entered and been
accounted by the vault.

This document freezes accounting semantics and authority boundaries. Exact ABI
names may change during implementation, but they must preserve these rules.

## 2. Decisions at a glance

| Topic | Frozen decision |
|---|---|
| Token relationship | One vault serves one token; both refer to the same IP revenue program. |
| Settlement asset | One immutable, allowlisted ERC-20 per vault; production baseline is chain-specific USDC. |
| Deposits | Only an authorized revenue-routing contract may create accounted revenue. |
| Distribution | Pull claims using a cumulative reward-per-share accumulator. |
| Balance changes | The token must checkpoint affected accounts before every balance update. |
| Recovery | Full-balance recovery migrates the old holder's complete unclaimed revenue ledger atomically. |
| Failure policy | Deposit, checkpoint, recovery, and claim accounting fail closed. |
| Pausing | Deposit, claim, and token-transfer pauses are separate powers with narrow effects. |
| Escrow integration | Future successful licensor settlements route a disclosed share into the vault atomically. |

## 3. Relationship with LicenseRevenueToken

### 3.1 One-to-one program binding

Each vault is permanently bound to:

- one `LicenseRevenueToken` contract;
- the token's immutable `IPAssetRegistry` address and `assetId`;
- one immutable settlement asset; and
- one revenue program identifier or factory registration.

The vault must verify the token/asset binding during deployment or program
activation. A program factory must prevent two active vaults from independently
claiming the same asset revenue stream.

```text
(IPAssetRegistry, assetId)
          |
          +---- one active LicenseRevenueToken
          |
          +---- one bound RevenueVault
```

The vault address must be bound once before revenue activation. It cannot be
silently replaced by an administrator. Any future migration requires a separate
audited process that preserves token balances, pending claims, vault assets, and
the complete event trail.

### 3.2 Responsibility split

| LicenseRevenueToken | RevenueVault |
|---|---|
| Stores balances and fixed supply | Custodies the settlement asset |
| Enforces holder eligibility | Authorizes and accounts revenue deposits |
| Classifies mint, transfer, and recovery | Maintains the global accumulator |
| Calls the checkpoint interface | Stores per-holder reward accounting |
| Cannot withdraw vault funds | Cannot mint or alter token balances |

Only the bound token may invoke balance-change and recovery checkpoints. Only
the vault may mutate its reward ledger. Neither side may use an alternative
privileged path that bypasses the handshake.

### 3.3 Activation dependency

The vault may accept accounted revenue only after:

1. the token is bound to the vault;
2. the token has reached `finalSupply`;
3. the token lifecycle is `Activated`; and
4. the vault/program is explicitly activated.

Consequently, every deposit uses a nonzero, fixed denominator. Revenue received
before activation must revert; it is not held as an ambiguous future reserve.

## 4. Revenue deposit authority

### 4.1 Authorized source

Accounted deposits require a narrowly scoped system permission such as
`REVENUE_DEPOSITOR_ROLE`. The intended holder is a future `RevenueRouter` or an
escrow settlement adapter, not the asset owner, token holder, or arbitrary EOA.

An administrator may manage the depositor role subject to the program's
governance controls, but possessing an admin role does not itself classify a
payment as revenue or permit withdrawal.

### 4.2 Deposit requirements

Every deposit must:

- come through the authorized deposit entry point;
- identify the source agreement or settlement with a unique reference;
- correspond to the vault's `assetId` and revenue program;
- use the immutable settlement asset;
- occur after program activation and while deposits are not paused;
- transfer the funds and update accounting atomically;
- reject reuse of the same settlement reference; and
- emit the depositor, source reference, received amount, and new accumulator.

For the initial allowlisted ERC-20 model, the actual vault balance increase must
equal the declared deposit. Fee-on-transfer, rebasing, or otherwise incompatible
assets are rejected rather than silently socializing a shortfall.

### 4.3 Unsolicited transfers

Direct ERC-20 transfers to the vault do not increase
`accumulatedRewardPerShare` and do not create holder liabilities. The vault
distinguishes:

```text
accounted settlement balance = totalDeposited - totalClaimed
actual token balance         = accounted balance + unsolicited excess
```

Unsolicited excess may be recovered only through a delayed, auditable excess
recovery process that proves the withdrawal cannot reduce the accounted
balance. It must never be treated as administrator revenue or used to mask an
accounting deficit.

## 5. Supported settlement asset

### 5.1 Frozen baseline

One vault supports exactly one immutable ERC-20 settlement asset. The production
baseline is the exact chain-specific USDC contract configured at deployment.
The vault must record the token address and decimals; it must not rely on a
symbol such as `USDC` as identity.

One accumulator never mixes assets or denominations:

```text
assetId 42 / USDC -> RevenueVault A
assetId 42 / ETH  -> not deposited into RevenueVault A
```

### 5.2 Asset requirements

The first implementation supports only reviewed ERC-20 assets with stable
balance semantics. It excludes:

- fee-on-transfer tokens;
- rebasing tokens;
- tokens whose balances change without a transfer;
- unreviewed bridge-wrapped assets;
- native ETH in the ERC-20 vault; and
- automatic swaps or oracle-based conversions.

Native ETH, another ERC-20, or another chain requires a separate vault and
separate economic program. Supporting another asset later must not mutate the
settlement asset of an active vault.

## 6. `accumulatedRewardPerShare` model

### 6.1 Global state

The vault maintains at least:

```text
accumulatedRewardPerShare  cumulative settlement units per token unit
scaledRemainder            division remainder carried into later deposits
totalDeposited             all authorized accounted deposits
totalClaimed               all successfully paid claims
```

Let:

```text
P = fixed precision scalar, selected to avoid material truncation
S = token.totalSupply(), fixed at finalSupply after activation
D = newly received settlement amount in its smallest unit
R = prior scaledRemainder
```

For each deposit:

```text
scaledDistribution          = D * P + R
increment                   = floor(scaledDistribution / S)
scaledRemainder             = scaledDistribution % S
accumulatedRewardPerShare  += increment
totalDeposited             += D
```

The implementation must select `P` and multiplication logic with explicit
overflow bounds. Settlement-asset decimals and token decimals are not assumed
to match. The carried remainder prevents global deposit-division dust from
being silently discarded.

### 6.2 No holder iteration

A deposit updates only global state. It never loops over holders. Holder amounts
are crystallized lazily on checkpoint or claim, keeping deposit cost bounded as
the holder set grows.

### 6.3 Deposit ordering

Funds must be present before new liabilities are finalized. The deposit follows
checks-effects/interactions appropriate to safe ERC-20 receipt, verifies the
actual balance delta, and then commits the accumulator atomically. Any failure
reverts the transfer and accounting together.

## 7. Claim accounting

### 7.1 Per-account state

For each account `a`:

```text
rewardDebt[a]    accumulator entitlement already checkpointed for its balance
pendingReward[a] crystallized but unpaid settlement amount
```

Before a balance change or claim, the vault settles the account using its
current pre-change balance:

```text
accruedNow = floor(balanceOf(a) * accumulatedRewardPerShare / P)
newAccrual = accruedNow - rewardDebt[a]

pendingReward[a] += newAccrual
rewardDebt[a]     = accruedNow
```

`rewardDebt` is not a debt owed by the holder. It is a checkpoint preventing the
same accumulator interval from being credited twice.

The implementation must use multiplication/division routines and bounds that
cannot overflow for the frozen maximum supply and deposit limits.

### 7.2 Claimable view

Without changing state:

```text
claimable(a)
  = pendingReward[a]
  + floor(balanceOf(a) * accumulatedRewardPerShare / P)
  - rewardDebt[a]
```

The view is informational. A successful claim must checkpoint again in the same
transaction so a preceding deposit or balance update cannot make the payment
stale.

### 7.3 Claim flow

```text
1. require claims active and claimant eligible under claim policy
2. checkpoint claimant
3. read pendingReward
4. set pendingReward to zero and increase totalClaimed
5. transfer settlement asset to the approved recipient
6. emit claim event
```

Claims use checks-effects-interactions and `nonReentrant`. If the settlement
transfer fails, the entire transaction reverts, restoring both accounting and
funds. A zero claim may revert or return zero consistently; it must not change
accounting.

Loss, suspension, expiration, or revocation of identity pauses payout but does
not erase earned revenue. Recovery handles permanently inaccessible accounts.

## 8. Token transfer checkpoint rules

### 8.1 Mandatory ordering

For every token balance change:

```text
1. token validates lifecycle, authority, and compliance
2. token asks the vault to checkpoint the classified movement
3. vault settles affected accounts using pre-change balances
4. vault records rewardDebt using projected post-change balances
5. token updates balances through ERC-20 _update()
```

All five steps are atomic and fail closed. If the vault call fails, token
balances do not move. If the token update later fails, the vault checkpoint is
also reverted.

### 8.2 Projected post-change debt

A simple pre-transfer checkpoint is insufficient: leaving `rewardDebt` based on
the old balance would let the receiver claim historical revenue or cause the
sender's next checkpoint to underflow.

The vault checkpoint therefore receives a classified movement and amount, reads
the pre-change token balances, and computes:

```text
senderPostBalance   = senderPreBalance - amount
receiverPostBalance = receiverPreBalance + amount

rewardDebt[sender]   = floor(senderPostBalance * accumulator / P)
rewardDebt[receiver] = floor(receiverPostBalance * accumulator / P)
```

This records the new balances' starting index before the ERC-20 update occurs.
Only the bound token may call this method, and the subsequent token update must
match the checkpointed movement in the same transaction.

### 8.3 Movement rules

| Movement | Vault treatment |
|---|---|
| Pre-activation mint | No revenue exists; initialize receiver debt consistently. |
| Ordinary transfer | Settle both parties; historical pending remains with the seller. |
| Self-transfer | No economic change; checkpoint once or use a verified no-op path. |
| Burn, if ever permitted | Settle sender before reducing balance; never discard pending revenue. |
| Recovery | Use the dedicated migration rule in Section 9. |

After revenue activation, there must be no balance-changing internal path that
bypasses the vault checkpoint, including controller or recovery paths.

### 8.4 Reentrancy boundary

The checkpoint does not transfer settlement assets and does not call arbitrary
external recipients. It may read the bound token's balances and global supply.
The token-vault callback graph must be documented and guarded so the vault
cannot reenter another balance change while a checkpoint is in progress.

## 9. Recovery accounting migration

### 9.1 Recovery purpose

Recovery replaces a lost, compromised, or permanently unusable holder address.
It is not confiscation, redemption, clawback, or a mechanism to redistribute
historical revenue.

The production recovery path requires:

- a narrowly authorized recovery role or governed process;
- an auditable reason/reference;
- an eligible replacement address;
- full-balance movement from the old address;
- zero net token-supply change; and
- atomic migration of the complete unclaimed reward ledger.

Full-balance recovery is frozen as the baseline because partial movement leaves
ambiguous ownership of already crystallized, account-level rewards. A partial
administrative movement must use a separately designed process and may not call
itself account recovery.

### 9.2 Atomic migration order

For source `old` and destination `replacement`:

```text
1. validate recovery authority, evidence reference, and replacement eligibility
2. require recovered amount == balanceOf(old)
3. checkpoint old and replacement at the current accumulator
4. migrated = pendingReward[old]
5. pendingReward[old] = 0
6. pendingReward[replacement] += migrated
7. set old rewardDebt to zero
8. set replacement rewardDebt for its projected post-recovery balance
9. move the full token balance without changing totalSupply
10. emit token and reward-migration events
```

Any failure reverts every step. After recovery, the old account has neither
tokens nor an unclaimed vault balance; the replacement owns both future token
participation and the migrated historical pending amount. Existing rewards of
the replacement are additive and cannot be overwritten.

### 9.3 Recovery invariants

```text
totalSupply before == totalSupply after

pending(old) + pending(replacement) before settlement/migration
  == pending(old) + pending(replacement) after settlement/migration

global totalDeposited, totalClaimed, and accumulator do not change
```

Phase 3.1-A2 integration must update the current A1 recovery path to satisfy this
handshake before the vault accepts revenue.

## 10. Revenue conservation invariants

The implementation and invariant test suite must continuously preserve:

### 10.1 Custody and solvency

For the supported non-rebasing, non-fee settlement asset:

```text
accountedVaultBalance = totalDeposited - totalClaimed

actualVaultBalance >= accountedVaultBalance
```

Equality holds when there are no unsolicited transfers. No successful claim may
make `actualVaultBalance < accountedVaultBalance`.

### 10.2 Liability conservation

At any reachable state:

```text
totalClaimed
  + all paid-but-not-accounted amounts
  + all outstanding holder entitlement
  + rounding residue
  <= totalDeposited
```

There are no paid-but-not-accounted amounts in the baseline atomic claim model,
so that term must remain zero. Rounding may delay distribution but may never
create liabilities above deposits.

### 10.3 No duplication or retroactive participation

- A deposit is accounted exactly once.
- A settlement reference cannot be replayed.
- A holder cannot claim the same accumulator interval twice.
- A buyer cannot claim revenue deposited before receiving tokens.
- A seller retains revenue earned before transferring tokens.
- Pre-activation minted balances cannot claim nonexistent historical revenue.
- Recovery neither loses nor duplicates pending revenue.
- Claim order does not change aggregate holder entitlement except for bounded
  per-account rounding.

### 10.4 Supply and denominator

```text
while deposits are enabled:
token.lifecycle == Activated
token.totalSupply == token.finalSupply
token.totalSupply > 0
```

No deposit may use a mutable, zero, or stale denominator.

### 10.5 Required invariant tests

The implementation phase must include stateful tests covering random sequences
of deposits, transfers, claims, eligibility changes, pauses, and recoveries. At
minimum they must prove custody solvency, deposit/claim conservation, no double
claim, transfer checkpoint correctness, and recovery conservation.

## 11. Emergency pause boundaries

### 11.1 Independent pause domains

Emergency controls are separated:

| Pause | Stops | Does not stop or change |
|---|---|---|
| Deposit pause | New accounted deposits | Existing balances, accumulator, and pending claims |
| Claim pause | Settlement-asset payouts | Accrual and existing pending balances |
| Token transfer pause | Ordinary token transfers | Supply, accrued rewards, and governed recovery |

The token owns transfer pausing; the vault owns deposit and claim pausing. A
global administrator shortcut must not accidentally grant all three powers.

### 11.2 Checkpoint availability

Checkpoint accounting itself is not independently pausable while token balance
changes are enabled. Either:

- checkpoints remain operational; or
- token transfers are paused first.

Allowing balances to move while checkpoints are disabled is forbidden. A vault
failure must fail closed at the token.

### 11.3 Forbidden emergency actions

No pause authority may:

- withdraw accounted holder funds;
- reset or decrease the accumulator;
- erase `pendingReward` or alter `rewardDebt` arbitrarily;
- change the settlement asset, token, `assetId`, or final supply;
- reopen minting;
- redirect claims to an administrator;
- classify unsolicited funds as revenue; or
- use pause as a permanent wind-down or confiscation mechanism.

Pause and unpause actions require events and should be held by a multisig or
timelocked governance with an emergency response policy. Accrual state remains
frozen in place during a claim pause and becomes claimable when claims resume.

## 12. Future integration with LicenseEscrow

### 12.1 Eligible settlement paths

No `LicenseEscrow` changes occur in this design phase. A future integration may
route only realized licensor revenue:

| Escrow outcome | RevenueVault treatment |
|---|---|
| `release()` succeeds | Deposit disclosed token-holder share. |
| `resolveDispute(true)` pays licensor | Deposit disclosed token-holder share. |
| `resolveDispute(false)` refunds licensee | No revenue deposit. |
| Funded/Active/Disputed balance | Not revenue until final settlement. |
| Cancelled or unfunded agreement | No revenue deposit. |

### 12.2 Atomic settlement routing

For an enrolled agreement:

```text
gross realized settlement
          |
          +---- protocol fee, if disclosed
          +---- licensor remainder
          +---- token-holder share -> RevenueRouter -> RevenueVault
```

The split formula and revenue-program binding must be fixed or governance-bounded
before the agreement is funded. A failed vault deposit must revert the entire
settlement so LicenseEscrow cannot mark an agreement paid while the holder share
is missing. Existing escrow CEI ordering, state transitions, and reentrancy
protection must be preserved.

### 12.3 Currency compatibility

The current escrow settles native ETH, while the frozen production vault
baseline is USDC. Integration must therefore choose one explicit path:

1. add a separately reviewed ERC-20/USDC escrow settlement mode; or
2. use a separately reviewed conversion router with disclosed slippage and
   oracle protections.

The baseline vault never treats ETH analytics or an off-chain conversion promise
as USDC backing. Until compatible settlement exists, current ETH agreements do
not fund the USDC vault.

### 12.4 Agreement enrollment and cutover

Each eligible agreement must bind to the revenue program and revenue-share terms
at creation or before funding. Historical Phase 2 revenue and already-funded
agreements are excluded by default. They cannot be retroactively enrolled merely
by incrementing an analytics counter.

The settlement reference should include chain, escrow contract, agreement ID,
and final outcome so the vault can reject duplicate routing.

## 13. Roles and authority matrix

| Authority | Permitted action | Explicitly forbidden |
|---|---|---|
| Revenue depositor/router | Deposit verified settlement revenue | Claim, withdraw, change accumulator manually |
| Eligible holder | Claim own accrued revenue | Deposit classified revenue, claim for another holder without authorization |
| Bound token | Invoke checkpoint and recovery accounting | Transfer settlement assets |
| Recovery authority | Execute governed full-account migration | Change total supply or global revenue totals |
| Deposit pauser | Pause/unpause deposits | Pause claims or withdraw funds |
| Claim pauser | Pause/unpause claims | Erase claims or redirect payout |
| Default admin/governance | Manage bounded roles | Change immutable economic bindings or seize accounted funds |

Role holders should be contracts, multisigs, or timelocked governance where
appropriate. Token ownership grants none of these administrative permissions.

## 14. Required events and observability

The future implementation must emit enough information to independently rebuild
the ledger:

- vault/program activation;
- authorized revenue deposit and unique source reference;
- accumulator increment and carried remainder;
- successful claim and recipient;
- token balance-change checkpoint;
- recovery reward migration;
- deposit pause/unpause;
- claim pause/unpause;
- depositor and recovery-role changes; and
- excess-token recovery, if implemented.

Public views must expose immutable bindings, global totals, accumulator state,
pause state, per-account pending/reward debt, and computed claimable amounts.

## 15. Non-goals

Phase 3.1-B does not design or authorize:

- Solidity implementation;
- changes to `LicenseEscrow`;
- native ETH and ERC-20 accounting in one vault;
- swaps, price oracles, or currency conversion;
- portfolio revenue pooling;
- holder governance or principal redemption;
- automatic distribution loops;
- administrator withdrawal of accounted revenue;
- retroactive claims on Phase 2 settlements; or
- a vault migration or terminal wind-down implementation.

## 16. Implementation gates for the next phase

Before Solidity implementation begins, review and freeze:

1. exact chain and settlement-token address;
2. precision scalar and proven arithmetic bounds;
3. token-vault binding and activation handshake;
4. checkpoint ABI and callback/reentrancy guard;
5. claim eligibility and authorized-recipient rules;
6. depositor, pause, recovery, and admin role holders;
7. settlement-reference format and replay protection;
8. full-balance recovery evidence/governance process;
9. excess-token recovery delay and proof of surplus; and
10. LicenseEscrow currency migration and revenue-share formula.

No vault should accept revenue until token checkpoints, claim accounting,
recovery migration, and conservation invariants are implemented and tested as a
single atomic system.
