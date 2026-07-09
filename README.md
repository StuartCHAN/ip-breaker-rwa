# IP Breaker RWA

**Evidence-Backed IP Passport & Programmable Licensing Protocol**

> Make IP verifiable before making it tokenized.

IP Breaker RWA is a Solidity-based MVP for registering intellectual property assets, attaching verification evidence, and issuing onchain license certificates before any financial tokenization.

Most RWA projects focus on token issuance. IP assets need something more basic first: an evidence layer. Before a patent, software project, dataset, AI model, or software product can be treated as an onchain asset, builders need a way to anchor ownership claims, public records, technical proofs, search reports, FTO reports, risk reviews, and license terms.

This project provides a minimal EVM protocol for that workflow.

## Current Status

- Core smart contracts completed
- Foundry unit tests completed
- Foundry integration demo completed
- Local Anvil deployment script completed
- Local demo script completed
- React frontend demo completed
- Read Dashboard completed for onchain state verification
- Public testnet deployment pending faucet funding
- Traditional backend/indexer not required for v0.1

## What this MVP does

IP Breaker RWA v0.1 supports three core actions:

1. **Register IP Asset**
   An IP owner registers an offchain IP asset and mints an IP Asset NFT.

2. **Attach Evidence Passport**
   The asset owner or an authorized reviewer attaches evidence records such as GitHub commit proofs, ownership claims, FTO reports, or risk reports.

3. **Issue License Certificate**
   The IP owner creates a license offer. A buyer pays ETH and receives a License Certificate NFT.

The protocol intentionally avoids fractional ownership, public investment claims, secondary-market speculation, and legal ownership transfer.

## Legal positioning

The IP Asset NFT is an onchain index and evidence container. It does **not** directly transfer legal ownership of the underlying patent, copyright, software, dataset, AI model, or other IP asset.

The License Certificate NFT represents a usage-right certificate based on offchain license terms. It is **not** an investment product, fractional ownership interest, or revenue-share token.

This project is a technical prototype and is not legal advice.

## Demo flow

The main demo story is:

```text
Alice registers "AI Patent Drafting Assistant" as a software IP asset.
Alice attaches GitHub commit evidence.
An authorized reviewer attaches an FTO report.
Alice creates a non-transferable commercial license offer.
Bob pays ETH to buy the license.
Bob receives a License Certificate NFT.
Bob cannot transfer the license certificate if it is marked as non-transferable.
```

This flow is covered by:

```text
test/Integration.t.sol
script/Demo.s.sol
frontend/
```

## Architecture

```text
IPAssetRegistry
    |
    | registers IP Asset NFT
    v

EvidenceRegistry
    |
    | attaches evidence records to IP assets
    | supports owner-submitted evidence
    | supports reviewer-submitted FTO / risk reports
    v

LicenseEscrow
    |
    | creates license offers
    | accepts ETH payment
    | mints License Certificate NFT
    | restricts transfer for non-transferable licenses
```

## Contracts

### `IPAssetRegistry.sol`

Registers offchain IP assets as NFT-based onchain passports.

Main features:

- ERC721 IP Asset NFT
- asset metadata storage
- document hash anchoring
- owner lookup
- token URI lookup
- asset existence check
- custom errors
- event indexing

Core function:

```solidity
function registerAsset(
    string calldata title,
    string calldata assetType,
    string calldata jurisdiction,
    bytes32 documentHash,
    string calldata metadataURI
) external returns (uint256 assetId);
```

Example asset types:

```text
PATENT
SOFTWARE
DATASET
AI_MODEL
TRADEMARK
DESIGN
```

### `EvidenceRegistry.sol`

Stores evidence records for each registered IP asset.

Main features:

- ordinary evidence submitted by asset owner
- FTO / risk reports submitted by authorized reviewers
- evidence hash anchoring
- evidence URI storage
- EAS-compatible `attestationUID` field
- evidence ID list per asset
- reviewer management

Core function:

```solidity
function addEvidence(
    uint256 assetId,
    string calldata evidenceType,
    bytes32 evidenceHash,
    string calldata evidenceURI,
    bytes32 attestationUID
) external returns (uint256 evidenceId);
```

Supported evidence examples:

```text
OWNERSHIP_CLAIM
PATENT_PUBLICATION
GITHUB_COMMIT
COPYRIGHT_CERTIFICATE
SEARCH_REPORT
FTO_REPORT
RISK_REPORT
LICENSE_TERMS
```

