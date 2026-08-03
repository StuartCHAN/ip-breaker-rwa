# Phase 3.1 LicenseRevenueToken Design Freeze

**Status:** Design freeze (pre-implementation)  
**Date:** 2026-07-21  
**Scope:** Asset-level revenue-share token behavior  
**Implementation:** No Solidity changes in Phase 3.1 Design Freeze

## 1. Purpose

`LicenseRevenueToken` is the transferable accounting unit for one IP asset's future, funded license-revenue distributions. It is designed to work with a separate `RevenueVault` and offering eligibility policy.

```text
IPAssetRegistry assetId
        │
        ├── LicenseRevenueToken
        │        balances + compliant transfers
        │
        └── RevenueVault
                 funded revenue + claims
```

This design freezes token semantics before any ERC-20 implementation. It does not itself settle the legal or regulatory classification of the instrument.

## 2. Decisions at a glance

| Topic | Frozen Phase 3.1 decision |
|---|---|
| Token scope | One token contract represents one `IPAssetRegistry.assetId`. |
| Economic meaning | Pro-rata participation in that asset's future revenue pool actually deposited into its bound RevenueVault. |
| Supply | Immutable final supply target; fully allocated before activation; no net supply changes after activation. |
| Mint authority | A narrowly authorized system role held by the future OfferingManager/tokenization controller, not an unrestricted asset-owner EOA. |
| Creation authority | Current IP NFT owner with active `ROLE_ASSET_OWNER`, enforced by a factory/program manager. |
| Transfer model | Compliance-restricted ERC-20 behavior. |
| Investor eligibility | Active `ROLE_INVESTOR` plus offering-specific eligibility. |
| Vault relation | One RevenueVault is bound once before activation and cannot later be replaced silently. |
| Transfer accounting | Compliance validation and revenue checkpoints are mandatory for mint, transfer, burn/recovery, and any forced movement. |
| Governance | Token ownership provides no governance rights. Administrative roles cannot change economic terms after activation. |

## 3. ERC-20 token meaning

### 3.1 Positive definition

For one asset-level revenue program:

```text
holder economic fraction
  = holder token balance / active total token supply
```

That fraction determines the holder's participation in eligible revenue deposited after program activation and after the holder obtained the balance.

The token is a revenue-accounting and transfer instrument. The RevenueVault, not the ERC-20 balance alone, holds settlement funds and records claimable amounts.

### 3.2 Explicit exclusions

Holding `LicenseRevenueToken` does not grant:

- ownership of the IP or IP Asset NFT;
- authority to license, sell, modify, or enforce the IP;
- a license to use the IP;
- ownership of a License Certificate NFT;
- governance over the IP owner or protocol;
- authority to change license terms, revenue share, fees, supply, or settlement asset;
- principal redemption or guaranteed yield;
- participation in historical Phase 2 revenue;
- a claim on funds that never entered the bound RevenueVault.

The token name and metadata must not describe it as IP ownership, equity, debt principal, or a guaranteed-return product.

### 3.3 Revenue starts at activation

Balances participate only after the revenue program is activated and the RevenueVault accepts accounted deposits.

`LicenseEscrow.totalRevenueByAsset` remains an analytics counter. Historical funds already paid to a licensor do not back the token and cannot be claimed by token holders.

## 4. Relation with the IP asset

### 4.1 Immutable asset binding

Each token is permanently bound to:

- one `IPAssetRegistry` address; and
- one `assetId` that exists at program creation.

The binding cannot be changed after deployment. Token metadata should expose this relationship clearly.

### 4.2 One asset, one active revenue program

A future factory or program registry must enforce:

```text
(IPAssetRegistry, assetId) -> at most one active Revenue Token/Vault program
```

Creating parallel active tokens against the same revenue stream would create double claims. Replacement requires an explicit wind-down and migration process, not a second independent deployment.

### 4.3 Who may initiate tokenization

Program creation requires the initiator to be both:

1. the current IP Asset NFT owner; and
2. an identity with an active `ROLE_ASSET_OWNER`.

These checks belong in the future factory/program manager because a token constructor cannot safely establish global uniqueness on its own.

