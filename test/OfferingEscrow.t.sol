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

    event ProceedsEnabled(bytes32 indexed offeringId, uint256 issuerProceeds, uint256 protocolFee);
    event IssuerProceedsClaimed(bytes32 indexed offeringId, address indexed issuerTreasury, uint256 amount);
    event ProtocolFeeClaimed(bytes32 indexed offeringId, address indexed feeRecipient, uint256 amount);

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

    function testEnableProceedsFreezesConservedEntitlementsWithoutTransfer() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_001, 500 ether, PAYMENT_REFERENCE, 0);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit ProceedsEnabled(OFFERING_ID, 487_501, 12_500);
        manager.enableProceeds(escrow);

        assertTrue(escrow.proceedsEnabled());
        assertEq(escrow.issuerProceeds(), 487_501);
        assertEq(escrow.protocolFee(), 12_500);
        assertEq(escrow.issuerProceeds() + escrow.protocolFee(), escrow.totalContributed());
        assertEq(usdc.balanceOf(address(escrow)), 500_001);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function testEnableProceedsOnlyManagerAndOnlyOnce() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedOfferingManager.selector, outsider));
        escrow.enableProceeds();

        manager.enableProceeds(escrow);
        vm.expectRevert(OfferingEscrow.ProceedsAlreadyEnabled.selector);
        manager.enableProceeds(escrow);
    }

    function testRefundAndProceedsPathsAreMutuallyExclusive() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        manager.enableRefunds(escrow);

        vm.expectRevert(OfferingEscrow.RefundPathActive.selector);
        manager.enableProceeds(escrow);

        OfferingEscrow secondEscrow =
            new OfferingEscrow(address(manager), keccak256("second"), address(usdc), treasury, feeRecipient, 250);
        manager.enableProceeds(secondEscrow);
        vm.expectRevert(OfferingEscrow.ProceedsAlreadyEnabled.selector);
        manager.enableRefunds(secondEscrow);
    }

    function testEnableProceedsInsolvencyRollsBackEntitlements() public {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        vm.prank(address(escrow));
        usdc.transfer(outsider, 1);

        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.EscrowInsolvent.selector, 500_000, 499_999));
        manager.enableProceeds(escrow);

        assertFalse(escrow.proceedsEnabled());
        assertEq(escrow.issuerProceeds(), 0);
        assertEq(escrow.protocolFee(), 0);
    }

    function testIssuerAndFeeClaimsSucceedIndependentlyAndConserveUSDC() public {
        _prepareFinalizedProceeds();

        vm.expectEmit(true, true, false, true, address(escrow));
        emit ProtocolFeeClaimed(OFFERING_ID, feeRecipient, 12_500);
        vm.prank(feeRecipient);
        assertEq(escrow.claimProtocolFee(), 12_500);
        assertEq(usdc.balanceOf(address(escrow)), 487_500);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit IssuerProceedsClaimed(OFFERING_ID, treasury, 487_500);
        vm.prank(treasury);
        assertEq(escrow.claimIssuerProceeds(), 487_500);

        assertTrue(escrow.issuerClaimed());
        assertTrue(escrow.feeClaimed());
        assertEq(escrow.totalProceedsClaimed(), escrow.totalContributed());
        assertEq(usdc.balanceOf(treasury), 487_500);
        assertEq(usdc.balanceOf(feeRecipient), 12_500);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testOnlyFrozenBeneficiariesCanClaimAndClaimsCannotRepeat() public {
        _prepareFinalizedProceeds();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedIssuerClaimant.selector, outsider, treasury));
        escrow.claimIssuerProceeds();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.UnauthorizedFeeClaimant.selector, outsider, feeRecipient));
        escrow.claimProtocolFee();

        vm.prank(treasury);
        escrow.claimIssuerProceeds();
        vm.prank(treasury);
        vm.expectRevert(OfferingEscrow.IssuerProceedsAlreadyClaimed.selector);
        escrow.claimIssuerProceeds();

        vm.prank(feeRecipient);
        escrow.claimProtocolFee();
        vm.prank(feeRecipient);
        vm.expectRevert(OfferingEscrow.ProtocolFeeAlreadyClaimed.selector);
        escrow.claimProtocolFee();
    }

    function testClaimsRequireFinalizedAndEnabledProceeds() public {
        manager.setOfferingStatus(5);
        vm.prank(treasury);
        vm.expectRevert(OfferingEscrow.ProceedsNotEnabled.selector);
        escrow.claimIssuerProceeds();

        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        manager.enableProceeds(escrow);
        manager.setOfferingStatus(3);

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.OfferingNotFinalized.selector, uint8(3)));
        escrow.claimIssuerProceeds();

        manager.setOfferingStatus(4);
        vm.prank(feeRecipient);
        vm.expectRevert(abi.encodeWithSelector(OfferingEscrow.OfferingNotFinalized.selector, uint8(4)));
        escrow.claimProtocolFee();
    }

    function testIssuerAndFeeTransferFailuresRollbackClaimAccounting() public {
        _prepareFinalizedProceeds();
        usdc.setTransferFailure(true);

        vm.prank(treasury);
        vm.expectRevert(SixDecimalSettlementMock.TransferFailed.selector);
        escrow.claimIssuerProceeds();
        assertFalse(escrow.issuerClaimed());
        assertEq(escrow.totalProceedsClaimed(), 0);

        vm.prank(feeRecipient);
        vm.expectRevert(SixDecimalSettlementMock.TransferFailed.selector);
        escrow.claimProtocolFee();
        assertFalse(escrow.feeClaimed());
        assertEq(escrow.totalProceedsClaimed(), 0);
        assertEq(usdc.balanceOf(address(escrow)), 500_000);
    }

    function _prepareFinalizedProceeds() private {
        manager.record(escrow, SUBSCRIPTION_ID, payer, destination, 500_000, 500 ether, PAYMENT_REFERENCE, 0);
        manager.enableProceeds(escrow);
        manager.setOfferingStatus(5);
    }
}

contract ContributionManagerMock {
    uint8 private _offeringStatus;

    function getOfferingStatus(bytes32) external view returns (uint8) {
        return _offeringStatus;
    }

    function setOfferingStatus(uint8 status) external {
        _offeringStatus = status;
    }

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

    function enableProceeds(OfferingEscrow escrow) external {
        escrow.enableProceeds();
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
