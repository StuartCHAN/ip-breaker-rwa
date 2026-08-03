import { useMemo, useState } from 'react';
import { formatEther } from 'viem';
import { useReadContract } from 'wagmi';

import { evidenceRegistryAbi, ipAssetRegistryAbi, licenseEscrowAbi } from '../abis';
import { contractAddresses } from '../config';

const agreementStatuses = [
  'Created',
  'Funded',
  'Active',
  'Disputed',
  'Completed',
  'Refunded',
  'Cancelled',
] as const;

type AgreementView = {
  status: number;
  licenseFee: bigint;
  escrowedAmount: bigint;
};

type DemoStepProps = {
  complete: boolean;
  label: string;
  detail: string;
};

function parsePositiveId(value: string): bigint | undefined {
  const normalized = value.trim();
  if (!/^\d+$/.test(normalized)) return undefined;

  const parsed = BigInt(normalized);
  return parsed > 0n ? parsed : undefined;
}

function DemoStep({ complete, label, detail }: DemoStepProps) {
  return (
    <div className="data-block">
      <h3>{complete ? '[done]' : '[ ]'} {label}</h3>
      <p className="hint">{detail}</p>
    </div>
  );
}

export default function DemoPanel() {
  const [assetIdInput, setAssetIdInput] = useState('1');
  const [agreementIdInput, setAgreementIdInput] = useState('1');

  const assetId = parsePositiveId(assetIdInput);
  const agreementId = parsePositiveId(agreementIdInput);

  const assetQuery = useReadContract({
    address: contractAddresses.ipAssetRegistry,
    abi: ipAssetRegistryAbi,
    functionName: 'getAsset',
    args: [assetId ?? 0n],
    query: {
      enabled: Boolean(contractAddresses.ipAssetRegistry && assetId),
      retry: false,
    },
  });

  const evidenceQuery = useReadContract({
    address: contractAddresses.evidenceRegistry,
    abi: evidenceRegistryAbi,
    functionName: 'getEvidenceIds',
    args: [assetId ?? 0n],
    query: {
      enabled: Boolean(contractAddresses.evidenceRegistry && assetId),
      retry: false,
    },
  });

  const agreementQuery = useReadContract({
    address: contractAddresses.licenseEscrow,
    abi: licenseEscrowAbi,
    functionName: 'getAgreement',
    args: [agreementId ?? 0n],
    query: {
      enabled: Boolean(contractAddresses.licenseEscrow && agreementId),
      retry: false,
    },
  });

  const agreement = agreementQuery.data as AgreementView | undefined;
  const statusNumber = agreement ? Number(agreement.status) : undefined;
  const statusLabel = statusNumber === undefined
    ? 'Not loaded'
    : (agreementStatuses[statusNumber] ?? `Unknown (${statusNumber})`);

  const evidenceCount = evidenceQuery.data?.length ?? 0;
  const assetRegistered = Boolean(assetQuery.data) && !assetQuery.error;
  const evidenceAttached = evidenceCount > 0;
  const agreementCreated = Boolean(agreement);
  const escrowFunded = statusNumber !== undefined && [1, 2, 3, 4, 5].includes(statusNumber);
  const performanceConfirmed = statusNumber !== undefined && [2, 3, 4, 5].includes(statusNumber);
  const settlementFinished = statusNumber === 4 || statusNumber === 5;

  const progress = useMemo(() => {
    return [assetRegistered, evidenceAttached, agreementCreated, escrowFunded, performanceConfirmed, settlementFinished]
      .filter(Boolean).length;
  }, [assetRegistered, evidenceAttached, agreementCreated, escrowFunded, performanceConfirmed, settlementFinished]);

  function refresh() {
    void assetQuery.refetch();
    void evidenceQuery.refetch();
    void agreementQuery.refetch();
  }

  return (
    <section className="card read-dashboard">
      <div className="section-heading">
        <p className="eyebrow dark">Demo Mode</p>
        <h2>AI Patent Drafting Assistant licensing scenario</h2>
        <p className="hint">
          This panel verifies the live onchain journey from IP registration to escrow settlement. It does not use mock progress.
        </p>
      </div>

      <div className="read-inputs">
        <label>
          Asset ID
          <input value={assetIdInput} onChange={(event) => setAssetIdInput(event.target.value)} placeholder="1" />
        </label>
        <label>
          Agreement ID
          <input value={agreementIdInput} onChange={(event) => setAgreementIdInput(event.target.value)} placeholder="1" />
        </label>
        <button type="button" onClick={refresh}>Refresh demo state</button>
      </div>

      <div className="summary-strip">
        <span>Progress: {progress}/6</span>
        <span>Agreement status: {statusLabel}</span>
        <span>Evidence records: {evidenceCount}</span>
        <span>
          Escrow: {agreement ? `${formatEther(agreement.escrowedAmount)} ETH` : '-'}
        </span>
      </div>

      <div className="read-grid">
        <DemoStep
          complete={assetRegistered}
          label="1. IP Asset Registered"
          detail={assetRegistered ? `Asset #${assetIdInput} exists onchain.` : 'Register the demo IP asset first.'}
        />
        <DemoStep
          complete={evidenceAttached}
          label="2. Evidence Passport Created"
          detail={evidenceAttached ? `${evidenceCount} evidence record(s) attached.` : 'Attach owner or reviewer evidence.'}
        />
        <DemoStep
          complete={agreementCreated}
          label="3. License Agreement Created"
          detail={agreementCreated ? `Agreement #${agreementIdInput} is ${statusLabel}.` : 'Create an agreement for the licensee.'}
        />
        <DemoStep
          complete={escrowFunded}
          label="4. Escrow Funded"
          detail={agreement ? `${formatEther(agreement.licenseFee)} ETH license fee.` : 'The licensee funds the agreement.'}
        />
        <DemoStep
          complete={performanceConfirmed}
          label="5. Performance Confirmed"
          detail={performanceConfirmed ? 'The licensor confirmed performance.' : 'The licensor confirms after funding.'}
        />
        <DemoStep
          complete={settlementFinished}
          label="6. Settlement Completed"
          detail={settlementFinished ? `Final state: ${statusLabel}.` : 'The licensee releases payment after confirmation.'}
        />
      </div>

      {(assetQuery.error || evidenceQuery.error || agreementQuery.error) && (
        <p className="hint">
          Some records are not loaded yet. Complete the corresponding transaction, check the IDs, then refresh.
        </p>
      )}
    </section>
  );
}
