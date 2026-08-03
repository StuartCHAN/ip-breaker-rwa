import { FormEvent, useState } from 'react';
import { formatEther, keccak256, parseEther, toHex } from 'viem';
import { useAccount, useReadContract, useWriteContract } from 'wagmi';

import { licenseEscrowAbi } from '../abis';
import { contractAddresses } from '../config';

const agreementStatusLabels = ['Created', 'Funded', 'Active', 'Disputed', 'Completed', 'Refunded', 'Cancelled'] as const;

const statusHints = [
  'Waiting for the named licensee to fund the agreement.',
  'Escrow is funded. Waiting for the licensor to confirm performance.',
  'Performance confirmed. Waiting for the licensee to release funds or raise a dispute.',
  'Agreement is disputed. Arbiter resolution will be added in the next sprint.',
  'Completed. Funds have been released to the licensor.',
  'Refunded. Funds have been returned to the licensee.',
  'Cancelled before funding.',
] as const;

type Agreement = {
  assetId: bigint;
  licensor: `0x${string}`;
  status: number;
  licensee: `0x${string}`;
  arbiter: `0x${string}`;
  licenseFee: bigint;
  escrowedAmount: bigint;
  termsHash: `0x${string}`;
  createdAt: bigint;
  fundedAt: bigint;
};

function parseUintInput(value: string): bigint {
  const normalized = value.trim();
  if (!/^\d+$/.test(normalized)) return 0n;
  return BigInt(normalized);
}

function isAddress(value: string): value is `0x${string}` {
  return /^0x[a-fA-F0-9]{40}$/.test(value.trim());
}

function hashText(value: string): `0x${string}` {
  return keccak256(toHex(value));
}

function requireAddress(value: `0x${string}` | undefined, label: string): `0x${string}` {
  if (!value) {
    throw new Error(`${label} contract address is missing. Please set it in frontend/.env.`);
  }
  return value;
}

