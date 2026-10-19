// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

interface ILayrsVenueVault is IERC4626 {
    function totalAssets() external view returns (uint256);
    function receiveFromVenue(uint256 amount) external;
}

interface IStargateOFT {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt, OFTReceipt memory oftReceipt);
}

contract BaseCrossChainZenStrategyManager is AccessControl, ReentrancyGuard, EIP712, IBridgeAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant QUEUE_MANAGER_ROLE = keccak256("QUEUE_MANAGER_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 public constant TEE_APPROVER_ROLE = keccak256("TEE_APPROVER_ROLE");

    bytes32 public constant BRIDGE_APPROVAL_TYPEHASH = keccak256(
        "BridgeApproval(address independentApprover,address teeApprover,uint256 amount,uint32 destinationEid,address recipient,uint256 minAmountLD,uint256 nativeFee,uint256 nonce,uint256 deadline,bytes32 routeHash)"
    );

    uint256 public constant BPS_DENOMINATOR = 10_000;

    enum BridgeStatus {
        NONE,
        SOURCE_SENT,
        REMOTE_RECEIVED,
        FAILED
    }

    enum WithdrawalStatus {
        NONE,
        QUEUED,
        COMPLETED,
        CANCELLED
    }

    struct BridgeParams {
        uint256 minAmountLD;
        uint256 nativeFee;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
        address refundAddress;
    }

    struct BridgeApproval {
        address independentApprover;
        address teeApprover;
        uint256 amount;
        uint32 destinationEid;
        address recipient;
        uint256 minAmountLD;
        uint256 nativeFee;
        uint256 nonce;
        uint256 deadline;
        bytes32 routeHash;
        bytes independentSignature;
        bytes teeSignature;
    }

    struct BridgeRecord {
        uint256 amount;
        uint256 minAmount;
        address recipient;
        BridgeStatus status;
        uint64 createdAt;
        bytes32 destinationTxHash;
    }

    struct AsyncWithdrawal {
        address owner;
        address receiver;
        uint256 shares;
        uint256 assetsAtQueue;
        WithdrawalStatus status;
        uint64 queuedAt;
        uint64 completedAt;
    }

    error ZeroAddress();
    error ZeroAmount();
    error UnauthorizedVault(address caller);
    error InvalidBps();
    error InvalidDestination(uint32 dstEid, address recipient);
    error IdleBufferBreach(uint256 postBridgeIdle, uint256 minimumIdle);
    error RemoteAllocationBreach(uint256 postBridgeRemote, uint256 maximumRemote);
    error InsufficientBridgeFee(uint256 required, uint256 available);
    error BridgeApprovalExpired(uint256 deadline);
    error BridgeApprovalNonceUsed(uint256 nonce);
    error InvalidBridgeApproval();
    error InvalidBridgeApprover(address approver, bytes32 requiredRole);
    error InvalidBridgeSignature(address approver);
    error UnknownBridge(bytes32 messageId);
    error InvalidBridgeStatus(BridgeStatus status);
    error InvalidDeliveredAmount(uint256 deliveredAmount, uint256 sourceAmount);
    error BaseReturnAlreadyProcessed(bytes32 messageId);
    error UnknownWithdrawal(uint256 requestId);
    error InvalidWithdrawalStatus(WithdrawalStatus status);
    error InsufficientBaseLiquidity(uint256 requestedAssets, uint256 availableAssets);
    error ETHRefundFailed();

    IERC20 public immutable asset;
    ILayrsVenueVault public immutable vault;
    IStargateOFT public immutable oft;
    uint32 public immutable horizenEid;
    address public remoteReceiver;

    uint256 public minIdleBps;
    uint256 public maxRemoteBps;
    uint256 public pendingOutbound;
    uint256 public remoteReportedBalance;
    uint64 public lastRemoteReportAt;
    bytes32 public lastRemoteReportHash;
    uint256 public nextWithdrawalRequestId = 1;

    mapping(bytes32 => BridgeRecord) public bridgeRecords;
    mapping(bytes32 => bool) public processedBaseReturns;
    mapping(uint256 => AsyncWithdrawal) public withdrawalRequests;
    mapping(uint256 => bool) public bridgeApprovalNonceUsed;

    event RemoteReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event AllocationPolicyUpdated(uint256 minIdleBps, uint256 maxRemoteBps);
    event RemoteBalanceReported(uint256 balance, bytes32 indexed reportHash, uint64 reportedAt);
    event BridgeSourceSent(bytes32 indexed messageId, uint256 amount, uint256 minAmount, address indexed recipient);
    event BridgeRemoteReceived(bytes32 indexed messageId, uint256 deliveredAmount, bytes32 indexed destinationTxHash);
    event BridgeMarkedFailed(bytes32 indexed messageId, bytes32 indexed failureHash);
    event BaseReturnRecorded(bytes32 indexed messageId, uint256 amount, bytes32 indexed sourceTxHash);
    event AsyncWithdrawalQueued(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 assetsAtQueue
    );
    event AsyncWithdrawalCompleted(uint256 indexed requestId, uint256 assets);
    event AsyncWithdrawalCancelled(uint256 indexed requestId);

    constructor(
        address asset_,
        address vault_,
        address oft_,
        uint32 horizenEid_,
        address remoteReceiver_,
        address admin_,
        uint256 minIdleBps_,
        uint256 maxRemoteBps_
    ) EIP712("LayrsBaseZenStrategyManager", "1") {
        if (asset_ == address(0) || vault_ == address(0) || oft_ == address(0) || remoteReceiver_ == address(0)) {
            revert ZeroAddress();
        }
        if (admin_ == address(0)) revert ZeroAddress();
        if (minIdleBps_ > BPS_DENOMINATOR || maxRemoteBps_ > BPS_DENOMINATOR) revert InvalidBps();
        if (minIdleBps_ + maxRemoteBps_ > BPS_DENOMINATOR) revert InvalidBps();

        asset = IERC20(asset_);
        vault = ILayrsVenueVault(vault_);
        oft = IStargateOFT(oft_);
        horizenEid = horizenEid_;
        remoteReceiver = remoteReceiver_;
        minIdleBps = minIdleBps_;
        maxRemoteBps = maxRemoteBps_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, admin_);
        _grantRole(REPORTER_ROLE, admin_);
        _grantRole(QUEUE_MANAGER_ROLE, admin_);
        _grantRole(APPROVER_ROLE, admin_);
        _grantRole(TEE_APPROVER_ROLE, admin_);
    }

    function bridgeUSDC(uint256 amount, uint32 destinationDomain, address recipient, bytes calldata extraData)
        external
        override
        nonReentrant
        returns (bytes32 messageId)
    {
        if (msg.sender != address(vault)) revert UnauthorizedVault(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (destinationDomain != horizenEid || recipient != remoteReceiver) {
            revert InvalidDestination(destinationDomain, recipient);
        }

        (BridgeParams memory params, BridgeApproval memory approval) =
            abi.decode(extraData, (BridgeParams, BridgeApproval));
        _consumeBridgeApproval(amount, destinationDomain, recipient, params, approval);
        if (address(this).balance < params.nativeFee) {
            revert InsufficientBridgeFee(params.nativeFee, address(this).balance);
        }

        _enforceAllocationAfterBridge(amount);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(address(oft), amount);

        // The function is nonReentrant and no role-bearing mutation path is
        // callable from the OFT. Slither only reports the public view of the
        // pre-call pending balance during the external call.
        // slither-disable-next-line reentrancy-eth
        (IStargateOFT.MessagingReceipt memory receipt, IStargateOFT.OFTReceipt memory oftReceipt) = oft.send{
            value: params.nativeFee
        }(
            IStargateOFT.SendParam({
                dstEid: destinationDomain,
                to: _addressToBytes32(recipient),
                amountLD: amount,
                minAmountLD: params.minAmountLD,
                extraOptions: params.extraOptions,
                composeMsg: params.composeMsg,
                oftCmd: params.oftCmd
            }),
            IStargateOFT.MessagingFee({nativeFee: params.nativeFee, lzTokenFee: 0}),
            params.refundAddress == address(0) ? address(this) : params.refundAddress
        );
        asset.forceApprove(address(oft), 0);

        messageId = receipt.guid;
        if (messageId == bytes32(0)) {
            messageId = keccak256(abi.encodePacked(block.chainid, address(this), amount, pendingOutbound, block.number));
        }

        pendingOutbound += oftReceipt.amountSentLD;
        bridgeRecords[messageId] = BridgeRecord({
            amount: oftReceipt.amountSentLD,
            minAmount: oftReceipt.amountReceivedLD,
            recipient: recipient,
            status: BridgeStatus.SOURCE_SENT,
            createdAt: uint64(block.timestamp),
            destinationTxHash: bytes32(0)
        });

        emit BridgeSourceSent(messageId, oftReceipt.amountSentLD, oftReceipt.amountReceivedLD, recipient);
        emit BridgeInitiated(destinationDomain, recipient, oftReceipt.amountSentLD, messageId);
    }

    function bridgeRouteHash(BridgeParams memory params) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(params.extraOptions),
                keccak256(params.composeMsg),
                keccak256(params.oftCmd),
                params.refundAddress
            )
        );
    }

    function bridgeApprovalDigest(BridgeApproval memory approval) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    BRIDGE_APPROVAL_TYPEHASH,
                    approval.independentApprover,
                    approval.teeApprover,
                    approval.amount,
                    approval.destinationEid,
                    approval.recipient,
                    approval.minAmountLD,
                    approval.nativeFee,
                    approval.nonce,
                    approval.deadline,
                    approval.routeHash
                )
            )
        );
    }

    function _consumeBridgeApproval(
        uint256 amount,
        uint32 destinationDomain,
        address recipient,
        BridgeParams memory params,
        BridgeApproval memory approval
    ) private {
        if (approval.deadline < block.timestamp) revert BridgeApprovalExpired(approval.deadline);
        if (bridgeApprovalNonceUsed[approval.nonce]) revert BridgeApprovalNonceUsed(approval.nonce);
        if (
            approval.independentApprover == address(0) || approval.teeApprover == address(0)
                || approval.independentApprover == approval.teeApprover || approval.amount != amount
                || approval.destinationEid != destinationDomain || approval.recipient != recipient
                || approval.minAmountLD != params.minAmountLD || approval.nativeFee != params.nativeFee
                || approval.routeHash != bridgeRouteHash(params)
        ) {
            revert InvalidBridgeApproval();
        }
        if (!hasRole(APPROVER_ROLE, approval.independentApprover)) {
            revert InvalidBridgeApprover(approval.independentApprover, APPROVER_ROLE);
        }
        if (!hasRole(TEE_APPROVER_ROLE, approval.teeApprover)) {
            revert InvalidBridgeApprover(approval.teeApprover, TEE_APPROVER_ROLE);
        }

        bytes32 digest = bridgeApprovalDigest(approval);
        if (!SignatureChecker.isValidSignatureNow(approval.independentApprover, digest, approval.independentSignature))
        {
            revert InvalidBridgeSignature(approval.independentApprover);
        }
        if (!SignatureChecker.isValidSignatureNow(approval.teeApprover, digest, approval.teeSignature)) {
            revert InvalidBridgeSignature(approval.teeApprover);
        }

        bridgeApprovalNonceUsed[approval.nonce] = true;
    }

    function reportRemoteBalance(uint256 balance, bytes32 reportHash) external onlyRole(REPORTER_ROLE) nonReentrant {
        remoteReportedBalance = balance;
        lastRemoteReportAt = uint64(block.timestamp);
        lastRemoteReportHash = reportHash;
        emit RemoteBalanceReported(balance, reportHash, uint64(block.timestamp));
    }

    function markRemoteReceived(bytes32 messageId, uint256 deliveredAmount, bytes32 destinationTxHash)
        external
        onlyRole(REPORTER_ROLE)
        nonReentrant
    {
        BridgeRecord storage record = bridgeRecords[messageId];
        if (record.status == BridgeStatus.NONE) revert UnknownBridge(messageId);
        if (record.status != BridgeStatus.SOURCE_SENT) revert InvalidBridgeStatus(record.status);
        if (deliveredAmount == 0 || deliveredAmount > record.amount) {
            revert InvalidDeliveredAmount(deliveredAmount, record.amount);
        }

        record.status = BridgeStatus.REMOTE_RECEIVED;
        record.destinationTxHash = destinationTxHash;
        pendingOutbound = record.amount >= pendingOutbound ? 0 : pendingOutbound - record.amount;

        emit BridgeRemoteReceived(messageId, deliveredAmount, destinationTxHash);
    }

    function markBridgeFailed(bytes32 messageId, bytes32 failureHash) external onlyRole(REPORTER_ROLE) nonReentrant {
        BridgeRecord storage record = bridgeRecords[messageId];
        if (record.status == BridgeStatus.NONE) revert UnknownBridge(messageId);
        if (record.status != BridgeStatus.SOURCE_SENT) revert InvalidBridgeStatus(record.status);

        record.status = BridgeStatus.FAILED;
        pendingOutbound = record.amount >= pendingOutbound ? 0 : pendingOutbound - record.amount;

        emit BridgeMarkedFailed(messageId, failureHash);
    }

    function recordBaseReturn(bytes32 messageId, uint256 amount, bytes32 sourceTxHash)
        external
        onlyRole(REPORTER_ROLE)
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (processedBaseReturns[messageId]) revert BaseReturnAlreadyProcessed(messageId);
        uint256 managerBalance = asset.balanceOf(address(this));
        if (managerBalance < amount) revert InsufficientBaseLiquidity(amount, managerBalance);

        processedBaseReturns[messageId] = true;
        remoteReportedBalance = amount >= remoteReportedBalance ? 0 : remoteReportedBalance - amount;
        asset.safeTransfer(address(vault), amount);
        vault.receiveFromVenue(amount);

        emit BaseReturnRecorded(messageId, amount, sourceTxHash);
    }

    function queueAsyncRedeem(uint256 shares, address receiver) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 assetsAtQueue = vault.previewRedeem(shares);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), shares);

        requestId = nextWithdrawalRequestId++;
        withdrawalRequests[requestId] = AsyncWithdrawal({
            owner: msg.sender,
            receiver: receiver,
            shares: shares,
            assetsAtQueue: assetsAtQueue,
            status: WithdrawalStatus.QUEUED,
            queuedAt: uint64(block.timestamp),
            completedAt: 0
        });

        emit AsyncWithdrawalQueued(requestId, msg.sender, receiver, shares, assetsAtQueue);
    }

    function completeAsyncRedeem(uint256 requestId)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (uint256 assets)
    {
        AsyncWithdrawal storage request = withdrawalRequests[requestId];
        if (request.status == WithdrawalStatus.NONE) revert UnknownWithdrawal(requestId);
        if (request.status != WithdrawalStatus.QUEUED) revert InvalidWithdrawalStatus(request.status);

        uint256 assetsNow = vault.previewRedeem(request.shares);
        uint256 available = asset.balanceOf(address(vault));
        if (available < assetsNow) revert InsufficientBaseLiquidity(assetsNow, available);

        request.status = WithdrawalStatus.COMPLETED;
        request.completedAt = uint64(block.timestamp);
        assets = vault.redeem(request.shares, request.receiver, address(this));

        emit AsyncWithdrawalCompleted(requestId, assets);
    }

    function cancelAsyncRedeem(uint256 requestId) external nonReentrant {
        AsyncWithdrawal storage request = withdrawalRequests[requestId];
        if (request.status == WithdrawalStatus.NONE) revert UnknownWithdrawal(requestId);
        if (request.status != WithdrawalStatus.QUEUED) revert InvalidWithdrawalStatus(request.status);
        if (msg.sender != request.owner && !hasRole(QUEUE_MANAGER_ROLE, msg.sender)) {
            _checkRole(QUEUE_MANAGER_ROLE);
        }

        request.status = WithdrawalStatus.CANCELLED;
        IERC20(address(vault)).safeTransfer(request.owner, request.shares);

        emit AsyncWithdrawalCancelled(requestId);
    }

    function setRemoteReceiver(address newReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newReceiver == address(0)) revert ZeroAddress();
        address oldReceiver = remoteReceiver;
        remoteReceiver = newReceiver;
        emit RemoteReceiverUpdated(oldReceiver, newReceiver);
    }

    function setAllocationPolicy(uint256 minIdleBps_, uint256 maxRemoteBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minIdleBps_ > BPS_DENOMINATOR || maxRemoteBps_ > BPS_DENOMINATOR) revert InvalidBps();
        if (minIdleBps_ + maxRemoteBps_ > BPS_DENOMINATOR) revert InvalidBps();
        minIdleBps = minIdleBps_;
        maxRemoteBps = maxRemoteBps_;
        emit AllocationPolicyUpdated(minIdleBps_, maxRemoteBps_);
    }

    function withdrawBridgeFees(address payable recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ETHRefundFailed();
    }

    function remoteManagedAssets() external view returns (uint256) {
        return pendingOutbound + remoteReportedBalance;
    }

    function _enforceAllocationAfterBridge(uint256 bridgeAmount) private view {
        uint256 total = vault.totalAssets();
        if (total == 0) return;

        uint256 idleBefore = asset.balanceOf(address(vault));
        uint256 postBridgeIdle = idleBefore > bridgeAmount ? idleBefore - bridgeAmount : 0;
        uint256 minimumIdle = total * minIdleBps / BPS_DENOMINATOR;
        if (postBridgeIdle < minimumIdle) revert IdleBufferBreach(postBridgeIdle, minimumIdle);

        uint256 postBridgeRemote = pendingOutbound + remoteReportedBalance + bridgeAmount;
        uint256 maximumRemote = total * maxRemoteBps / BPS_DENOMINATOR;
        if (postBridgeRemote > maximumRemote) revert RemoteAllocationBreach(postBridgeRemote, maximumRemote);
    }

    function _addressToBytes32(address account) private pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    receive() external payable {}
}
