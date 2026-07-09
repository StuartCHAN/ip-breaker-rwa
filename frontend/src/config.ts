import { http, createConfig } from 'wagmi';
import { injected } from 'wagmi/connectors';
import { arbitrumSepolia, baseSepolia, foundry, sepolia } from 'wagmi/chains';

export const wagmiConfig = createConfig({
  chains: [foundry, sepolia, baseSepolia, arbitrumSepolia],
  connectors: [injected()],
  transports: {
    [foundry.id]: http('http://127.0.0.1:8545'),
    [sepolia.id]: http(),
    [baseSepolia.id]: http(),
    [arbitrumSepolia.id]: http(),
  },
});

export const contractAddresses = {
  ipAssetRegistry: import.meta.env.VITE_IP_ASSET_REGISTRY as `0x${string}` | undefined,
  evidenceRegistry: import.meta.env.VITE_EVIDENCE_REGISTRY as `0x${string}` | undefined,
  licenseEscrow: import.meta.env.VITE_LICENSE_ESCROW as `0x${string}` | undefined,
};
