// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";

/// @title Deploy
/// @notice Deploys the core IP Breaker RWA v0.1 contracts.
contract Deploy is Script {
    function run()
        external
        returns (IPAssetRegistry assetRegistry, EvidenceRegistry evidenceRegistry, LicenseEscrow licenseEscrow)
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        assetRegistry = new IPAssetRegistry();
        evidenceRegistry = new EvidenceRegistry(address(assetRegistry));
        licenseEscrow = new LicenseEscrow(address(assetRegistry));

        vm.stopBroadcast();

        console2.log("IP Breaker RWA v0.1 deployed");
        console2.log("IPAssetRegistry:", address(assetRegistry));
        console2.log("EvidenceRegistry:", address(evidenceRegistry));
        console2.log("LicenseEscrow:", address(licenseEscrow));
        console2.log("Deployer / Admin:", vm.addr(deployerPrivateKey));
    }
}
