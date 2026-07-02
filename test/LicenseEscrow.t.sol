// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

contract LicenseEscrowTest is Test {
    IPAssetRegistry private assetRegistry;
    LicenseEscrow private licenseEscrow;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";

    bytes32 private constant DOCUMENT_HASH =
        keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    uint256 private constant LICENSE_PRICE = 0.01 ether;
    uint64 private constant LICENSE_DURATION = 365 days;
    bytes32 private constant TERMS_HASH =
        keccak256("commercial internal use, no resale, no sublicensing");
    string private constant TERMS_URI = "ipfs://license-terms-commercial-internal-use";

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

    function setUp() public {
        assetRegistry = new IPAssetRegistry();
        licenseEscrow = new LicenseEscrow(address(assetRegistry));

        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function testConstructorStoresAssetRegistry() public view {
        assertEq(address(licenseEscrow.assetRegistry()), address(assetRegistry));
    }

    function testConstructorRevertsWhenAssetRegistryIsZero() public {
        vm.expectRevert(LicenseEscrow.ZeroAssetRegistry.selector);
        new LicenseEscrow(address(0));
    }

    function testCreateLicenseOfferStoresOffer() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.prank(alice);
        uint256 offerId = licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );

        assertEq(offerId, 1);

        LicenseEscrow.LicenseOffer memory offer = licenseEscrow.getLicenseOffer(offerId);

        assertEq(offer.assetId, assetId);
        assertEq(offer.licensor, alice);
        assertEq(offer.price, LICENSE_PRICE);
        assertEq(offer.duration, LICENSE_DURATION);
        assertEq(offer.termsHash, TERMS_HASH);
        assertEq(offer.termsURI, TERMS_URI);
        assertFalse(offer.transferable);
        assertTrue(offer.active);
        assertEq(offer.createdAt, block.timestamp);
    }

    function testCreateLicenseOfferEmitsEvent() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectEmit(true, true, true, true, address(licenseEscrow));
        emit LicenseOfferCreated(
            1,
            assetId,
            alice,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenAssetDoesNotExist() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.AssetDoesNotExist.selector,
                missingAssetId
            )
        );

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            missingAssetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenCallerIsNotAssetOwner() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.NotAssetOwner.selector,
                assetId,
                bob
            )
        );

        vm.prank(bob);
        licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenPriceIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidPrice.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            assetId,
            0,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenDurationIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.InvalidDuration.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            0,
            TERMS_HASH,
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenTermsHashIsZero() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.ZeroTermsHash.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            bytes32(0),
            TERMS_URI,
            false
        );
    }

    function testCreateLicenseOfferRevertsWhenTermsURIIsEmpty() public {
        uint256 assetId = _registerDefaultAsset(alice);

        vm.expectRevert(LicenseEscrow.EmptyTermsURI.selector);

        vm.prank(alice);
        licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            "",
            false
        );
    }

    function testLicensorCanDeactivateOffer() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.expectEmit(true, false, false, true, address(licenseEscrow));
        emit LicenseOfferStatusUpdated(offerId, false);

        vm.prank(alice);
        licenseEscrow.setLicenseOfferActive(offerId, false);

        LicenseEscrow.LicenseOffer memory offer = licenseEscrow.getLicenseOffer(offerId);
        assertFalse(offer.active);
    }

    function testNonLicensorCannotUpdateOfferStatus() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.NotOfferLicensor.selector,
                offerId,
                bob
            )
        );

        vm.prank(bob);
        licenseEscrow.setLicenseOfferActive(offerId, false);
    }

    function testSetOfferStatusRevertsWhenOfferDoesNotExist() public {
        uint256 missingOfferId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.OfferDoesNotExist.selector,
                missingOfferId
            )
        );

        vm.prank(alice);
        licenseEscrow.setLicenseOfferActive(missingOfferId, false);
    }

    function testBuyLicenseMintsLicenseNFTAndPaysLicensor() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        uint256 aliceBalanceBefore = alice.balance;

        vm.expectEmit(true, true, true, true, address(licenseEscrow));
        emit LicensePurchased(
            offerId,
            1,
            assetId,
            bob,
            alice,
            LICENSE_PRICE,
            block.timestamp,
            block.timestamp + LICENSE_DURATION
        );

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertEq(licenseId, 1);
        assertEq(licenseEscrow.ownerOf(licenseId), bob);
        assertEq(alice.balance, aliceBalanceBefore + LICENSE_PRICE);
        assertEq(licenseEscrow.totalRevenueByAsset(assetId), LICENSE_PRICE);

        LicenseEscrow.License memory licenseData = licenseEscrow.getLicense(licenseId);

        assertEq(licenseData.assetId, assetId);
        assertEq(licenseData.offerId, offerId);
        assertEq(licenseData.licensee, bob);
        assertEq(licenseData.issuedAt, block.timestamp);
        assertEq(licenseData.expiresAt, block.timestamp + LICENSE_DURATION);
        assertEq(licenseData.termsHash, TERMS_HASH);
        assertEq(licenseData.termsURI, TERMS_URI);
        assertFalse(licenseData.transferable);
    }

    function testBuyLicenseCanBeCalledMultipleTimesForSameOffer() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(bob);
        uint256 firstLicenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        vm.prank(carol);
        uint256 secondLicenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertEq(firstLicenseId, 1);
        assertEq(secondLicenseId, 2);
        assertEq(licenseEscrow.ownerOf(firstLicenseId), bob);
        assertEq(licenseEscrow.ownerOf(secondLicenseId), carol);
        assertEq(licenseEscrow.totalRevenueByAsset(assetId), LICENSE_PRICE * 2);
    }

    function testBuyLicenseRevertsWhenOfferDoesNotExist() public {
        uint256 missingOfferId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.OfferDoesNotExist.selector,
                missingOfferId
            )
        );

        vm.prank(bob);
        licenseEscrow.buyLicense{value: LICENSE_PRICE}(missingOfferId);
    }

    function testBuyLicenseRevertsWhenOfferIsInactive() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(alice);
        licenseEscrow.setLicenseOfferActive(offerId, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.OfferNotActive.selector,
                offerId
            )
        );

        vm.prank(bob);
        licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);
    }

    function testBuyLicenseRevertsWhenBuyerIsLicensor() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.deal(alice, 10 ether);

        vm.expectRevert(LicenseEscrow.BuyerIsLicensor.selector);

        vm.prank(alice);
        licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);
    }

    function testBuyLicenseRevertsWhenPaymentIsTooLow() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        uint256 wrongPayment = LICENSE_PRICE - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.IncorrectPayment.selector,
                LICENSE_PRICE,
                wrongPayment
            )
        );

        vm.prank(bob);
        licenseEscrow.buyLicense{value: wrongPayment}(offerId);
    }

    function testBuyLicenseRevertsWhenPaymentIsTooHigh() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        uint256 wrongPayment = LICENSE_PRICE + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.IncorrectPayment.selector,
                LICENSE_PRICE,
                wrongPayment
            )
        );

        vm.prank(bob);
        licenseEscrow.buyLicense{value: wrongPayment}(offerId);
    }

    function testBuyLicenseRevertsWhenLicensorNoLongerOwnsAsset() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(alice);
        assetRegistry.transferFrom(alice, carol, assetId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.LicensorNoLongerAssetOwner.selector,
                assetId,
                alice
            )
        );

        vm.prank(bob);
        licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);
    }

    function testNonTransferableLicenseCannotBeTransferred() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.NonTransferableLicense.selector,
                licenseId
            )
        );

        vm.prank(bob);
        licenseEscrow.transferFrom(bob, carol, licenseId);
    }

    function testTransferableLicenseCanBeTransferred() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, true);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        vm.prank(bob);
        licenseEscrow.transferFrom(bob, carol, licenseId);

        assertEq(licenseEscrow.ownerOf(licenseId), carol);

        LicenseEscrow.License memory licenseData = licenseEscrow.getLicense(licenseId);
        assertEq(licenseData.licensee, carol);
        assertTrue(licenseData.transferable);
    }

    function testTokenURIReturnsTermsURI() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertEq(licenseEscrow.tokenURI(licenseId), TERMS_URI);
    }

    function testTokenURIRevertsWhenLicenseDoesNotExist() public {
        uint256 missingLicenseId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.LicenseDoesNotExist.selector,
                missingLicenseId
            )
        );

        licenseEscrow.tokenURI(missingLicenseId);
    }

    function testGetLicenseRevertsWhenLicenseDoesNotExist() public {
        uint256 missingLicenseId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseEscrow.LicenseDoesNotExist.selector,
                missingLicenseId
            )
        );

        licenseEscrow.getLicense(missingLicenseId);
    }

    function testLicenseIsValidBeforeExpiry() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertTrue(licenseEscrow.isLicenseValid(licenseId));
    }

    function testLicenseIsInvalidAfterExpiry() public {
        uint256 assetId = _registerDefaultAsset(alice);
        uint256 offerId = _createDefaultOffer(alice, assetId, false);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        vm.warp(block.timestamp + LICENSE_DURATION + 1);

        assertFalse(licenseEscrow.isLicenseValid(licenseId));
    }

    function testMissingLicenseIsInvalid() public view {
        assertFalse(licenseEscrow.isLicenseValid(999));
    }

    function testNextOfferIdStartsAtOne() public view {
        assertEq(licenseEscrow.nextOfferId(), 1);
    }

    function testNextLicenseIdStartsAtOne() public view {
        assertEq(licenseEscrow.nextLicenseId(), 1);
    }

    function testNextIdsIncrement() public {
        uint256 assetId = _registerDefaultAsset(alice);

        uint256 offerId = _createDefaultOffer(alice, assetId, false);
        assertEq(licenseEscrow.nextOfferId(), 2);

        vm.prank(bob);
        uint256 licenseId = licenseEscrow.buyLicense{value: LICENSE_PRICE}(offerId);

        assertEq(licenseId, 1);
        assertEq(licenseEscrow.nextLicenseId(), 2);
    }

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = assetRegistry.registerAsset(
            TITLE,
            ASSET_TYPE,
            JURISDICTION,
            DOCUMENT_HASH,
            METADATA_URI
        );
    }

    function _createDefaultOffer(
        address licensor,
        uint256 assetId,
        bool transferable
    ) private returns (uint256 offerId) {
        vm.prank(licensor);
        offerId = licenseEscrow.createLicenseOffer(
            assetId,
            LICENSE_PRICE,
            LICENSE_DURATION,
            TERMS_HASH,
            TERMS_URI,
            transferable
        );
    }
} 
