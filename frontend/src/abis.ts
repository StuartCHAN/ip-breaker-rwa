export const ipAssetRegistryAbi = [
  {
    type: 'function',
    name: 'registerAsset',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'title', type: 'string' },
      { name: 'assetType', type: 'string' },
      { name: 'jurisdiction', type: 'string' },
      { name: 'documentHash', type: 'bytes32' },
      { name: 'metadataURI', type: 'string' },
    ],
    outputs: [{ name: 'assetId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'ownerOf',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function',
    name: 'tokenURI',
    stateMutability: 'view',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [{ name: '', type: 'string' }],
  },
] as const;

export const evidenceRegistryAbi = [
  {
    type: 'function',
    name: 'addEvidence',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'assetId', type: 'uint256' },
      { name: 'evidenceType', type: 'string' },
      { name: 'evidenceHash', type: 'bytes32' },
      { name: 'evidenceURI', type: 'string' },
      { name: 'attestationUID', type: 'bytes32' },
    ],
    outputs: [{ name: 'evidenceId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'setReviewer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'reviewer', type: 'address' },
      { name: 'approved', type: 'bool' },
    ],
    outputs: [],
  },
] as const;

export const licenseEscrowAbi = [
  {
    type: 'function',
    name: 'createLicenseOffer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'assetId', type: 'uint256' },
      { name: 'price', type: 'uint256' },
      { name: 'duration', type: 'uint64' },
      { name: 'termsHash', type: 'bytes32' },
      { name: 'termsURI', type: 'string' },
      { name: 'transferable', type: 'bool' },
    ],
    outputs: [{ name: 'offerId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'buyLicense',
    stateMutability: 'payable',
    inputs: [{ name: 'offerId', type: 'uint256' }],
    outputs: [{ name: 'licenseId', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'totalRevenueByAsset',
    stateMutability: 'view',
    inputs: [{ name: 'assetId', type: 'uint256' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const;
