// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AllocationEscrow} from "../contracts/AllocationEscrow.sol";
import {EvidenceRegistry} from "../contracts/EvidenceRegistry.sol";
import {IdentityRegistry} from "../contracts/IdentityRegistry.sol";
import {IPAssetRegistry} from "../contracts/IPAssetRegistry.sol";
import {LicenseEscrow} from "../contracts/LicenseEscrow.sol";
import {LicenseRevenueToken} from "../contracts/LicenseRevenueToken.sol";
import {OfferingEscrow} from "../contracts/OfferingEscrow.sol";
import {OfferingManager} from "../contracts/OfferingManager.sol";
import {RecoveryManager} from "../contracts/RecoveryManager.sol";
import {RevenueProgramRegistry} from "../contracts/RevenueProgramRegistry.sol";
import {RevenueVault} from "../contracts/RevenueVault.sol";
import {IInvestorEligibility} from "../contracts/interfaces/IInvestorEligibility.sol";
import {IRevenueProgramRegistry} from "../contracts/interfaces/IRevenueProgramRegistry.sol";

/// @notice Testnet-only six-decimal settlement asset used by the full-protocol deployment script.
/// @dev Replace this contract with a production settlement asset before a production deployment.
contract DemoUSDC6 is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e6;

    constructor(address admin_) ERC20("IP Breaker Demo USD Coin", "dUSDC") Ownable(admin_) {
        _mint(admin_, INITIAL_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

/// @notice Testnet issuer allowlist satisfying OfferingManager's issuer-verification boundary.
contract DemoIssuerEligibility is Ownable {
    mapping(address issuer => bool eligible) public isEligibleIssuer;

    event IssuerEligibilityUpdated(address indexed issuer, bool eligible);

    constructor(address admin_) Ownable(admin_) {}

    function setEligibleIssuer(address issuer, bool eligible) external onlyOwner {
        isEligibleIssuer[issuer] = eligible;
        emit IssuerEligibilityUpdated(issuer, eligible);
    }
}

/// @notice Testnet investor policy combining identity status with an asset-specific allowlist.
/// @dev Protocol custody accounts are explicitly allowlisted so primary minting can enter AllocationEscrow.
contract DemoInvestorEligibility is IInvestorEligibility, Ownable {
    IdentityRegistry public immutable identityRegistry;

    mapping(uint256 assetId => mapping(address account => bool eligible)) public investorEligible;
    mapping(address account => bool allowed) public protocolCustodian;

    event InvestorEligibilityUpdated(uint256 indexed assetId, address indexed account, bool eligible);
    event ProtocolCustodianUpdated(address indexed account, bool allowed);

    constructor(address identityRegistry_, address admin_) Ownable(admin_) {
        require(identityRegistry_ != address(0), "zero identity registry");
        identityRegistry = IdentityRegistry(identityRegistry_);
    }

    function setInvestorEligible(uint256 assetId, address account, bool eligible) external onlyOwner {
        investorEligible[assetId][account] = eligible;
        emit InvestorEligibilityUpdated(assetId, account, eligible);
    }

    function setProtocolCustodian(address account, bool allowed) external onlyOwner {
        protocolCustodian[account] = allowed;
        emit ProtocolCustodianUpdated(account, allowed);
    }

    function canHold(address account, uint256 assetId) external view returns (bool) {
        if (protocolCustodian[account]) return true;
        if (!investorEligible[assetId][account]) return false;
        return identityRegistry.hasBusinessRole(account, identityRegistry.ROLE_INVESTOR());
    }
}

/// @title DeployFullProtocol
/// @notice Deploys a complete, internally bound IP Breaker RWA testnet bundle and creates one Draft offering.
/// @dev Token-to-Vault/Recovery/AllocationEscrow bindings are intentionally performed later by
///      OfferingManager.openOffering(), where the bindings, mint, custody deposit and status transition
///      can succeed or revert atomically.
contract DeployFullProtocol is Script {
    uint256 private constant FINAL_SUPPLY = 10_000 ether;
    uint256 private constant ALLOCATION_LOT = 100 ether;
    uint256 private constant PRICE_PER_WHOLE_TOKEN_USDC = 1e6;
    uint16 private constant PROTOCOL_FEE_BPS = 250;
    uint256 private constant RECOVERY_CHALLENGE_PERIOD = 1 days;
    uint256 private constant RECOVERY_EXECUTION_WINDOW = 2 days;
    uint256 private constant OPEN_DELAY = 1 hours;
    uint256 private constant OFFERING_DURATION = 7 days;

    struct Deployment {
        IdentityRegistry identityRegistry;
        IPAssetRegistry assetRegistry;
        EvidenceRegistry evidenceRegistry;
        LicenseEscrow licenseEscrow;
        DemoIssuerEligibility issuerEligibility;
        DemoInvestorEligibility investorEligibility;
        DemoUSDC6 settlementToken;
        RevenueProgramRegistry programRegistry;
        RecoveryManager recoveryManager;
        OfferingManager offeringManager;
        LicenseRevenueToken revenueToken;
        RevenueVault revenueVault;
        AllocationEscrow allocationEscrow;
        OfferingEscrow offeringEscrow;
        address legalHoldEscrow;
        uint256 assetId;
        bytes32 offeringId;
        uint64 opensAt;
        uint64 closesAt;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        Deployment memory deployment = _deployFoundation(deployer);
        deployment = _deployOfferingBundle(deployment, deployer);
        vm.stopBroadcast();

        _verifyDeployment(deployment, deployer);
        _logDeployment(deployment, deployer);
    }

    function _deployFoundation(address deployer) private returns (Deployment memory deployment) {
        deployment.identityRegistry = new IdentityRegistry();
        deployment.identityRegistry.grantVerifierRole(deployer);

        uint256 identityRoles = deployment.identityRegistry.ROLE_ASSET_OWNER()
            | deployment.identityRegistry.ROLE_LICENSEE() | deployment.identityRegistry.ROLE_INVESTOR();
        deployment.identityRegistry.registerIdentity("ipfs://ip-breaker/deployer-identity", identityRoles);
        deployment.identityRegistry.verifyIdentity(deployer, identityRoles, 0);

        deployment.assetRegistry = new IPAssetRegistry(address(deployment.identityRegistry));
        deployment.evidenceRegistry =
            new EvidenceRegistry(address(deployment.assetRegistry), address(deployment.identityRegistry));
        deployment.licenseEscrow =
            new LicenseEscrow(address(deployment.assetRegistry), address(deployment.identityRegistry));

        deployment.assetId = deployment.assetRegistry.registerAsset(
            "IP Breaker RWA Demonstration Asset",
            "SOFTWARE_IP",
            "GLOBAL",
            keccak256(bytes("IP Breaker RWA demonstration asset document v1")),
            "ipfs://ip-breaker/demo-asset-metadata"
        );

        deployment.issuerEligibility = new DemoIssuerEligibility(deployer);
        deployment.issuerEligibility.setEligibleIssuer(deployer, true);

        deployment.investorEligibility =
            new DemoInvestorEligibility(address(deployment.identityRegistry), deployer);
        deployment.investorEligibility.setInvestorEligible(deployment.assetId, deployer, true);

        deployment.settlementToken = new DemoUSDC6(deployer);
        deployment.programRegistry = new RevenueProgramRegistry(deployer);
        deployment.recoveryManager =
            new RecoveryManager(deployer, RECOVERY_CHALLENGE_PERIOD, RECOVERY_EXECUTION_WINDOW);

        deployment.offeringManager = new OfferingManager(
            deployer,
            address(deployment.identityRegistry),
            address(deployment.assetRegistry),
            address(deployment.issuerEligibility),
            address(deployment.programRegistry)
        );

        deployment.programRegistry.grantRole(
            deployment.programRegistry.PROGRAM_MANAGER_ROLE(), address(deployment.offeringManager)
        );
        deployment.offeringManager.grantRole(deployment.offeringManager.OFFERING_OPERATOR_ROLE(), deployer);

        deployment.recoveryManager.grantRole(deployment.recoveryManager.RECOVERY_REQUESTER_ROLE(), deployer);
        deployment.recoveryManager.grantRole(deployment.recoveryManager.IDENTITY_VERIFIER_ROLE(), deployer);
        deployment.recoveryManager.grantRole(deployment.recoveryManager.RECOVERY_APPROVER_ROLE(), deployer);
        deployment.recoveryManager.grantRole(deployment.recoveryManager.RECOVERY_EXECUTOR_ROLE(), deployer);
        deployment.recoveryManager.grantRole(deployment.recoveryManager.RECOVERY_GUARDIAN_ROLE(), deployer);
    }

    function _deployOfferingBundle(Deployment memory deployment, address deployer)
        private
        returns (Deployment memory)
    {
        bytes32 termsHash = keccak256(bytes("IP Breaker RWA offering terms v1"));
        bytes32 disclosureHash = keccak256(bytes("IP Breaker RWA risk disclosure v1"));
        uint256 creatorNonce = deployment.offeringManager.creatorNonce(deployer);

        deployment.offeringId = _deriveOfferingId(
            address(deployment.offeringManager),
            address(deployment.assetRegistry),
            deployment.assetId,
            deployer,
            deployer,
            creatorNonce,
            termsHash
        );

        deployment.revenueToken = new LicenseRevenueToken(
            "IP Breaker License Revenue Token",
            "IPRVT",
            address(deployment.assetRegistry),
            deployment.assetId,
            FINAL_SUPPLY,
            address(deployment.investorEligibility),
            address(deployment.offeringManager)
        );

        deployment.revenueVault = new RevenueVault(
            address(deployment.revenueToken),
            address(deployment.settlementToken),
            deployer,
            deployer,
            address(deployment.offeringManager)
        );

        deployment.allocationEscrow = new AllocationEscrow(
            address(deployment.offeringManager), deployment.offeringId, address(deployment.revenueToken), FINAL_SUPPLY
        );
        deployment.legalHoldEscrow = deployment.allocationEscrow.legalHoldEscrow();
        deployment.investorEligibility.setProtocolCustodian(address(deployment.allocationEscrow), true);

        deployment.offeringEscrow = new OfferingEscrow(
            address(deployment.offeringManager),
            deployment.offeringId,
            address(deployment.settlementToken),
            deployer,
            deployer,
            PROTOCOL_FEE_BPS
        );

        deployment.opensAt = uint64(block.timestamp + OPEN_DELAY);
        deployment.closesAt = uint64(uint256(deployment.opensAt) + OFFERING_DURATION);

        OfferingManager.OfferingConfig memory config;
        config.assetId = deployment.assetId;
        config.issuer = deployer;
        config.issuerTreasury = deployer;
        config.revenueToken = address(deployment.revenueToken);
        config.revenueVault = address(deployment.revenueVault);
        config.allocationEscrow = address(deployment.allocationEscrow);
        config.offeringEscrow = address(deployment.offeringEscrow);
        config.investorEligibility = address(deployment.investorEligibility);
        config.recoveryManager = address(deployment.recoveryManager);
        config.settlementToken = address(deployment.settlementToken);
        config.finalSupply = FINAL_SUPPLY;
        config.allocationLot = ALLOCATION_LOT;
        config.pricePerWholeTokenUSDC = PRICE_PER_WHOLE_TOKEN_USDC;
        config.protocolFeeBps = PROTOCOL_FEE_BPS;
        config.feeRecipient = deployer;
        config.opensAt = deployment.opensAt;
        config.closesAt = deployment.closesAt;
        config.termsHash = termsHash;
        config.disclosureHash = disclosureHash;

        bytes32 actualOfferingId = deployment.offeringManager.createOffering(config);
        require(actualOfferingId == deployment.offeringId, "offering id mismatch");

        return deployment;
    }

    function _deriveOfferingId(
        address offeringManager,
        address assetRegistry,
        uint256 assetId,
        address creator,
        address issuer,
        uint256 creatorNonce,
        bytes32 termsHash
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                offeringManager,
                assetRegistry,
                assetId,
                creator,
                issuer,
                creatorNonce,
                termsHash
            )
        );
    }

    function _verifyDeployment(Deployment memory deployment, address deployer) private view {
        require(deployment.assetRegistry.ownerOf(deployment.assetId) == deployer, "asset owner mismatch");
        require(
            deployment.identityRegistry.hasBusinessRole(
                deployer, deployment.identityRegistry.ROLE_ASSET_OWNER()
            ),
            "asset-owner identity missing"
        );
        require(deployment.issuerEligibility.isEligibleIssuer(deployer), "issuer not eligible");
        require(
            deployment.investorEligibility.canHold(deployer, deployment.assetId), "investor not eligible"
        );

        require(
            deployment.programRegistry.hasRole(
                deployment.programRegistry.PROGRAM_MANAGER_ROLE(), address(deployment.offeringManager)
            ),
            "program-manager role missing"
        );
        require(
            deployment.offeringManager.hasRole(deployment.offeringManager.OFFERING_OPERATOR_ROLE(), deployer),
            "offering-operator role missing"
        );
        require(
            deployment.revenueToken.hasRole(
                deployment.revenueToken.TOKEN_CONTROLLER_ROLE(), address(deployment.offeringManager)
            ),
            "token-controller role missing"
        );

        require(
            deployment.offeringManager.getOfferingStatus(deployment.offeringId)
                == OfferingManager.OfferingStatus.Draft,
            "offering is not draft"
        );
        require(
            deployment.programRegistry.liveOfferingByAsset(deployment.assetId) == deployment.offeringId,
            "live program reservation mismatch"
        );
        IRevenueProgramRegistry.RevenueProgram memory program =
            deployment.programRegistry.getProgram(deployment.offeringId);
        require(
            program.status == IRevenueProgramRegistry.ProgramStatus.Reserved, "program is not reserved"
        );

        require(
            deployment.revenueVault.activationController() == address(deployment.offeringManager),
            "vault activation controller mismatch"
        );
        require(
            address(deployment.revenueVault.revenueToken()) == address(deployment.revenueToken),
            "vault token mismatch"
        );
        require(
            deployment.allocationEscrow.offeringManager() == address(deployment.offeringManager),
            "allocation escrow manager mismatch"
        );
        require(
            deployment.allocationEscrow.offeringId() == deployment.offeringId,
            "allocation escrow offering mismatch"
        );
        require(
            deployment.allocationEscrow.revenueToken() == address(deployment.revenueToken),
            "allocation escrow token mismatch"
        );
        require(deployment.legalHoldEscrow.code.length != 0, "legal-hold escrow not deployed");
        require(
            deployment.offeringEscrow.offeringManager() == address(deployment.offeringManager),
            "offering escrow manager mismatch"
        );
        require(
            deployment.offeringEscrow.offeringId() == deployment.offeringId,
            "offering escrow offering mismatch"
        );
        require(
            deployment.offeringEscrow.settlementToken() == address(deployment.settlementToken),
            "offering escrow settlement mismatch"
        );

        require(address(deployment.revenueToken.revenueVault()) == address(0), "token vault bound too early");
        require(
            address(deployment.revenueToken.recoveryManager()) == address(0),
            "recovery manager bound too early"
        );
        require(
            deployment.revenueToken.primaryDistributionEscrow() == address(0),
            "distribution escrow bound too early"
        );
        require(deployment.revenueToken.totalSupply() == 0, "token supply created too early");
        require(!deployment.allocationEscrow.depositConfirmed(), "token deposit confirmed too early");

        require(
            IERC20(address(deployment.settlementToken)).balanceOf(address(deployment.offeringManager)) == 0,
            "manager holds settlement token"
        );
        require(
            deployment.revenueToken.balanceOf(address(deployment.offeringManager)) == 0,
            "manager holds revenue token"
        );
    }

    function _logDeployment(Deployment memory deployment, address deployer) private view {
        OfferingManager.Offering memory offering = deployment.offeringManager.getOffering(deployment.offeringId);

        console2.log("=== IP Breaker RWA Full Protocol Deployment ===");
        console2.log("Deployer / Admin:", deployer);

        console2.log("--- Core Registries ---");
        console2.log("IdentityRegistry:", address(deployment.identityRegistry));
        console2.log("IPAssetRegistry:", address(deployment.assetRegistry));
        console2.log("EvidenceRegistry:", address(deployment.evidenceRegistry));
        console2.log("LicenseEscrow:", address(deployment.licenseEscrow));
        console2.log("RevenueProgramRegistry:", address(deployment.programRegistry));

        console2.log("--- Compliance and Settlement ---");
        console2.log("IssuerEligibility:", address(deployment.issuerEligibility));
        console2.log("InvestorEligibility:", address(deployment.investorEligibility));
        console2.log("RecoveryManager:", address(deployment.recoveryManager));
        console2.log("DemoUSDC6:", address(deployment.settlementToken));

        console2.log("--- Offering Bundle ---");
        console2.log("OfferingManager:", address(deployment.offeringManager));
        console2.log("LicenseRevenueToken:", address(deployment.revenueToken));
        console2.log("RevenueVault:", address(deployment.revenueVault));
        console2.log("AllocationEscrow:", address(deployment.allocationEscrow));
        console2.log("LegalHoldEscrow:", deployment.legalHoldEscrow);
        console2.log("OfferingEscrow:", address(deployment.offeringEscrow));

        console2.log("--- Offering ---");
        console2.log("Asset ID:", deployment.assetId);
        console2.log("Offering ID:");
        console2.logBytes32(deployment.offeringId);
        console2.log("Status (Draft = 1):", uint256(offering.status));
        console2.log("Final supply:", FINAL_SUPPLY);
        console2.log("Allocation lot:", ALLOCATION_LOT);
        console2.log("Price per whole token (USDC base units):", PRICE_PER_WHOLE_TOKEN_USDC);
        console2.log("Target USDC (base units):", offering.targetUSDC);
        console2.log("Protocol fee (bps):", uint256(PROTOCOL_FEE_BPS));
        console2.log("Opens at:", uint256(deployment.opensAt));
        console2.log("Closes at:", uint256(deployment.closesAt));

        console2.log("Deployment invariants: PASS");
        console2.log("Token bindings and full-supply mint are deferred to openOffering() by design.");
    }
}
