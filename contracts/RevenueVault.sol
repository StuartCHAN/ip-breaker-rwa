// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRevenueVault} from "./interfaces/IRevenueVault.sol";

/// @title RevenueVault
/// @notice Holds and distributes one ERC-20 settlement asset to holders of one revenue token.
/// @dev Recovery-ledger migration remains intentionally deferred after Phase 3.1-B2-A.
contract RevenueVault is AccessControl, ReentrancyGuard, IRevenueVault {
    using SafeERC20 for IERC20;

    bytes32 public constant REVENUE_DEPOSITOR_ROLE = keccak256("REVENUE_DEPOSITOR");
    uint256 public constant ACCUMULATOR_PRECISION = 1e27;

    IERC20 public immutable override revenueToken;
    IERC20 public immutable settlementToken;

    uint256 public accumulatedRewardPerShare;
    uint256 public precisionRemainder;
    uint256 public totalDeposited;
    uint256 public totalClaimed;

    mapping(address account => uint256 debt) public rewardDebt;
    mapping(address account => uint256 reward) public pendingReward;

    error ZeroRevenueToken();
    error ZeroSettlementToken();
    error ZeroAdmin();
    error ZeroDepositor();
    error ZeroDeposit();
    error ZeroRevenueTokenSupply();
    error UnsupportedSettlementTransfer(uint256 requested, uint256 received);
    error NothingToClaim(address account);
    error MissingTransferCheckpoint(address account, uint256 accumulated, uint256 debt);
    error ClaimsExceedDeposits(uint256 claimed, uint256 deposited);
    error VaultInsolvent(uint256 actualBalance, uint256 accountedBalance);
    error OnlyRevenueToken(address caller);
    error InsufficientCheckpointBalance(address account, uint256 balance, uint256 amount);
    error InvalidRecoveryAccounts(address source, address destination);
    error RecoveryRequiresFullBalance(uint256 requested, uint256 available);
    error ZeroRecoveryBalance();

    event RevenueDeposited(
        address indexed depositor, uint256 amount, uint256 accumulatedRewardPerShare, uint256 precisionRemainder
    );
    event RevenueClaimed(address indexed account, uint256 amount, uint256 totalClaimed);
    event TransferCheckpointed(address indexed from, address indexed to, uint256 amount);
    event RevenueStateMigrated(
        address indexed source, address indexed destination, uint256 tokenAmount, uint256 pendingRewardAmount
    );

    constructor(address revenueToken_, address settlementToken_, address admin_, address depositor_) {
        if (revenueToken_ == address(0)) revert ZeroRevenueToken();
        if (settlementToken_ == address(0)) revert ZeroSettlementToken();
        if (admin_ == address(0)) revert ZeroAdmin();
        if (depositor_ == address(0)) revert ZeroDepositor();

        revenueToken = IERC20(revenueToken_);
        settlementToken = IERC20(settlementToken_);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REVENUE_DEPOSITOR_ROLE, depositor_);
    }

    /// @notice Deposits accounted settlement revenue for all current revenue-token shares.
    /// @dev Direct token transfers to this contract are not accounted deposits.
    function depositRevenue(uint256 amount) external onlyRole(REVENUE_DEPOSITOR_ROLE) nonReentrant {
        if (amount == 0) revert ZeroDeposit();

        uint256 supply = revenueToken.totalSupply();
        if (supply == 0) revert ZeroRevenueTokenSupply();

        uint256 balanceBefore = settlementToken.balanceOf(address(this));
        settlementToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = settlementToken.balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore;
        if (received != amount) revert UnsupportedSettlementTransfer(amount, received);

        (uint256 increment, uint256 newRemainder) = _calculateAccumulatorIncrement(amount, supply);
        accumulatedRewardPerShare += increment;
        precisionRemainder = newRemainder;
        totalDeposited += amount;

        _requireSolvent();
        emit RevenueDeposited(msg.sender, amount, accumulatedRewardPerShare, newRemainder);
    }

    /// @inheritdoc IRevenueVault
    function checkpointTransfer(address from, address to, uint256 amount) external nonReentrant {
        if (msg.sender != address(revenueToken)) revert OnlyRevenueToken(msg.sender);

        if (from == to) {
            if (from != address(0)) {
                uint256 balance = revenueToken.balanceOf(from);
                _accrueWithBalance(from, balance);
                rewardDebt[from] = _accumulatedFor(balance);
            }

            emit TransferCheckpointed(from, to, amount);
            return;
        }

        if (from != address(0)) {
            uint256 fromBalance = revenueToken.balanceOf(from);
            if (fromBalance < amount) revert InsufficientCheckpointBalance(from, fromBalance, amount);

            _accrueWithBalance(from, fromBalance);
            rewardDebt[from] = _accumulatedFor(fromBalance - amount);
        }

        if (to != address(0)) {
            uint256 toBalance = revenueToken.balanceOf(to);
            _accrueWithBalance(to, toBalance);
            rewardDebt[to] = _accumulatedFor(toBalance + amount);
        }

        emit TransferCheckpointed(from, to, amount);
    }

    /// @inheritdoc IRevenueVault
    function checkpointRecovery(address source, address destination, uint256 amount) external nonReentrant {
        if (msg.sender != address(revenueToken)) revert OnlyRevenueToken(msg.sender);
        if (source == address(0) || destination == address(0) || source == destination) {
            revert InvalidRecoveryAccounts(source, destination);
        }

        uint256 sourceBalance = revenueToken.balanceOf(source);
        if (sourceBalance == 0) revert ZeroRecoveryBalance();
        if (amount != sourceBalance) revert RecoveryRequiresFullBalance(amount, sourceBalance);

        uint256 destinationBalance = revenueToken.balanceOf(destination);
        uint256 depositedBefore = totalDeposited;
        uint256 claimedBefore = totalClaimed;
        uint256 settlementBalanceBefore = settlementToken.balanceOf(address(this));

        _accrueWithBalance(source, sourceBalance);
        _accrueWithBalance(destination, destinationBalance);

        uint256 migratedPending = pendingReward[source];
        pendingReward[source] = 0;
        pendingReward[destination] += migratedPending;

        rewardDebt[source] = 0;
        rewardDebt[destination] = _accumulatedFor(destinationBalance + sourceBalance);

        assert(totalDeposited == depositedBefore);
        assert(totalClaimed == claimedBefore);
        assert(settlementToken.balanceOf(address(this)) == settlementBalanceBefore);
        _requireSolvent();

        emit RevenueStateMigrated(source, destination, amount, migratedPending);
    }

    /// @notice Pulls all revenue currently accrued to the caller.
    function claim() external nonReentrant returns (uint256 amount) {
        address account = msg.sender;
        _accrue(account);

        amount = pendingReward[account];
        if (amount == 0) revert NothingToClaim(account);

        pendingReward[account] = 0;

        uint256 newTotalClaimed = totalClaimed + amount;
        if (newTotalClaimed > totalDeposited) revert ClaimsExceedDeposits(newTotalClaimed, totalDeposited);
        totalClaimed = newTotalClaimed;

        uint256 balance = settlementToken.balanceOf(address(this));
        if (balance < amount) revert VaultInsolvent(balance, amount);

        settlementToken.safeTransfer(account, amount);
        _requireSolvent();

        emit RevenueClaimed(account, amount, newTotalClaimed);
    }

    /// @notice Returns the caller's stored and newly accrued unpaid revenue.
    function claimable(address account) external view returns (uint256) {
        uint256 accumulated = _accumulatedFor(revenueToken.balanceOf(account));
        uint256 debt = rewardDebt[account];
        if (accumulated < debt) revert MissingTransferCheckpoint(account, accumulated, debt);

        return pendingReward[account] + accumulated - debt;
    }

    /// @notice Returns whether the actual settlement balance covers all accounted funds not yet claimed.
    function isSolvent() external view returns (bool) {
        return settlementToken.balanceOf(address(this)) >= totalDeposited - totalClaimed;
    }

    function _accrue(address account) private {
        _accrueWithBalance(account, revenueToken.balanceOf(account));
    }

    function _accrueWithBalance(address account, uint256 balance) private {
        uint256 accumulated = _accumulatedFor(balance);
        uint256 debt = rewardDebt[account];
        if (accumulated < debt) revert MissingTransferCheckpoint(account, accumulated, debt);

        pendingReward[account] += accumulated - debt;
        rewardDebt[account] = accumulated;
    }

    function _accumulatedFor(uint256 balance) private view returns (uint256) {
        return Math.mulDiv(balance, accumulatedRewardPerShare, ACCUMULATOR_PRECISION);
    }

    function _calculateAccumulatorIncrement(uint256 amount, uint256 supply)
        private
        view
        returns (uint256 increment, uint256 newRemainder)
    {
        increment = Math.mulDiv(amount, ACCUMULATOR_PRECISION, supply);

        uint256 productRemainder = mulmod(amount, ACCUMULATOR_PRECISION, supply);
        uint256 previousRemainder = precisionRemainder;

        // Both remainders are below `supply`. Compute their carry without overflowing.
        if (previousRemainder != 0 && productRemainder >= supply - previousRemainder) {
            increment += 1;
        }
        newRemainder = addmod(productRemainder, previousRemainder, supply);
    }

    function _requireSolvent() private view {
        uint256 accountedBalance = totalDeposited - totalClaimed;
        uint256 actualBalance = settlementToken.balanceOf(address(this));
        if (actualBalance < accountedBalance) revert VaultInsolvent(actualBalance, accountedBalance);
    }
}
