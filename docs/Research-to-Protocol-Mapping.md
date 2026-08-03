# Research-to-Protocol Mapping

## Purpose

IP Breaker RWA is not presented as a generic NFT project with an RWA label added afterward. Its architecture was shaped by comparative research into several families of IP-RWA and tokenized-rights projects:

- patent registries and IP transaction infrastructure;
- research-funding and IP-NFT structures;
- programmable-IP licensing protocols;
- music royalty and receivables platforms;
- regulated tokenized securities and funds;
- projects that contracted, changed product direction, or shut down after technical or operational failures.

The accompanying research paper is preserved on Zenodo:

- [Research paper record](https://zenodo.org/records/21335130)
- DOI-form link: [10.5281/zenodo.21335130](https://doi.org/10.5281/zenodo.21335130)

The central research conclusion is:

> IP-RWA is not merely an NFT issuance problem. It requires the joint design of legal rights, cash-flow boundaries, compliance, custody, recovery, investor protection, and operational continuity.

This document shows how that conclusion was translated into protocol mechanisms. It also identifies where the current repository remains a research prototype rather than a complete legal or financial product.

---

## 1. An IP Asset NFT must not be confused with legal IP ownership

### Research finding

Patent registries and programmable-IP protocols show that blockchain can improve asset indexing, provenance, licensing workflows, and transaction records. They do not make an ERC-721 token equivalent to legal ownership of a patent, copyright, dataset, or other off-chain right.

### Protocol translation

| Layer | Implementation |
| --- | --- |
| Asset identity | [`IPAssetRegistry.sol`](../contracts/IPAssetRegistry.sol) creates an on-chain asset passport and evidence container. |
| Evidence | [`EvidenceRegistry.sol`](../contracts/EvidenceRegistry.sol) binds hashes, URIs, submitters, timestamps, and review states to the asset. |
| Licence relationship | [`LicenseEscrow.sol`](../contracts/LicenseEscrow.sol) represents specific licence offers and agreements rather than transferring the underlying IP. |
| Revenue participation | [`LicenseRevenueToken.sol`](../contracts/LicenseRevenueToken.sol) represents a separate economic instrument tied to one Revenue Program. |

### Design record

- [Phase 2.3 Architecture Freeze](./Phase2.3-Architecture-Freeze.md)
- [Phase 3 Revenue Model Design](./Phase3-Revenue-Model-Design.md)

### Remaining off-chain boundary

The protocol does not independently establish legal title, patent validity, assignment formalities, territorial scope, encumbrances, litigation status, or regulatory classification.

---

## 2. Legal terms must exist outside the Token standard

### Research finding

IP-NFT and regulated royalty products rely on contracts, assignment instruments, offering disclosures, and responsible legal entities. A token standard cannot define or enforce the complete off-chain legal relationship by itself.

### Protocol translation

The repository uses cryptographic references to legal and disclosure documents:

```text
termsHash + termsURI
        ↓
immutable on-chain reference
        ↓
off-chain agreement or disclosure package
```

Relevant surfaces include:

- licence offer and agreement terms in [`LicenseEscrow.sol`](../contracts/LicenseEscrow.sol);
- Offering terms and disclosure commitments in [`OfferingManager.sol`](../contracts/OfferingManager.sol);
- immutable dependency and economic configuration snapshots in the Offering record.

### Design record

- [LicenseEscrow State Machine](./Phase2.3-LicenseEscrow-State-Machine.md)
- [Offering Architecture Design](./Phase3.2-Offering-Architecture-Design.md)
- [OfferingManager Implementation Design](./Phase3.2-OfferingManager-Implementation-Design.md)

### Remaining off-chain boundary

The repository does not yet ship a jurisdiction-specific legal document package, SPV agreement, receivables assignment, subscription agreement, investor disclosure, or backup servicing agreement.

---

## 3. A funded revenue claim is different from expected revenue

### Research finding

The strongest royalty products are based on acquired rights, existing catalogues, or identifiable receivables. A projected licence opportunity or database entry is not the same as funded cash available for distribution.

### Protocol translation

The Revenue Token only participates in settlement assets actually deposited and accounted for by [`RevenueVault.sol`](../contracts/RevenueVault.sol).

```text
expected invoice / event / analytics counter
                    ≠
funded Token-holder claim

settlement asset transferred into RevenueVault
                    +
accounted by accumulator
                    =
claimable funded revenue
```

The Vault uses:

- authorized revenue depositor boundaries;
- actual balance-delta checks;
- cumulative reward-per-share accounting;
- `pendingReward` and `rewardDebt`;
- precision-remainder carry;
- pull claims and solvency checks.

### Design record

- [Phase 3 Revenue Model Design](./Phase3-Revenue-Model-Design.md)
- [RevenueVault Design](./Phase3.1-RevenueVault-Design.md)

### Remaining off-chain boundary

The Vault proves correct distribution of deposited funds. It does not prove that every off-chain licence payment was reported or deposited. Production use needs contractual reporting duties, audited statements, payment integration, or a trusted revenue attestation system.

---

## 4. Primary capital and operating revenue must remain separate

### Research finding

A tokenized product becomes misleading if subscription proceeds are presented as asset-generated yield. Primary capital and later operating revenue are economically different cash flows.

### Protocol translation

The protocol uses separate custody and accounting paths:

```text
Primary offering capital:
Investor → OfferingEscrow → issuer / protocol-fee entitlements

Future operating revenue:
Revenue depositor → RevenueVault → eligible Token holders
```

- [`OfferingEscrow.sol`](../contracts/OfferingEscrow.sol) holds USDC contributions, enables refunds after failure, and freezes issuer and fee entitlements after success.
- [`RevenueVault.sol`](../contracts/RevenueVault.sol) accepts post-activation operating revenue only.
- [`OfferingManager.sol`](../contracts/OfferingManager.sol) orchestrates lifecycle state but does not custody either economic pool.

### Design record

- [OfferingEscrow Design](./Phase3.2-OfferingEscrow-Design.md)
- [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)

---

## 5. Custody should be separated by asset type and failure path

### Research finding

RWA projects depend on clear custody, entitlement, refund, and continuity rules. A single manager that controls Token supply, investor cash, allocation records, and payouts becomes a large technical and governance trust surface.

### Protocol translation

IP Breaker RWA uses dual Escrows:

| Custody contract | Responsibility |
| --- | --- |
| [`AllocationEscrow.sol`](../contracts/AllocationEscrow.sol) | Full Revenue Token supply, immutable allocation records, direct delivery, and Legal-Hold delivery. |
| [`OfferingEscrow.sol`](../contracts/OfferingEscrow.sol) | USDC contributions, failed-offering refunds, issuer proceeds, and protocol fees. |

`OfferingManager` is an orchestrator and canonical state owner, not the protocol's asset wallet.

### Design record

- [AllocationEscrow Design](./Phase3.2-AllocationEscrow-Design.md)
- [OfferingEscrow Design](./Phase3.2-OfferingEscrow-Design.md)
- [Offering Architecture Design](./Phase3.2-Offering-Architecture-Design.md)

---

## 6. Identity and transfer restrictions are product boundaries, not UI preferences

### Research finding

Regulated and institutionally structured tokenized products identify an issuer, eligible participants, transfer constraints, record responsibility, and disclosure obligations. Calling a system decentralized does not remove those boundaries.

### Protocol translation

- [`IdentityRegistry.sol`](../contracts/IdentityRegistry.sol) separates business identities from governance permissions.
- Identity status includes verification, suspension, revocation, and expiry.
- Issuer and investor eligibility are separate dependencies.
- [`LicenseRevenueToken.sol`](../contracts/LicenseRevenueToken.sol) restricts ordinary transfers to eligible participants.
- Eligibility is rechecked at protected lifecycle actions rather than assumed permanently valid.

### Design record

- [IdentityRegistry Design](./Phase2-IdentityRegistry-Design.md)
- [Identity Integration Architecture](./Phase2.3-Identity-Integration-Architecture.md)
- [Permission Matrix](./Phase2.3-Permission-Matrix.md)

### Remaining off-chain boundary

The included demo eligibility contracts are not a substitute for jurisdiction-specific KYC, sanctions screening, accreditation, concentration limits, suitability, or regulated transfer-agent functions.

---

## 7. Compliance failure should not destroy economic rights or block everyone else

### Research finding

A real asset product must handle a participant becoming temporarily ineligible after allocation. Forced delivery breaches compliance; confiscation destroys economic rights; blocking the whole issuance creates a liveness failure.

### Protocol translation

Each remediation subscription receives an isolated deterministic Legal-Hold position:

```text
immutable subscription allocation
        ↓
per-subscription Legal-Hold position
        ↓
original beneficial owner preserved
        ↓
release only after current eligibility is restored
```

Relevant contracts:

- [`LegalHoldEscrow.sol`](../contracts/LegalHoldEscrow.sol)
- [`AllocationEscrow.sol`](../contracts/AllocationEscrow.sol)
- [`OfferingManager.sol`](../contracts/OfferingManager.sol)
- [`LicenseRevenueToken.sol`](../contracts/LicenseRevenueToken.sol)

The position keeps its own Token balance and RevenueVault accounting, allowing the Offering to finalize without replacing the beneficiary.

### Design record

- [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)
- [Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)

---

## 8. Wallet recovery must migrate the economic position, not only Token balance

### Research finding

A restricted RWA token cannot rely solely on ordinary ERC-20 transfer behavior when a verified holder loses control of a wallet. Recovery must preserve consent, identity continuity, role separation, historical revenue, and replay safety.

### Protocol translation

[`RecoveryManager.sol`](../contracts/RecoveryManager.sol) uses:

- EIP-712 destination consent;
- per-source nonces;
- requester, verifier, approver, guardian, and executor separation;
- challenge and execution windows;
- immutable recovery parameters.

[`LicenseRevenueToken.sol`](../contracts/LicenseRevenueToken.sol) and [`RevenueVault.sol`](../contracts/RevenueVault.sol) migrate the full Token balance and accrued revenue state atomically.

### Design record

- [RecoveryManager Design](./Phase3.1-RecoveryManager-Design.md)
- [Revenue Recovery Design](./Phase3.1-RevenueRecovery-Design.md)

---

## 9. A broader recovery role must not override a narrower custody rule

### Research finding

Composing individually reasonable modules can create new authority. A general wallet-recovery mechanism must not become a substitute for Legal-Hold release or other custody-specific processes.

### Protocol translation

The security review found that generic recovery could otherwise target an active Legal-Hold position. The final Token migration authority now checks the authoritative Legal-Hold registry before moving Token or Vault state.

```text
generic wallet recovery
        ≠
Legal-Hold disposition authority
```

### Design record and tests

- [Phase 3.3 Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)
- [`LegalHoldEscrow.t.sol`](../test/LegalHoldEscrow.t.sol)

The regression suite covers normal-holder recovery, active-position rejection, state preservation, historical revenue, and fuzzed amounts.

---

## 10. Lifecycle progress must not depend on externally controllable ambient balances

### Research finding

Operational and technical failures can destroy otherwise plausible RWA products. Protocol liveness must depend on authoritative accounting, not balances an external party can manipulate.

### Protocol translation

The security review found that checking the absolute USDC balance of `OfferingManager` allowed any holder to transfer one base unit of settlement token and block every later finalization.

The repaired invariant is:

```text
Offering-specific authoritative accounting
        controls lifecycle progress

ambient ERC-20 wallet balance
        does not control lifecycle progress
```

### Design record and tests

- [Phase 3.3 Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)
- [`OfferingManager.t.sol`](../test/OfferingManager.t.sol)

No generic administrator rescue function was added as a prerequisite for finalization.

---

## 11. Finalization must be an atomic economic boundary

### Research finding

An issuance is not complete merely because an ERC-20 exists. Allocation, custody, programme activation, funded-capital entitlements, and future revenue accounting must enter a mutually consistent state.

### Protocol translation

Finalization atomically verifies and activates:

```text
all subscriptions have terminal delivery dispositions
        ↓
AllocationEscrow Token balance is zero
        ↓
Revenue Token activates
        ↓
Revenue Program activates
        ↓
RevenueVault deposits become enabled
        ↓
OfferingEscrow freezes pull entitlements
        ↓
Offering is written Finalized last
```

If any dependency or postcondition fails, the whole transaction reverts.

### Design record

- [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)
- [`OfferingFinalizationModule.sol`](../contracts/modules/OfferingFinalizationModule.sol)
- [`OfferingManager.sol`](../contracts/OfferingManager.sol)

---

## 12. Passing tests is not enough if the contract cannot be deployed

### Research finding

RWA infrastructure also has operational constraints. A logically correct contract that exceeds EVM deployment limits is not a usable protocol.

### Protocol translation

The Phase 3.3 review measured `OfferingManager` above the EIP-170 runtime limit. The contract was decomposed without a proxy or `delegatecall`:

- canonical storage and asset-moving calls remain in `OfferingManager`;
- configuration validation moved to [`OfferingValidationModule.sol`](../contracts/modules/OfferingValidationModule.sol);
- finalization preconditions and postconditions moved to [`OfferingFinalizationModule.sol`](../contracts/modules/OfferingFinalizationModule.sol);
- both modules are immutable and stateless.

Verified runtime after modularization:

```text
OfferingManager runtime: 21,958 bytes
EIP-170 limit:           24,576 bytes
Remaining margin:         2,618 bytes
```

### Design record

- [Phase 3.3 Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)

---

## 13. Research conclusions intentionally not claimed as solved

The research also highlights areas that are not fully solved by the current repository:

| Open requirement | Current status |
| --- | --- |
| Patent validity, ownership, maintenance, encumbrances, and territorial scope | Represented through asset and evidence records, but not independently verified by the blockchain. |
| Legal wrapper and issuer/SPV obligations | Hash and URI hooks exist; production legal templates and responsible entities remain external. |
| Complete reporting of off-chain licence revenue | Vault distribution is verifiable after deposit; revenue completeness remains an attestation and audit boundary. |
| Valuation and structured-product pricing | Outside the current contract implementation. |
| Jurisdiction-specific offering compliance | Demo eligibility boundaries exist; regulatory classification and licences require professional review. |
| Secondary-market liquidity | Not promised or implemented as a guaranteed exit. |
| Platform shutdown and backup servicing | Not yet implemented as an independent servicing arrangement. |
| External security audit | Automated testing is extensive, but no independent audit is claimed. |

---

## Conclusion

The project's differentiator is not that it can mint an IP-related Token. It is that comparative research was translated into explicit protocol boundaries:

```text
IP identity is separated from legal ownership
Token rights are separated from licences and governance
primary capital is separated from operating revenue
allocation custody is separated from cash custody
normal recovery is separated from Legal-Hold release
funded revenue is separated from expected revenue
protocol accounting is separated from ambient balances
research claims are separated from unresolved trust assumptions
```

That traceability—from research finding, to design record, to contract, to regression test—is the intended evidence that IP Breaker RWA is a research-backed protocol prototype rather than a tokenization mock-up.