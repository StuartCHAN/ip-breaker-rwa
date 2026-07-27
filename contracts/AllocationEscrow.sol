// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAllocationEscrow} from "./interfaces/IAllocationEscrow.sol";

interface IOfferingManagerStatus {
    function getOfferingStatus(bytes32 offeringId) external view returns (uint8);
}

interface IRevenueTokenSupply is IERC20 {
    function finalSupply() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

/// @title AllocationEscrow
/// @notice One-offering custody boundary for pre-minted primary allocations.
/// @dev Phase 3.2-2B2 records custody and immutable allocations. Token release is intentionally absent.
contract AllocationEscrow is IAllocationEscrow, ReentrancyGuard {
    struct Allocation {
        bytes32 investorCommitment;
        address destination;
        uint256 amount;
        uint64 sequence;
        bool exists;
    }

    uint8 private constant STATUS_DRAFT = 1;
    uint8 private constant STATUS_OPEN = 2;

    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable revenueToken;
    uint256 public immutable finalSupply;

    bool public depositConfirmed;
    uint256 public totalAllocated;
    uint256 public totalReleased;
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
    /// @dev No Token moves in this phase and no release entry point exists.
    function registerAllocation(
        bytes32 subscriptionId,
        bytes32 investorCommitment,
        address destination,
        uint256 amount,
        uint64 sequence
    ) external onlyOfferingManager nonReentrant {
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
            exists: true
        });
        allocationHash[subscriptionId] = recordHash;
        totalAllocated = requestedTotal;
        nextSequence = sequence + 1;

        emit AllocationRegistered(
            offeringId, subscriptionId, destination, amount, sequence, investorCommitment, recordHash
        );
    }

    function getAllocation(bytes32 subscriptionId) external view returns (Allocation memory) {
        return _allocations[subscriptionId];
    }
}
