// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {AllocationEscrow} from "../contracts/AllocationEscrow.sol";
import {ILegalHoldEscrow} from "../contracts/interfaces/ILegalHoldEscrow.sol";

contract AllocationEscrowTest is Test {
    uint256 private constant FINAL_SUPPLY = 10_000 ether;
    bytes32 private constant OFFERING_ID = keccak256("offering");

    AllocationManagerMock private manager;
    AllocationTokenMock private token;
    AllocationEscrow private escrow;

    address private outsider = makeAddr("outsider");
    address private investor = makeAddr("investor");

    event TokenDepositConfirmed(bytes32 indexed offeringId, address indexed revenueToken, uint256 finalSupply);
    event AllocationReleased(
        bytes32 indexed offeringId,
        bytes32 indexed subscriptionId,
        address indexed destination,
        uint256 amount,
        uint256 totalReleased
    );

    function setUp() public {
        manager = new AllocationManagerMock();
        token = new AllocationTokenMock(FINAL_SUPPLY);
        escrow = new AllocationEscrow(address(manager), OFFERING_ID, address(token), FINAL_SUPPLY);
        manager.setOfferingStatus(OFFERING_ID, 1);
    }

    function testImmutableOneToOneBindings() public view {
        assertEq(escrow.offeringManager(), address(manager));
        assertEq(escrow.offeringId(), OFFERING_ID);
        assertEq(escrow.revenueToken(), address(token));
        assertEq(escrow.finalSupply(), FINAL_SUPPLY);
        ILegalHoldEscrow holdEscrow = ILegalHoldEscrow(escrow.legalHoldEscrow());
        assertEq(holdEscrow.offeringManager(), address(manager));
        assertEq(holdEscrow.offeringId(), OFFERING_ID);
        assertEq(holdEscrow.allocationEscrow(), address(escrow));
        assertEq(holdEscrow.revenueToken(), address(token));
    }

    function testExactDepositConfirmation() public {
        token.mint(address(escrow), FINAL_SUPPLY);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit TokenDepositConfirmed(OFFERING_ID, address(token), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);

        assertTrue(escrow.depositConfirmed());
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
    }

    function testUnauthorizedConfirmationRejected() public {
        token.mint(address(escrow), FINAL_SUPPLY);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.confirmTokenDeposit();

        assertFalse(escrow.depositConfirmed());
    }

    function testRepeatedConfirmationRejected() public {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);

        vm.expectRevert(AllocationEscrow.DepositAlreadyConfirmed.selector);
        manager.confirmDeposit(escrow);

        assertTrue(escrow.depositConfirmed());
    }

    function testIncorrectBalanceRejected() public {
        token.mint(address(escrow), FINAL_SUPPLY - 1);
        token.mint(address(this), 1);

        vm.expectRevert(
            abi.encodeWithSelector(AllocationEscrow.IncorrectTokenBalance.selector, FINAL_SUPPLY, FINAL_SUPPLY - 1)
        );
        manager.confirmDeposit(escrow);

        assertFalse(escrow.depositConfirmed());
    }

    function testWrongTokenSupplyBindingRejected() public {
        AllocationTokenMock wrongSupplyToken = new AllocationTokenMock(FINAL_SUPPLY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(AllocationEscrow.TokenFinalSupplyMismatch.selector, FINAL_SUPPLY, FINAL_SUPPLY + 1)
        );
        new AllocationEscrow(address(manager), OFFERING_ID, address(wrongSupplyToken), FINAL_SUPPLY);
    }

    function testAllocationRecordIsImmutableAndCapped() public {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);
        manager.setOfferingStatus(OFFERING_ID, 2);

        bytes32 subscriptionId = keccak256("subscription-1");
        bytes32 investorCommitment = keccak256("investor-commitment");
        manager.registerAllocation(escrow, subscriptionId, investorCommitment, investor, 6_000 ether, 0);

        AllocationEscrow.Allocation memory allocation = escrow.getAllocation(subscriptionId);
        assertEq(allocation.investorCommitment, investorCommitment);
        assertEq(allocation.destination, investor);
        assertEq(allocation.amount, 6_000 ether);
        assertEq(allocation.sequence, 0);
        assertTrue(allocation.exists);
        assertEq(escrow.totalAllocated(), 6_000 ether);
        assertEq(escrow.totalReleased(), 0);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationAlreadyExists.selector, subscriptionId));
        manager.registerAllocation(escrow, subscriptionId, keccak256("replacement"), outsider, 1 ether, 1);

        vm.expectRevert(
            abi.encodeWithSelector(AllocationEscrow.AllocationExceedsFinalSupply.selector, 11_000 ether, FINAL_SUPPLY)
        );
        manager.registerAllocation(
            escrow, keccak256("subscription-2"), keccak256("investor-2"), outsider, 5_000 ether, 1
        );

        assertEq(escrow.totalAllocated(), 6_000 ether);
        assertEq(escrow.totalReleased(), 0);
    }

    function testAllocationCannotRegisterBeforeOfferingOpen() public {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.InvalidOfferingStatus.selector, uint8(2), uint8(1)));
        manager.registerAllocation(escrow, keccak256("subscription"), keccak256("investor"), investor, 1 ether, 0);
    }

    function testNoArbitraryWithdrawalOrTokenTransfer() public {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);

        (bool withdrawSuccess,) =
            address(escrow).call(abi.encodeWithSignature("withdraw(address,uint256)", outsider, FINAL_SUPPLY));
        (bool rescueSuccess,) = address(escrow)
            .call(abi.encodeWithSignature("rescue(address,address,uint256)", address(token), outsider, FINAL_SUPPLY));
        (bool transferSuccess,) = address(escrow)
            .call(
                abi.encodeWithSignature(
                    "transferToken(address,address,uint256)", address(token), outsider, FINAL_SUPPLY
                )
            );

        assertFalse(withdrawSuccess);
        assertFalse(rescueSuccess);
        assertFalse(transferSuccess);
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
        assertEq(token.balanceOf(outsider), 0);
    }

    function testTombstoneIsPermanentAndBlocksFurtherAllocation() public {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);
        manager.tombstone(escrow);

        assertTrue(escrow.tombstoned());
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
        assertEq(escrow.totalReleased(), 0);

        manager.setOfferingStatus(OFFERING_ID, 2);
        vm.expectRevert(AllocationEscrow.EscrowTombstoned.selector);
        manager.registerAllocation(escrow, keccak256("subscription"), keccak256("investor"), investor, 1 ether, 0);

        vm.expectRevert(AllocationEscrow.AlreadyTombstoned.selector);
        manager.tombstone(escrow);
    }

    function testUnauthorizedTombstoneRejected() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.tombstone();
    }

    function testSuccessfulReleaseUsesImmutableDestinationAndAmount() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 6_000 ether);
        manager.setOfferingStatus(OFFERING_ID, 3);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit AllocationReleased(OFFERING_ID, subscriptionId, investor, 6_000 ether, 6_000 ether);
        manager.releaseAllocation(escrow, subscriptionId);

        AllocationEscrow.Allocation memory allocation = escrow.getAllocation(subscriptionId);
        assertTrue(allocation.released);
        assertEq(escrow.totalReleased(), 6_000 ether);
        assertEq(token.balanceOf(investor), 6_000 ether);
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY - 6_000 ether);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationAlreadyReleased.selector, subscriptionId));
        manager.releaseAllocation(escrow, subscriptionId);
    }

    function testReleaseRejectedUnlessSuccessfulAndCalledByManager() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.InvalidOfferingStatus.selector, uint8(3), uint8(2)));
        manager.releaseAllocation(escrow, subscriptionId);

        manager.setOfferingStatus(OFFERING_ID, 3);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.releaseAllocation(subscriptionId);

        assertEq(escrow.totalReleased(), 0);
        assertEq(token.balanceOf(investor), 0);
    }

    function testTombstonedEscrowCannotRelease() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 1 ether);
        manager.tombstone(escrow);
        manager.setOfferingStatus(OFFERING_ID, 3);

        vm.expectRevert(AllocationEscrow.EscrowTombstoned.selector);
        manager.releaseAllocation(escrow, subscriptionId);

        assertEq(escrow.totalReleased(), 0);
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
    }

    function testTokenTransferFailureRollsBackReleaseAccounting() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 1 ether);
        manager.setOfferingStatus(OFFERING_ID, 3);
        token.setDeliveryFailure(true);

        vm.expectRevert(AllocationTokenMock.DeliveryFailed.selector);
        manager.releaseAllocation(escrow, subscriptionId);

        assertFalse(escrow.getAllocation(subscriptionId).released);
        assertEq(escrow.totalReleased(), 0);
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
        assertEq(token.balanceOf(investor), 0);
    }

    function testRemediationAllocationMovesToIsolatedLegalHoldPosition() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 4_000 ether);
        manager.setOfferingStatus(OFFERING_ID, 3);

        address position = manager.holdAllocation(escrow, subscriptionId);
        AllocationEscrow.Allocation memory allocation = escrow.getAllocation(subscriptionId);
        ILegalHoldEscrow.LegalHoldPosition memory heldPosition =
            ILegalHoldEscrow(escrow.legalHoldEscrow()).getPosition(subscriptionId);

        assertTrue(allocation.legalHeld);
        assertFalse(allocation.released);
        assertEq(heldPosition.position, position);
        assertEq(heldPosition.beneficialOwner, investor);
        assertEq(heldPosition.amount, 4_000 ether);
        assertEq(heldPosition.sequence, 0);
        assertEq(uint256(heldPosition.status), uint256(ILegalHoldEscrow.PositionStatus.Held));
        assertEq(escrow.legalHoldTransferred(), 4_000 ether);
        assertEq(escrow.totalDelivered(), 4_000 ether);
        assertEq(token.balanceOf(position), 4_000 ether);
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY - 4_000 ether);

        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationAlreadyHeld.selector, subscriptionId));
        manager.holdAllocation(escrow, subscriptionId);
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationAlreadyHeld.selector, subscriptionId));
        manager.releaseAllocation(escrow, subscriptionId);
    }

    function testUnauthorizedOrUnknownLegalHoldInstructionRejected() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 1 ether);
        manager.setOfferingStatus(OFFERING_ID, 3);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.holdAllocation(subscriptionId);

        bytes32 unknownId = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(AllocationEscrow.AllocationNotFound.selector, unknownId));
        manager.holdAllocation(escrow, unknownId);

        (bool amountOverrideSuccess,) = address(escrow)
            .call(abi.encodeWithSignature("holdAllocation(bytes32,uint256)", subscriptionId, uint256(2 ether)));
        assertFalse(amountOverrideSuccess);
        assertEq(escrow.legalHoldTransferred(), 0);
    }

    function testLegalHoldTransferFailureRollsBackPositionAndAccounting() public {
        bytes32 subscriptionId = _prepareAllocation(investor, 1 ether);
        manager.setOfferingStatus(OFFERING_ID, 3);
        token.setDeliveryFailure(true);

        vm.expectRevert(AllocationTokenMock.DeliveryFailed.selector);
        manager.holdAllocation(escrow, subscriptionId);

        assertFalse(escrow.getAllocation(subscriptionId).legalHeld);
        assertEq(escrow.legalHoldTransferred(), 0);
        assertEq(ILegalHoldEscrow(escrow.legalHoldEscrow()).positionOf(subscriptionId), address(0));
        assertEq(token.balanceOf(address(escrow)), FINAL_SUPPLY);
    }

    function testFuzzDirectAndLegalHoldDeliveryConserveSupply(uint256 directAmount) public {
        directAmount = bound(directAmount, 1, FINAL_SUPPLY - 1);
        uint256 heldAmount = FINAL_SUPPLY - directAmount;
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);
        manager.setOfferingStatus(OFFERING_ID, 2);
        bytes32 directId = keccak256(abi.encode("direct", directAmount));
        bytes32 heldId = keccak256(abi.encode("held", heldAmount));
        manager.registerAllocation(escrow, directId, keccak256("direct-investor"), investor, directAmount, 0);
        manager.registerAllocation(escrow, heldId, keccak256("held-investor"), outsider, heldAmount, 1);
        manager.setOfferingStatus(OFFERING_ID, 3);

        manager.releaseAllocation(escrow, directId);
        address position = manager.holdAllocation(escrow, heldId);

        assertEq(escrow.totalReleased(), directAmount);
        assertEq(escrow.legalHoldTransferred(), heldAmount);
        assertEq(escrow.totalDelivered(), FINAL_SUPPLY);
        assertLe(escrow.totalDelivered(), FINAL_SUPPLY);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(token.balanceOf(investor), directAmount);
        assertEq(token.balanceOf(position), heldAmount);
        assertEq(token.totalSupply(), FINAL_SUPPLY);
    }

    function _prepareAllocation(address destination, uint256 amount) private returns (bytes32 subscriptionId) {
        token.mint(address(escrow), FINAL_SUPPLY);
        manager.confirmDeposit(escrow);
        manager.setOfferingStatus(OFFERING_ID, 2);
        subscriptionId = keccak256(abi.encode(destination, amount));
        manager.registerAllocation(escrow, subscriptionId, keccak256("investor-commitment"), destination, amount, 0);
    }
}

