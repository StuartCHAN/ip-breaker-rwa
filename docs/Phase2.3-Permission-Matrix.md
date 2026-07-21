# Phase 2.3 Permission Matrix

**Status:** Frozen baseline  
**Date:** 2026-07-21

## Reading the matrix

- **Identity gate** means `IIdentityRegistry.hasBusinessRole` must return true at call time.
- **Domain authorization** means ownership, assigned-party, governance, or state checks enforced by the target contract.
- A dash means there is no IdentityRegistry role requirement for that function in the frozen Phase 2 architecture.

## IdentityRegistry

| Function | Caller/domain authorization | Business identity role | Notes |
|---|---|---|---|
| `registerIdentity` | Self-service; only None or Rejected may register | — | Moves identity to Pending. |
| `verifyIdentity` | `VERIFIER_MANAGER_ROLE` | — | Grants business role mask and expiration. |
| `rejectIdentity` | `VERIFIER_MANAGER_ROLE` | — | Pending → Rejected. |
| `suspendIdentity` | `VERIFIER_MANAGER_ROLE` | — | Verified → Suspended. |
| `restoreIdentity` | `VERIFIER_MANAGER_ROLE` | — | Suspended → Verified. Expiration still applies. |
| `revokeIdentity` | `DEFAULT_ADMIN_ROLE` | — | Verified/Suspended → Revoked; terminal. |
| `grantVerifierRole` / `revokeVerifierRole` | `DEFAULT_ADMIN_ROLE` | — | Governance permission, not `ROLE_VERIFIER`. |
| Queries | Public | — | No state changes. |

## IPAssetRegistry

| Function | Caller/domain authorization | Identity gate | Frozen behavior |
|---|---|---|---|
| `registerAsset` | Caller becomes NFT owner | Active `ROLE_ASSET_OWNER` | Checked before asset storage and mint. |
| ERC-721 transfers/approvals | Standard ERC-721 authorization | — | Identity restrictions intentionally not applied. |
| `ownerOf`, `exists`, `getAsset`, `tokenURI`, `nextAssetId` | Public read | — | No identity gate. |

## EvidenceRegistry

| Function | Caller/domain authorization | Identity gate | State transition/effect |
|---|---|---|---|
| `addEvidence` | Caller must currently own the referenced IP Asset NFT | Active `ROLE_ASSET_OWNER` | Creates `Submitted` evidence. |
| `verifyEvidence` | Evidence must be Submitted | Active `ROLE_VERIFIER` | Submitted → Verified. |
| `rejectEvidence` | Evidence must be Submitted | Active `ROLE_VERIFIER` | Submitted → Rejected. |
| `revokeEvidence` | Evidence must be Verified | Active `ROLE_VERIFIER` | Verified → Revoked. |
| `getEvidence`, `getEvidenceIds`, `nextEvidenceId` | Public read | — | No identity gate. |

There is no separate `reviewers[address]` allowlist. IdentityRegistry is the single source of reviewer business eligibility.

## LicenseEscrow: direct offer and License Certificate path

| Function | Caller/domain authorization | Identity gate | Frozen behavior |
|---|---|---|---|
| `createLicenseOffer` | Current IP Asset NFT owner | — | Existing direct-offer behavior preserved. |
| `setLicenseOfferActive` | Original offer licensor | — | Existing behavior preserved. |
| `buyLicense` | Buyer cannot be licensor; exact payment; offer active; licensor still owns asset | — | Existing behavior preserved. |
| License Certificate transfer | ERC-721 authorization plus certificate transferability flag | — | Existing behavior preserved. |

The absence of an identity gate here is a frozen Phase 2 boundary, not permission to infer Phase 3 token eligibility.

## LicenseEscrow: escrow agreement path

| Function | Caller/domain authorization | Identity gate | State/effect |
|---|---|---|---|
| `createLicenseAgreement` | Caller is current asset NFT owner; valid non-self licensee | Licensor: active `ROLE_ASSET_OWNER`; licensee: active `ROLE_LICENSEE` | Creates agreement in Created; snapshots arbiter. |
| `fundLicense` | Caller equals `agreement.licensee`; exact fee; licensor still owns asset | Caller: active `ROLE_LICENSEE` | Created → Funded; receives escrow. |
| `confirmPerformance` | Caller equals `agreement.licensor` | Caller: active `ROLE_ASSET_OWNER` | Funded → Active; escrow unchanged. |
| `release` | Caller equals `agreement.licensee` | — | Active → Completed; pays licensor. |
| `raiseDispute` | Caller is agreement licensor or licensee | — | Funded/Active → Disputed; escrow frozen. |
| `resolveDispute` | Caller equals snapshotted `agreement.arbiter` | Caller: active `ROLE_ARBITRATOR` | Disputed → Completed or Refunded; settles escrow. |
| `cancelAgreement` | Caller equals agreement licensor | — | Created → Cancelled. |
| `setArbiter` | Contract owner; nonzero address | — | Changes global arbiter for future agreements only. |
| Agreement queries | Public read | — | No identity gate. |

## Role-to-action summary

| Business role | Phase 2 protected actions |
|---|---|
| `ROLE_ASSET_OWNER` | Register IP asset; submit evidence for owned asset; create escrow agreement as licensor; confirm performance. |
| `ROLE_LICENSEE` | Be accepted as licensee during agreement creation; fund assigned agreement. |
| `ROLE_VERIFIER` | Verify, reject, and revoke evidence. |
| `ROLE_ARBITRATOR` | Resolve an assigned disputed agreement. |
| `ROLE_INVESTOR` | None in Phase 2. Reserved for a separately designed future phase. |

## Failure semantics

An identity failure reverts the transaction. It does not automatically:

- delete an asset, evidence record, or agreement;
- transfer an IP NFT;
- change an Evidence status;
- change a LicenseAgreement status;
- move escrowed funds;
- change recorded revenue.

This separation prevents identity lifecycle changes from silently rewriting historical protocol state.
