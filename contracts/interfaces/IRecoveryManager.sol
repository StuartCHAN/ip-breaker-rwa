// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRecoveryManager {
    function isExecutionAuthorized(bytes32 recoveryId, address revenueToken, address source, address destination)
        external
        view
        returns (bool);
}
