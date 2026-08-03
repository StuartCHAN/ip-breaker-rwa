// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Offering-specific investor eligibility used by revenue tokens.
interface IInvestorEligibility {
    /// @return True when `account` may hold the revenue token for `assetId` now.
    function canHold(address account, uint256 assetId) external view returns (bool);
}
