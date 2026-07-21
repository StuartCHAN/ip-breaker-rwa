# Phase 2.3 Identity Integration Architecture

**Status:** Frozen baseline  
**Date:** 2026-07-21

## 1. Architecture objective

Identity is a protocol service that answers whether an address may perform a business action now. It is not the source of IP ownership, agreement state, evidence content, or escrow balances.

```text
                         IdentityRegistry
                    roles + status + expiration
                                │
                    IIdentityRegistry interface
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
     IPAssetRegistry     EvidenceRegistry     LicenseEscrow
       asset creation      submit/review      create/fund/
                                               confirm/resolve
             │                  │                  │
             └────────── IIPAssetRegistry ────────┘
                    ownership + existence
```

## 2. Dependency and deployment order

```text
1. IdentityRegistry
2. IPAssetRegistry(identityRegistry)
3. EvidenceRegistry(ipAssetRegistry, identityRegistry)
4. LicenseEscrow(ipAssetRegistry, identityRegistry)
```

All downstream identity references are immutable constructor dependencies. Zero-address dependencies are rejected.

## 3. Interface boundary

Protocol modules consume the minimal `IIdentityRegistry` interface. The interface exposes role constants and `hasBusinessRole(account, roleMask)`.

The concrete implementation can later be replaced by another compatible identity provider only through a new deployment or an explicitly designed upgrade/migration mechanism. Current contracts do not contain mutable registry setters.

`hasBusinessRole` is the canonical business authorization query. It returns true only when:

```text
identity.status == Verified
AND (expiresAt == 0 OR block.timestamp < expiresAt)
AND all requested role bits are present
```

Consequently, Pending, Suspended, Rejected, Revoked, and expired identities fail protected actions without requiring changes in downstream contracts.

## 4. Business roles

| Role | Meaning in the frozen architecture |
|---|---|
| `ROLE_ASSET_OWNER` | May register IP assets, submit evidence for owned assets, create escrow agreements as licensor, and confirm performance as licensor. |
| `ROLE_LICENSEE` | May be selected as an escrow licensee and fund an agreement. |
| `ROLE_INVESTOR` | Reserved for later phases; it grants no Phase 2 protocol action. |
| `ROLE_VERIFIER` | May verify, reject, or revoke evidence records. |
| `ROLE_ARBITRATOR` | May resolve a dispute only when also assigned as that agreement's snapshotted arbiter. |

`DEFAULT_ADMIN_ROLE` and `VERIFIER_MANAGER_ROLE` are governance permissions inside IdentityRegistry. They are not business identity roles.

## 5. Authorization composition

Identity roles supplement rather than replace domain ownership and agreement membership.

### Asset creation

```text
active ROLE_ASSET_OWNER
        ↓
registerAsset()
        ↓
mint IP Asset NFT
```

### Evidence submission

```text
active ROLE_ASSET_OWNER
        AND
IPAssetRegistry.ownerOf(assetId) == msg.sender
        ↓
addEvidence()
```

### Agreement creation

```text
asset exists
AND ownerOf(assetId) == msg.sender
AND licensor has active ROLE_ASSET_OWNER
AND licensee has active ROLE_LICENSEE
        ↓
Created agreement
```

### Dispute resolution

```text
msg.sender == agreement.arbiter
AND msg.sender has active ROLE_ARBITRATOR
AND agreement.status == Disputed
        ↓
settlement
```

## 6. Dynamic checks and snapshots

Identity authorization is dynamic. A role valid during agreement creation does not remain implicitly valid forever:

- licensee is rechecked when funding;
- licensor is rechecked when confirming performance;
- arbiter is rechecked when resolving a dispute.

Failed identity checks occur before protected state changes and transfers. Existing agreements and evidence records remain stored; the invalid identity simply cannot perform the protected action.

The arbiter address follows a different rule: it is snapshotted into each agreement at creation. Changing the global arbiter does not replace the arbiter for an existing agreement. At resolution time, the snapshotted address must also possess a currently valid arbitrator identity.

```text
agreement creation             dispute resolution
        │                              │
snapshot global arbiter     compare msg.sender to snapshot
        │                              +
future global changes       check current ROLE_ARBITRATOR
do not affect agreement               │
                                      ▼
                                  may resolve
```

## 7. Evidence architecture

Evidence content and indexes remain in EvidenceRegistry. IdentityRegistry only controls who may submit or review.

```text
Submitted ── verifier approves ──▶ Verified ── verifier revokes ──▶ Revoked
    │
    └────── verifier rejects ────▶ Rejected
```

Review actions record `reviewedBy` and `reviewedAt`. Evidence hashes, URIs, attestation identifiers, submitter, timestamp, asset binding, and per-asset evidence indexes remain preserved.

## 8. Deliberate Phase 2 boundaries

The following behaviors are intentionally not generalized into universal KYC gates:

- IP Asset NFT transfers retain standard ERC-721 behavior.
- `LicenseEscrow.release()` checks the assigned licensee and state but not IdentityRegistry.
- `LicenseEscrow.raiseDispute()` checks agreement participation and state but not IdentityRegistry.
- cancellation remains a licensor/state authorization operation.
- the direct license offer and purchase path retains its pre-integration authorization behavior.
- read functions remain public.

These are explicit boundaries, not accidental omissions. Any later compliance expansion must be designed as a separate phase and must account for liveness and funds already in escrow.

## 9. Security properties preserved

- Identity checks precede protected state changes.
- Escrow functions retain their existing state-transition gates.
- Payment functions retain exact-value accounting.
- `fundLicense`, `release`, and `resolveDispute` retain `nonReentrant` protection.
- Settlement retains checks-effects-interactions ordering.
- Failed identity checks leave agreement state, escrow accounting, balances, and revenue totals unchanged.

## 10. Phase 3 architectural boundary

Identity roles establish participant eligibility; they do not define token economics. Phase 3 tokenization must introduce a separate model for economic rights, supply, distribution, claims, transfer compliance, and lifecycle events. It must not treat the IP Asset NFT, Evidence status, or Identity role bit mask as an implicit security or revenue-share instrument.
