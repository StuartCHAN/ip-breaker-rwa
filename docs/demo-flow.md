# Local Demo Flow

This document describes the local Anvil demo for IP Breaker RWA v0.1.

## Actors

- Admin: deploys contracts and approves reviewer
- Alice: IP owner / licensor
- Reviewer: authorized FTO report reviewer
- Bob: license buyer

## Flow

1. Deploy `IPAssetRegistry`, `EvidenceRegistry`, and `LicenseEscrow`.
2. Admin approves Reviewer.
3. Alice registers `AI Patent Drafting Assistant` as a software IP asset.
4. Alice attaches `GITHUB_COMMIT` evidence.
5. Reviewer attaches `FTO_REPORT` evidence.
6. Alice creates a non-transferable commercial license offer.
7. Bob buys the license with ETH.
8. Bob receives a License Certificate NFT.
9. License revenue is recorded for the IP asset.
10. Bob cannot transfer the non-transferable license NFT.

## Run

Start Anvil:

```bash
anvil 

