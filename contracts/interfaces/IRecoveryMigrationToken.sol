// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRecoveryMigrationToken {
    function executeRecoveryMigration(bytes32 recoveryId, address source, address destination) external;
}
