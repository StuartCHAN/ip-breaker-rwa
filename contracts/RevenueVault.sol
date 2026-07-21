// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RevenueVault
/// @notice Holds and distributes one ERC-20 settlement asset to holders of one revenue token.
/// @dev Phase 3.1-B1 assumes revenue-token balances remain unchanged while revenue is active.
///      Transfer checkpoints and recovery-ledger migration are intentionally deferred.
contract RevenueVault is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REVENUE_DEPOSITOR_ROLE = keccak256("REVENUE_DEPOSITOR");
    uint256 public constant ACCUMULATOR_PRECISION = 1e27;

    IERC20 public immutable revenueToken;
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

    event RevenueDeposited(
        address indexed depositor, uint256 amount, uint256 accumulatedRewardPerShare, uint256 precisionRemainder
    );
    event RevenueClaimed(address indexed account, uint256 amount, uint256 totalClaimed);

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
        uint256 accumulated =
            Math.mulDiv(revenueToken.balanceOf(account), accumulatedRewardPerShare, ACCUMULATOR_PRECISION);
        uint256 debt = rewardDebt[account];
        if (accumulated < debt) revert MissingTransferCheckpoint(account, accumulated, debt);

        return pendingReward[account] + accumulated - debt;
    }

    /// @notice Returns whether the actual settlement balance covers all accounted funds not yet claimed.
    function isSolvent() external view returns (bool) {
        return settlementToken.balanceOf(address(this)) >= totalDeposited - totalClaimed;
    }

    function _accrue(address account) private {
        uint256 accumulated =
            Math.mulDiv(revenueToken.balanceOf(account), accumulatedRewardPerShare, ACCUMULATOR_PRECISION);
        uint256 debt = rewardDebt[account];
        if (accumulated < debt) revert MissingTransferCheckpoint(account, accumulated, debt);

        pendingReward[account] += accumulated - debt;
        rewardDebt[account] = accumulated;
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
