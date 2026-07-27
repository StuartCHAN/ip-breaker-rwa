// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAllocationEscrow} from "./interfaces/IAllocationEscrow.sol";
import {ILegalHoldEscrow} from "./interfaces/ILegalHoldEscrow.sol";
import {LegalHoldEscrow} from "./LegalHoldEscrow.sol";

interface IOfferingManagerStatus {
    function getOfferingStatus(bytes32 offeringId) external view returns (uint8);
}

interface IRevenueTokenSupply is IERC20 {
    function finalSupply() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function executePrimaryDelivery(address destination, uint256 amount) external;

    function executePrimaryLegalHoldDelivery(bytes32 subscriptionId, address position, uint256 amount) external;
}

/// @title AllocationEscrow
/// @notice One-offering custody boundary for pre-minted primary allocations.
/// @dev Releases only immutable allocations authorized by the bound OfferingManager after success.
contract AllocationEscrow is IAllocationEscrow, ReentrancyGuard {
    struct Allocation {
        bytes32 investorCommitment;
        address destination;
        uint256 amount;
        uint64 sequence;
        bool exists;
        bool released;
        bool legalHeld;
    }

    uint8 private constant STATUS_DRAFT = 1;
    uint8 private constant STATUS_OPEN = 2;
    uint8 private constant STATUS_SUCCESSFUL = 3;

    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;
    address public immutable legalHoldEscrow;

    bool public depositConfirmed;
    bool public tombstoned;
    uint256 public totalAllocated;
    uint256 public totalReleased;
    uint256 public legalHoldTransferred;
    uint64 public nextSequence;

    mapping(bytes32 subscriptionId => Allocation allocation) private _allocations;
    mapping(bytes32 subscriptionId => bytes32 allocationHash) public allocationHash;

    error ZeroOfferingManager();
    error ZeroOfferingId();
    error ZeroRevenueToken();
    error InvalidRevenueToken(address revenueToken);
    error ZeroFinalSupply();
    error TokenFinalSupplyMismatch(uint256 expected, uint256 actual);
    error UnauthorizedOfferingManager(address caller);
    error DepositAlreadyConfirmed();
    error InvalidOfferingStatus(uint8 expected, uint8 actual);
    error IncorrectTokenBalance(uint256 expected, uint256 actual);
    error IncorrectTokenSupply(uint256 expected, uint256 actual);
    error DepositNotConfirmed();
    error ZeroSubscriptionId();
    error ZeroInvestorCommitment();
    error ZeroDestination();
    error ZeroAllocationAmount();
    error AllocationAlreadyExists(bytes32 subscriptionId);
    error InvalidAllocationSequence(uint64 expected, uint64 actual);
    error AllocationExceedsFinalSupply(uint256 requestedTotal, uint256 finalSupply);
    error AlreadyTombstoned();
    error EscrowTombstoned();
    error AllocationNotFound(bytes32 subscriptionId);
    error AllocationAlreadyReleased(bytes32 subscriptionId);
    error AllocationAlreadyHeld(bytes32 subscriptionId);
    error ReleasedAmountExceedsAllocated(uint256 releasedTotal, uint256 allocatedTotal);
    error DeliveredAmountExceedsAllocated(uint256 deliveredTotal, uint256 allocatedTotal);

    event TokenDepositConfirmed(bytes32 indexed offeringId, address indexed revenueToken, uint256 finalSupply);
    event AllocationRegistered(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed destination,
        uint256 amount,
        uint64 sequence,
        bytes32 investorCommitment,
        bytes32 allocationHash
    );
    event AllocationEscrowTombstoned(
        bytes32 indexed offeringId, address indexed revenueToken, uint256 remainingBalance
    );
    event AllocationReleased(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed destination,
        uint256 amount,
        uint256 totalReleased
    );
    event AllocationTransferredToLegalHold(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed position,
        address beneficialOwner,
        uint256 amount,
        uint256 legalHoldTransferred
    );

    modifier onlyOfferingManager() {
        if (msg.sender != offeringManager) {
            revert UnauthorizedOfferingManager(msg.sender);
        }
        _;
    }

    constructor(address offeringManager_, bytes32 offeringId_, address revenueToken_, uint256 finalSupply_) {
        if (offeringManager_ == address(0)) revert ZeroOfferingManager();
        if (offeringId_ == bytes32(0)) revert ZeroOfferingId();
        if (revenueToken_ == address(0)) revert ZeroRevenueToken();
        if (revenueToken_.code.length == 0) {
            revert InvalidRevenueToken(revenueToken_);
        }
        if (finalSupply_ == 0) revert ZeroFinalSupply();

        uint256 tokenFinalSupply = IRevenueTokenSupply(revenueToken_).finalSupply();
        if (tokenFinalSupply != finalSupply_) {
            revert TokenFinalSupplyMismatch(finalSupply_, tokenFinalSupply);
        }

        offeringManager = offeringManager_;
        offeringId = offeringId_;
        revenueToken = revenueToken_;
        finalSupply = finalSupply_;
        legalHoldEscrow = address(new LegalHoldEscrow(offeringManager_, offeringId_, address(this), revenueToken_));
    }

    /// @notice Confirms the one-time exact full-supply deposit while the offering is Draft.
    function confirmTokenDeposit() external onlyOfferingManager nonReentrant {
        if (depositConfirmed) revert DepositAlreadyConfirmed();

        uint8 status = IOfferingManagerStatus(offeringManager).getOfferingStatus(offeringId);
        if (status != STATUS_DRAFT) {
            revert InvalidOfferingStatus(STATUS_DRAFT, status);
        }

        IRevenueTokenSupply token = IRevenueTokenSupply(revenueToken);
        uint256 actualSupply = token.totalSupply();
        if (actualSupply != finalSupply) {
            revert IncorrectTokenSupply(finalSupply, actualSupply);
        }

        uint256 actualBalance = token.balanceOf(address(this));
        if (actualBalance != finalSupply) {
            revert IncorrectTokenBalance(finalSupply, actualBalance);
        }

        depositConfirmed = true;
        emit TokenDepositConfirmed(offeringId, revenueToken, finalSupply);
    }

    /// @notice Stores one immutable primary-allocation commitment.
    /// @dev No Token moves while the offering is Open.
    function registerAllocation(
        bytes32 subscriptionId,
        bytes32 investorCommitment,
        address destination,
        uint256 amount,
        uint64 sequence
    ) external onlyOfferingManager nonReentrant {
        if (tombstoned) revert EscrowTombstoned();
        if (!depositConfirmed) revert DepositNotConfirmed();

        uint8 status = IOfferingManagerStatus(offeringManager).getOfferingStatus(offeringId);
        if (status != STATUS_OPEN) {
            revert InvalidOfferingStatus(STATUS_OPEN, status);
        }
        if (subscriptionId == bytes32(0)) revert ZeroSubscriptionId();
        if (investorCommitment == bytes32(0)) revert ZeroInvestorCommitment();
        if (destination == address(0)) revert ZeroDestination();
        if (amount == 0) revert ZeroAllocationAmount();
        if (_allocations[subscriptionId].exists) {
            revert AllocationAlreadyExists(subscriptionId);
        }
        if (sequence != nextSequence) {
            revert InvalidAllocationSequence(nextSequence, sequence);
        }

        uint256 requestedTotal = totalAllocated + amount;
        if (requestedTotal > finalSupply) {
            revert AllocationExceedsFinalSupply(requestedTotal, finalSupply);
        }

        bytes32 recordHash = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                offeringId,
                subscriptionId,
                investorCommitment,
                destination,
                amount,
                sequence
            )
        );

        _allocations[subscriptionId] = Allocation({
            investorCommitment: investorCommitment,
            destination: destination,
            amount: amount,
            sequence: sequence,
            exists: true,
            released: false,
            legalHeld: false
        });
        allocationHash[subscriptionId] = recordHash;
        totalAllocated = requestedTotal;
        nextSequence = sequence + 1;

        emit AllocationRegistered(
            offeringId, subscriptionId, destination, amount, sequence, investorCommitment, recordHash
        );
    }

    function tombstone() external onlyOfferingManager {
        if (tombstoned) revert AlreadyTombstoned();
        tombstoned = true;
        emit AllocationEscrowTombstoned(offeringId, revenueToken, IERC20(revenueToken).balanceOf(address(this)));
    }

    /// @notice Releases exactly one immutable subscription allocation after a Successful outcome.
    function releaseAllocation(bytes32 subscriptionId) external onlyOfferingManager nonReentrant {
        if (tombstoned) revert EscrowTombstoned();
        if (!depositConfirmed) revert DepositNotConfirmed();

        uint8 status = IOfferingManagerStatus(offeringManager).getOfferingStatus(offeringId);
        if (status != STATUS_SUCCESSFUL) {
            revert InvalidOfferingStatus(STATUS_SUCCESSFUL, status);
        }

        Allocation storage allocation = _allocations[subscriptionId];
        if (!allocation.exists) revert AllocationNotFound(subscriptionId);
        if (allocation.released) revert AllocationAlreadyReleased(subscriptionId);
        if (allocation.legalHeld) revert AllocationAlreadyHeld(subscriptionId);

        uint256 releasedTotal = totalReleased + allocation.amount;
        uint256 deliveredTotal = releasedTotal + legalHoldTransferred;
        if (deliveredTotal > totalAllocated || deliveredTotal > finalSupply) {
            revert ReleasedAmountExceedsAllocated(deliveredTotal, totalAllocated);
        }

        allocation.released = true;
        totalReleased = releasedTotal;
        IRevenueTokenSupply(revenueToken).executePrimaryDelivery(allocation.destination, allocation.amount);

        emit AllocationReleased(offeringId, subscriptionId, allocation.destination, allocation.amount, releasedTotal);
    }

    /// @notice Moves one frozen remediation allocation into its isolated legal-hold position.
    function holdAllocation(bytes32 subscriptionId)
        external
        onlyOfferingManager
        nonReentrant
        returns (address position)
    {
        if (tombstoned) revert EscrowTombstoned();
        if (!depositConfirmed) revert DepositNotConfirmed();

        uint8 status = IOfferingManagerStatus(offeringManager).getOfferingStatus(offeringId);
        if (status != STATUS_SUCCESSFUL) {
            revert InvalidOfferingStatus(STATUS_SUCCESSFUL, status);
        }

        Allocation storage allocation = _allocations[subscriptionId];
        if (!allocation.exists) revert AllocationNotFound(subscriptionId);
        if (allocation.released) revert AllocationAlreadyReleased(subscriptionId);
        if (allocation.legalHeld) revert AllocationAlreadyHeld(subscriptionId);

        uint256 heldTotal = legalHoldTransferred + allocation.amount;
        uint256 deliveredTotal = totalReleased + heldTotal;
        if (deliveredTotal > totalAllocated || deliveredTotal > finalSupply) {
            revert DeliveredAmountExceedsAllocated(deliveredTotal, totalAllocated);
        }

        position = ILegalHoldEscrow(legalHoldEscrow)
            .createPosition(subscriptionId, allocation.destination, allocation.amount, allocation.sequence);
        allocation.legalHeld = true;
        legalHoldTransferred = heldTotal;
        IRevenueTokenSupply(revenueToken).executePrimaryLegalHoldDelivery(subscriptionId, position, allocation.amount);

        emit AllocationTransferredToLegalHold(
            offeringId, subscriptionId, position, allocation.destination, allocation.amount, heldTotal
        );
    }

    function totalDelivered() external view returns (uint256) {
        return totalReleased + legalHoldTransferred;
    }

    function getAllocation(bytes32 subscriptionId) external view returns (Allocation memory) {
        return _allocations[subscriptionId];
    }
}
