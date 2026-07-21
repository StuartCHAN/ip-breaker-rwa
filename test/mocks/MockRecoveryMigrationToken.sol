// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRecoveryMigrationToken} from "../../contracts/interfaces/IRecoveryMigrationToken.sol";

contract MockRecoveryMigrationToken is IRecoveryMigrationToken {
    uint256 public executionCount;
    bytes32 public lastRecoveryId;
    address public lastSource;
    address public lastDestination;

    function executeRecoveryMigration(bytes32 recoveryId, address source, address destination) external {
        ++executionCount;
        lastRecoveryId = recoveryId;
        lastSource = source;
        lastDestination = destination;
    }
}