### 4.4 Later IP NFT transfers

Transferring the IP Asset NFT does not automatically:

- transfer Revenue Token balances;
- transfer already accrued holder revenue;
- replace the RevenueVault;
- change supply, revenue share, or settlement asset;
- give the new NFT owner authority to mint tokens;
- terminate investor rights.

The offering agreement must define who owes future revenue after an IP NFT transfer. On-chain implementation must not silently infer this legal obligation from ERC-721 ownership alone.

## 5. Token supply model

### 5.1 Fixed active supply

The program defines an immutable `finalSupply` before deployment or configuration. The token uses a staged lifecycle:

```text
Draft / Allocation
  - mint allocations up to finalSupply
  - correct allocations before revenue starts
          │
          │ require totalSupply == finalSupply
          ▼
Activated
  - minting permanently disabled
  - no ordinary burn that changes net supply
  - compliant transfers only
```

Activation is one-way. No administrator may unfreeze minting or increase `finalSupply`.

### 5.2 Why supply freezes before revenue

Revenue-per-share accounting assumes a known denominator at every deposit. Arbitrary post-activation minting would dilute existing holders and could let new supply claim value it did not fund or earn.

The implementation must enforce:

```text
after activation:
totalSupply == finalSupply
```

except within an atomic recovery operation that burns and re-mints exactly the same amount without changing net supply.

### 5.3 Decimals

The baseline uses 18 token decimals for standard ERC-20 integrations. `finalSupply` is defined in smallest units. Decimals do not imply economic value or settlement-asset decimals.

### 5.4 Burn policy

There is no public `ERC20Burnable` behavior after activation because an uncompensated burn changes every remaining holder's share of future revenue.

Allowed burn behavior:

- allocation correction before activation; or
- an authorized atomic recovery that burns from a compromised/lost address and re-mints the same amount to an eligible replacement address.

Burning is not redemption and does not entitle the holder to settlement assets.

## 6. Mint authority

### 6.1 Separation of authority

The asset owner may authorize creation of a revenue program, but should not receive an unlimited operational mint capability.

The token uses a system permission such as `MINTER_ROLE`, distinct from IdentityRegistry business roles. The intended holder is a future OfferingManager or tightly scoped tokenization controller.

```text
Asset Owner
  authorizes program creation and disclosed allocations
        │
        ▼
OfferingManager / Token Controller
  executes capped pre-activation minting
        │
        ▼
LicenseRevenueToken
```

### 6.2 Mint constraints

Every mint must satisfy:

- token is not activated;
- caller has the system mint permission;
- recipient is eligible for this offering;
- new total supply does not exceed `finalSupply`;
- RevenueVault checkpoints are updated for the recipient;
- an auditable event records recipient and amount.

Activation requires `totalSupply == finalSupply`. Unallocated supply cannot be minted later after revenue begins.

### 6.3 Administrative limits

Neither default admin nor minter may:

- increase `finalSupply`;
- mint after activation;
- change the bound asset;
- change token balances without using checkpointed transfer/recovery paths;
- claim holder revenue;
- use token administration to alter the RevenueVault's settlement accounting.

## 7. Investor eligibility

### 7.1 Two-layer eligibility

An account is eligible only when both layers pass:

```text
IdentityRegistry:
  active ROLE_INVESTOR
        AND
Offering Eligibility Policy:
  account may hold this specific token
```

`ROLE_INVESTOR` is deliberately broad. It does not prove that an investor is eligible for every asset, jurisdiction, risk category, or offering.

### 7.2 Offering-specific policy

The offering policy may later encode or reference:

- permitted jurisdictions;
- investor category or accreditation;
- sanctions and blocklist status;
- per-investor concentration limits;
- offering capacity limits;
- lockup or holding periods;
- transfer windows;
- institutional/custodial requirements.

The token should depend on a minimal eligibility interface rather than embedding every compliance regime directly in ERC-20 code.

### 7.3 Eligibility checks by action

