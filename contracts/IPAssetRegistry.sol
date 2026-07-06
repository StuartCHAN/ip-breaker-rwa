// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @title IPAssetRegistry
/// @notice Registers offchain intellectual property assets as onchain NFT-based passports.
/// @dev The IP Asset NFT is an onchain index and evidence container.
///      It does not by itself transfer legal ownership of the underlying IP.
contract IPAssetRegistry is ERC721, Ownable, IIPAssetRegistry {
    struct IPAsset {
        string title;
        string assetType;
        string jurisdiction;
        bytes32 documentHash;
        string metadataURI;
        uint256 createdAt;
    }

    error EmptyTitle();
    error EmptyAssetType();
    error EmptyJurisdiction();
    error ZeroDocumentHash();
    error EmptyMetadataURI();
    error AssetDoesNotExist(uint256 assetId);

    event IPAssetRegistered(
        uint256 indexed assetId,
        address indexed owner,
        string title,
        string assetType,
        bytes32 documentHash,
        string metadataURI
    );

    uint256 private _nextAssetId = 1;

    mapping(uint256 assetId => IPAsset asset) private _assets;

    constructor() ERC721("IP Breaker Asset", "IPBA") Ownable(msg.sender) {}

    /// @notice Registers an IP asset and mints an IP Asset NFT to the caller.
    /// @param title Human-readable asset title.
    /// @param assetType Asset category, e.g. PATENT, SOFTWARE, DATASET, AI_MODEL.
    /// @param jurisdiction Jurisdiction or target legal region, e.g. US, CN, EU.
    /// @param documentHash Hash of the core offchain document or evidence bundle.
    /// @param metadataURI URI for NFT metadata, usually ipfs://...
    /// @return assetId Newly created asset ID.
    function registerAsset(
        string calldata title,
        string calldata assetType,
        string calldata jurisdiction,
        bytes32 documentHash,
        string calldata metadataURI
    ) external returns (uint256 assetId) {
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(assetType).length == 0) revert EmptyAssetType();
        if (bytes(jurisdiction).length == 0) revert EmptyJurisdiction();
        if (documentHash == bytes32(0)) revert ZeroDocumentHash();
        if (bytes(metadataURI).length == 0) revert EmptyMetadataURI();

        assetId = _nextAssetId++;

        _assets[assetId] = IPAsset({
            title: title,
            assetType: assetType,
            jurisdiction: jurisdiction,
            documentHash: documentHash,
            metadataURI: metadataURI,
            createdAt: block.timestamp
        });

        emit IPAssetRegistered(assetId, msg.sender, title, assetType, documentHash, metadataURI);

        _safeMint(msg.sender, assetId);
    }

    /// @notice Returns the stored IP asset metadata.
    function getAsset(uint256 assetId) external view returns (IPAsset memory asset) {
        if (!exists(assetId)) revert AssetDoesNotExist(assetId);
        return _assets[assetId];
    }

    /// @notice Returns the metadata URI associated with an IP Asset NFT.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!exists(tokenId)) revert AssetDoesNotExist(tokenId);
        return _assets[tokenId].metadataURI;
    }

    ///这里debugged过了：里面 ERC721 已经有一个 ownerOf(uint256)，而 IIPAssetRegistry 也声明了一个同名 ownerOf(uint256)。Solidity 要求我们显式 override 一下。
    /// @notice Returns the owner of an IP Asset NFT.
    /// @dev Explicit override required because both ERC721 and IIPAssetRegistry define ownerOf.
    function ownerOf(uint256 tokenId) public view override(ERC721, IIPAssetRegistry) returns (address) {
        return super.ownerOf(tokenId);
    }

    /// @notice Checks whether an IP Asset NFT has been minted.
    function exists(uint256 assetId) public view returns (bool) {
        return _ownerOf(assetId) != address(0);
    }

    /// @notice Returns the next asset ID that will be assigned.
    function nextAssetId() external view returns (uint256) {
        return _nextAssetId;
    }
}
