// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";
import {IInvestorEligibility} from "./interfaces/IInvestorEligibility.sol";

/// @title LicenseRevenueToken
/// @notice Compliance-restricted revenue participation units for one registered IP asset.
/// @dev The token does not represent IP ownership, a license, governance, debt principal,
///      guaranteed yield, or a claim on revenue that has not entered a future RevenueVault.
///      Revenue accounting hooks are intentionally deferred to Phase 3.1-A2.
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

    event LifecycleChanged(Lifecycle indexed previousLifecycle, Lifecycle indexed newLifecycle);
    event TokensRecovered(address indexed from, address indexed to, uint256 amount, address indexed controller);

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

    /// @notice Opens the one-time allocation phase.
    function beginMinting() external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (lifecycle != Lifecycle.Created) revert InvalidLifecycle(lifecycle, Lifecycle.Created);
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

    /// @notice Moves tokens from an inaccessible/ineligible account without changing supply.
    /// @dev This is the only A1 recovery path. Phase 3.1-A2 must add RevenueVault checkpoints
    ///      to this path before revenue accounting is activated.
    function recoverTokens(address from, address to, uint256 amount) external onlyRole(TOKEN_CONTROLLER_ROLE) {
        if (from == address(0)) revert InvalidRecoveryAccount(from);
        if (to == address(0) || to == from) revert InvalidRecoveryAccount(to);
        if (!_canHold(to)) revert IneligibleInvestor(to);

        uint256 supplyBefore = totalSupply();

        // Deliberately bypasses ordinary sender eligibility and transfer-state checks.
        // Receiver eligibility and controller authority are checked above.
        super._update(from, to, amount);

        assert(totalSupply() == supplyBefore);
        emit TokensRecovered(from, to, amount, msg.sender);
    }

    /// @dev Single extension point for mint and ordinary token movements. Phase 3.1-A2 adds
    ///      RevenueVault checkpoints here before `super._update`.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0)) {
            if (lifecycle != Lifecycle.Minting) revert InvalidLifecycle(lifecycle, Lifecycle.Minting);
            if (!_canHold(to)) revert IneligibleInvestor(to);
        } else if (to == address(0)) {
            revert ArbitraryBurnDisabled();
        } else {
            if (lifecycle != Lifecycle.Activated) revert TransfersNotActive();
            if (!_canHold(from)) revert IneligibleInvestor(from);
            if (!_canHold(to)) revert IneligibleInvestor(to);
        }

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