| Action | Required eligibility |
|---|---|
| Mint | Recipient must be eligible. |
| Ordinary transfer | Sender must be permitted to transfer; receiver must be eligible to hold. |
| Claim | Holder must satisfy the RevenueVault claim policy. Ineligibility pauses payout but does not erase accrual. |
| Recovery transfer | Authorized recovery caller; destination must be eligible. |
| Pre-activation correction burn | Authorized controller; source balance is checkpointed. |

### 7.4 Identity becomes invalid after acquisition

Suspension, expiration, or revocation does not confiscate balances or delete accrued revenue.

The normal transfer/claim path may be blocked until eligibility is restored. Permanently revoked or inaccessible accounts require a narrowly authorized recovery process with complete event history. Recovery rules must be finalized before production issuance.

## 8. Compliance transfer rule

### 8.1 Baseline rule

The token is not permissionless. An ordinary nonzero-to-nonzero transfer succeeds only when:

1. transfers are active and not paused;
2. sender is permitted to transfer under the offering policy;
3. receiver has an active `ROLE_INVESTOR`;
4. receiver passes offering-specific eligibility;
5. amount and post-transfer holdings satisfy applicable limits;
6. both revenue checkpoints complete successfully.

Any failure reverts the entire transfer.

### 8.2 Mint, burn, and recovery distinctions

The transfer policy distinguishes:

| Movement | Compliance behavior |
|---|---|
| Mint (`from == address(0)`) | Check mint authority, lifecycle, cap, and receiver eligibility. |
| Ordinary transfer | Check sender permission and receiver eligibility. |
| Pre-activation correction burn (`to == address(0)`) | Check controller authority and lifecycle; checkpoint source. |
| Recovery | Use dedicated authorization; checkpoint both accounts; require eligible receiver; preserve net active supply. |

No code path may use an internal balance update to bypass compliance or checkpoints.

### 8.3 Pausing

A narrowly scoped compliance/emergency role may pause ordinary transfers. Pausing:

- does not change balances;
- does not erase accrued revenue;
- does not reopen minting;
- does not alter `finalSupply`;
- does not grant token-holder governance;
- must emit an event and follow documented authority rules.

Whether claims continue while transfers are paused is a RevenueVault policy decision and must be frozen before vault implementation.

## 9. Relation with RevenueVault

### 9.1 Responsibility split

| LicenseRevenueToken | RevenueVault |
|---|---|
| Stores compliant balances and fixed supply | Holds the settlement asset |
| Enforces transfer eligibility | Accepts accounted revenue deposits |
| Triggers balance-change checkpoints | Maintains revenue-per-share accumulator |
| Exposes asset/program identity | Calculates and pays claims |
| Does not custody distributable revenue | Does not independently mutate token balances |

The token does not promise payment unless the matching vault has received and accounted for settlement funds.

### 9.2 One-time vault binding

The token is deployed/configured in a non-active state, then bound once to its RevenueVault before activation.

```text
deploy token
    ↓
deploy vault referencing token
    ↓
bind vault once
    ↓
mint final allocations
    ↓
activate token and revenue program
```

After activation, the vault address cannot be replaced by an ordinary admin action. Migration requires a dedicated process that preserves balances, accrued claims, and auditability.

### 9.3 Minimal checkpoint interface

The exact Solidity interface is deferred to the RevenueVault design, but the semantic operation is frozen:

```text
checkpointBalanceChange(from, to)
```

Only the bound token may notify the vault of token balance changes. The vault must settle pending accrual for affected nonzero accounts using balances before the update.

### 9.4 Vault failure behavior

After activation, if the mandatory vault checkpoint fails, the token movement reverts. Failing open would corrupt revenue ownership.

This creates a deliberate liveness dependency between token transfers and the vault. The RevenueVault must therefore be small, non-iterative, reentrancy-safe, and thoroughly tested.

## 10. Transfer checkpoint requirement

### 10.1 Required order

For every balance-changing operation:

```text
1. classify movement: mint / transfer / burn / recovery
2. validate lifecycle and compliance
3. checkpoint affected accounts in RevenueVault
4. update ERC-20 balances and total supply
5. emit standard and protocol-specific events
```

All steps occur atomically. A revert at any step leaves eligibility state, vault accounting, token balances, and supply unchanged.

