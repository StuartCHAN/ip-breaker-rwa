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
import AgreementDashboard from './components/AgreementDashboard';
import DemoPanel from './components/DemoPanel';
import EventTimeline from './components/EventTimeline';

const zeroBytes32 = '0x0000000000000000000000000000000000000000000000000000000000000000' as const;

type EvidenceForm = {
  evidenceType: string;
  evidence: string;
  evidenceURI: string;
  attestationUID: string;
};

type DataBlockProps = {
  title: string;
  data: unknown;
  error?: Error | null;
};

function hashText(value: string): `0x${string}` {
  return keccak256(toHex(value));
}

function requireAddress(value: `0x${string}` | undefined, label: string): `0x${string}` {
  if (!value) {
    throw new Error(`${label} contract address is missing. Please set it in frontend/.env.`);
  }
  return value;
}

function parseUintInput(value: string): bigint {
  const normalized = value.trim();
  if (!/^\d+$/.test(normalized)) return 0n;
  return BigInt(normalized);
}

function isPositiveUintInput(value: string): boolean {
  return parseUintInput(value) > 0n;
}

function formatUnknown(value: unknown): string {
  if (value === undefined || value === null) return 'Not loaded';

  return JSON.stringify(
    value,
    (_key, item) => {
      if (typeof item === 'bigint') return item.toString();
      return item;
    },
    2,
  );
}

