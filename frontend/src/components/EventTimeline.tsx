import { useState } from 'react';
import { formatEther, parseAbiItem } from 'viem';
import { usePublicClient } from 'wagmi';

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

const agreementCreatedEvent = parseAbiItem(
  'event LicenseAgreementCreated(uint256 indexed agreementId, uint256 indexed assetId, address indexed licensor, address licensee, address arbiter, uint256 licenseFee, bytes32 termsHash, string termsURI)',
);
const statusChangedEvent = parseAbiItem(
  'event LicenseStatusChanged(uint256 indexed agreementId, uint8 from, uint8 to)',
);
const fundedEvent = parseAbiItem(
  'event LicenseFunded(uint256 indexed agreementId, address indexed licensee, uint256 amount)',
);
const performanceConfirmedEvent = parseAbiItem(
  'event PerformanceConfirmed(uint256 indexed agreementId, address indexed licensor)',
);
const fundsReleasedEvent = parseAbiItem(
  'event FundsReleased(uint256 indexed agreementId, address indexed to, uint256 amount)',
);
const disputeRaisedEvent = parseAbiItem(
  'event DisputeRaised(uint256 indexed agreementId, address indexed raisedBy)',
);
const disputeResolvedEvent = parseAbiItem(
  'event DisputeResolved(uint256 indexed agreementId, bool paidToLicensor, uint256 amount)',
);
const agreementCancelledEvent = parseAbiItem(
  'event AgreementCancelled(uint256 indexed agreementId)',
);

type TimelineItem = {
  key: string;
  blockNumber: bigint;
  logIndex: number;
  title: string;
  detail: string;
  transactionHash: `0x${string}`;
  timestamp?: bigint;
};

function parsePositiveInteger(value: string): bigint | undefined {
  const normalized = value.trim();
  if (!/^\d+$/.test(normalized)) return undefined;

  const parsed = BigInt(normalized);
  return parsed > 0n ? parsed : undefined;
}

function statusName(value: number): string {
  return agreementStatuses[value] ?? `Unknown (${value})`;
}

