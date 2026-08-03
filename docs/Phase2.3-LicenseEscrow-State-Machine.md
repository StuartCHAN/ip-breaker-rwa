# Phase 2.3 LicenseEscrow State Machine After Identity Integration

**Status:** Frozen baseline  
**Date:** 2026-07-21  
**Scope:** Escrow-based `LicenseAgreement`; the direct offer/License Certificate path is separate

## 1. Agreement state graph

```text
                          cancelAgreement()
                     ┌────────────────────────▶ Cancelled
                     │
                     │
                  Created
                     │
                     │ fundLicense()
                     ▼
                   Funded ───────────────┐
                     │                   │
                     │ confirmPerformance│ raiseDispute()
                     ▼                   │
                   Active ───────────────┤
                     │                   │
                     │ release()         ▼
                     ▼                Disputed
                 Completed              │   │
                                  true  │   │ false
                         resolveDispute  │   │ resolveDispute
                                        ▼   ▼
                                  Completed Refunded
```

Terminal states are `Completed`, `Refunded`, and `Cancelled`. No outgoing transition is valid from a terminal state.

## 2. Transition table with identity gates

| From | To | Function | Party authorization | Identity requirement | Funds |
|---|---|---|---|---|---|
| — | Created | `createLicenseAgreement` | Licensor is current asset owner; licensee is valid and different | Licensor active `ROLE_ASSET_OWNER`; licensee active `ROLE_LICENSEE` | None received. |
| Created | Funded | `fundLicense` | Caller is assigned licensee; exact fee; licensor still owns asset | Caller active `ROLE_LICENSEE` | Fee enters escrow; `escrowedAmount = licenseFee`. |
| Funded | Active | `confirmPerformance` | Caller is agreement licensor | Caller active `ROLE_ASSET_OWNER` | Escrow unchanged. |
| Funded | Disputed | `raiseDispute` | Caller is licensor or licensee | — | Escrow remains frozen. |
| Active | Disputed | `raiseDispute` | Caller is licensor or licensee | — | Escrow remains frozen. |
| Active | Completed | `release` | Caller is agreement licensee | — | Escrow cleared; licensor paid; asset revenue increases. |
| Disputed | Completed | `resolveDispute(true)` | Caller is snapshotted agreement arbiter | Caller active `ROLE_ARBITRATOR` | Escrow cleared; licensor paid; asset revenue increases. |
| Disputed | Refunded | `resolveDispute(false)` | Caller is snapshotted agreement arbiter | Caller active `ROLE_ARBITRATOR` | Escrow cleared; licensee refunded; revenue unchanged. |
| Created | Cancelled | `cancelAgreement` | Caller is agreement licensor | — | No escrow exists. |

## 3. Creation preconditions

`createLicenseAgreement` validates:

1. asset exists;
2. caller currently owns the IP Asset NFT;
3. licensee is nonzero and not the licensor;
4. licensor has a current valid Asset Owner identity;
5. licensee has a current valid Licensee identity;
6. fee and terms inputs are valid.

The agreement stores the licensor, licensee, fee, terms hash, creation timestamp, and a snapshot of the current global arbiter.

## 4. Action-time identity revalidation

Identity eligibility is not permanently snapshotted at agreement creation.

```text
Create:   check licensor + licensee
Fund:     recheck licensee
Confirm:  recheck licensor
Resolve:  check assigned arbiter + current arbitrator identity
```

Suspension, revocation, or expiration after creation can therefore block the next protected action. It does not mutate the agreement automatically.

## 5. Arbiter snapshot rule

```text
global arbiter = A
        ↓ create agreement #1
agreement #1 arbiter = A
        ↓ setArbiter(B)
global arbiter = B
agreement #1 arbiter remains A
        ↓ create agreement #2
agreement #2 arbiter = B
```

For agreement #1, only A can pass the address authorization. A must additionally hold a valid `ROLE_ARBITRATOR` when resolving. B cannot resolve agreement #1 merely because B is the new global arbiter.

## 6. Escrow accounting by state

| Status | Expected `escrowedAmount` |
|---|---:|
| Created | 0 |
| Funded | `licenseFee` |
| Active | `licenseFee` |
| Disputed | `licenseFee` |
| Completed | 0 |
| Refunded | 0 |
| Cancelled | 0 |

The contract balance must cover the sum of all open agreement escrow amounts. Existing invariant tests exercise this property across randomized transition sequences.

## 7. Settlement and CEI

Both `release` and `resolveDispute` retain `nonReentrant` protection.

The resolution path preserves checks-effects-interactions:

```text
Checks
  - agreement exists
  - caller is snapshotted arbiter
  - active ROLE_ARBITRATOR
  - current state is Disputed

Effects
  - transition to Completed or Refunded
  - copy escrow amount
  - clear escrowedAmount
  - update asset revenue only for licensor payout

Interaction
  - transfer ETH to selected recipient
```

If the transfer fails, the EVM reverts the entire transaction, including the status change, escrow clearing, and revenue update.

## 8. Identity failure semantics

If a protected action fails its identity check:

- no state transition occurs;
- `escrowedAmount` is unchanged;
- contract and participant balances are unchanged;
- `totalRevenueByAsset` is unchanged;
- the agreement record remains unchanged; whether a later valid action is possible depends on the identity lifecycle and the immutable participant/arbiter assignments.

The protocol does not automatically refund or cancel an agreement solely because an identity becomes invalid. In particular, a permanently revoked snapshotted arbiter can create a liveness problem because changing the global arbiter does not alter that agreement. Timeout, emergency exit, arbiter replacement, governance intervention, and sanctions-handling procedures require separate design.

## 9. Deliberate exclusions from the frozen state machine

- `release()` has no IdentityRegistry role check.
- `raiseDispute()` has no IdentityRegistry role check.
- `cancelAgreement()` has no IdentityRegistry role check.
- no automatic deadlines or timeout transitions exist.
- no License Certificate NFT is minted from an escrow agreement.
- no revenue-share token is minted by any transition.
- no token holder acquires rights to escrow revenue in Phase 2.

These exclusions must not be silently changed as part of Phase 3 token implementation.
