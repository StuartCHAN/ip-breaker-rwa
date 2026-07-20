// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IIPAssetRegistry} from "./interfaces/IIPAssetRegistry.sol";

/// @title LicenseEscrow
/// @notice Creates license offers for registered IP assets and mints license certificate NFTs.
///         Also supports an escrow-based licensing flow with dispute arbitration between
///         a licensor, a licensee, and an arbiter snapshotted per agreement (see `arbiter`
///         and `createLicenseAgreement` for how the global default is captured per deal).
/// @dev The License Certificate NFT represents a usage-right certificate,
///      not an investment product or fractional ownership of the underlying IP.
contract LicenseEscrow is ERC721, Ownable, ReentrancyGuard {
    // ============ Types: existing offer/license NFT flow ============

    struct LicenseOffer {
        uint256 assetId;
        address licensor;
        uint256 price;
        uint64 duration;
        bytes32 termsHash;
        string termsURI;
        bool transferable;
        bool active;
        uint256 createdAt;
    }

    struct License {
        uint256 assetId;
        uint256 offerId;
        address licensee;
        uint256 issuedAt;
        uint256 expiresAt;
        bytes32 termsHash;
        string termsURI;
        bool transferable;
    }

    // ============ Types: escrow + arbitration flow ============

    enum LicenseStatus {
        Created, // 已创建，等待被许可方付款
        Funded, // 已付款，资金托管中，等待权利人确认履行
        Active, // 权利人已确认履行，等待被许可方验收放款或发起争议
        Disputed, // 争议中，等待仲裁方裁决
        Completed, // 资金已释放给权利人（正常放款或仲裁裁决支持权利人）
        Refunded, // 资金已退还被许可方（仲裁裁决支持被许可方）
        Cancelled // 付款前被权利人取消

    }

    /// @dev v0.1 KNOWN LIMITATION: there are no funding/performance/acceptance deadlines.
    ///      An agreement can only move forward via an explicit action from the licensor,
    ///      licensee, or arbiter — if a party goes silent (e.g. licensor never calls
    ///      confirmPerformance, or the arbiter never resolves a dispute), funds stay locked
    ///      in escrow indefinitely with no automatic timeout/refund path. Timeout-based
    ///      auto-transitions (e.g. Funded -> Refunded after a performance deadline) are
    ///      planned for a later version and intentionally out of scope here.
    struct LicenseAgreement {
        uint256 assetId; // 关联的 IP 资产编号
        address licensor; // 权利人
        LicenseStatus status; // 当前状态（与 licensor 同槽打包）
        address licensee; // 被许可方
        // 创建时从全局 arbiter 快照进来的仲裁人地址。后续 setArbiter() 更换全局仲裁人
        // 不会影响已创建的协议——避免争议发生后仲裁人被中途替换的信任风险。
        address arbiter;
        uint256 licenseFee; // 约定许可费（wei）
        uint256 escrowedAmount; // 实际已托管金额，释放/退款后清零
        bytes32 termsHash; // 许可条款哈希；完整条款文本/URI 只在创建事件中记录，不占用存储
        uint64 createdAt; // 创建时间戳（与 fundedAt 同槽打包）
        uint64 fundedAt; // 付款时间戳（0 表示尚未付款）
    }

    // ============ Errors: existing offer/license NFT flow ============

    error ZeroAssetRegistry();
    error AssetDoesNotExist(uint256 assetId);
    error NotAssetOwner(uint256 assetId, address caller);
    error OfferDoesNotExist(uint256 offerId);
    error NotOfferLicensor(uint256 offerId, address caller);
    error OfferNotActive(uint256 offerId);
    error LicensorNoLongerAssetOwner(uint256 assetId, address licensor);
    error InvalidPrice();
    error InvalidDuration();
    error ZeroTermsHash();
    error EmptyTermsURI();
    error BuyerIsLicensor();
    error IncorrectPayment(uint256 expected, uint256 actual);
    error PaymentTransferFailed();
    error LicenseDoesNotExist(uint256 licenseId);
    error NonTransferableLicense(uint256 licenseId);

    // ============ Errors: escrow + arbitration flow ============

    error AgreementDoesNotExist(uint256 agreementId);
    error NotLicensor(uint256 agreementId, address caller);
    error NotLicensee(uint256 agreementId, address caller);
    error NotLicensorOrLicensee(uint256 agreementId, address caller);
    error NotArbiter(uint256 agreementId, address caller);
    error InvalidStatusTransition(LicenseStatus from, LicenseStatus to);
    error IncorrectLicenseFee(uint256 expected, uint256 actual);
    error ZeroLicenseFee();
    error InvalidLicensee();
    error ZeroArbiter();

    // ============ Events: existing offer/license NFT flow ============

    event LicenseOfferCreated(
        uint256 indexed offerId,
        uint256 indexed assetId,
        address indexed licensor,
        uint256 price,
        uint64 duration,
        bytes32 termsHash,
        string termsURI,
        bool transferable
    );

    event LicenseOfferStatusUpdated(uint256 indexed offerId, bool active);

    event LicensePurchased(
        uint256 indexed offerId,
        uint256 indexed licenseId,
        uint256 indexed assetId,
        address licensee,
        address licensor,
        uint256 price,
        uint256 issuedAt,
        uint256 expiresAt
    );

    // ============ Events: escrow + arbitration flow ============

    event LicenseAgreementCreated(
        uint256 indexed agreementId,
        uint256 indexed assetId,
        address indexed licensor,
        address licensee,
        address arbiter,
        uint256 licenseFee,
        bytes32 termsHash,
        string termsURI
    );

    event LicenseStatusChanged(uint256 indexed agreementId, LicenseStatus from, LicenseStatus to);

    event LicenseFunded(uint256 indexed agreementId, address indexed licensee, uint256 amount);

    event PerformanceConfirmed(uint256 indexed agreementId, address indexed licensor);

    event FundsReleased(uint256 indexed agreementId, address indexed to, uint256 amount);

    event DisputeRaised(uint256 indexed agreementId, address indexed raisedBy);

    event DisputeResolved(uint256 indexed agreementId, bool paidToLicensor, uint256 amount);

    event AgreementCancelled(uint256 indexed agreementId);

    event ArbiterUpdated(address indexed previousArbiter, address indexed newArbiter);

    // ============ Storage ============

    IIPAssetRegistry public immutable assetRegistry;

    uint256 private _nextOfferId = 1;
    uint256 private _nextLicenseId = 1;

    mapping(uint256 offerId => LicenseOffer offer) public licenseOffers;
    mapping(uint256 licenseId => License licenseData) public licenses;
    mapping(uint256 assetId => uint256 totalRevenue) public totalRevenueByAsset;

    /// @notice Global arbiter role for the escrow + dispute flow. Deployer by default.
    address public arbiter;

    uint256 private _nextAgreementId = 1;

    mapping(uint256 agreementId => LicenseAgreement agreement) public agreements;

    constructor(address assetRegistry_) ERC721("IP Breaker License", "IPBL") Ownable(msg.sender) {
        if (assetRegistry_ == address(0)) revert ZeroAssetRegistry();
        assetRegistry = IIPAssetRegistry(assetRegistry_);

        // Arbiter defaults to the deployer and can be reassigned later via setArbiter().
        // Kept out of the constructor signature so existing deployments/tests are unaffected.
        arbiter = msg.sender;
    }

    // ======================================================================
    // Existing offer/license NFT flow (unchanged)
    // ======================================================================

    /// @notice Creates a license offer for an existing IP asset.
    /// @dev Only the current owner of the IP Asset NFT can create a license offer.
    function createLicenseOffer(
        uint256 assetId,
        uint256 price,
        uint64 duration,
        bytes32 termsHash,
        string calldata termsURI,
        bool transferable
    ) external returns (uint256 offerId) {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        if (assetRegistry.ownerOf(assetId) != msg.sender) {
            revert NotAssetOwner(assetId, msg.sender);
        }
        if (price == 0) revert InvalidPrice();
        if (duration == 0) revert InvalidDuration();
        if (termsHash == bytes32(0)) revert ZeroTermsHash();
        if (bytes(termsURI).length == 0) revert EmptyTermsURI();

        offerId = _nextOfferId++;

        licenseOffers[offerId] = LicenseOffer({
            assetId: assetId,
            licensor: msg.sender,
            price: price,
            duration: duration,
            termsHash: termsHash,
            termsURI: termsURI,
            transferable: transferable,
            active: true,
            createdAt: block.timestamp
        });

        emit LicenseOfferCreated(offerId, assetId, msg.sender, price, duration, termsHash, termsURI, transferable);
    }

    /// @notice Activates or deactivates a license offer.
    /// @dev Only the original licensor can update offer status.
    function setLicenseOfferActive(uint256 offerId, bool active) external {
        LicenseOffer storage offer = _getExistingOffer(offerId);

        if (msg.sender != offer.licensor) {
            revert NotOfferLicensor(offerId, msg.sender);
        }

        offer.active = active;

        emit LicenseOfferStatusUpdated(offerId, active);
    }

    /// @notice Buys a license and mints a License Certificate NFT to the buyer.
    /// @dev The offer may be bought multiple times while active.
    function buyLicense(uint256 offerId) external payable nonReentrant returns (uint256 licenseId) {
        LicenseOffer memory offer = _getExistingOffer(offerId);

        if (!offer.active) revert OfferNotActive(offerId);
        if (msg.sender == offer.licensor) revert BuyerIsLicensor();
        if (msg.value != offer.price) {
            revert IncorrectPayment(offer.price, msg.value);
        }

        // Prevent stale offers from being sold after the IP Asset NFT changes hands.
        if (assetRegistry.ownerOf(offer.assetId) != offer.licensor) {
            revert LicensorNoLongerAssetOwner(offer.assetId, offer.licensor);
        }

        licenseId = _nextLicenseId++;

        uint256 issuedAt = block.timestamp;
        uint256 expiresAt = issuedAt + uint256(offer.duration);

        licenses[licenseId] = License({
            assetId: offer.assetId,
            offerId: offerId,
            licensee: msg.sender,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            termsHash: offer.termsHash,
            termsURI: offer.termsURI,
            transferable: offer.transferable
        });

        totalRevenueByAsset[offer.assetId] += msg.value;

        _safeMint(msg.sender, licenseId);

        (bool success,) = payable(offer.licensor).call{value: msg.value}("");
        if (!success) revert PaymentTransferFailed();

        emit LicensePurchased(
            offerId, licenseId, offer.assetId, msg.sender, offer.licensor, msg.value, issuedAt, expiresAt
        );
    }

    /// @notice Returns a license offer by ID.
    function getLicenseOffer(uint256 offerId) external view returns (LicenseOffer memory offer) {
        return _getExistingOffer(offerId);
    }

    /// @notice Returns a license certificate by ID.
    function getLicense(uint256 licenseId) external view returns (License memory licenseData) {
        if (!licenseExists(licenseId)) revert LicenseDoesNotExist(licenseId);
        return licenses[licenseId];
    }

    /// @notice Returns whether a license NFT exists.
    function licenseExists(uint256 licenseId) public view returns (bool) {
        return _ownerOf(licenseId) != address(0);
    }

    /// @notice Returns whether a license is currently within its duration.
    function isLicenseValid(uint256 licenseId) external view returns (bool) {
        if (!licenseExists(licenseId)) return false;
        return block.timestamp <= licenses[licenseId].expiresAt;
    }

    /// @notice Returns the metadata URI associated with a License Certificate NFT.
    /// @dev For v0.1, this points to the offchain license terms URI.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!licenseExists(tokenId)) revert LicenseDoesNotExist(tokenId);
        return licenses[tokenId].termsURI;
    }

    /// @notice Returns the next license offer ID that will be assigned.
    function nextOfferId() external view returns (uint256) {
        return _nextOfferId;
    }

    /// @notice Returns the next license certificate ID that will be assigned.
    function nextLicenseId() external view returns (uint256) {
        return _nextLicenseId;
    }

    // ======================================================================
    // Escrow + arbitration flow
    // ======================================================================

    /// @notice Creates a new escrow-based license agreement in the Created state.
    /// @dev Only the current owner of the IP Asset NFT can create an agreement. Snapshots
    ///      the current global `arbiter` into the agreement so a later setArbiter() call
    ///      cannot change who adjudicates an already-created (possibly already-funded) deal.
    function createLicenseAgreement(
        uint256 assetId,
        address licensee,
        uint256 licenseFee,
        bytes32 termsHash,
        string calldata termsURI
    ) external returns (uint256 agreementId) {
        if (!assetRegistry.exists(assetId)) revert AssetDoesNotExist(assetId);
        if (assetRegistry.ownerOf(assetId) != msg.sender) {
            revert NotAssetOwner(assetId, msg.sender);
        }
        if (licensee == address(0) || licensee == msg.sender) revert InvalidLicensee();
        if (licenseFee == 0) revert ZeroLicenseFee();
        if (termsHash == bytes32(0)) revert ZeroTermsHash();
        if (bytes(termsURI).length == 0) revert EmptyTermsURI();

        agreementId = _nextAgreementId++;

        agreements[agreementId] = LicenseAgreement({
            assetId: assetId,
            licensor: msg.sender,
            status: LicenseStatus.Created,
            licensee: licensee,
            arbiter: arbiter,
            licenseFee: licenseFee,
            escrowedAmount: 0,
            termsHash: termsHash,
            createdAt: uint64(block.timestamp),
            fundedAt: 0
        });

        emit LicenseAgreementCreated(agreementId, assetId, msg.sender, licensee, arbiter, licenseFee, termsHash, termsURI);
    }

    /// @notice Licensee pays the agreed license fee into escrow.
    /// @dev Reverts on a second call because the agreement is no longer in Created status
    ///      once funded — the transition gate itself prevents double payment. Also re-checks
    ///      asset ownership: if the licensor has since transferred away the underlying IP
    ///      Asset NFT, the agreement is stale and funding is rejected (mirrors buyLicense()'s
    ///      LicensorNoLongerAssetOwner check in the direct-purchase flow, for consistency).
    function fundLicense(uint256 agreementId) external payable nonReentrant {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.licensee) revert NotLicensee(agreementId, msg.sender);
        if (msg.value != agreement.licenseFee) {
            revert IncorrectLicenseFee(agreement.licenseFee, msg.value);
        }
        if (assetRegistry.ownerOf(agreement.assetId) != agreement.licensor) {
            revert LicensorNoLongerAssetOwner(agreement.assetId, agreement.licensor);
        }

        _transition(agreementId, agreement, LicenseStatus.Created, LicenseStatus.Funded);

        agreement.escrowedAmount = msg.value;
        agreement.fundedAt = uint64(block.timestamp);

        emit LicenseFunded(agreementId, msg.sender, msg.value);
    }

    /// @notice Licensor confirms that performance (delivery of the licensed rights) is done.
    function confirmPerformance(uint256 agreementId) external {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.licensor) revert NotLicensor(agreementId, msg.sender);

        _transition(agreementId, agreement, LicenseStatus.Funded, LicenseStatus.Active);

        emit PerformanceConfirmed(agreementId, msg.sender);
    }

    /// @notice Licensee accepts performance and releases escrowed funds to the licensor.
    /// @dev Completed is also reachable from Disputed via resolveDispute(); passing
    ///      LicenseStatus.Active as expectedFrom to _transition() is what enforces rule 7
    ///      (no release while Disputed) — the graph alone can't tell these two edges apart,
    ///      since Active -> Completed and Disputed -> Completed are both topologically legal.
    function release(uint256 agreementId) external nonReentrant {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.licensee) revert NotLicensee(agreementId, msg.sender);

        _transition(agreementId, agreement, LicenseStatus.Active, LicenseStatus.Completed);

        uint256 amount = agreement.escrowedAmount;
        agreement.escrowedAmount = 0;
        totalRevenueByAsset[agreement.assetId] += amount;

        (bool success,) = payable(agreement.licensor).call{value: amount}("");
        if (!success) revert PaymentTransferFailed();

        emit FundsReleased(agreementId, agreement.licensor, amount);
    }

    /// @notice Either party raises a dispute from Funded or Active, freezing the escrow.
    /// @dev Unlike release()/resolveDispute(), Disputed has no shared-destination ambiguity
    ///      to resolve — Funded and Active are both legitimate starting points for a dispute,
    ///      and nothing else can produce a Disputed status. So expectedFrom here is just the
    ///      agreement's current status (the check is trivially true); the real gate is still
    ///      _isValidTransition(current, Disputed) inside _transition(), which accepts Funded
    ///      or Active and rejects everything else (Created, Disputed itself, and all
    ///      terminal states).
    function raiseDispute(uint256 agreementId) external {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.licensor && msg.sender != agreement.licensee) {
            revert NotLicensorOrLicensee(agreementId, msg.sender);
        }

        _transition(agreementId, agreement, agreement.status, LicenseStatus.Disputed);

        emit DisputeRaised(agreementId, msg.sender);
    }

    /// @notice Arbiter resolves a dispute, paying either the licensor or the licensee.
    /// @dev Completed is also reachable from Active via release(); passing
    ///      LicenseStatus.Disputed as expectedFrom to _transition() is what stops an arbiter
    ///      from force-completing an agreement that was never disputed.
    ///      Checks against agreement.arbiter (snapshotted at creation), not the current global
    ///      arbiter — see createLicenseAgreement's NatSpec for why.
    function resolveDispute(uint256 agreementId, bool payToLicensor) external nonReentrant {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.arbiter) revert NotArbiter(agreementId, msg.sender);

        _transition(
            agreementId,
            agreement,
            LicenseStatus.Disputed,
            payToLicensor ? LicenseStatus.Completed : LicenseStatus.Refunded
        );

        uint256 amount = agreement.escrowedAmount;
        agreement.escrowedAmount = 0;

        address recipient = payToLicensor ? agreement.licensor : agreement.licensee;

        // Only a payout to the licensor counts as realized license revenue for the asset —
        // a refund to the licensee is money going back, not revenue.
        if (payToLicensor) {
            totalRevenueByAsset[agreement.assetId] += amount;
        }

        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert PaymentTransferFailed();

        emit DisputeResolved(agreementId, payToLicensor, amount);
    }

    /// @notice Licensor cancels an agreement before it has been funded.
    function cancelAgreement(uint256 agreementId) external {
        LicenseAgreement storage agreement = _getExistingAgreement(agreementId);

        if (msg.sender != agreement.licensor) revert NotLicensor(agreementId, msg.sender);

        _transition(agreementId, agreement, LicenseStatus.Created, LicenseStatus.Cancelled);

        emit AgreementCancelled(agreementId);
    }

    /// @notice Updates the global arbiter address.
    function setArbiter(address newArbiter) external onlyOwner {
        if (newArbiter == address(0)) revert ZeroArbiter();

        emit ArbiterUpdated(arbiter, newArbiter);
        arbiter = newArbiter;
    }

    /// @notice Returns a license agreement by ID.
    function getAgreement(uint256 agreementId) external view returns (LicenseAgreement memory) {
        return _getExistingAgreement(agreementId);
    }

    /// @notice Returns the next license agreement ID that will be assigned.
    function nextAgreementId() external view returns (uint256) {
        return _nextAgreementId;
    }

    // ======================================================================
    // Internal
    // ======================================================================

    /// @dev Restricts transfer of non-transferable license certificate NFTs.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address previousOwner) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            if (!licenses[tokenId].transferable) {
                revert NonTransferableLicense(tokenId);
            }
        }

        previousOwner = super._update(to, tokenId, auth);

        if (from != address(0) && to != address(0)) {
            licenses[tokenId].licensee = to;
        }
    }

    function _getExistingOffer(uint256 offerId) internal view returns (LicenseOffer storage offer) {
        if (offerId == 0 || offerId >= _nextOfferId) {
            revert OfferDoesNotExist(offerId);
        }

        offer = licenseOffers[offerId];
    }

    function _getExistingAgreement(uint256 agreementId) internal view returns (LicenseAgreement storage agreement) {
        if (agreementId == 0 || agreementId >= _nextAgreementId) {
            revert AgreementDoesNotExist(agreementId);
        }

        agreement = agreements[agreementId];
    }

    /// @dev Single choke point for every agreement status change: validates BOTH that the
    ///      agreement is currently in `expectedFrom` AND that expectedFrom -> to is a legal
    ///      edge in the state graph, then writes the new status and emits
    ///      LicenseStatusChanged. Requiring the caller to name its expected starting state
    ///      (rather than only checking graph topology) is what closes the ambiguity around
    ///      shared destination states like Completed (reachable from both Active via
    ///      release() and Disputed via resolveDispute()) — each call site now states its own
    ///      precondition explicitly instead of relying on a shared graph that can't tell two
    ///      different functions' edges apart. Every external function that moves an agreement
    ///      forward goes through this, so every legal transition is logged (rule 9) and every
    ///      illegal one — including "right edge, wrong function" — reverts here (rule 10).
    function _transition(
        uint256 agreementId,
        LicenseAgreement storage agreement,
        LicenseStatus expectedFrom,
        LicenseStatus to
    ) internal {
        LicenseStatus from = agreement.status;

        if (from != expectedFrom || !_isValidTransition(from, to)) {
            revert InvalidStatusTransition(from, to);
        }

        agreement.status = to;

        emit LicenseStatusChanged(agreementId, from, to);
    }

    /// @dev Encodes the state graph from the design doc. Terminal states
    ///      (Completed, Refunded, Cancelled) have no outgoing edges.
    function _isValidTransition(LicenseStatus from, LicenseStatus to) internal pure returns (bool) {
        if (from == LicenseStatus.Created) {
            return to == LicenseStatus.Funded || to == LicenseStatus.Cancelled;
        }
        if (from == LicenseStatus.Funded) {
            return to == LicenseStatus.Active || to == LicenseStatus.Disputed;
        }
        if (from == LicenseStatus.Active) {
            return to == LicenseStatus.Completed || to == LicenseStatus.Disputed;
        }
        if (from == LicenseStatus.Disputed) {
            return to == LicenseStatus.Completed || to == LicenseStatus.Refunded;
        }
        return false;
    }
}
