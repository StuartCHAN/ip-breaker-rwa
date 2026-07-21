// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInvestorEligibility} from "../../contracts/interfaces/IInvestorEligibility.sol";

contract MockInvestorEligibility is IInvestorEligibility {
    mapping(uint256 assetId => mapping(address account => bool eligible)) private _eligibility;

    function setEligible(uint256 assetId, address account, bool eligible) external {
        _eligibility[assetId][account] = eligible;
    }

    function canHold(address account, uint256 assetId) external view returns (bool) {
        return _eligibility[assetId][account];
    }
}
