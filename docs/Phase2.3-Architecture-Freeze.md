# Phase 2.3 Architecture Freeze

**Status:** Frozen baseline  
**Date:** 2026-07-21  
**Scope:** Identity-aware IP asset, evidence, and escrow architecture before Phase 3 tokenization

## Purpose

Phase 2 established a compliance-aware protocol foundation:

```text
IP proof
   ↓
Identity
   ↓
Permission
   ↓
License
   ↓
Revenue
   ↓
Future tokenization
```

This freeze records the implemented architecture before any revenue-share or tokenization module is designed. It is a baseline, not a claim that future requirements can never change. Any Phase 3 proposal that changes these rules must identify the change explicitly, provide a migration plan, and update the relevant tests and documentation.

## Frozen documents

1. [Identity Integration Architecture](./Phase2.3-Identity-Integration-Architecture.md)
2. [Permission Matrix](./Phase2.3-Permission-Matrix.md)
3. [LicenseEscrow State Machine](./Phase2.3-LicenseEscrow-State-Machine.md)

## Frozen design decisions

- Business identity roles are stored in `IdentityRegistry` as a bit mask.
- Governance permissions remain separate from business identity roles.
- Protocol modules depend on `IIdentityRegistry`, not the concrete registry implementation.
- Identity validity is checked at the time of a protected action.
- IP asset registration requires an active `ROLE_ASSET_OWNER` identity.
- Evidence submission requires both active `ROLE_ASSET_OWNER` identity and current NFT ownership.
- Evidence review requires an active `ROLE_VERIFIER` identity.
- Escrow agreement creation validates both licensor and licensee identities.
- Escrow funding revalidates the licensee identity.
- Performance confirmation revalidates the licensor identity.
- Dispute resolution requires both the snapshotted arbiter address and an active arbitrator identity.
- `release()` and `raiseDispute()` do not currently add identity checks.
- Existing ERC-721 transfer behavior remains unrestricted by IdentityRegistry.
- The direct offer/license-certificate path remains outside the Phase 2 escrow identity gates.
- No revenue-share token or financial claim is created in Phase 2.

## Phase 3 entry constraints

Before implementing tokenization, Phase 3 design must separately define:

- what legal/economic right a token represents;
- the revenue source and accounting boundary;
- eligibility and transfer restrictions for token holders;
- whether compliance is checked at mint, transfer, claim, or all three;
- how identity expiration, suspension, and revocation affect existing holdings;
- whether token rights follow IP NFT ownership, license agreements, or a separate offering instrument;
- upgrade and migration behavior for the frozen Phase 2 contracts.

Phase 3 must not infer these answers from the existing IP Asset NFT or License Certificate NFT.
