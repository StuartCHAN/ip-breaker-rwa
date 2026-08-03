// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRecoveryMigrationToken} from "./interfaces/IRecoveryMigrationToken.sol";

/// @title RecoveryManager
/// @notice Governs recovery authorization and executes approved migrations on the fixed Revenue Token.
/// @dev Calls only the request's Revenue Token and never calls RevenueVault directly.
contract RecoveryManager is AccessControl, EIP712, ReentrancyGuard {
    enum RequestStatus {
        None,
        Requested,
        Verified,
        Approved,
        Challenged,
        ExecutionAuthorized,
        Executed,
        Cancelled,
        Expired
    }

    struct RecoveryRequest {
        address revenueToken;
        address source;
        address destination;
        address requester;
        address verifier;
        address approver;
        bytes32 evidenceCommitment;
        bytes32 attestationHash;
        uint256 nonce;
        uint256 consentDeadline;
        uint256 attestationExpiry;
        uint256 challengeDeadline;
        uint256 executionExpiry;
        RequestStatus status;
    }

    bytes32 public constant RECOVERY_REQUESTER_ROLE = keccak256("RECOVERY_REQUESTER");
    bytes32 public constant IDENTITY_VERIFIER_ROLE = keccak256("IDENTITY_VERIFIER");
    bytes32 public constant RECOVERY_APPROVER_ROLE = keccak256("RECOVERY_APPROVER");
    bytes32 public constant RECOVERY_EXECUTOR_ROLE = keccak256("RECOVERY_EXECUTOR");
    bytes32 public constant RECOVERY_GUARDIAN_ROLE = keccak256("RECOVERY_GUARDIAN");

    bytes32 public constant RECOVERY_CONSENT_TYPEHASH = keccak256(
        "RecoveryConsent(address revenueToken,address source,address destination,uint256 nonce,bytes32 evidenceCommitment,uint256 deadline)"
    );

    uint256 public immutable challengePeriod;
    uint256 public immutable executionWindow;

    mapping(bytes32 recoveryId => RecoveryRequest request) private _requests;
    mapping(address revenueToken => mapping(address source => uint256 nonce)) public recoveryNonce;
    mapping(address revenueToken => mapping(address source => bytes32 recoveryId)) public activeRequest;

    error ZeroAdmin();
    error InvalidChallengePeriod();
    error InvalidExecutionWindow();
    error InvalidRecoveryAccounts(address source, address destination);
    error ZeroRevenueToken();
    error InvalidRevenueToken(address revenueToken);
    error ZeroEvidenceCommitment();
    error InvalidDeadline(uint256 deadline);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidConsentSignature(address destination);
    error ActiveRequestExists(bytes32 recoveryId);
    error RequestNotFound(bytes32 recoveryId);
    error InvalidRequestStatus(bytes32 recoveryId, RequestStatus current, RequestStatus required);
    error RequestExpired(bytes32 recoveryId);
    error InvalidAttestation();
    error AuthorizationNotSeparated(address account);
    error ChallengePeriodActive(uint256 currentTime, uint256 challengeDeadline);
    error RequestNotExpired(bytes32 recoveryId);
    error UnauthorizedCancellation(address caller);

    event RecoveryRequested(
        bytes32 indexed recoveryId,
        address indexed revenueToken,
        address indexed source,
        address destination,
        uint256 nonce,
        bytes32 evidenceCommitment,
        address requester,
        uint256 consentDeadline
    );
    event RecoveryIdentityVerified(
        bytes32 indexed recoveryId, address indexed verifier, bytes32 attestationHash, uint256 attestationExpiry
    );
    event RecoveryApproved(
        bytes32 indexed recoveryId, address indexed approver, uint256 challengeDeadline, uint256 executionExpiry
    );
    event RecoveryChallenged(bytes32 indexed recoveryId, address indexed guardian, bytes32 reasonHash);
    event RecoveryExecutionAuthorized(
        bytes32 indexed recoveryId,
        address indexed executor,
        address indexed revenueToken,
        address source,
        address destination,
        uint256 nonce
    );
    event RecoveryExecuted(
        bytes32 indexed recoveryId,
        address indexed revenueToken,
        address indexed source,
        address destination,
        address executor
    );
    event RecoveryCancelled(bytes32 indexed recoveryId, address indexed authority, bytes32 reasonHash);
    event RecoveryExpired(bytes32 indexed recoveryId);

    constructor(address admin_, uint256 challengePeriod_, uint256 executionWindow_)
        EIP712("IP Breaker RecoveryManager", "1")
    {
        if (admin_ == address(0)) revert ZeroAdmin();
        if (challengePeriod_ == 0) revert InvalidChallengePeriod();
        if (executionWindow_ == 0) revert InvalidExecutionWindow();

        challengePeriod = challengePeriod_;
        executionWindow = executionWindow_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Creates an immutable recovery request with destination consent.
    function requestRecovery(
        address revenueToken,
        address source,
        address destination,
        uint256 nonce,
        bytes32 evidenceCommitment,
        uint256 consentDeadline,
        bytes calldata destinationSignature
    ) external onlyRole(RECOVERY_REQUESTER_ROLE) returns (bytes32 recoveryId) {
        if (revenueToken == address(0)) revert ZeroRevenueToken();
        if (revenueToken.code.length == 0) revert InvalidRevenueToken(revenueToken);
        if (source == address(0) || destination == address(0) || source == destination) {
            revert InvalidRecoveryAccounts(source, destination);
        }
        if (evidenceCommitment == bytes32(0)) revert ZeroEvidenceCommitment();
        if (consentDeadline <= block.timestamp) revert InvalidDeadline(consentDeadline);

        uint256 expectedNonce = recoveryNonce[revenueToken][source];
        if (nonce != expectedNonce) revert InvalidNonce(expectedNonce, nonce);

        bytes32 currentRequest = activeRequest[revenueToken][source];
        if (currentRequest != bytes32(0)) revert ActiveRequestExists(currentRequest);

        bytes32 consentDigest =
            hashRecoveryConsent(revenueToken, source, destination, nonce, evidenceCommitment, consentDeadline);
        if (!SignatureChecker.isValidSignatureNow(destination, consentDigest, destinationSignature)) {
            revert InvalidConsentSignature(destination);
        }

        recoveryId = keccak256(
            abi.encode(block.chainid, address(this), revenueToken, source, destination, nonce, evidenceCommitment)
        );
        if (_requests[recoveryId].status != RequestStatus.None) revert ActiveRequestExists(recoveryId);

        _requests[recoveryId] = RecoveryRequest({
            revenueToken: revenueToken,
            source: source,
            destination: destination,
            requester: msg.sender,
            verifier: address(0),
            approver: address(0),
            evidenceCommitment: evidenceCommitment,
            attestationHash: bytes32(0),
            nonce: nonce,
            consentDeadline: consentDeadline,
            attestationExpiry: 0,
            challengeDeadline: 0,
            executionExpiry: 0,
            status: RequestStatus.Requested
        });

        recoveryNonce[revenueToken][source] = expectedNonce + 1;
        activeRequest[revenueToken][source] = recoveryId;

        emit RecoveryRequested(
            recoveryId, revenueToken, source, destination, nonce, evidenceCommitment, msg.sender, consentDeadline
        );
    }

    /// @notice Records an independent identity-continuity attestation.
    function verifyRecovery(bytes32 recoveryId, bytes32 attestationHash, uint256 attestationExpiry)
        external
        onlyRole(IDENTITY_VERIFIER_ROLE)
    {
        RecoveryRequest storage request = _getRequest(recoveryId);
        _requireStatus(recoveryId, request.status, RequestStatus.Requested);
        _requireConsentLive(recoveryId, request);
        if (attestationHash == bytes32(0) || attestationExpiry <= block.timestamp) revert InvalidAttestation();
        if (msg.sender == request.requester) revert AuthorizationNotSeparated(msg.sender);

        request.verifier = msg.sender;
        request.attestationHash = attestationHash;
        request.attestationExpiry = attestationExpiry;
        request.status = RequestStatus.Verified;

        emit RecoveryIdentityVerified(recoveryId, msg.sender, attestationHash, attestationExpiry);
    }

    /// @notice Independently approves a verified request and starts its mandatory challenge period.
    function approveRecovery(bytes32 recoveryId) external onlyRole(RECOVERY_APPROVER_ROLE) {
        RecoveryRequest storage request = _getRequest(recoveryId);
        _requireStatus(recoveryId, request.status, RequestStatus.Verified);
        _requireConsentLive(recoveryId, request);
        if (block.timestamp > request.attestationExpiry) revert RequestExpired(recoveryId);
        if (msg.sender == request.requester || msg.sender == request.verifier) {
            revert AuthorizationNotSeparated(msg.sender);
        }

        uint256 deadline = block.timestamp + challengePeriod;
        uint256 expiry = deadline + executionWindow;
        if (expiry > request.consentDeadline || expiry > request.attestationExpiry) {
            revert RequestExpired(recoveryId);
        }

        request.approver = msg.sender;
        request.challengeDeadline = deadline;
        request.executionExpiry = expiry;
        request.status = RequestStatus.Approved;

        emit RecoveryApproved(recoveryId, msg.sender, deadline, expiry);
    }

    /// @notice Blocks execution of an approved request pending off-chain resolution.
    function challengeRecovery(bytes32 recoveryId, bytes32 reasonHash) external onlyRole(RECOVERY_GUARDIAN_ROLE) {
        RecoveryRequest storage request = _getRequest(recoveryId);
        _requireStatus(recoveryId, request.status, RequestStatus.Approved);

        request.status = RequestStatus.Challenged;
        emit RecoveryChallenged(recoveryId, msg.sender, reasonHash);
    }

    /// @notice Authorizes and atomically executes the request against its fixed Revenue Token.
    function authorizeExecution(bytes32 recoveryId) external onlyRole(RECOVERY_EXECUTOR_ROLE) nonReentrant {
        RecoveryRequest storage request = _getRequest(recoveryId);
        _requireStatus(recoveryId, request.status, RequestStatus.Approved);

        if (msg.sender == request.requester || msg.sender == request.verifier || msg.sender == request.approver) {
            revert AuthorizationNotSeparated(msg.sender);
        }

        if (block.timestamp < request.challengeDeadline) {
            revert ChallengePeriodActive(block.timestamp, request.challengeDeadline);
        }
        if (
            block.timestamp > request.executionExpiry || block.timestamp > request.consentDeadline
                || block.timestamp > request.attestationExpiry
        ) {
            revert RequestExpired(recoveryId);
        }

        request.status = RequestStatus.ExecutionAuthorized;

        emit RecoveryExecutionAuthorized(
            recoveryId, msg.sender, request.revenueToken, request.source, request.destination, request.nonce
        );

        IRecoveryMigrationToken(request.revenueToken)
            .executeRecoveryMigration(recoveryId, request.source, request.destination);

        request.status = RequestStatus.Executed;
        activeRequest[request.revenueToken][request.source] = bytes32(0);
        emit RecoveryExecuted(recoveryId, request.revenueToken, request.source, request.destination, msg.sender);
    }

    /// @notice Cancels a nonterminal request by its requester or a recovery guardian.
    function cancelRecovery(bytes32 recoveryId, bytes32 reasonHash) external {
        RecoveryRequest storage request = _getRequest(recoveryId);
        RequestStatus status = request.status;
        if (!_isLive(status)) revert InvalidRequestStatus(recoveryId, status, RequestStatus.Requested);

        bool isRequester = msg.sender == request.requester;
        bool isGuardian = hasRole(RECOVERY_GUARDIAN_ROLE, msg.sender);
        if (!isRequester && !isGuardian) revert UnauthorizedCancellation(msg.sender);

        request.status = RequestStatus.Cancelled;
        activeRequest[request.revenueToken][request.source] = bytes32(0);
        emit RecoveryCancelled(recoveryId, msg.sender, reasonHash);
    }

    /// @notice Finalizes an elapsed request deadline so a new nonce may be requested.
    function expireRecovery(bytes32 recoveryId) external {
        RecoveryRequest storage request = _getRequest(recoveryId);
        RequestStatus status = request.status;
        if (!_isLive(status)) revert InvalidRequestStatus(recoveryId, status, RequestStatus.Requested);

        bool expired = block.timestamp > request.consentDeadline;
        if (status == RequestStatus.Verified || status == RequestStatus.Approved) {
            expired = expired || block.timestamp > request.attestationExpiry;
        }
        if (status == RequestStatus.Approved) {
            expired = expired || block.timestamp > request.executionExpiry;
        }
        if (!expired) revert RequestNotExpired(recoveryId);

        request.status = RequestStatus.Expired;
        activeRequest[request.revenueToken][request.source] = bytes32(0);
        emit RecoveryExpired(recoveryId);
    }

    function getRequest(bytes32 recoveryId) external view returns (RecoveryRequest memory) {
        RecoveryRequest memory request = _requests[recoveryId];
        if (request.status == RequestStatus.None) revert RequestNotFound(recoveryId);
        return request;
    }

    /// @notice Allows the bound Revenue Token to verify the exact in-flight migration parameters.
    function isExecutionAuthorized(bytes32 recoveryId, address revenueToken, address source, address destination)
        external
        view
        returns (bool)
    {
        RecoveryRequest storage request = _requests[recoveryId];
        return request.status == RequestStatus.ExecutionAuthorized && request.revenueToken == revenueToken
            && request.source == source && request.destination == destination;
    }

    function hashRecoveryConsent(
        address revenueToken,
        address source,
        address destination,
        uint256 nonce,
        bytes32 evidenceCommitment,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECOVERY_CONSENT_TYPEHASH, revenueToken, source, destination, nonce, evidenceCommitment, deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _getRequest(bytes32 recoveryId) private view returns (RecoveryRequest storage request) {
        request = _requests[recoveryId];
        if (request.status == RequestStatus.None) revert RequestNotFound(recoveryId);
    }

    function _requireStatus(bytes32 recoveryId, RequestStatus current, RequestStatus required) private pure {
        if (current != required) revert InvalidRequestStatus(recoveryId, current, required);
    }

    function _requireConsentLive(bytes32 recoveryId, RecoveryRequest storage request) private view {
        if (block.timestamp > request.consentDeadline) revert RequestExpired(recoveryId);
    }

    function _isLive(RequestStatus status) private pure returns (bool) {
        return status == RequestStatus.Requested || status == RequestStatus.Verified || status == RequestStatus.Approved
            || status == RequestStatus.Challenged;
    }
}
