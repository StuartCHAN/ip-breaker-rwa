# IP Breaker RWA

## Compliance-aware IP Revenue Tokenization Infrastructure

[![Research DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.21335130.svg)](https://zenodo.org/records/21335130?preview_file=patent_rwa_arxiv_v02.pdf)

Transforming verified intellectual-property assets into programmable, transparent, and compliance-aware revenue participation instruments.

> **Protocol status:** research prototype with a complete Solidity protocol core, full deployment simulation, and automated security regression. It is not an audited production financial product or a substitute for legal, regulatory, valuation, or patent-validity review.

---

## Overview

IP Breaker RWA is an on-chain protocol for structuring the lifecycle of an IP-linked revenue programme:

```text
Verified IP Asset
        ↓
Revenue Program
        ↓
Revenue Token
        ↓
Primary Offering
        ↓
Investor Allocation
        ↓
Revenue Distribution
        ↓
Recovery / Legal-Hold Compliance
```

The protocol combines:

- IP asset and evidence records;
- identity and eligibility boundaries;
- fixed-supply Revenue Tokens;
- USDC-based primary offerings;
- separate Token and cash Escrows;
- immutable investor allocations;
- funded-revenue accounting;
- wallet recovery and Legal-Hold custody;
- atomic cross-contract finalization.

Unlike a simple NFT or ERC-20 tokenization demo, the project focuses on the legal, economic, custody, accounting, and failure-state boundaries required by an IP-linked RWA lifecycle.

---

# Research-backed Protocol

IP Breaker RWA is supported by a public research paper preserved on Zenodo. The research compares patent registries, IP-NFT structures, programmable-IP protocols, royalty and receivables platforms, regulated tokenized products, and projects that contracted or failed after technical or operational problems.

## Key research conclusion

> IP-RWA is not merely an NFT issuance problem. It requires the joint design of legal rights, cash-flow boundaries, compliance, custody, recovery, investor protection, and operational continuity.

The engineering translation is visible throughout the repository:

| Research concern | Protocol response |
| --- | --- |
| An NFT is not automatically legal IP ownership | IP Asset Passport, Evidence Registry, and separate licence and revenue instruments |
| Expected revenue is not a funded claim | Revenue rights arise only from settlement assets actually deposited and accounted for in `RevenueVault` |
| Primary capital must not be presented as operating yield | `OfferingEscrow` and `RevenueVault` use separate cash-flow paths |
| Issuer, investor, and owner identities are different boundaries | `IdentityRegistry`, issuer eligibility, and investor eligibility remain distinct |
| One participant's compliance failure must not block everyone | Per-subscription deterministic Legal-Hold positions |
| Wallet recovery must preserve the complete economic position | Token balance and accrued Vault state migrate atomically |
| Broad recovery authority must not override narrow custody rules | Active Legal-Hold positions are excluded from generic recovery |
| Protocol liveness must not depend on attacker-controlled balances | Settlement-token dust is excluded from authoritative finalization accounting |
| A tested contract must still be deployable | Stateless immutable modules reduce `OfferingManager` below EIP-170 |

### Explore the evidence

- **[Read the research paper](https://zenodo.org/records/21335130?preview_file=patent_rwa_arxiv_v02.pdf)**
- **[Explore the full documentation index](docs/Documentation-Index.md)**
- **[See the research-to-protocol mapping](docs/Research-to-Protocol-Mapping.md)**
- **[Review the security hardening journey](docs/Phase3.3-Security-Hardening-Plan.md)**

---

# The Problem

Traditional IP commercialization and simplistic tokenization approaches leave several unresolved questions:

1. **What off-chain right does the Token actually represent?**
2. **Who is authorized to create an offering or receive a restricted asset?**
3. **Where are investor funds held before the offering succeeds or fails?**
4. **How are allocations frozen and delivered without administrator substitution?**
5. **What happens if an investor becomes temporarily ineligible?**
6. **How are historical revenue rights preserved after transfer or wallet recovery?**
7. **How can multiple contracts activate without leaving a partial economic state?**
8. **Which facts remain dependent on legal documents, audits, and off-chain attestations?**

IP Breaker RWA treats these questions as first-class protocol-design requirements.

---

# Core Architecture

```text
                      IPAssetRegistry
                             │
                             ▼
                 RevenueProgramRegistry
                             │
                             ▼
                      OfferingManager
                    /        │         \
                   /         │          \
       AllocationEscrow   RevenueToken   OfferingEscrow
              │               │                 │
              │               ▼                 │
              │          RevenueVault           │
              │                                 │
       LegalHoldEscrow                      USDC custody

                RecoveryManager ───────► RevenueToken
                                      + RevenueVault state
```

## Separation of responsibilities

### `OfferingManager`

Owns canonical Offering and Subscription state, deterministic IDs, sequencing, reconciliation, delivery orchestration, and finalization. It does not intentionally custody Revenue Tokens or offering USDC.

### `AllocationEscrow`

Holds the complete initial Revenue Token supply, freezes immutable allocations, performs direct delivery, and moves remediation allocations into isolated Legal-Hold positions.

### `OfferingEscrow`

Holds investor USDC, enables full refunds after a failed offering, and freezes independent pull-payment entitlements for the issuer and protocol fee after success.

### `RevenueVault`

Accounts only for settlement assets actually deposited as operating revenue. It uses cumulative revenue-per-share accounting, pending rewards, reward debt, precision remainder, and solvency checks.

### `LegalHoldEscrow`

Creates one deterministic custody position per remediation subscription while preserving the original beneficial owner, amount, sequence, and historical revenue relationship.

### `RecoveryManager`

Uses EIP-712 destination consent, nonces, independent verification and approval roles, a challenge period, and a bounded execution window to restore access to an existing economic position.

---

# Key Design Invariants

## Rights separation

```text
IP Asset NFT
    ≠ legal ownership transfer by itself
    ≠ licence right
    ≠ Revenue Token
    ≠ governance right
```

## Supply conservation

```text
Final Supply
    = Directly Delivered
    + Legal-Hold Custody
```

At finalization, `AllocationEscrow` must hold zero Revenue Tokens.

## Offering-fund conservation

```text
Total Contributions
    = Issuer Proceeds
    + Protocol Fee
```

## Funded-revenue boundary

```text
Expected licence revenue
    ≠ Token-holder claim

Settlement asset deposited into RevenueVault
    + accounted by the Vault
    = funded claimable revenue
```

## Historical-revenue preservation

Every Token mint, transfer, recovery, or Legal-Hold release checkpoints Vault accounting before balances change. A new holder cannot claim revenue accrued by the previous holder.

## Atomic finalization

```text
All subscriptions receive terminal delivery dispositions
        ↓
Revenue Token activates
        ↓
Revenue Program activates
        ↓
RevenueVault deposits become enabled
        ↓
OfferingEscrow freezes proceeds entitlements
        ↓
postconditions pass
        ↓
Offering is written Finalized last
```

Any failed dependency or postcondition reverts the complete transaction.

---

# Differentiating Features

## Dual Escrow architecture

Token custody and USDC custody are isolated from one another. The Manager coordinates the lifecycle but does not become a combined asset wallet.

## Immutable allocation model

Each subscription freezes the payer, destination, Token amount, USDC amount, sequence, and payment reference. The delivery path cannot replace the investor destination or change the allocation.

## Legal-Hold custody without confiscation

A temporary eligibility failure delays beneficial delivery without destroying the economic position or blocking finalization for every other participant.

## Recovery-aware revenue accounting

Wallet recovery migrates the complete Token balance and historical RevenueVault state. It does not mint new supply, change the original allocation, or redirect a Legal-Hold position.

## Permissionless objective progress

Where no discretionary parameter can change, objective lifecycle steps such as reconciliation, delivery, and finalization can be executed without relying on an issuer or administrator remaining online.

---

# Security Hardening Journey

The repository records three confirmed engineering issues and their remediation:

| Finding | Risk | Resolution |
| --- | --- | --- |
| Settlement-token dust finalization DoS | Any ERC-20 holder could transfer one base unit to `OfferingManager` and block an incorrect zero-balance gate | Finalization now relies on Offering-specific authoritative Escrow accounting, not ambient wallet balances |
| Generic Recovery crossing Legal-Hold custody | A broad wallet-recovery path could bypass the original-beneficiary-bound release process | `LicenseRevenueToken` rejects active Legal-Hold positions as generic recovery sources |
| `OfferingManager` exceeded EIP-170 | All tests passed, but the approximately 30 KB runtime could not be deployed on a standard EVM network | Validation and finalization checks moved into immutable stateless modules; canonical storage and asset movement remain in the Manager |

Current size result:

```text
OfferingManager runtime: 21,958 bytes
EIP-170 limit:           24,576 bytes
Remaining margin:         2,618 bytes
```

Detailed threat model: **[Phase 3.3 Security Hardening Plan](docs/Phase3.3-Security-Hardening-Plan.md)**

---

# Executable Evidence

## Verified baseline

```text
Full protocol deployment simulation: PASS
Foundry tests:                        406 passed, 0 failed
OfferingManager targeted tests:       80 passed
RevenueVault tests:                   18 passed
LegalHoldEscrow tests:                 6 passed
Legal-Hold fuzz:                     256 runs
Invariant suites:                    PASS
```

The full deployment script creates the protocol bundle, precomputes the deterministic `offeringId`, deploys the Offering-specific Token, Vault and Escrows, creates a Draft Offering, and verifies post-deployment bindings and non-custodial invariants.

```bash
forge script script/DeployFullProtocol.s.sol:DeployFullProtocol -vvv
```

Sepolia broadcast:

```bash
forge script script/DeployFullProtocol.s.sol:DeployFullProtocol \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  -vvvv
```

The testnet deployment uses demo eligibility modules and a mock six-decimal USDC. They are not production KYC, sanctions, transfer-agent, or settlement infrastructure.

---

# Featured Design Records

For a five-minute review, start with these six resources:

1. **[Research paper](https://zenodo.org/records/21335130?preview_file=patent_rwa_arxiv_v02.pdf)** — comparative IP-RWA research and product lessons.
2. **[Phase 2.3 Architecture Freeze](docs/Phase2.3-Architecture-Freeze.md)** — IP, identity, evidence, and licensing boundary before tokenization.
3. **[Phase 3 Revenue Model Design](docs/Phase3-Revenue-Model-Design.md)** — what the Token represents and explicitly does not represent.
4. **[Phase 3.2 Atomic Finalization Design](docs/Phase3.2-Atomic-Finalization-Design.md)** — cross-contract activation, custody completion, and cash-flow isolation.
5. **[Phase 3.3 Security Hardening Plan](docs/Phase3.3-Security-Hardening-Plan.md)** — real findings, threat models, and acceptance tests.
6. **[`DeployFullProtocol.s.sol`](script/DeployFullProtocol.s.sol)** — executable proof that the complete protocol bundle can be deployed and verified.

All design records: **[Documentation Index](docs/Documentation-Index.md)**

Research conclusions mapped to code: **[Research-to-Protocol Mapping](docs/Research-to-Protocol-Mapping.md)**

---

# Project Structure

```text
ip-breaker-rwa/
├── contracts/
│   ├── IdentityRegistry.sol
│   ├── IPAssetRegistry.sol
│   ├── EvidenceRegistry.sol
│   ├── LicenseEscrow.sol
│   ├── RevenueProgramRegistry.sol
│   ├── LicenseRevenueToken.sol
│   ├── RevenueVault.sol
│   ├── OfferingManager.sol
│   ├── AllocationEscrow.sol
│   ├── LegalHoldEscrow.sol
│   ├── OfferingEscrow.sol
│   ├── RecoveryManager.sol
│   └── modules/
│       ├── OfferingValidationModule.sol
│       └── OfferingFinalizationModule.sol
├── docs/
│   ├── Documentation-Index.md
│   ├── Research-to-Protocol-Mapping.md
│   ├── Phase2.3-Architecture-Freeze.md
│   ├── Phase3-Revenue-Model-Design.md
│   ├── Phase3.2-Atomic-Finalization-Design.md
│   └── Phase3.3-Security-Hardening-Plan.md
├── script/
│   ├── Deploy.s.sol
│   ├── Demo.s.sol
│   └── DeployFullProtocol.s.sol
├── test/
└── frontend/
```

---

# Technology Stack

- Solidity 0.8.24
- Foundry
- OpenZeppelin Contracts
- ERC-20 and ERC-721 standards
- EIP-712 and signature verification
- role-based access control
- restricted transfer policies
- escrow-based settlement
- cumulative revenue-per-share accounting
- state-machine, fuzz, invariant, and dependency-failure testing

---

# Trust Boundaries and Non-Claims

The current protocol can enforce configured on-chain identities, allocations, custody paths, funded-revenue accounting, and lifecycle transitions. It does not independently prove or guarantee:

- legal ownership, validity, maintenance, territorial scope, or freedom to operate of the underlying IP;
- completeness of off-chain licensing revenue;
- valuation, liquidity, commercial success, principal protection, or yield;
- compliance with securities, tax, sanctions, custody, or offering law in any jurisdiction;
- continuity of an issuer, SPV, revenue attestor, or external service provider;
- production security or legal readiness without independent review.

These limitations are documented because RWA credibility depends on making the remaining trust assumptions explicit.

---

# Why IP Breaker RWA?

Most tokenization projects answer:

> How do we create a Token?

IP Breaker RWA asks a broader question:

> How do we preserve legal and economic meaning across IP verification, primary issuance, custody, funded revenue, compliance failure, wallet recovery, and protocol finalization?

The repository provides a traceable chain from public research, to architecture decisions, to Solidity implementation, to security findings, to executable verification.

---

# License

Open-source project for Web3 research, protocol engineering, and Hackathon demonstration.
