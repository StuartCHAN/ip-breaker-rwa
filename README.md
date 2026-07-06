# IP Breaker RWA

**Evidence-Backed IP Passport & Programmable Licensing Protocol**

> Make IP verifiable before making it tokenized.

IP Breaker RWA is a Solidity-based MVP for registering intellectual property assets, attaching verification evidence, and issuing onchain license certificates before any financial tokenization.

Most RWA projects focus on token issuance. IP assets need something more basic first: an evidence layer. Before a patent, software project, dataset, or AI model can be treated as an onchain asset, builders need a way to anchor ownership claims, public records, technical proofs, search reports, FTO reports, risk reviews, and license terms.

This project provides a minimal EVM protocol for that workflow.

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

The IP Asset NFT is an onchain index and evidence container. It does **not** directly transfer legal ownership of the underlying patent, copyright, software, dataset, or other IP asset.

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

This flow is covered in:

```text
test/Integration.t.sol
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

* ERC721 IP Asset NFT
* asset metadata storage
* document hash anchoring
* owner lookup
* asset existence check
* custom errors
* event indexing

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

* ordinary evidence submitted by asset owner
* FTO / risk reports submitted by authorized reviewers
* evidence hash anchoring
* evidence URI storage
* EAS-compatible `attestationUID` field
* evidence ID list per asset
* reviewer management

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

* native ETH payment
* license offer creation
* license certificate minting
* non-transferable license NFT support
* license expiration timestamp
* revenue tracking per IP asset
* stale offer protection if the IP Asset NFT changes owner

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

## Repository structure

```text
ip-breaker-rwa/
├── contracts/
│   ├── IPAssetRegistry.sol
│   ├── EvidenceRegistry.sol
│   ├── LicenseEscrow.sol
│   └── interfaces/
│       └── IIPAssetRegistry.sol
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

* Solidity `^0.8.24`
* Foundry
* OpenZeppelin Contracts
* ERC721
* Native ETH payment
* Custom errors
* Foundry unit and integration tests

## Getting started

### 1. Clone the repository

```bash
git clone https://github.com/StuartCHAN/ip-breaker-rwa.git
cd ip-breaker-rwa
```

### 2. Install dependencies

```bash
forge install
```

If dependencies are not installed yet:

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 3. Build

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

Create a local `.env` file. Do not commit it.

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

## Testnet deployment

This project can be deployed to Sepolia, Base Sepolia, or Arbitrum Sepolia.

Example `.env` fields:

```bash
SEPOLIA_RPC_URL=
BASE_SEPOLIA_RPC_URL=
ARBITRUM_SEPOLIA_RPC_URL=

PRIVATE_KEY=
ALICE_PRIVATE_KEY=
REVIEWER_PRIVATE_KEY=
BOB_PRIVATE_KEY=

IP_ASSET_REGISTRY=
EVIDENCE_REGISTRY=
LICENSE_ESCROW=
```

Use a dedicated testnet burner wallet. Do not use production wallets or mainnet private keys.

### Sepolia

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast
```

### Base Sepolia

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast
```

### Arbitrum Sepolia

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast
```

After deployment, update `.env` with the deployed addresses and run:

```bash
forge script script/Demo.s.sol:Demo \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast
```

Replace `$SEPOLIA_RPC_URL` with the target network RPC variable if using Base Sepolia or Arbitrum Sepolia.

## Security notes

This is an MVP and has not been audited.

Current design choices:

* license payments use native ETH only;
* license fees are sent directly to the licensor;
* stale offers cannot be purchased if the licensor no longer owns the IP Asset NFT;
* non-transferable licenses cannot be transferred after minting;
* reviewer-only evidence types are restricted to authorized reviewers;
* offchain documents are represented by hash and URI only.

Future improvements may include:

* pull-payment pattern for license proceeds;
* ERC20 payment support;
* role-based access control;
* EAS integration;
* IPFS/Filecoin evidence bundles;
* Chainlink Functions for external IP status checks;
* The Graph indexing;
* frontend dashboard.

## Roadmap

### v0.1

* IP Asset NFT registration
* Evidence Passport
* reviewer-submitted FTO / risk evidence
* native ETH license payment
* License Certificate NFT
* non-transferable license support
* Foundry unit and integration tests
* deployment and demo scripts

### v0.2

* frontend with wallet connection
* asset detail page
* evidence passport page
* license offer page
* license purchase flow

### v0.3

* EAS-backed attestations
* IPFS/Filecoin evidence bundles
* deployed testnet demo
* project video
* hackathon submission page

### Future

* Story Protocol integration
* Chainlink automation / external status checks
* permissioned RWA token standard exploration
* regulated license revenue workflows

## Example resume description

Built **IP Breaker RWA**, a Solidity-based IP asset passport and programmable licensing protocol. Implemented ERC721 IP asset registration, evidence anchoring, reviewer-based FTO/risk evidence, ETH license payment, and non-transferable License Certificate NFTs using Foundry and OpenZeppelin.

## Disclaimer

This repository is for technical experimentation and portfolio demonstration only. It does not provide legal, investment, financial, or intellectual property advice. The protocol does not by itself validate IP ownership, transfer legal title, or create regulated investment products.