contract AllocationManagerMock {
    mapping(bytes32 offeringId => uint8 status) private _statuses;

    function setOfferingStatus(bytes32 offeringId, uint8 status) external {
        _statuses[offeringId] = status;
    }

    function getOfferingStatus(bytes32 offeringId) external view returns (uint8) {
        return _statuses[offeringId];
    }

    function confirmDeposit(AllocationEscrow escrow) external {
        escrow.confirmTokenDeposit();
    }

    function registerAllocation(
        AllocationEscrow escrow,
        bytes32 subscriptionId,
        bytes32 investorCommitment,
        address destination,
        uint256 amount,
        uint64 sequence
    ) external {
        escrow.registerAllocation(subscriptionId, investorCommitment, destination, amount, sequence);
    }

    function tombstone(AllocationEscrow escrow) external {
        escrow.tombstone();
    }

    function releaseAllocation(AllocationEscrow escrow, bytes32 subscriptionId) external {
        escrow.releaseAllocation(subscriptionId);
    }

    function holdAllocation(AllocationEscrow escrow, bytes32 subscriptionId) external returns (address position) {
        return escrow.holdAllocation(subscriptionId);
    }

    function releaseLegalHold(ILegalHoldEscrow holdEscrow, bytes32 subscriptionId) external {
        holdEscrow.releasePosition(subscriptionId);
    }
}

contract AllocationTokenMock is ERC20 {
    uint256 public immutable finalSupply;
    bool private _deliveryFailure;

    error DeliveryFailed();

    constructor(uint256 finalSupply_) ERC20("Allocation Token", "ALLOC") {
        finalSupply = finalSupply_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDeliveryFailure(bool shouldFail) external {
        _deliveryFailure = shouldFail;
    }

    function executePrimaryDelivery(address destination, uint256 amount) external {
        if (_deliveryFailure) revert DeliveryFailed();
        _transfer(msg.sender, destination, amount);
    }

    function executePrimaryLegalHoldDelivery(bytes32, address position, uint256 amount) external {
        if (_deliveryFailure) revert DeliveryFailed();
        _transfer(msg.sender, position, amount);
    }

    function executeLegalHoldRelease(bytes32, address source, address destination, uint256 amount) external {
        if (_deliveryFailure) revert DeliveryFailed();
        _transfer(source, destination, amount);
    }
}
