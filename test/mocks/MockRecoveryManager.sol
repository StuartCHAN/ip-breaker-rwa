// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRecoveryManager} from "../../contracts/interfaces/IRecoveryManager.sol";
import {IRecoveryMigrationToken} from "../../contracts/interfaces/IRecoveryMigrationToken.sol";

contract MockRecoveryManager is IRecoveryManager {
    mapping(bytes32 recoveryId => bytes32 parameterHash) private _authorization;

    function authorize(bytes32 recoveryId, address token, address source, address destination) external {
        _authorization[recoveryId] = keccak256(abi.encode(token, source, destination));
    }

    function execute(address token, bytes32 recoveryId, address source, address destination) external {
        IRecoveryMigrationToken(token).executeRecoveryMigration(recoveryId, source, destination);
    }

    function isExecutionAuthorized(bytes32 recoveryId, address revenueToken, address source, address destination)
        external
        view
        returns (bool)
    {
        return _authorization[recoveryId] == keccak256(abi.encode(revenueToken, source, destination));
    }
}
