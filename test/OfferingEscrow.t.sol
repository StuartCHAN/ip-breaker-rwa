// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OfferingEscrow} from "../contracts/OfferingEscrow.sol";

contract OfferingEscrowTest is Test {
    bytes32 private constant OFFERING_ID = keccak256("offering");
    bytes32 private constant SUBSCRIPTION_ID = keccak256("subscription");
    bytes32 private constant PAYMENT_REFERENCE = keccak256("payment");

    ContributionManagerMock private manager;
    SixDecimalSettlementMock private usdc;
    OfferingEscrow private escrow;

    address private payer = makeAddr("payer");
    address private destination = makeAddr("destination");
    address private treasury = makeAddr("treasury");
    address private feeRecipient = makeAddr("fee-recipient");
    address private outsider = makeAddr("outsider");

    function setUp() public {
        manager = new ContributionManagerMock();
        usdc = new SixDecimalSettlementMock();
        escrow = new OfferingEscrow(address(manager), OFFERING_ID, address(usdc), treasury, feeRecipient, 250);
        usdc.mint(payer, 1_000_000);
        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testExactContributionIsPulledAndRecorded() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);

        OfferingEscrow.Contribution memory contribution = escrow.getContribution(SUBSCRIPTION_ID);
        assertEq(contribution.payer, payer);
        assertEq(contribution.destination, destination);
        assertEq(contribution.usdcAmount, 500_000);
        assertEq(contribution.allocationAmount, 500 ether);
        assertEq(contribution.paymentReference, PAYMENT_REFERENCE);
        assertEq(contribution.sequence, 0);
        assertEq(escrow.totalContributed(), 500_000);
        assertEq(usdc.balanceOf(address(escrow)), 500_000);
    }

    function testUnauthorizedDirectContributionRejected() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.recordContribution(SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
    }

    function testDuplicateSubscriptionAndPaymentReferenceRejected() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 100_000, 100 ether, PAYMENT_REFERENCE, 0);

        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.ContributionAlreadyExists.selector, SUBSCRIPTION_ID));
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 100_000, 100 ether, keccak256("other-payment"), 1);

        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.PaymentReferenceAlreadyUsed.selector, PAYMENT_REFERENCE));
        manager.record(
            escrow, keccak256("other-subscription"), payer, destination, 100_000, 100 ether, PAYMENT_REFERENCE, 1
        );
    }

    function testIncorrectUSDCBalanceDeltaRejected() public {
        FeeOnTransferSettlementMock feeToken = new FeeOnTransferSettlementMock();
        OfferingEscrow feeEscrow =
            new OfferingEscrow(address(manager), OFFERING_ID, address(feeToken), treasury, feeRecipient, 250);
        feeToken.mint(payer, 1_000_000);
        vm.prank(payer);
        feeToken.approve(address(feeEscrow), type(uint256).max);
        feeToken.setFeeEnabled(true);

        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.IncorrectSettlementDelta.selector, 500_000, 499_999));
        manager.record(feeEscrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);

        assertEq(feeToken.balanceOf(address(feeEscrow)), 0);
        assertEq(feeEscrow.totalContributed(), 0);
    }

    function testNoWithdrawalRescueOrArbitraryTransfer() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);

        (bool withdrawSuccess,) =
            address(escrow).call(abi.encodeWithSignature("withdraw(address,uint256)", outsider, 500_000));
        (bool rescueSuccess,) = address(escrow)
            .call(abi.encodeWithSignature("rescue(address,address,uint256)", address(usdc), outsider, 500_000));

        assertFalse(withdrawSuccess);
        assertFalse(rescueSuccess);
        assertEq(usdc.balanceOf(address(escrow)), 500_000);
        assertEq(usdc.balanceOf(outsider), 0);
    }

    function testFullRefundOnlyOriginalPayerAndOnlyOnce() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        manager.enableRefunds(escrow);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedRefundClaimant.selector, outsider, payer));
        escrow.claimRefund(SUBSCRIPTION_ID);

        uint256 balanceBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        escrow.claimRefund(SUBSCRIPTION_ID);
        assertEq(usdc.balanceOf(payer), balanceBefore + 500_000);
        assertEq(escrow.totalRefunded(), 500_000);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.RefundAlreadyClaimed.selector, SUBSCRIPTION_ID));
        escrow.claimRefund(SUBSCRIPTION_ID);
    }

    function testRefundBeforeFailedRejected() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);

        vm.prank(payer);
        vm.expectRevert(OfferingEscrow.RefundsNotEnabled.selector);
        escrow.claimRefund(SUBSCRIPTION_ID);
    }

    function testRefundTransferFailureRollsBackAccounting() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        manager.enableRefunds(escrow);
        usdc.setTransferFailure(true);

        vm.prank(payer);
        vm.expectRevert(SixDecimalSettlementMock.TransferFailed.selector);
        escrow.claimRefund(SUBSCRIPTION_ID);

        OfferingEscrow.Contribution memory contribution = escrow.getContribution(SUBSCRIPTION_ID);
        assertFalse(contribution.refunded);
        assertEq(escrow.totalRefunded(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 500_000);
    }

    function testRefundGateOnlyManagerAndOneWay() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.markRefundable();

        manager.enableRefunds(escrow);
        assertTrue(escrow.refundable());
        vm.expectRevert(OfferingEscrow.RefundsAlreadyEnabled.selector);
        manager.enableRefunds(escrow);
    }
}

contract ContributionManagerMock {
    function record(
        OfferingEscrow escrow,
        bytes32 subscriptionId,
        address payer,
        address destination,
        uint256 usdcAmount,
        uint256 allocationAmount,
        bytes32 paymentReference,
        uint64 sequence
    ) external {
        escrow.recordContribution(
            subscriptionId, payer, destination, usdcAmount, allocationAmount, paymentReference, sequence
        );
    }

    function enableRefunds(OfferingEscrow escrow) external {
        escrow.markRefundable();
    }
}

contract SixDecimalSettlementMock is ERC20 {
    bool private _transferFailure;

    error TransferFailed();

    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferFailure(bool shouldFail) external {
        _transferFailure = shouldFail;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (_transferFailure && from != address(0) && to != address(0)) {
            revert TransferFailed();
        }
        super._update(from, to, value);
    }
}

contract FeeOnTransferSettlementMock is SixDecimalSettlementMock {
    bool private _feeEnabled;

    function setFeeEnabled(bool enabled) external {
        _feeEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_feeEnabled && from != address(0) && to != address(0)) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
            return;
        }
        super._update(from, to, value);
    }
}