### 10.2 Accounts to checkpoint

| Operation | Accounts checkpointed before balance change |
|---|---|
| Mint | Receiver |
| Transfer | Sender and receiver |
| Burn | Sender |
| Recovery | Old holder and replacement holder |

Self-transfers must not create or duplicate accrual. The implementation should either handle them as a no-economic-change path or checkpoint exactly once.

### 10.3 Historical revenue ownership

The checkpoint rule guarantees:

- seller keeps revenue accrued before transfer;
- buyer participates from the post-transfer balance forward;
- minted supply cannot claim pre-mint revenue;
- burned/recovered balances do not lose or duplicate pre-change accrual;
- the same revenue cannot be claimed by both old and new holders.

### 10.4 OpenZeppelin integration direction

For OpenZeppelin Contracts 5.x, balance changes converge through `_update`. The future implementation should centralize policy and checkpoint integration around the supported balance-update extension point rather than scattering checks among `transfer`, `transferFrom`, mint, and burn wrappers.

No alternative internal balance-changing function may bypass the centralized path.

## 11. Token lifecycle

```text
Draft
  - asset binding established
  - vault not yet active
  - transfers disabled
        │
        ▼
Allocating
  - vault bound
  - capped minting to eligible recipients
  - corrections allowed under controller authority
        │ totalSupply == finalSupply
        ▼
Active
  - mint permanently frozen
  - compliant transfers enabled
  - mandatory vault checkpoints
  - revenue participation enabled
        │
        ▼
Paused (temporary sub-state)
  - ordinary transfers blocked
  - supply and accrued rights unchanged
        │
        ▼
Active / future wind-down process
```

Wind-down, migration, and final vault closure require a separate design. An administrator cannot use “wind-down” as an implicit redemption promise.

## 12. Security and economic invariants

The implementation phase must preserve at least:

### Supply invariants

```text
totalSupply <= finalSupply

if activated:
    totalSupply == finalSupply
```

An atomic recovery must have zero net supply change.

### Binding invariants

```text
assetRegistry and assetId never change
bound vault cannot change after activation
activation cannot be reversed
minting cannot resume after activation
```

### Compliance invariants

```text
every ordinary receiver is eligible at transfer time
every mint receiver is eligible at mint time
no privileged path bypasses transfer checkpoints
```

### Distribution-boundary invariants

```text
balance change cannot succeed if required checkpoint fails
transfer does not move seller's accrued historical revenue
minted balance cannot claim pre-mint revenue
recovery cannot duplicate accrual
```

## 13. Required events and observability

In addition to standard ERC-20 events, implementation should expose auditable events for:

- token activation and permanent mint freeze;
- RevenueVault binding;
- compliance pause/unpause;
- recovery transfers;
- pre-activation allocation corrections;
- relevant eligibility-policy updates, if the policy is mutable;
- program metadata/disclosure URI updates, if allowed and bounded.

Economic terms that are immutable should be readable directly from contract state.

## 14. Non-goals for LicenseRevenueToken

The token contract does not implement:

- revenue deposits or custody;
- claim calculations or settlement transfers;
- offering subscriptions or fundraising;
- AMM liquidity;
- portfolio aggregation;
- holder governance;
- principal redemption;
- oracle conversion;
- arbitrary post-activation minting;
- automatic rights changes when the IP NFT transfers.

These boundaries keep the token focused on supply, balances, compliance, and distribution checkpoints.

## 15. Decisions required before Phase 3.1-A Solidity

Before implementing `LicenseRevenueToken.sol`, freeze:

1. factory/program-manager authority model;
2. exact `finalSupply`, name, symbol, and metadata format;
3. identity and offering-eligibility interface signatures;
4. pause and recovery role holders;
5. whether the eligibility policy address is immutable or governance-bounded;
6. exact one-time RevenueVault binding handshake;
7. checkpoint interface and reentrancy strategy;
8. self-transfer behavior;
9. pre-activation correction workflow;
10. migration behavior if the bound vault is permanently unusable.

No ERC-20 implementation should begin until these interfaces and authority boundaries are reviewed together with the RevenueVault accounting design.
