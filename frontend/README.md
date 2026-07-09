# IP Breaker RWA Frontend

A lightweight Vite + React + wagmi demo UI for the IP Breaker RWA v0.1 contracts.

## What it supports

- Connect injected wallet, such as MetaMask
- Switch between Foundry, Sepolia, Base Sepolia, and Arbitrum Sepolia
- Register an IP asset
- Approve a reviewer
- Add evidence to an IP asset
- Create a license offer
- Buy a license certificate NFT
- Read total revenue by asset

## Local setup

Install dependencies:

```bash
cd frontend
npm install
```

Create `.env` from `.env.example`:

```bash
cp .env.example .env
```

Fill contract addresses:

```bash
VITE_IP_ASSET_REGISTRY=0x...
VITE_EVIDENCE_REGISTRY=0x...
VITE_LICENSE_ESCROW=0x...
```

Run the app:

```bash
npm run dev
```

## Local Anvil flow

1. Start Anvil from the repository root:

```bash
anvil
```

2. Deploy contracts:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

3. Copy the deployed contract addresses into `frontend/.env`.

4. Run the frontend:

```bash
cd frontend
npm run dev
```

5. Connect MetaMask to local chain `31337` and import Anvil demo accounts as needed.

## Notes

This frontend is intentionally minimal. It is designed for portfolio demos and hackathon submissions, not production use.
