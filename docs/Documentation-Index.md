# IP Breaker RWA Documentation Index

This index organizes the repository's design records as a traceable engineering narrative:

```text
Research and problem definition
        ↓
Identity and licensing foundation
        ↓
Revenue-rights modeling
        ↓
Offering and custody architecture
        ↓
Atomic finalization
        ↓
Security hardening
        ↓
Executable deployment and verification
```

The documents are not marketing summaries. They record design boundaries, rejected alternatives, state-machine decisions, economic invariants, security findings, and implementation constraints. Historical documents should be read in phase order because later phases may implement or refine decisions recorded earlier.

## Start here

| Resource | Purpose |
| --- | --- |
| [Research paper on Zenodo](https://zenodo.org/records/21335130) | Public research foundation covering IP-RWA analogues, royalty products, programmable-IP protocols, regulated tokenized products, and failed or contracted implementations. |
| [Research-to-Protocol Mapping](./Research-to-Protocol-Mapping.md) | Connects research conclusions to specific contracts, protocol mechanisms, and design records. |
| [Phase 2.3 Architecture Freeze](./Phase2.3-Architecture-Freeze.md) | Freezes the identity-aware IP asset, evidence, and licensing baseline before tokenization. |
| [Phase 3 Revenue Model Design](./Phase3-Revenue-Model-Design.md) | Defines what the Revenue Token represents, what it does not represent, and when a funded claim exists. |
| [Phase 3.2 Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md) | Defines the cross-contract boundary that activates the Token, Program, Vault, and proceeds entitlements. |
| [Phase 3.3 Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md) | Records the settlement-dust DoS, Recovery/Legal-Hold isolation, and EIP-170 deployment blocker. |
| [`DeployFullProtocol.s.sol`](../script/DeployFullProtocol.s.sol) | Deploys the complete testnet protocol bundle and verifies Draft-offering invariants. |

## 1. Security and licensing foundation

### Phase 1

- [Phase 1 Security Review](./Phase1-Security-Review.md)  
  Initial security review of the licensing and escrow foundation.

### Phase 2

- [IdentityRegistry Design](./Phase2-IdentityRegistry-Design.md)  
  Business identity roles, lifecycle states, expiry, role conflicts, and governance separation.

### Phase 2.3 architecture freeze

- [Architecture Freeze](./Phase2.3-Architecture-Freeze.md)  
  Frozen baseline before revenue tokenization.
- [Identity Integration Architecture](./Phase2.3-Identity-Integration-Architecture.md)  
  Identity checks across IP registration, evidence, licensing, funding, performance, and dispute resolution.
- [Permission Matrix](./Phase2.3-Permission-Matrix.md)  
  Business roles and contract permissions by protected action.
- [LicenseEscrow State Machine](./Phase2.3-LicenseEscrow-State-Machine.md)  
  Legal transitions and terminal-state restrictions for escrowed licence agreements.

## 2. Revenue-rights and token accounting

- [Phase 3 Revenue Model Design](./Phase3-Revenue-Model-Design.md)  
  Economic rights, funded-revenue boundary, settlement scope, transfer restrictions, and no-yield-guarantee rules.
- [Phase 3.1 Final Architecture Review](./Phase3.1-Final-Architecture-Review.md)  
  Architecture review before the primary-offering phase.
- [LicenseRevenueToken Design](./Phase3.1-LicenseRevenueToken-Design.md)  
  Fixed supply, lifecycle gates, compliance-restricted transfers, and Vault checkpoint integration.
- [RevenueVault Design](./Phase3.1-RevenueVault-Design.md)  
  Cumulative revenue-per-share accounting, reward debt, precision remainder, claims, and solvency.
- [Revenue Recovery Design](./Phase3.1-RevenueRecovery-Design.md)  
  Migration of Token balances together with accrued revenue state.
- [RecoveryManager Design](./Phase3.1-RecoveryManager-Design.md)  
  EIP-712 consent, role separation, challenge period, nonces, and execution windows.

## 3. Offering and custody architecture

- [Offering Architecture Design](./Phase3.2-Offering-Architecture-Design.md)  
  Overall primary-offering architecture and contract boundaries.
- [OfferingManager State Machine Design](./Phase3.2-OfferingManager-StateMachine-Design.md)  
  Draft, Open, Successful, Failed, and Finalized lifecycle rules.
- [OfferingManager Implementation Design](./Phase3.2-OfferingManager-Implementation-Design.md)  
  Canonical storage, subscription sequencing, reconciliation, delivery, and dependency validation.
- [AllocationEscrow Design](./Phase3.2-AllocationEscrow-Design.md)  
  Full-supply custody, immutable allocation records, direct delivery, remediation, and failure tombstones.
- [OfferingEscrow Design](./Phase3.2-OfferingEscrow-Design.md)  
  USDC contributions, refunds, issuer proceeds, protocol fees, and pull-payment claims.

## 4. Atomic finalization and Legal-Hold custody

- [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)  
  Completion equations, dependency postconditions, cash-flow separation, and all-or-nothing activation.

The implemented Legal-Hold design is also reflected directly in:

- [`LegalHoldEscrow.sol`](../contracts/LegalHoldEscrow.sol)
- [`AllocationEscrow.sol`](../contracts/AllocationEscrow.sol)
- [`LicenseRevenueToken.sol`](../contracts/LicenseRevenueToken.sol)
- [`OfferingManager.sol`](../contracts/OfferingManager.sol)

## 5. Security hardening

- [Phase 3.3 Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)  
  Threat model and remediation plan for three confirmed engineering risks:
  1. unsolicited settlement-token dust blocking finalization;
  2. generic Recovery crossing the Legal-Hold custody boundary;
  3. `OfferingManager` exceeding the EIP-170 runtime limit.

Implemented evidence:

- [`OfferingManager.t.sol`](../test/OfferingManager.t.sol) — finalization rollback, settlement-dust regression, dependency failures, and economic invariants.
- [`LegalHoldEscrow.t.sol`](../test/LegalHoldEscrow.t.sol) — custody isolation, historical revenue migration, and recovery rejection fuzzing.
- [`RevenueVault.Checkpoint.t.sol`](../test/RevenueVault.Checkpoint.t.sol) — transfer and recovery checkpoint behavior.
- [`LicenseEscrow.Invariant.t.sol`](../test/LicenseEscrow.Invariant.t.sol) — stateful escrow conservation invariants.

## 6. Deployment and executable verification

- [`DeployFullProtocol.s.sol`](../script/DeployFullProtocol.s.sol)  
  Deploys registries, eligibility policies, settlement token, Revenue Program components, RecoveryManager, OfferingManager, Token, Vault, and both Escrows. It precomputes `offeringId`, creates a Draft Offering, and verifies bindings and non-custodial invariants.
- [`Demo.s.sol`](../script/Demo.s.sol)  
  Earlier IP registration and licensing demonstration.
- [GitHub Actions workflow](../.github/workflows/test.yml)  
  Runs formatting, size-aware compilation, full deployment simulation, the Foundry suite, security tests, state-machine tests, and invariants.

Current verified baseline at the Phase 3 merge:

```text
Full protocol deployment simulation: PASS
Foundry tests: 406 passed, 0 failed
OfferingManager runtime: 21,958 bytes
EIP-170 runtime limit: 24,576 bytes
Legal-Hold fuzz: 256 runs
Invariant suites: PASS
```

These figures describe the repository's automated test baseline. They are not a substitute for an independent external audit, legal opinion, valuation report, or production readiness assessment.

## 7. Reading paths by audience

### Hackathon reviewer

1. [Research paper](https://zenodo.org/records/21335130)
2. [Research-to-Protocol Mapping](./Research-to-Protocol-Mapping.md)
3. [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)
4. [Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)
5. [`DeployFullProtocol.s.sol`](../script/DeployFullProtocol.s.sol)

### Solidity engineer

1. [OfferingManager Implementation Design](./Phase3.2-OfferingManager-Implementation-Design.md)
2. [LicenseRevenueToken Design](./Phase3.1-LicenseRevenueToken-Design.md)
3. [RevenueVault Design](./Phase3.1-RevenueVault-Design.md)
4. [Atomic Finalization Design](./Phase3.2-Atomic-Finalization-Design.md)
5. [Security Hardening Plan](./Phase3.3-Security-Hardening-Plan.md)

### RWA, finance, or legal reviewer

1. [Research paper](https://zenodo.org/records/21335130)
2. [Architecture Freeze](./Phase2.3-Architecture-Freeze.md)
3. [Revenue Model Design](./Phase3-Revenue-Model-Design.md)
4. [Permission Matrix](./Phase2.3-Permission-Matrix.md)
5. [Research-to-Protocol Mapping](./Research-to-Protocol-Mapping.md)

## Scope and trust boundaries

IP Breaker RWA is a research prototype. The on-chain system can enforce configured identities, custody rules, allocation conservation, funded-revenue accounting, and lifecycle transitions. It cannot independently establish:

- legal ownership or validity of an underlying patent or other IP right;
- completeness of off-chain licensing revenue;
- valuation or future commercial performance;
- securities, tax, sanctions, or offering compliance in a particular jurisdiction;
- continuity of an issuer, SPV, revenue attestor, or external service provider.

Those boundaries are part of the project thesis, not omissions to conceal.