function DataBlock({ title, data, error }: DataBlockProps) {
  return (
    <div className="data-block">
      <h3>{title}</h3>
      {error ? <p className="error-text">{error.message}</p> : <pre>{formatUnknown(data)}</pre>}
    </div>
  );
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
  const [evidenceId, setEvidenceId] = useState('1');
  const [licenseId, setLicenseId] = useState('1');

  const assetIdBigInt = parseUintInput(assetId);
  const offerIdBigInt = parseUintInput(offerId);
  const evidenceIdBigInt = parseUintInput(evidenceId);
  const licenseIdBigInt = parseUintInput(licenseId);
  const hasAssetId = isPositiveUintInput(assetId);
  const hasOfferId = isPositiveUintInput(offerId);
  const hasEvidenceId = isPositiveUintInput(evidenceId);
  const hasLicenseId = isPositiveUintInput(licenseId);

  const [assetForm, setAssetForm] = useState({
    title: 'AI Patent Drafting Assistant',
    assetType: 'SOFTWARE',
    jurisdiction: 'US / CN',
    document: 'AI Patent Drafting Assistant technical whitepaper v1',
    metadataURI: 'ipfs://metadata-ai-patent-assistant',
  });

  const [evidenceForm, setEvidenceForm] = useState<EvidenceForm>({
    evidenceType: 'GITHUB_COMMIT',
    evidence: 'github commit proof for ai patent drafting assistant',
    evidenceURI: 'ipfs://github-commit-proof',
    attestationUID: zeroBytes32,
  });

  const [evidenceReviewId, setEvidenceReviewId] = useState('1');

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

  const { data: assetData, error: assetError } = useReadContract({
    address: contractAddresses.ipAssetRegistry,
    abi: ipAssetRegistryAbi,
    functionName: 'getAsset',
    args: [assetIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.ipAssetRegistry && hasAssetId),
    },
  });

  const { data: assetOwner, error: assetOwnerError } = useReadContract({
    address: contractAddresses.ipAssetRegistry,
    abi: ipAssetRegistryAbi,
    functionName: 'ownerOf',
    args: [assetIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.ipAssetRegistry && hasAssetId),
    },
  });

  const { data: assetTokenURI, error: assetTokenURIError } = useReadContract({
    address: contractAddresses.ipAssetRegistry,
    abi: ipAssetRegistryAbi,
    functionName: 'tokenURI',
    args: [assetIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.ipAssetRegistry && hasAssetId),
    },
  });

  const { data: nextAssetId } = useReadContract({
    address: contractAddresses.ipAssetRegistry,
    abi: ipAssetRegistryAbi,
    functionName: 'nextAssetId',
    query: {
      enabled: Boolean(contractAddresses.ipAssetRegistry),
    },
  });

  const { data: evidenceIds, error: evidenceIdsError } = useReadContract({
    address: contractAddresses.evidenceRegistry,
    abi: evidenceRegistryAbi,
    functionName: 'getEvidenceIds',
    args: [assetIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.evidenceRegistry && hasAssetId),
    },
  });

  const { data: evidenceData, error: evidenceError } = useReadContract({
    address: contractAddresses.evidenceRegistry,
    abi: evidenceRegistryAbi,
    functionName: 'getEvidence',
    args: [evidenceIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.evidenceRegistry && hasEvidenceId),
    },
  });

  const { data: nextEvidenceId } = useReadContract({
    address: contractAddresses.evidenceRegistry,
    abi: evidenceRegistryAbi,
    functionName: 'nextEvidenceId',
    query: {
      enabled: Boolean(contractAddresses.evidenceRegistry),
    },
  });

  const { data: offerData, error: offerError } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'getLicenseOffer',
    args: [offerIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasOfferId),
    },
  });

  const { data: licenseData, error: licenseError } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'getLicense',
    args: [licenseIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasLicenseId),
    },
  });

  const { data: licenseValid, error: licenseValidError } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'isLicenseValid',
    args: [licenseIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasLicenseId),
    },
  });

  const { data: licenseTokenURI, error: licenseTokenURIError } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'tokenURI',
    args: [licenseIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasLicenseId),
    },
  });

  const { data: totalRevenue, error: revenueError } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'totalRevenueByAsset',
    args: [assetIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasAssetId),
    },
  });

  const { data: nextOfferId } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'nextOfferId',
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow),
    },
  });

  const { data: nextLicenseId } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'nextLicenseId',
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow),
    },
  });

  async function runTx(label: string, callback: () => Promise<`0x${string}`>) {
    if (!isConnected) {
      setStatus('Please connect your wallet first. The typed address is not enough; MetaMask must be connected to the app.');
      return;
    }

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
          assetIdBigInt,
          evidenceForm.evidenceType,
          hashText(evidenceForm.evidence),
          evidenceForm.evidenceURI,
          evidenceForm.attestationUID as `0x${string}`,
        ],
      });
    });
  }

  async function verifyEvidence(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await runTx('Verifying evidence', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.evidenceRegistry, 'EvidenceRegistry'),
        abi: evidenceRegistryAbi,
        functionName: 'verifyEvidence',
        args: [BigInt(evidenceReviewId)],
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
          assetIdBigInt,
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
        args: [offerIdBigInt],
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

      <DemoPanel />

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

        <form className="card" onSubmit={verifyEvidence}>
          <h2>2. Verify Evidence</h2>
          <p className="hint">Requires an active ROLE_VERIFIER identity.</p>
          <input value={evidenceReviewId} onChange={(e) => setEvidenceReviewId(e.target.value)} placeholder="Evidence ID" />
          <button type="submit">Verify evidence</button>
        </form>

        <form className="card" onSubmit={addEvidence}>
          <h2>3. Add Evidence</h2>
          <input value={assetId} onChange={(e) => setAssetId(e.target.value)} placeholder="Asset ID" />
          <input value={evidenceForm.evidenceType} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidenceType: e.target.value })} placeholder="Evidence type" />
          <textarea value={evidenceForm.evidence} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidence: e.target.value })} placeholder="Evidence text to hash" />
          <input value={evidenceForm.evidenceURI} onChange={(e) => setEvidenceForm({ ...evidenceForm, evidenceURI: e.target.value })} placeholder="Evidence URI" />
          <input value={evidenceForm.attestationUID} onChange={(e) => setEvidenceForm({ ...evidenceForm, attestationUID: e.target.value })} placeholder="Attestation UID" />
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
          {revenueError && <p className="error-text">{revenueError.message}</p>}
        </section>
      </section>


      <AgreementDashboard />

      <EventTimeline />

      <section className="card read-dashboard">
        <div className="section-heading">
          <p className="eyebrow dark">Read Dashboard</p>
          <h2>Verify onchain state</h2>
          <p className="hint">Use this panel after each transaction to confirm that the asset passport, evidence records, license offer, and license certificate were written onchain.</p>
        </div>

        <div className="read-inputs">
          <label>
            Asset ID
            <input value={assetId} onChange={(event) => setAssetId(event.target.value)} placeholder="1" />
          </label>
          <label>
            Evidence ID
            <input value={evidenceId} onChange={(event) => setEvidenceId(event.target.value)} placeholder="1" />
          </label>
          <label>
            Offer ID
            <input value={offerId} onChange={(event) => setOfferId(event.target.value)} placeholder="1" />
          </label>
          <label>
            License ID
            <input value={licenseId} onChange={(event) => setLicenseId(event.target.value)} placeholder="1" />
          </label>
        </div>

        <div className="summary-strip">
          <span>Next Asset ID: {typeof nextAssetId === 'bigint' ? nextAssetId.toString() : '-'}</span>
          <span>Next Evidence ID: {typeof nextEvidenceId === 'bigint' ? nextEvidenceId.toString() : '-'}</span>
          <span>Next Offer ID: {typeof nextOfferId === 'bigint' ? nextOfferId.toString() : '-'}</span>
          <span>Next License ID: {typeof nextLicenseId === 'bigint' ? nextLicenseId.toString() : '-'}</span>
        </div>

        <div className="read-grid">
          <DataBlock title="Asset Passport" data={assetData} error={assetError} />
          <DataBlock title="Asset Owner" data={assetOwner} error={assetOwnerError} />
          <DataBlock title="Asset Token URI" data={assetTokenURI} error={assetTokenURIError} />
          <DataBlock title="Evidence IDs for Asset" data={evidenceIds} error={evidenceIdsError} />
          <DataBlock title="Evidence Record" data={evidenceData} error={evidenceError} />
          <DataBlock title="License Offer" data={offerData} error={offerError} />
          <DataBlock title="License Certificate" data={licenseData} error={licenseError} />
          <DataBlock title="License Valid" data={licenseValid} error={licenseValidError} />
          <DataBlock title="License Token URI" data={licenseTokenURI} error={licenseTokenURIError} />
          <DataBlock title="Total Revenue by Asset" data={typeof totalRevenue === 'bigint' ? `${formatEther(totalRevenue)} ETH` : totalRevenue} error={revenueError} />
        </div>
      </section>
    </main>
  );
}

export default App;