function shortAddress(value: string): string {
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function formatTimestamp(value?: bigint): string {
  if (value === undefined) return 'Timestamp unavailable';
  return new Date(Number(value) * 1000).toLocaleString();
}

export default function EventTimeline() {
  const publicClient = usePublicClient();
  const [agreementIdInput, setAgreementIdInput] = useState('1');
  const [lookbackInput, setLookbackInput] = useState('10000');
  const [items, setItems] = useState<TimelineItem[]>([]);
  const [status, setStatus] = useState('Enter an agreement ID and load its onchain history.');
  const [isLoading, setIsLoading] = useState(false);

  async function loadTimeline() {
    const agreementId = parsePositiveInteger(agreementIdInput);
    const lookback = parsePositiveInteger(lookbackInput);
    const address = contractAddresses.licenseEscrow;

    if (!publicClient) {
      setStatus('Wallet client is not ready. Check the selected network.');
      return;
    }
    if (!address) {
      setStatus('LicenseEscrow address is missing from frontend/.env.');
      return;
    }
    if (!agreementId) {
      setStatus('Agreement ID must be a positive integer.');
      return;
    }
    if (!lookback) {
      setStatus('Lookback blocks must be a positive integer.');
      return;
    }

    setIsLoading(true);
    setStatus('Reading LicenseEscrow events...');

    try {
      const latestBlock = await publicClient.getBlockNumber();
      const fromBlock = latestBlock > lookback ? latestBlock - lookback : 0n;

      const [createdLogs, statusLogs, fundedLogs, confirmedLogs, releasedLogs, raisedLogs, resolvedLogs, cancelledLogs] =
        await Promise.all([
          publicClient.getLogs({ address, event: agreementCreatedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: statusChangedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: fundedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: performanceConfirmedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: fundsReleasedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: disputeRaisedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: disputeResolvedEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
          publicClient.getLogs({ address, event: agreementCancelledEvent, args: { agreementId }, fromBlock, toBlock: 'latest' }),
        ]);

      const timeline: TimelineItem[] = [];

      for (const log of createdLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Agreement Created',
          detail: `Asset #${log.args.assetId ?? 0n}; ${formatEther(log.args.licenseFee ?? 0n)} ETH fee; licensee ${shortAddress(log.args.licensee ?? '0x0000000000000000000000000000000000000000')}.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of statusLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Status Changed',
          detail: `${statusName(log.args.from ?? 0)} to ${statusName(log.args.to ?? 0)}.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of fundedLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Escrow Funded',
          detail: `${shortAddress(log.args.licensee ?? '0x0000000000000000000000000000000000000000')} deposited ${formatEther(log.args.amount ?? 0n)} ETH.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of confirmedLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Performance Confirmed',
          detail: `Licensor ${shortAddress(log.args.licensor ?? '0x0000000000000000000000000000000000000000')} confirmed performance.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of releasedLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Funds Released',
          detail: `${formatEther(log.args.amount ?? 0n)} ETH paid to ${shortAddress(log.args.to ?? '0x0000000000000000000000000000000000000000')}.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of raisedLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Dispute Raised',
          detail: `Raised by ${shortAddress(log.args.raisedBy ?? '0x0000000000000000000000000000000000000000')}.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of resolvedLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Dispute Resolved',
          detail: `${formatEther(log.args.amount ?? 0n)} ETH ${log.args.paidToLicensor ? 'paid to the licensor' : 'refunded to the licensee'}.`,
          transactionHash: log.transactionHash,
        });
      }
      for (const log of cancelledLogs) {
        timeline.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex,
          title: 'Agreement Cancelled',
          detail: 'The licensor cancelled the agreement before funding.',
          transactionHash: log.transactionHash,
        });
      }

      timeline.sort((left, right) => {
        if (left.blockNumber === right.blockNumber) return left.logIndex - right.logIndex;
        return left.blockNumber < right.blockNumber ? -1 : 1;
      });

      const uniqueBlocks = [...new Set(timeline.map((item) => item.blockNumber))];
      const blockEntries = await Promise.all(
        uniqueBlocks.map(async (blockNumber) => {
          const block = await publicClient.getBlock({ blockNumber });
          return [blockNumber.toString(), block.timestamp] as const;
        }),
      );
      const timestamps = new Map(blockEntries);

      setItems(timeline.map((item) => ({
        ...item,
        timestamp: timestamps.get(item.blockNumber.toString()),
      })));
      setStatus(
        timeline.length > 0
          ? `Loaded ${timeline.length} event(s) from block ${fromBlock} to ${latestBlock}.`
          : `No events found in the last ${lookback} blocks. Increase the lookback if the agreement is older.`,
      );
    } catch (error) {
      setItems([]);
      setStatus(`Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <section className="card read-dashboard">
      <div className="section-heading">
        <p className="eyebrow dark">Onchain Event Timeline</p>
        <h2>Agreement history</h2>
        <p className="hint">
          Reads verified LicenseEscrow logs directly from the selected network. No backend indexer or mock history is used.
        </p>
      </div>

      <div className="read-inputs">
        <label>
          Agreement ID
          <input value={agreementIdInput} onChange={(event) => setAgreementIdInput(event.target.value)} placeholder="1" />
        </label>
        <label>
          Lookback blocks
          <input value={lookbackInput} onChange={(event) => setLookbackInput(event.target.value)} placeholder="10000" />
        </label>
        <button type="button" disabled={isLoading} onClick={() => void loadTimeline()}>
          {isLoading ? 'Loading events...' : 'Load timeline'}
        </button>
      </div>

      <p className="hint">{status}</p>

      <div className="read-grid">
        {items.map((item) => (
          <article className="data-block" key={item.key}>
            <h3>{item.title}</h3>
            <p>{item.detail}</p>
            <p className="hint">{formatTimestamp(item.timestamp)} · Block {item.blockNumber.toString()}</p>
            <code>{item.transactionHash}</code>
          </article>
        ))}
      </div>
    </section>
  );
}
