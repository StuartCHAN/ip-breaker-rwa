// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRevenueVault} from "../../contracts/interfaces/IRevenueVault.sol";

contract MockRevenueVault is IRevenueVault {
    IERC20 public immutable override revenueToken;
    address public immutable activationController;
    DepositLifecycle public depositLifecycle;

    uint256 public checkpointCount;
    bool public checkpointShouldRevert;

    error CheckpointFailed();

    constructor(address revenueToken_) {
        revenueToken = IERC20(revenueToken_);
        activationController = msg.sender;
    }

    function enableDeposits() external {
        depositLifecycle = DepositLifecycle.Enabled;
    }

    function setCheckpointShouldRevert(bool shouldRevert) external {
        checkpointShouldRevert = shouldRevert;
    }

    function checkpointTransfer(address, address, uint256) external {
        if (checkpointShouldRevert) revert CheckpointFailed();
        ++checkpointCount;
    }

    function checkpointRecovery(address, address, uint256) external {
        if (checkpointShouldRevert) revert CheckpointFailed();
        ++checkpointCount;
    }

    function checkpointLegalHoldRelease(address, address, uint256) external {
        if (checkpointShouldRevert) revert CheckpointFailed();
        ++checkpointCount;
    }
}
