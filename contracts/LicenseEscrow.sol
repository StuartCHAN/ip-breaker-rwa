// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @title LicenseEscrow
/// @notice Creates license offers for registered IP assets and mints license certificate NFTs.
/// @dev The License Certificate NFT represents a usage-right certificate,
///      not an investment product or fractional ownership of the underlying IP.
contract LicenseEscrow is ERC721, Ownable, ReentrancyGuard {
    struct LicenseOffer {
        uint256 assetId;
        address licensor;
        uint256 price;
        uint64 duration;
        bytes32 termsHash;
        string termsURI;
        bool transferable;
        bool active;
        uint256 createdAt;
    }

    struct License {
        uint256 assetId;
        uint256 offerId;
        address licensee;
        uint256 issuedAt;
        uint256 expiresAt;
        bytes32 termsHash;
        string termsURI;
        bool transferable;
    }

    error ZeroAssetRegistry();
    error AssetDoesNotExist(uint256 assetId);
    error NotAssetOwner(uint256 assetId, address caller);
    error OfferDoesNotExist(uint256 offerId);
    error NotOfferLicensor(uint256 offerId, address caller);
    error OfferNotActive(uint256 offerId);
    error LicensorNoLongerAssetOwner(uint256 assetId, address licensor);
    error InvalidPrice();
    error InvalidDuration();
    error ZeroTermsHash();
    error EmptyTermsURI();
    error BuyerIsLicensor();
    error IncorrectPayment(uint256 expected, uint256 actual);
    error PaymentTransferFailed();
    error LicenseDoesNotExist(uint256 licenseId);
    error NonTransferableLicense(uint256 licenseId);

    event LicenseOfferCreated(
        uint256 indexed offerId,
        uint256 indexed assetId,
        address indexed licensor,
        uint256 price,
        uint64 duration,
        bytes32 termsHash,
        string termsURI,
        bool transferable
    );

    event LicenseOfferStatusUpdated(
        uint256 indexed offerId,
        bool active
    );

    event LicensePurchased(
        uint256 indexed offerId,
        uint256 indexed licenseId,
        uint256 indexed assetId,
        address licensee,
        address licensor,
        uint256 price,
        uint256 issuedAt,
        uint256 expiresAt
    );

    IIPAssetRegistry public immutable assetRegistry;

    uint256 private _nextOfferId = 1;
    uint256 private _nextLicenseId = 1;

    mapping(uint256 offerId => LicenseOffer offer) public licenseOffers;
    mapping(uint256 licenseId => License licenseData) public licenses;
    mapping(uint256 assetId => uint256 totalRevenue) public totalRevenueByAsset;

    constructor(address assetRegistry_) ERC721("IP Breaker License", "IPBL") Ownable(msg.sender) {
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        assetRegistry = IIPAssetRegistry(assetRegistry_);
    }

    /// @notice Creates a license offer for an existing IP asset.
    /// @dev Only the current owner of the IP Asset NFT can create a license offer.
    function createLicenseOffer(
        uint256 assetId,
        uint256 price,
        uint64 duration,
        bytes32 termsHash,
        string calldata termsURI,
        bool transferable
    ) external returns (uint256 offerId) {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        if (assetRegistry.ownerOf(assetId) != msg.sender) {
            revert NotAssetOwner(assetId, msg.sender);
        }
        if (price == 0) revert InvalidPrice();
        if (duration == 0) revert InvalidDuration();
        if (termsHash == bytes32(0)) revert ZeroTermsHash();
        if (bytes(termsURI).length == 0) revert EmptyTermsURI();

        offerId = _nextOfferId++;

        licenseOffers[offerId] = LicenseOffer({
            assetId: assetId,
            licensor: msg.sender,
            price: price,
            duration: duration,
            termsHash: termsHash,
            termsURI: termsURI,
            transferable: transferable,
            active: true,
            createdAt: block.timestamp
        });

        emit LicenseOfferCreated(
            offerId,
            assetId,
            msg.sender,
            price,
            duration,
            termsHash,
            termsURI,
            transferable
        );
    }

    /// @notice Activates or deactivates a license offer.
    /// @dev Only the original licensor can update offer status.
    function setLicenseOfferActive(uint256 offerId, bool active) external {
        LicenseOffer storage offer = _getExistingOffer(offerId);

        if (msg.sender != offer.licensor) {
            revert NotOfferLicensor(offerId, msg.sender);
        }

        offer.active = active;

        emit LicenseOfferStatusUpdated(offerId, active);
    }

    /// @notice Buys a license and mints a License Certificate NFT to the buyer.
    /// @dev The offer may be bought multiple times while active.
    function buyLicense(uint256 offerId) external payable nonReentrant returns (uint256 licenseId) {
        LicenseOffer memory offer = _getExistingOffer(offerId);

        if (!offer.active) revert OfferNotActive(offerId);
        if (msg.sender == offer.licensor) revert BuyerIsLicensor();
        if (msg.value != offer.price) {
            revert IncorrectPayment(offer.price, msg.value);
        }

        // Prevent stale offers from being sold after the IP Asset NFT changes hands.
        if (assetRegistry.ownerOf(offer.assetId) != offer.licensor) {
            revert LicensorNoLongerAssetOwner(offer.assetId, offer.licensor);
        }

        licenseId = _nextLicenseId++;

        uint256 issuedAt = block.timestamp;
        uint256 expiresAt = issuedAt + uint256(offer.duration);

        licenses[licenseId] = License({
            assetId: offer.assetId,
            offerId: offerId,
            licensee: msg.sender,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            termsHash: offer.termsHash,
            termsURI: offer.termsURI,
            transferable: offer.transferable
        });

        totalRevenueByAsset[offer.assetId] += msg.value;

        _safeMint(msg.sender, licenseId);

        (bool success, ) = payable(offer.licensor).call{value: msg.value}("");
        if (!success) revert PaymentTransferFailed();

        emit LicensePurchased(
            offerId,
            licenseId,
            offer.assetId,
            msg.sender,
            offer.licensor,
            msg.value,
            issuedAt,
            expiresAt
        );
    }

    /// @notice Returns a license offer by ID.
    function getLicenseOffer(uint256 offerId) external view returns (LicenseOffer memory offer) {
        return _getExistingOffer(offerId);
    }

    /// @notice Returns a license certificate by ID.
    function getLicense(uint256 licenseId) external view returns (License memory licenseData) {
        if (!licenseExists(licenseId)) revert LicenseDoesNotExist(licenseId);
        return licenses[licenseId];
    }

    /// @notice Returns whether a license NFT exists.
    function licenseExists(uint256 licenseId) public view returns (bool) {
        return _ownerOf(licenseId) != address(0);
    }

    /// @notice Returns whether a license is currently within its duration.
    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        if (!licenseExists(licenseId)) return false;
        return block.timestamp <= licenses[licenseId].expiresAt;
    }

    /// @notice Returns the metadata URI associated with a License Certificate NFT.
    /// @dev For v0.1, this points to the offchain license terms URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!licenseExists(tokenId)) revert LicenseDoesNotExist(tokenId);
        return licenses[tokenId].termsURI;
    }

    /// @notice Returns the next license offer ID that will be assigned.
    function nextOfferId() external view returns (uint256) {
        return _nextOfferId;
    }

    /// @notice Returns the next license certificate ID that will be assigned.
    function nextLicenseId() external view returns (uint256) {
        return _nextLicenseId;
    }

    /// @dev Restricts transfer of non-transferable license certificate NFTs.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address previousOwner) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            if (!licenses[tokenId].transferable) {
                revert NonTransferableLicense(tokenId);
            }
        }

        previousOwner = super._update(to, tokenId, auth);

        if (from != address(0) && to != address(0)) {
            licenses[tokenId].licensee = to;
        }
    }

    function _getExistingOffer(uint256 offerId) internal view returns (LicenseOffer storage offer) {
        if (offerId == 0 || offerId >= _nextOfferId) {
            revert OfferDoesNotExist(offerId);
        }

        offer = licenseOffers[offerId];
    }
} 
