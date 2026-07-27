// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRevenueVault {
    enum DepositLifecycle {
        Disabled,
        Enabled
    }

    function revenueToken() external view returns (IERC20);

    function activationController() external view returns (address);

    function depositLifecycle() external view returns (DepositLifecycle);

    function enableDeposits() external;

    /// @notice Settles affected accounts and records debt for their projected post-update balances.
    /// @dev Must be called by the bound revenue token before its ERC-20 balance update.
    function checkpointTransfer(address from, address to, uint256 amount) external;

    /// @notice Settles both accounts and migrates all source pending rewards to the destination.
    /// @dev Must be called by the bound revenue token before a full-balance recovery update.
    function checkpointRecovery(address source, address destination, uint256 amount) external;

    /// @notice Migrates one isolated legal-hold position's complete reward state.
    /// @dev Must be called by the bound revenue token before the full position balance moves.
    function checkpointLegalHoldRelease(address source, address destination, uint256 amount) external;
}
