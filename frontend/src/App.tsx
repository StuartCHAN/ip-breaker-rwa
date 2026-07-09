import { FormEvent, useMemo, useState } from 'react';
import { formatEther, keccak256, parseEther, toHex } from 'viem';
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from 'wagmi';
import { arbitrumSepolia, baseSepolia, foundry, sepolia } from 'wagmi/chains';

import { ipAssetRegistryAbi, evidenceRegistryAbi, licenseEscrowAbi } from './abis';
import { contractAddresses } from './config';

const zeroBytes32 = '0x0000000000000000000000000000000000000000000000000000000000000000' as const;

function hashText(value: string): `0x${string}` {
  return keccak256(toHex(value));
}

function requireAddress(value: `0x${string}` | undefined, label: string): `0x${string}` {
  if (!value) {
    throw new Error(`${label} contract address is missing. Please set it in frontend/.env.`);
  }
  return value;
}

function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors, isPending: isConnecting } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync, isPending } = useWriteContract();

  const [lastTx, setLastTx] = useState<`0x${string}` | undefined>();
  const [status, setStatus] = useState('Ready');

  const [assetId, setAssetId] = useState('1');
  const [offerId, setOfferId] = useState('1');

  const [assetForm, setAssetForm] = useState({
    title: 'AI Patent Drafting Assistant',
    assetType: 'SOFTWARE',
    jurisdiction: 'US / CN',
    document: 'AI Patent Drafting Assistant technical whitepaper v1',
    metadataURI: 'ipfs://metadata-ai-patent-assistant',
  });

  const [evidenceForm, setEvidenceForm] = useState({
    evidenceType: 'GITHUB_COMMIT',
    evidence: 'github commit proof for ai patent drafting assistant',
    evidenceURI: 'ipfs://github-commit-proof',
    attestationUID: zeroBytes32,
  });

  const [reviewerAddress, setReviewerAddress] = useState('');

  const [licenseForm, setLicenseForm] = useState({
    priceEth: '0.0001',
    durationDays: '365',
    terms: 'commercial internal use, no resale, no sublicensing',
    termsURI: 'ipfs://license-terms-commercial-internal-use',
    transferable: false,
  });

  const currentNetworkName = useMemo(() => {
    const match = [foundry, sepolia, baseSepolia, arbitrumSepolia].find((chain) => chain.id === chainId);
    return match?.name ?? `Unknown chain ${chainId}`;
  }, [chainId]);

  const { data: totalRevenue } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'totalRevenueByAsset',
    args: [BigInt(assetId || '0')],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && assetId),
    },
  });

  async function runTx(label: string, callback: () => Promise<`0x${string}`>) {
    try {
      setStatus(`${label}...`);
      const txHash = await callback();
      setLastTx(txHash);
      setStatus(`${label} submitted`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStatus(`Error: ${message}`);
    }
  }

  async function registerAsset(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Registering IP asset', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.ipAssetRegistry, 'IPAssetRegistry'),
        abi: ipAssetRegistryAbi,
        functionName: 'registerAsset',
        args: [
          assetForm.title,
          assetForm.assetType,
          assetForm.jurisdiction,
          hashText(assetForm.document),
          assetForm.metadataURI,
        ],
      });
    });
  }

  async function addEvidence(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Adding evidence', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.evidenceRegistry, 'EvidenceRegistry'),
        abi: evidenceRegistryAbi,
        functionName: 'addEvidence',
        args: [
          BigInt(assetId),
          evidenceForm.evidenceType,
          hashText(evidenceForm.evidence),
          evidenceForm.evidenceURI,
          evidenceForm.attestationUID as `0x${string}`,
        ],
      });
    });
  }

  async function approveReviewer(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Approving reviewer', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.evidenceRegistry, 'EvidenceRegistry'),
        abi: evidenceRegistryAbi,
        functionName: 'setReviewer',
        args: [reviewerAddress as `0x${string}`, true],
      });
    });
  }

  async function createLicenseOffer(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Creating license offer', async () => {
      const durationSeconds = BigInt(Number(licenseForm.durationDays) * 24 * 60 * 60);
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'createLicenseOffer',
        args: [
          BigInt(assetId),
          parseEther(licenseForm.priceEth),
          durationSeconds,
          hashText(licenseForm.terms),
          licenseForm.termsURI,
          licenseForm.transferable,
        ],
      });
    });
  }

  async function buyLicense(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Buying license', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'buyLicense',
        args: [BigInt(offerId)],
        value: parseEther(licenseForm.priceEth),
      });
    });
  }

  return (
    <main className="app-shell">
      <section className="hero">
        <p className="eyebrow">IP Breaker RWA v0.1</p>
        <h1>Evidence-backed IP passport and programmable licensing protocol</h1>
        <p className="subtitle">Register IP assets, attach evidence, create license offers, and mint usage-right certificates.</p>
      </section>

      <section className="card wallet-card">
        <div>
          <h2>Wallet</h2>
          <p>Network: {currentNetworkName}</p>
          <p>{isConnected ? `Connected: ${address}` : 'Connect an injected wallet such as MetaMask.'}</p>
        </div>
        <div className="button-row">
          {!isConnected ? (
            connectors.map((connector) => (
              <button key={connector.uid} disabled={isConnecting} onClick={() => connect({ connector })}>
                Connect {connector.name}
              </button>
            ))
          ) : (
            <button onClick={() => disconnect()}>Disconnect</button>
          )}
          <button onClick={() => switchChain({ chainId: foundry.id })}>Foundry</button>
          <button onClick={() => switchChain({ chainId: baseSepolia.id })}>Base Sepolia</button>
          <button onClick={() => switchChain({ chainId: arbitrumSepolia.id })}>Arbitrum Sepolia</button>
        </div>
      </section>

      <section className="status-bar">
        <span>{isPending ? 'Waiting for wallet confirmation...' : status}</span>
        {lastTx && <code>{lastTx}</code>}
      </section>

      <section className="grid">
        <form className="card" onSubmit={registerAsset}>
          <h2>1. Register IP Asset</h2>
          <input value={assetForm.title} onChange={(e) => setAssetForm({ ...assetForm, title: e.target.value })} placeholder="Title" />
          <input value={assetForm.assetType} onChange={(e) => setAssetForm({ ...assetForm, assetType: e.target.value })} placeholder="Asset type" />
          <input value={assetForm.jurisdiction} onChange={(e) => setAssetForm({ ...assetForm, jurisdiction: e.target.value })} placeholder="Jurisdiction" />
          <textarea value={assetForm.document} onChange={(e) => setAssetForm({ ...assetForm, document: e.target.value })} placeholder="Document text to hash" />
          <input value={assetForm.metadataURI} onChange={(e) => setAssetForm({ ...assetForm, metadataURI: e.target.value })} placeholder="Metadata URI" />
          <button type="submit">Register asset</button>
        </form>

        <form className="card" onSubmit={approveReviewer}>
          <h2>2. Approve Reviewer</h2>
          <p className="hint">Only the EvidenceRegistry owner can approve reviewers.</p>
          <input value={reviewerAddress} onChange={(e) => setReviewerAddress(e.target.value)} placeholder="Reviewer address" />
          <button type="submit">Approve reviewer</button>
        </form>

        <form className="card" onSubmit={addEvidence}>
          <h2>3. Add Evidence</h2>
          <input value={assetId} onChange={(e) => setAssetId(e.target.value)} placeholder="Asset ID" />
          <input value={evidenceForm.evidenceType} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidenceType: e.target.value })} placeholder="Evidence type" />
          <textarea value={evidenceForm.evidence} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidence: e.target.value })} placeholder="Evidence text to hash" />
          <input value={evidenceForm.evidenceURI} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidenceURI: e.target.value })} placeholder="Evidence URI" />
          <input value={evidenceForm.attestationUID} onChange={(e) => setEvidenceForm({ ...evidenceForm, attestationUID: e.target.value as `0x${string}` })} placeholder="Attestation UID" />
          <button type="submit">Add evidence</button>
        </form>

        <form className="card" onSubmit={createLicenseOffer}>
          <h2>4. Create License Offer</h2>
          <input value={assetId} onChange={(e) => setAssetId(e.target.value)} placeholder="Asset ID" />
          <input value={licenseForm.priceEth} onChange={(e) => setLicenseForm({ ...licenseForm, priceEth: e.target.value })} placeholder="Price in ETH" />
          <input value={licenseForm.durationDays} onChange={(e) => setLicenseForm({ ...licenseForm, durationDays: e.target.value })} placeholder="Duration in days" />
          <textarea value={licenseForm.terms} onChange={(e) => setLicenseForm({ ...licenseForm, terms: e.target.value })} placeholder="License terms to hash" />
          <input value={licenseForm.termsURI} onChange={(e) => setLicenseForm({ ...licenseForm, termsURI: e.target.value })} placeholder="Terms URI" />
          <label className="checkbox-row">
            <input type="checkbox" checked={licenseForm.transferable} onChange={(e) => setLicenseForm({ ...licenseForm, transferable: e.target.checked })} />
            Transferable license certificate
          </label>
          <button type="submit">Create offer</button>
        </form>

        <form className="card" onSubmit={buyLicense}>
          <h2>5. Buy License</h2>
          <input value={offerId} onChange={(e) => setOfferId(e.target.value)} placeholder="Offer ID" />
          <input value={licenseForm.priceEth} onChange={(e) => setLicenseForm({ ...licenseForm, priceEth: e.target.value })} placeholder="Payment in ETH" />
          <button type="submit">Buy license</button>
        </form>

        <section className="card">
          <h2>Asset Revenue</h2>
          <input value={assetId} onChange={(e) => setAssetId(e.target.value)} placeholder="Asset ID" />
          <p>Total revenue for this asset:</p>
          <strong>{typeof totalRevenue === 'bigint' ? `${formatEther(totalRevenue)} ETH` : 'Not loaded'}</strong>
        </section>
      </section>
    </main>
  );
}

export default App;
