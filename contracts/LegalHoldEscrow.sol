// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILegalHoldEscrow} from "./interfaces/ILegalHoldEscrow.sol";

interface ILegalHoldRevenueToken {
    function executeLegalHoldRelease(bytes32 subscriptionId, address source, address destination, uint256 amount)
        external;
}

/// @notice Token-holding address isolated to one remediation subscription.
/// @dev It exposes no transfer, approval, withdrawal, rescue, or arbitrary-call entrypoint.
contract LegalHoldPositionAccount {
    address public immutable legalHoldEscrow;
    bytes32 public immutable offeringId;
    bytes32 public immutable subscriptionId;

    constructor(address legalHoldEscrow_, bytes32 offeringId_, bytes32 subscriptionId_) {
        legalHoldEscrow = legalHoldEscrow_;
        offeringId = offeringId_;
        subscriptionId = subscriptionId_;
    }
}

/// @title LegalHoldEscrow
/// @notice Creates isolated per-subscription custody positions and coordinates full-state release.
contract LegalHoldEscrow is ILegalHoldEscrow, ReentrancyGuard {
    address public immutable offeringManager;
    bytes32 public immutable offeringId;
    address public immutable allocationEscrow;
    address public immutable revenueToken;

    mapping(bytes32 subscriptionId => LegalHoldPosition position) private _positions;
    mapping(address position => bool registered) public isRegisteredPosition;
    mapping(address position => bool active) public isActivePosition;

    error ZeroOfferingManager();
    error ZeroOfferingId();
    error ZeroAllocationEscrow();
    error ZeroRevenueToken();
    error UnauthorizedAllocationEscrow(address caller);
    error UnauthorizedOfferingManager(address caller);
    error ZeroSubscriptionId();
    error ZeroBeneficialOwner();
    error ZeroPositionAmount();
    error PositionAlreadyExists(bytes32 subscriptionId);
    error PositionNotHeld(bytes32 subscriptionId, PositionStatus status);

    event LegalHoldPositionCreated(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed position,
        address beneficialOwner,
        uint256 amount,
        uint64 sequence
    );
    event LegalHoldPositionReleased(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed position,
        address beneficialOwner,
        uint256 amount
    );

    modifier onlyAllocationEscrow() {
        if (msg.sender != allocationEscrow) revert UnauthorizedAllocationEscrow(msg.sender);
        _;
    }

    modifier onlyOfferingManager() {
        if (msg.sender != offeringManager) revert UnauthorizedOfferingManager(msg.sender);
        _;
    }

    constructor(address offeringManager_, bytes32 offeringId_, address allocationEscrow_, address revenueToken_) {
        if (offeringManager_ == address(0)) revert ZeroOfferingManager();
        if (offeringId_ == bytes32(0)) revert ZeroOfferingId();
        if (allocationEscrow_ == address(0)) revert ZeroAllocationEscrow();
        if (revenueToken_ == address(0)) revert ZeroRevenueToken();

        offeringManager = offeringManager_;
        offeringId = offeringId_;
        allocationEscrow = allocationEscrow_;
        revenueToken = revenueToken_;
    }

    function createPosition(bytes32 subscriptionId, address beneficialOwner, uint256 amount, uint64 sequence)
        external
        onlyAllocationEscrow
        returns (address position)
    {
        if (subscriptionId == bytes32(0)) revert ZeroSubscriptionId();
        if (beneficialOwner == address(0)) revert ZeroBeneficialOwner();
        if (amount == 0) revert ZeroPositionAmount();
        if (_positions[subscriptionId].status != PositionStatus.None) {
            revert PositionAlreadyExists(subscriptionId);
        }

        position =
            address(new LegalHoldPositionAccount{salt: subscriptionId}(address(this), offeringId, subscriptionId));
        _positions[subscriptionId] = LegalHoldPosition({
            offeringId: offeringId,
            subscriptionId: subscriptionId,
            beneficialOwner: beneficialOwner,
            position: position,
            amount: amount,
            sequence: sequence,
            status: PositionStatus.Held
        });
        isRegisteredPosition[position] = true;
        isActivePosition[position] = true;

        emit LegalHoldPositionCreated(offeringId, subscriptionId, position, beneficialOwner, amount, sequence);
    }

    function releasePosition(bytes32 subscriptionId) external onlyOfferingManager nonReentrant {
        LegalHoldPosition storage heldPosition = _positions[subscriptionId];
        if (heldPosition.status != PositionStatus.Held) {
            revert PositionNotHeld(subscriptionId, heldPosition.status);
        }

        ILegalHoldRevenueToken(revenueToken)
            .executeLegalHoldRelease(
                subscriptionId, heldPosition.position, heldPosition.beneficialOwner, heldPosition.amount
            );
        heldPosition.status = PositionStatus.Released;
        isActivePosition[heldPosition.position] = false;

        emit LegalHoldPositionReleased(
            offeringId, subscriptionId, heldPosition.position, heldPosition.beneficialOwner, heldPosition.amount
        );
    }

    function positionOf(bytes32 subscriptionId) external view returns (address) {
        return _positions[subscriptionId].position;
    }

    function isHeldPosition(bytes32 subscriptionId, address position, address beneficialOwner, uint256 amount)
        external
        view
        returns (bool)
    {
        LegalHoldPosition storage heldPosition = _positions[subscriptionId];
        return heldPosition.status == PositionStatus.Held && heldPosition.position == position
            && heldPosition.beneficialOwner == beneficialOwner && heldPosition.amount == amount;
    }

    function getPosition(bytes32 subscriptionId) external view returns (LegalHoldPosition memory) {
        return _positions[subscriptionId];
    }
}
