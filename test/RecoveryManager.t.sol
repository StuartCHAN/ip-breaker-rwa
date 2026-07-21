// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {RecoveryManager} from "../contracts/RecoveryManager.sol";

contract RecoveryManagerTest is Test {
    RecoveryManager private manager;

    address private admin = makeAddr("admin");
    address private requester = makeAddr("requester");
    address private verifier = makeAddr("verifier");
    address private approver = makeAddr("approver");
    address private executor = makeAddr("executor");
    address private guardian = makeAddr("guardian");
    address private outsider = makeAddr("outsider");
    address private revenueToken = makeAddr("revenueToken");
    address private source = makeAddr("source");

    address private destination;
    uint256 private destinationKey;

    uint256 private constant CHALLENGE_PERIOD = 3 days;
    uint256 private constant EXECUTION_WINDOW = 7 days;
    bytes32 private constant EVIDENCE = keccak256("recovery-evidence");
    bytes32 private constant ATTESTATION = keccak256("identity-attestation");

    function setUp() public {
        (destination, destinationKey) = makeAddrAndKey("destination");
        manager = new RecoveryManager(admin, CHALLENGE_PERIOD, EXECUTION_WINDOW);

        vm.startPrank(admin);
        manager.grantRole(manager.RECOVERY_REQUESTER_ROLE(), requester);
        manager.grantRole(manager.IDENTITY_VERIFIER_ROLE(), verifier);
        manager.grantRole(manager.RECOVERY_APPROVER_ROLE(), approver);
        manager.grantRole(manager.RECOVERY_EXECUTOR_ROLE(), executor);
        manager.grantRole(manager.RECOVERY_GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    function testInvalidRequesterRejected() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes memory signature = _consentSignature(0, deadline, destinationKey);

        vm.prank(outsider);
        vm.expectRevert();
        manager.requestRecovery(revenueToken, source, destination, 0, EVIDENCE, deadline, signature);
    }

    function testInvalidSignatureRejected() public {
        (, uint256 wrongKey) = makeAddrAndKey("wrong-signer");
        uint256 deadline = block.timestamp + 30 days;
        bytes memory signature = _consentSignature(0, deadline, wrongKey);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.InvalidConsentSignature.selector, destination));
        manager.requestRecovery(revenueToken, source, destination, 0, EVIDENCE, deadline, signature);

        assertEq(manager.recoveryNonce(revenueToken, source), 0);
    }

    function testReplayRejectedByNonce() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes memory signature = _consentSignature(0, deadline, destinationKey);

        vm.prank(requester);
        manager.requestRecovery(revenueToken, source, destination, 0, EVIDENCE, deadline, signature);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.InvalidNonce.selector, 1, 0));
        manager.requestRecovery(revenueToken, source, destination, 0, EVIDENCE, deadline, signature);

        assertEq(manager.recoveryNonce(revenueToken, source), 1);
    }

    function testChallengePeriodEnforced() public {
        bytes32 recoveryId = _createVerifiedAndApprovedRequest();
        RecoveryManager.RecoveryRequest memory request = manager.getRequest(recoveryId);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecoveryManager.ChallengePeriodActive.selector, block.timestamp, request.challengeDeadline
            )
        );
        manager.authorizeExecution(recoveryId);

        vm.warp(request.challengeDeadline);
        vm.prank(executor);
        manager.authorizeExecution(recoveryId);

        request = manager.getRequest(recoveryId);
        assertEq(uint256(request.status), uint256(RecoveryManager.RequestStatus.ExecutionAuthorized));
    }

    function testExecutorCannotModifyParameters() public {
        bytes32 recoveryId = _createVerifiedAndApprovedRequest();
        RecoveryManager.RecoveryRequest memory beforeRequest = manager.getRequest(recoveryId);

        vm.warp(beforeRequest.challengeDeadline);
        vm.prank(executor);
        manager.authorizeExecution(recoveryId);

        RecoveryManager.RecoveryRequest memory afterRequest = manager.getRequest(recoveryId);
        assertEq(afterRequest.revenueToken, beforeRequest.revenueToken);
        assertEq(afterRequest.source, beforeRequest.source);
        assertEq(afterRequest.destination, beforeRequest.destination);
        assertEq(afterRequest.nonce, beforeRequest.nonce);
        assertEq(afterRequest.evidenceCommitment, beforeRequest.evidenceCommitment);

        bytes32 fabricatedId = keccak256("fabricated-request");
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.RequestNotFound.selector, fabricatedId));
        manager.authorizeExecution(fabricatedId);
    }

    function testInvalidLifecycleTransitionRejected() public {
        bytes32 recoveryId = _createRequest();

        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecoveryManager.InvalidRequestStatus.selector,
                recoveryId,
                RecoveryManager.RequestStatus.Requested,
                RecoveryManager.RequestStatus.Verified
            )
        );
        manager.approveRecovery(recoveryId);

        _verify(recoveryId);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecoveryManager.InvalidRequestStatus.selector,
                recoveryId,
                RecoveryManager.RequestStatus.Verified,
                RecoveryManager.RequestStatus.Requested
            )
        );
        manager.verifyRecovery(recoveryId, ATTESTATION, block.timestamp + 30 days);
    }

    function testExpiredRequestRejected() public {
        bytes32 recoveryId = _createVerifiedAndApprovedRequest();
        RecoveryManager.RecoveryRequest memory request = manager.getRequest(recoveryId);

        vm.warp(request.executionExpiry + 1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.RequestExpired.selector, recoveryId));
        manager.authorizeExecution(recoveryId);

        request = manager.getRequest(recoveryId);
        assertEq(uint256(request.status), uint256(RecoveryManager.RequestStatus.Approved));
    }

    function testChallengedRequestCannotBeExecuted() public {
        bytes32 recoveryId = _createVerifiedAndApprovedRequest();

        vm.prank(guardian);
        manager.challengeRecovery(recoveryId, keccak256("challenge"));

        vm.warp(block.timestamp + CHALLENGE_PERIOD);
        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecoveryManager.InvalidRequestStatus.selector,
                recoveryId,
                RecoveryManager.RequestStatus.Challenged,
                RecoveryManager.RequestStatus.Approved
            )
        );
        manager.authorizeExecution(recoveryId);
    }

    function testAuthorizationRolesAreSeparated() public {
        bytes32 recoveryId = _createRequest();

        vm.prank(executor);
        vm.expectRevert();
        manager.verifyRecovery(recoveryId, ATTESTATION, block.timestamp + 30 days);

        vm.prank(verifier);
        manager.verifyRecovery(recoveryId, ATTESTATION, block.timestamp + 30 days);

        bytes32 approverRole = manager.RECOVERY_APPROVER_ROLE();
        vm.prank(admin);
        manager.grantRole(approverRole, verifier);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.AuthorizationNotSeparated.selector, verifier));
        manager.approveRecovery(recoveryId);
    }

    function testRequesterCannotVerifyOwnRequestEvenWhenGrantedVerifierRole() public {
        bytes32 recoveryId = _createRequest();
        bytes32 verifierRole = manager.IDENTITY_VERIFIER_ROLE();
        vm.prank(admin);
        manager.grantRole(verifierRole, requester);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(RecoveryManager.AuthorizationNotSeparated.selector, requester));
        manager.verifyRecovery(recoveryId, ATTESTATION, block.timestamp + 30 days);
    }

    function _createRequest() private returns (bytes32 recoveryId) {
        uint256 nonce = manager.recoveryNonce(revenueToken, source);
        uint256 deadline = block.timestamp + 30 days;
        bytes memory signature = _consentSignature(nonce, deadline, destinationKey);

        vm.prank(requester);
        recoveryId = manager.requestRecovery(revenueToken, source, destination, nonce, EVIDENCE, deadline, signature);
    }

    function _createVerifiedAndApprovedRequest() private returns (bytes32 recoveryId) {
        recoveryId = _createRequest();
        _verify(recoveryId);

        vm.prank(approver);
        manager.approveRecovery(recoveryId);
    }

    function _verify(bytes32 recoveryId) private {
        vm.prank(verifier);
        manager.verifyRecovery(recoveryId, ATTESTATION, block.timestamp + 30 days);
    }

    function _consentSignature(uint256 nonce, uint256 deadline, uint256 signingKey)
        private
        view
        returns (bytes memory)
    {
        bytes32 digest = manager.hashRecoveryConsent(revenueToken, source, destination, nonce, EVIDENCE, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
