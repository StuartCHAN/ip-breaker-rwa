// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";

contract IPAssetRegistryTest is Test {
    IPAssetRegistry private registry;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    string private constant TITLE = "AI Patent Drafting Assistant";
    string private constant ASSET_TYPE = "SOFTWARE";
    string private constant JURISDICTION = "US / CN";
    string private constant METADATA_URI = "ipfs://metadata-ai-patent-assistant";

    bytes32 private constant DOCUMENT_HASH =
        keccak256("AI Patent Drafting Assistant technical whitepaper v1");

    event IPAssetRegistered(
        uint256 indexed assetId,
        address indexed owner,
        string title,
        string assetType,
        bytes32 documentHash,
        string metadataURI
    );

    function setUp() public {
        registry = new IPAssetRegistry();
    }

    function testRegisterAssetMintsNFTToCaller() public {
        uint256 assetId = _registerDefaultAsset(alice);

        assertEq(assetId, 1);
        assertEq(registry.ownerOf(assetId), alice);
        assertTrue(registry.exists(assetId));
    }

    function testRegisterAssetStoresAssetData() public {
        uint256 assetId = _registerDefaultAsset(alice);

        IPAssetRegistry.IPAsset memory asset = registry.getAsset(assetId);

        assertEq(asset.title, TITLE);
        assertEq(asset.assetType, ASSET_TYPE);
        assertEq(asset.jurisdiction, JURISDICTION);
        assertEq(asset.documentHash, DOCUMENT_HASH);
        assertEq(asset.metadataURI, METADATA_URI);
        assertEq(asset.createdAt, block.timestamp);
    }

    function testRegisterAssetIncrementsAssetIds() public {
        uint256 firstAssetId = _registerDefaultAsset(alice);
        uint256 secondAssetId = _registerDefaultAsset(bob);

        assertEq(firstAssetId, 1);
        assertEq(secondAssetId, 2);

        assertEq(registry.ownerOf(firstAssetId), alice);
        assertEq(registry.ownerOf(secondAssetId), bob);
        assertEq(registry.nextAssetId(), 3);
    }

    function testTokenURIReturnsMetadataURI() public {
        uint256 assetId = _registerDefaultAsset(alice);

        assertEq(registry.tokenURI(assetId), METADATA_URI);
    }

    function testExistsReturnsFalseForMissingAsset() public view {
        assertFalse(registry.exists(999));
    }

    function testGetAssetRevertsForMissingAsset() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPAssetRegistry.AssetDoesNotExist.selector,
                missingAssetId
            )
        );

        registry.getAsset(missingAssetId);
    }

    function testTokenURIRevertsForMissingAsset() public {
        uint256 missingAssetId = 999;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPAssetRegistry.AssetDoesNotExist.selector,
                missingAssetId
            )
        );

        registry.tokenURI(missingAssetId);
    }

    function testRegisterAssetEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit IPAssetRegistered(
            1,
            alice,
            TITLE,
            ASSET_TYPE,
            DOCUMENT_HASH,
            METADATA_URI
        );

        vm.prank(alice);
        registry.registerAsset(
            TITLE,
            ASSET_TYPE,
            JURISDICTION,
            DOCUMENT_HASH,
            METADATA_URI
        );
    }

    function testRegisterAssetRevertsWhenTitleIsEmpty() public {
        vm.expectRevert(IPAssetRegistry.EmptyTitle.selector);

        vm.prank(alice);
        registry.registerAsset(
            "",
            ASSET_TYPE,
            JURISDICTION,
            DOCUMENT_HASH,
            METADATA_URI
        );
    }

    function testRegisterAssetRevertsWhenAssetTypeIsEmpty() public {
        vm.expectRevert(IPAssetRegistry.EmptyAssetType.selector);

        vm.prank(alice);
        registry.registerAsset(
            TITLE,
            "",
            JURISDICTION,
            DOCUMENT_HASH,
            METADATA_URI
        );
    }

    function testRegisterAssetRevertsWhenJurisdictionIsEmpty() public {
        vm.expectRevert(IPAssetRegistry.EmptyJurisdiction.selector);

        vm.prank(alice);
        registry.registerAsset(
            TITLE,
            ASSET_TYPE,
            "",
            DOCUMENT_HASH,
            METADATA_URI
        );
    }

    function testRegisterAssetRevertsWhenDocumentHashIsZero() public {
        vm.expectRevert(IPAssetRegistry.ZeroDocumentHash.selector);

        vm.prank(alice);
        registry.registerAsset(
            TITLE,
            ASSET_TYPE,
            JURISDICTION,
            bytes32(0),
            METADATA_URI
        );
    }

    function testRegisterAssetRevertsWhenMetadataURIIsEmpty() public {
        vm.expectRevert(IPAssetRegistry.EmptyMetadataURI.selector);

        vm.prank(alice);
        registry.registerAsset(
            TITLE,
            ASSET_TYPE,
            JURISDICTION,
            DOCUMENT_HASH,
            ""
        );
    }

    function _registerDefaultAsset(address registrant) private returns (uint256 assetId) {
        vm.prank(registrant);
        assetId = registry.registerAsset(
            TITLE,
            ASSET_TYPE,
            JURISDICTION,
            DOCUMENT_HASH,
            METADATA_URI
        );
    }
} 