function shortAddress(value: string | undefined): string {
  if (!value) return '-';
  if (value.length <= 12) return value;
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function formatTimestamp(value: bigint | undefined): string {
  if (!value || value === 0n) return '-';
  return new Date(Number(value) * 1000).toLocaleString();
}

export default function AgreementDashboard() {
  const { address, isConnected } = useAccount();
  const { writeContractAsync, isPending } = useWriteContract();

  const [status, setStatus] = useState('Ready');
  const [lastTx, setLastTx] = useState<`0x${string}` | undefined>();
  const [agreementId, setAgreementId] = useState('1');
  const [agreementForm, setAgreementForm] = useState({
    assetId: '1',
    licensee: '',
    licenseFeeEth: '0.0001',
    terms: 'commercial internal use, no resale, no sublicensing',
    termsURI: 'ipfs://license-terms-commercial-internal-use',
  });

  const agreementIdBigInt = parseUintInput(agreementId);
  const hasAgreementId = agreementIdBigInt > 0n;

  const {
    data: rawAgreement,
    error: agreementError,
    refetch: refetchAgreement,
  } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'getAgreement',
    args: [agreementIdBigInt],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && hasAgreementId),
    },
  });

  const { data: nextAgreementId, refetch: refetchNextAgreementId } = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'nextAgreementId',
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow),
    },
  });

  const agreement = rawAgreement as Agreement | undefined;
  const statusIndex = agreement ? Number(agreement.status) : 0;
  const statusLabel = agreementStatusLabels[statusIndex] ?? `Unknown (${statusIndex})`;
  const statusHint = statusHints[statusIndex] ?? 'Unknown agreement status.';

  const isLicensor = Boolean(address && agreement && address.toLowerCase() === agreement.licensor.toLowerCase());
  const isLicensee = Boolean(address && agreement && address.toLowerCase() === agreement.licensee.toLowerCase());

  async function refreshReads() {
    await Promise.allSettled([refetchAgreement(), refetchNextAgreementId()]);
  }

  async function runTx(label: string, callback: () => Promise<`0x${string}`>) {
    if (!isConnected) {
      setStatus('Please connect your wallet first.');
      return;
    }

    try {
      setStatus(`${label}...`);
      const txHash = await callback();
      setLastTx(txHash);
      setStatus(`${label} submitted`);
      await refreshReads();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      setStatus(`Error: ${message}`);
    }
  }

  async function createAgreement(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    if (!isAddress(agreementForm.licensee)) {
      setStatus('Please enter a valid licensee address.');
      return;
    }

    await runTx('Creating license agreement', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'createLicenseAgreement',
        args: [
          parseUintInput(agreementForm.assetId),
          agreementForm.licensee.trim() as `0x${string}`,
          parseEther(agreementForm.licenseFeeEth),
          hashText(agreementForm.terms),
          agreementForm.termsURI,
        ],
      });
    });
  }

  async function fundAgreement() {
    if (!agreement) {
      setStatus('Agreement is not loaded yet.');
      return;
    }

    await runTx('Funding license agreement', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'fundLicense',
        args: [agreementIdBigInt],
        value: agreement.licenseFee,
      });
    });
  }

  async function confirmPerformance() {
    await runTx('Confirming performance', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'confirmPerformance',
        args: [agreementIdBigInt],
      });
    });
  }

  async function releasePayment() {
    await runTx('Releasing escrow payment', async () => {
      return writeContractAsync({
        address: requireAddress(contractAddresses.licenseEscrow, 'LicenseEscrow'),
        abi: licenseEscrowAbi,
        functionName: 'release',
        args: [agreementIdBigInt],
      });
    });
  }

  return (
    <section className="card read-dashboard">
      <div className="section-heading">
        <p className="eyebrow dark">License Agreement Flow</p>
        <h2>Escrow Agreement Dashboard</h2>
        <p className="hint">
          Create a named license agreement, fund escrow, confirm performance, and release payment. Dispute resolution will be added in the next frontend sprint.
        </p>
      </div>

      <section className="status-bar">
        <span>{isPending ? 'Waiting for wallet confirmation...' : status}</span>
        {lastTx && <code>{lastTx}</code>}
      </section>

      <form className="card" onSubmit={createAgreement}>
        <h3>Create License Agreement</h3>
        <input
          value={agreementForm.assetId}
          onChange={(event) => setAgreementForm({ ...agreementForm, assetId: event.target.value })}
          placeholder="Asset ID"
        />
        <input
          value={agreementForm.licensee}
          onChange={(event) => setAgreementForm({ ...agreementForm, licensee: event.target.value })}
          placeholder="Licensee address"
        />
        <input
          value={agreementForm.licenseFeeEth}
          onChange={(event) => setAgreementForm({ ...agreementForm, licenseFeeEth: event.target.value })}
          placeholder="License fee in ETH"
        />
        <textarea
          value={agreementForm.terms}
          onChange={(event) => setAgreementForm({ ...agreementForm, terms: event.target.value })}
          placeholder="Agreement terms to hash"
        />
        <input
          value={agreementForm.termsURI}
          onChange={(event) => setAgreementForm({ ...agreementForm, termsURI: event.target.value })}
          placeholder="Terms URI"
        />
        <button type="submit">Create agreement</button>
      </form>

      <div className="read-inputs">
        <label>
          Agreement ID
          <input value={agreementId} onChange={(event) => setAgreementId(event.target.value)} placeholder="1" />
        </label>
        <label>
          Next Agreement ID
          <input readOnly value={typeof nextAgreementId === 'bigint' ? nextAgreementId.toString() : '-'} />
        </label>
      </div>

      <div className="summary-strip">
        <span>Status: {agreement ? statusLabel : 'Not loaded'}</span>
        <span>Escrow: {agreement ? `${formatEther(agreement.escrowedAmount)} ETH` : '-'}</span>
        <span>Fee: {agreement ? `${formatEther(agreement.licenseFee)} ETH` : '-'}</span>
        <span>Current role: {isLicensor ? 'Licensor' : isLicensee ? 'Licensee' : 'Observer'}</span>
      </div>

      {agreementError && <p className="error-text">{agreementError.message}</p>}

      <div className="read-grid">
        <div className="data-block">
          <h3>Agreement Snapshot</h3>
          <p className="hint">{statusHint}</p>
          <pre>{`Agreement ID: ${agreementId}
Asset ID: ${agreement?.assetId?.toString() ?? '-'}
Licensor: ${agreement?.licensor ?? '-'}
Licensee: ${agreement?.licensee ?? '-'}
Arbiter: ${agreement?.arbiter ?? '-'}
Terms Hash: ${agreement?.termsHash ?? '-'}
Created At: ${formatTimestamp(agreement?.createdAt)}
Funded At: ${formatTimestamp(agreement?.fundedAt)}`}</pre>
        </div>

        <div className="data-block">
          <h3>Lifecycle Actions</h3>
          <p className="hint">Switch MetaMask accounts to Alice or Bob before clicking the role-specific buttons.</p>
          <div className="button-row">
            <button type="button" onClick={fundAgreement} disabled={!agreement || !isLicensee || statusIndex !== 0 || isPending}>
              Fund License
            </button>
            <button type="button" onClick={confirmPerformance} disabled={!agreement || !isLicensor || statusIndex !== 1 || isPending}>
              Confirm Performance
            </button>
            <button type="button" onClick={releasePayment} disabled={!agreement || !isLicensee || statusIndex !== 2 || isPending}>
              Release Payment
            </button>
          </div>
          <p className="hint">Expected path: Created → Funded → Active → Completed.</p>
          <p className="hint">Connected: {shortAddress(address)}</p>
        </div>
      </div>
    </section>
  );
}
