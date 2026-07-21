// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";
import {IInvestorEligibility} from "./interfaces/IInvestorEligibility.sol";
import {IRecoveryManager} from "./interfaces/IRecoveryManager.sol";
import {IRevenueVault} from "./interfaces/IRevenueVault.sol";

/// @title LicenseRevenueToken
/// @notice Compliance-restricted revenue participation units for one registered IP asset.
/// @dev The token does not represent IP ownership, a license, governance, debt principal,
///      guaranteed yield, or a claim on revenue that has not entered its RevenueVault.
contract LicenseRevenueToken is ERC20, AccessControl {
    enum Lifecycle {
        Created,
        Minting,
        Activated
    }

    bytes32 public constant TOKEN_CONTROLLER_ROLE = keccak256("TOKEN_CONTROLLER");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");

    IIPAssetRegistry public immutable ipAssetRegistry;
    IInvestorEligibility public immutable eligibilityPolicy;
    uint256 public immutable assetId;
    uint256 public immutable finalSupply;

    Lifecycle public lifecycle;
    IRevenueVault public revenueVault;
    IRecoveryManager public recoveryManager;

    mapping(bytes32 recoveryId => bool executed) public executedRecovery;

    bool private _recoveryInProgress;
    bool private _checkpointInProgress;

    error ZeroIPAssetRegistry();
    error ZeroEligibilityPolicy();
    error ZeroController();
    error InvalidFinalSupply();
    error AssetDoesNotExist(uint256 assetId);
    error InvalidLifecycle(Lifecycle current, Lifecycle required);
    error SupplyCapExceeded(uint256 requestedSupply, uint256 finalSupply);
    error FinalSupplyNotReached(uint256 currentSupply, uint256 finalSupply);
    error IneligibleInvestor(address account);
    error TransfersNotActive();
    error ArbitraryBurnDisabled();
    error InvalidRecoveryAccount(address account);
    error ZeroRevenueVault();
    error RevenueVaultAlreadyBound(address vault);
    error RevenueVaultNotBound();
    error RevenueVaultTokenMismatch(address expectedToken, address actualToken);
    error ReentrantCheckpoint();
    error ZeroRecoveryBalance(address account);
    error ZeroRecoveryManager();
    error RecoveryManagerAlreadyBound(address manager);
    error RecoveryManagerNotBound();
    error OnlyRecoveryManager(address caller);
    error InvalidRecoveryId();
    error RecoveryAlreadyExecuted(bytes32 recoveryId);
    error RecoveryParametersNotAuthorized(bytes32 recoveryId, address source, address destination);

    event LifecycleChanged(Lifecycle indexed previousLifecycle, Lifecycle indexed newLifecycle);
    event RevenueVaultBound(address indexed vault);
    event RecoveryManagerBound(address indexed manager);
    event RecoveryMigrationExecuted(
        bytes32 indexed recoveryId,
        address indexed source,
        address indexed destination,
        uint256 amount,
        address recoveryManager
    );

    constructor(
        string memory name_,
        string memory symbol_,
        address ipAssetRegistry_,
        uint256 assetId_,
        uint256 finalSupply_,
        address eligibilityPolicy_,
        address controller_
    ) ERC20(name_, symbol_) {
        if (ipAssetRegistry_ == address(0)) revert ZeroIPAssetRegistry();
        if (eligibilityPolicy_ == address(0)) revert ZeroEligibilityPolicy();
        if (controller_ == address(0)) revert ZeroController();
        if (finalSupply_ == 0) revert InvalidFinalSupply();

        IIPAssetRegistry registry = IIPAssetRegistry(ipAssetRegistry_);
        if (!registry.exists(assetId_)) revert AssetDoesNotExist(assetId_);

        ipAssetRegistry = registry;
        assetId = assetId_;
        finalSupply = finalSupply_;
        eligibilityPolicy = IInvestorEligibility(eligibilityPolicy_);

        _grantRole(DEFAULT_ADMIN_ROLE, controller_);
        _grantRole(TOKEN_CONTROLLER_ROLE, controller_);
        _setRoleAdmin(MINTER_ROLE, TOKEN_CONTROLLER_ROLE);
    }

    /// @notice Permanently binds the token to its reward-accounting vault before allocation.
    function bindRevenueVault(address vault_) external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (lifecycle != Lifecycle.Created) revert InvalidLifecycle(lifecycle, Lifecycle.Created);
        if (vault_ == address(0)) revert ZeroRevenueVault();

        address currentVault = address(revenueVault);
        if (currentVault != address(0)) revert RevenueVaultAlreadyBound(currentVault);

        IRevenueVault candidate = IRevenueVault(vault_);
        address boundToken = address(candidate.revenueToken());
        if (boundToken != address(this)) revert RevenueVaultTokenMismatch(address(this), boundToken);

        revenueVault = candidate;
        emit RevenueVaultBound(vault_);
    }

    /// @notice Permanently binds the only contract authorized to execute account recovery.
    function bindRecoveryManager(address manager_) external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (lifecycle != Lifecycle.Created) revert InvalidLifecycle(lifecycle, Lifecycle.Created);
        if (manager_ == address(0)) revert ZeroRecoveryManager();

        address currentManager = address(recoveryManager);
        if (currentManager != address(0)) revert RecoveryManagerAlreadyBound(currentManager);

        recoveryManager = IRecoveryManager(manager_);
        emit RecoveryManagerBound(manager_);
    }

    /// @notice Opens the one-time allocation phase.
    function beginMinting() external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (lifecycle != Lifecycle.Created) revert InvalidLifecycle(lifecycle, Lifecycle.Created);
        if (address(revenueVault) == address(0)) revert RevenueVaultNotBound();
        if (address(recoveryManager) == address(0)) revert RecoveryManagerNotBound();
        _setLifecycle(Lifecycle.Minting);
    }

    /// @notice Mints a disclosed allocation before activation.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (lifecycle != Lifecycle.Minting) revert InvalidLifecycle(lifecycle, Lifecycle.Minting);

        uint256 requestedSupply = totalSupply() + amount;
        if (requestedSupply > finalSupply) revert SupplyCapExceeded(requestedSupply, finalSupply);

        _mint(to, amount);
    }

    /// @notice Permanently freezes minting and enables compliant ordinary transfers.
    function activate() external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (lifecycle != Lifecycle.Minting) revert InvalidLifecycle(lifecycle, Lifecycle.Minting);

        uint256 currentSupply = totalSupply();
        if (currentSupply != finalSupply) revert FinalSupplyNotReached(currentSupply, finalSupply);

        _setLifecycle(Lifecycle.Activated);
    }

    /// @notice Migrates one source account's complete balance under an authorized recovery request.
    function executeRecoveryMigration(bytes32 recoveryId, address source, address destination) external {
        IRecoveryManager manager = recoveryManager;
        if (msg.sender != address(manager)) revert OnlyRecoveryManager(msg.sender);
        if (recoveryId == bytes32(0)) revert InvalidRecoveryId();
        if (executedRecovery[recoveryId]) revert RecoveryAlreadyExecuted(recoveryId);
        if (source == address(0)) revert InvalidRecoveryAccount(source);
        if (destination == address(0) || destination == source) revert InvalidRecoveryAccount(destination);
        if (!_canHold(destination)) revert IneligibleInvestor(destination);
        if (!manager.isExecutionAuthorized(recoveryId, address(this), source, destination)) {
            revert RecoveryParametersNotAuthorized(recoveryId, source, destination);
        }

        uint256 sourceBalance = balanceOf(source);
        if (sourceBalance == 0) revert ZeroRecoveryBalance(source);

        uint256 supplyBefore = totalSupply();
        executedRecovery[recoveryId] = true;

        _recoveryInProgress = true;
        _update(source, destination, sourceBalance);
        _recoveryInProgress = false;

        assert(totalSupply() == supplyBefore);
        emit RecoveryMigrationExecuted(recoveryId, source, destination, sourceBalance, msg.sender);
    }

    /// @dev Single extension point for every token balance movement. The vault settles
    ///      pre-update rewards and records debt for projected post-update balances.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            if (lifecycle != Lifecycle.Minting) revert InvalidLifecycle(lifecycle, Lifecycle.Minting);
            if (!_canHold(to)) revert IneligibleInvestor(to);
        } else if (to == address(0)) {
            revert ArbitraryBurnDisabled();
        } else if (!_recoveryInProgress) {
            if (lifecycle != Lifecycle.Activated) revert TransfersNotActive();
            if (!_canHold(from)) revert IneligibleInvestor(from);
            if (!_canHold(to)) revert IneligibleInvestor(to);
        }

        IRevenueVault vault = revenueVault;
        if (address(vault) == address(0)) revert RevenueVaultNotBound();

        if (_checkpointInProgress) revert ReentrantCheckpoint();
        _checkpointInProgress = true;
        if (_recoveryInProgress) {
            vault.checkpointRecovery(from, to, value);
        } else {
            vault.checkpointTransfer(from, to, value);
        }
        _checkpointInProgress = false;

        super._update(from, to, value);
    }

    function _canHold(address account) internal view returns (bool) {
        return eligibilityPolicy.canHold(account, assetId);
    }

    function _setLifecycle(Lifecycle newLifecycle) internal {
        Lifecycle previousLifecycle = lifecycle;
        lifecycle = newLifecycle;
        emit LifecycleChanged(previousLifecycle, newLifecycle);
    }
}
