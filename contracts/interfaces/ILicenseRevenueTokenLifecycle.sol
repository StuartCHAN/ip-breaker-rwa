// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILicenseRevenueTokenLifecycle {
    enum Lifecycle {
        Created,
        Minting,
        Activated
    }

    function lifecycle() external view returns (Lifecycle);
}