### `LicenseEscrow.sol`

Allows IP asset owners to create license offers and issue License Certificate NFTs.

Main features:

- native ETH payment
- license offer creation
- license certificate minting
- non-transferable license NFT support
- license expiration timestamp
- revenue tracking per IP asset
- stale offer protection if the IP Asset NFT changes owner

Core functions:

```solidity
function createLicenseOffer(
    uint256 assetId,
    uint256 price,
    uint64 duration,
    bytes32 termsHash,
    string calldata termsURI,
    bool transferable
) external returns (uint256 offerId);
```

```solidity
function buyLicense(uint256 offerId)
    external
    payable
    returns (uint256 licenseId);
```

## Frontend demo

The repository includes a lightweight frontend:

```text
frontend/
```

The frontend uses:

```text
Vite + React + TypeScript + wagmi + viem
```

It supports:

- connecting an injected wallet such as MetaMask;
- switching between Foundry, Sepolia, Base Sepolia, and Arbitrum Sepolia;
- registering an IP asset;
- approving an authorized reviewer;
- adding ordinary or reviewer evidence;
- creating a license offer;
- buying a license certificate NFT;
- reading back onchain asset, evidence, license offer, license certificate, and revenue state.

### Read Dashboard

The frontend includes a Read Dashboard for local demo verification.

It can read:

- IP Asset passport data;
- IP Asset owner;
- IP Asset token URI;
- evidence IDs attached to an asset;
- evidence record details;
- reviewer approval status;
- license offer details;
- license certificate details;
- license validity;
- license token URI;
- total revenue by asset;
- next asset, evidence, offer, and license IDs.

This is useful for demo recordings because each write action can be verified immediately from the UI.

## Repository structure

```text
ip-breaker-rwa/
├── contracts/
│   ├── IPAssetRegistry.sol
│   ├── EvidenceRegistry.sol
│   ├── LicenseEscrow.sol
│   └── interfaces/
│       └── IIPAssetRegistry.sol
├── frontend/
│   ├── src/
│   │   ├── abis.ts
│   │   ├── App.tsx
│   │   ├── config.ts
│   │   ├── main.tsx
│   │   ├── styles.css
│   │   └── vite-env.d.ts
│   ├── .env.example
│   ├── index.html
│   ├── package.json
│   ├── tsconfig.json
│   └── vite.config.ts
├── test/
│   ├── IPAssetRegistry.t.sol
│   ├── EvidenceRegistry.t.sol
│   ├── LicenseEscrow.t.sol
│   └── Integration.t.sol
├── script/
│   ├── Deploy.s.sol
│   └── Demo.s.sol
├── foundry.toml
├── remappings.txt
└── README.md
```

## Tech stack

- Solidity `^0.8.24`
- Foundry
- OpenZeppelin Contracts
- ERC721
- Native ETH payment
- Custom errors
- Foundry unit and integration tests
- Vite
- React
- TypeScript
- wagmi
- viem

## Getting started

### 1. Clone the repository

```bash
git clone https://github.com/StuartCHAN/ip-breaker-rwa.git
cd ip-breaker-rwa
```

### 2. Install Solidity dependencies

```bash
forge install
```

If dependencies are not installed yet:

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 3. Build contracts

```bash
forge build
```

### 4. Run tests

Run all tests:

```bash
forge test -vvv
```

Run the integration demo test only:

```bash
forge test --match-path test/Integration.t.sol -vvv
```

Format contracts:

```bash
forge fmt
```

## Local deployment with Anvil

### 1. Start local chain

In one terminal:

```bash
anvil
```

### 2. Configure environment variables

Create a local `.env` file in the repository root. Do not commit it.

```bash
PRIVATE_KEY=0x...

ALICE_PRIVATE_KEY=0x...
REVIEWER_PRIVATE_KEY=0x...
BOB_PRIVATE_KEY=0x...

IP_ASSET_REGISTRY=
EVIDENCE_REGISTRY=
LICENSE_ESCROW=
```

For local Anvil testing, you can use the default accounts printed by Anvil. Do not use Anvil private keys on public networks.

Load the environment:

```bash
set -a
source .env
set +a
```

### 3. Deploy contracts locally

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

After deployment, copy the printed contract addresses into `.env`:

```bash
IP_ASSET_REGISTRY=0x...
EVIDENCE_REGISTRY=0x...
LICENSE_ESCROW=0x...
```

Reload:

```bash
set -a
source .env
set +a
```

### 4. Run the local demo script

```bash
forge script script/Demo.s.sol:Demo \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

The demo script will:

1. approve a reviewer;
2. register an IP asset;
3. add GitHub commit evidence;
4. add FTO report evidence;
5. create a non-transferable license offer;
6. buy the license;
7. mint a License Certificate NFT.

## Run the frontend locally

After deploying the contracts to Anvil, create a frontend environment file:

```bash
cd frontend
cp .env.example .env
```

Fill in the deployed local contract addresses:

```bash
VITE_IP_ASSET_REGISTRY=0x...
VITE_EVIDENCE_REGISTRY=0x...
VITE_LICENSE_ESCROW=0x...
```

Install frontend dependencies:

```bash
npm install
```

Build frontend:

```bash
npm run build
```

Run frontend:

```bash
npm run dev
```

In MetaMask, connect to the local Anvil network:

```text
RPC URL: http://127.0.0.1:8545
Chain ID: 31337
Currency: ETH
```

Then import local Anvil accounts for demo roles:

```text
Admin / deployer
Alice / IP owner
Reviewer / FTO reviewer
Bob / license buyer
```

## Manual frontend demo sequence

Use the frontend in this order:

```text
1. Admin approves Reviewer
2. Alice registers IP Asset
3. Alice adds GITHUB_COMMIT evidence
4. Reviewer adds FTO_REPORT evidence
5. Alice creates non-transferable license offer
6. Bob buys license certificate
7. Read Dashboard verifies asset, evidence, offer, license, and revenue state
```

## Deployment Status

### Local Anvil Demo

Status: **Completed**

The full IP Breaker RWA v0.1 demo flow can be executed locally with Anvil, Foundry scripts, Foundry tests, and the React frontend.

### Public Testnet Deployment

Status: **Pending faucet funding**

Target networks:

```text
Base Sepolia
Arbitrum Sepolia
Ethereum Sepolia
```

The contracts are ready for testnet deployment, but public testnet deployment is currently pending because faucet funding for Base Sepolia / Arbitrum Sepolia is limited.

Once testnet ETH is available, the project can be deployed with:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast
```

or:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast
```

After successful deployment, this section will be updated with deployed contract addresses:

```text
Network: Base Sepolia or Arbitrum Sepolia

IPAssetRegistry: 0x...
EvidenceRegistry: 0x...
LicenseEscrow: 0x...
```

For now, the project should be evaluated by its local Anvil demo, Foundry unit tests, integration test, deployment scripts, frontend demo, and contract architecture.

## Security notes

This is an MVP and has not been audited.

Current design choices:

- license payments use native ETH only;
- license fees are sent directly to the licensor;
- stale offers cannot be purchased if the licensor no longer owns the IP Asset NFT;
- non-transferable licenses cannot be transferred after minting;
- reviewer-only evidence types are restricted to authorized reviewers;
- offchain documents are represented by hash and URI only.

Future improvements may include:

- pull-payment pattern for license proceeds;
- ERC20 payment support;
- role-based access control;
- EAS integration;
- IPFS/Filecoin evidence bundles;
- Chainlink Functions for external IP status checks;
- The Graph indexing;
- richer frontend dashboard;
- optional backend metadata/indexing service.

## Roadmap

### v0.1

- IP Asset NFT registration
- Evidence registry
- Reviewer-only FTO / risk report evidence
- Native ETH license purchase
- Non-transferable license certificate NFT
- Local Anvil demo
- Foundry tests
- React frontend demo
- Read Dashboard

### v0.2

- IPFS metadata and evidence bundle upload
- Event indexing
- richer asset passport page
- reviewer dashboard
- optional backend service for metadata generation

### v0.3

- EAS integration
- multi-chain deployment
- license templates
- payment token support
- protocol-level risk review workflow

## Resume description

**IP Breaker RWA** — Built an evidence-backed IP asset passport and programmable licensing MVP using Solidity, Foundry, ERC721, React, wagmi, and viem. The project supports IP asset registration, evidence anchoring, reviewer-submitted FTO reports, ETH-based license purchases, non-transferable license certificate NFTs, local Anvil deployment, Foundry integration tests, and a frontend Read Dashboard for onchain state verification.

## Disclaimer

This repository is a technical prototype for educational, portfolio, and hackathon purposes. It does not provide legal advice and does not create legally enforceable IP ownership or investment rights by itself.
