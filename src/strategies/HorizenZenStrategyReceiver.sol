// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IStargateOFT} from "./BaseCrossChainZenStrategyManager.sol";

contract HorizenZenStrategyReceiver is AccessControl, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 public constant TEE_APPROVER_ROLE = keccak256("TEE_APPROVER_ROLE");

    bytes32 public constant BRIDGE_APPROVAL_TYPEHASH = keccak256(
        "BridgeApproval(address independentApprover,address teeApprover,uint256 amount,uint32 destinationEid,address recipient,uint256 minAmountLD,uint256 nativeFee,uint256 nonce,uint256 deadline,bytes32 routeHash)"
    );

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

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAdapter(address adapter);
    error DuplicateAdapter(address adapter);
    error InvalidDestination(uint32 dstEid, address recipient);
    error InsufficientBridgeFee(uint256 required, uint256 available);
    error BridgeApprovalExpired(uint256 deadline);
    error BridgeApprovalNonceUsed(uint256 nonce);
    error InvalidBridgeApproval();
    error InvalidBridgeApprover(address approver, bytes32 requiredRole);
    error InvalidBridgeSignature(address approver);
    error ETHRefundFailed();

    IERC20 public immutable asset;
    IStargateOFT public immutable oft;
    uint32 public immutable baseEid;
    address public baseStrategyManager;
    mapping(address => bool) public approvedAdapters;
    mapping(uint256 => bool) public bridgeApprovalNonceUsed;
    uint256 public remoteAccountingBalance;
    uint64 public lastRemoteAccountingAt;
    bytes32 public lastRemoteAccountingHash;

    event BaseStrategyManagerUpdated(address indexed oldManager, address indexed newManager);
    event AdapterApprovalSet(address indexed adapter, bool approved);
    event DeployedToAdapter(address indexed adapter, uint256 amount, uint256 deployedBalance);
    event RecalledFromAdapter(
        address indexed adapter, uint256 amountRequested, uint256 amountReceived, uint256 deployedBalance
    );
    event RemoteAccountingPublished(uint256 balance, bytes32 indexed reportHash, uint64 reportedAt);
    event BridgedBackToBase(bytes32 indexed messageId, uint256 amount, uint256 minAmount, address indexed recipient);

    constructor(address asset_, address oft_, uint32 baseEid_, address baseStrategyManager_, address admin_)
        EIP712("LayrsHorizenZenStrategyReceiver", "1")
    {
        if (asset_ == address(0) || oft_ == address(0) || baseStrategyManager_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        asset = IERC20(asset_);
        oft = IStargateOFT(oft_);
        baseEid = baseEid_;
        baseStrategyManager = baseStrategyManager_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, admin_);
        _grantRole(REPORTER_ROLE, admin_);
        _grantRole(APPROVER_ROLE, admin_);
        _grantRole(TEE_APPROVER_ROLE, admin_);
    }

    function setBaseStrategyManager(address newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newManager == address(0)) revert ZeroAddress();
        address oldManager = baseStrategyManager;
        baseStrategyManager = newManager;
        emit BaseStrategyManagerUpdated(oldManager, newManager);
    }

    function setAdapterApproved(address adapter, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (IYieldAdapter(adapter).asset() != address(asset)) revert InvalidAdapter(adapter);
        approvedAdapters[adapter] = approved;
        emit AdapterApprovalSet(adapter, approved);
    }

    function deployToAdapter(address adapter, uint256 amount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (!approvedAdapters[adapter]) revert InvalidAdapter(adapter);
        if (amount == 0) revert ZeroAmount();
        asset.forceApprove(adapter, amount);
        IYieldAdapter(adapter).deposit(amount);
        asset.forceApprove(adapter, 0);
        emit DeployedToAdapter(adapter, amount, IYieldAdapter(adapter).deposited());
    }

    function recallFromAdapter(address adapter, uint256 amount) external onlyRole(KEEPER_ROLE) nonReentrant {
        if (!approvedAdapters[adapter]) revert InvalidAdapter(adapter);
        if (amount == 0) revert ZeroAmount();
        uint256 balanceBefore = asset.balanceOf(address(this));
        IYieldAdapter(adapter).withdraw(amount);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;
        emit RecalledFromAdapter(adapter, amount, received, IYieldAdapter(adapter).deposited());
    }

    function publishRemoteAccounting(address[] calldata adapters, bytes32 reportHash)
        external
        onlyRole(REPORTER_ROLE)
        returns (uint256 balance)
    {
        balance = asset.balanceOf(address(this));
        uint256 len = adapters.length;
        for (uint256 i; i < len; ++i) {
            address adapter = adapters[i];
            if (!approvedAdapters[adapter]) revert InvalidAdapter(adapter);
            for (uint256 j; j < i; ++j) {
                if (adapters[j] == adapter) revert DuplicateAdapter(adapter);
            }
            balance += IYieldAdapter(adapter).deposited();
        }
        remoteAccountingBalance = balance;
        lastRemoteAccountingAt = uint64(block.timestamp);
        lastRemoteAccountingHash = reportHash;
        emit RemoteAccountingPublished(balance, reportHash, uint64(block.timestamp));
    }

    function bridgeBackToBase(uint256 amount, address recipient, bytes calldata extraData)
        external
        onlyRole(KEEPER_ROLE)
        nonReentrant
        returns (bytes32 messageId)
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient != baseStrategyManager) revert InvalidDestination(baseEid, recipient);

        (BridgeParams memory params, BridgeApproval memory approval) =
            abi.decode(extraData, (BridgeParams, BridgeApproval));
        _consumeBridgeApproval(amount, baseEid, recipient, params, approval);
        if (address(this).balance < params.nativeFee) {
            revert InsufficientBridgeFee(params.nativeFee, address(this).balance);
        }

        asset.forceApprove(address(oft), amount);
        (IStargateOFT.MessagingReceipt memory receipt, IStargateOFT.OFTReceipt memory oftReceipt) = oft.send{
            value: params.nativeFee
        }(
            IStargateOFT.SendParam({
                dstEid: baseEid,
                to: bytes32(uint256(uint160(recipient))),
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
            messageId = keccak256(abi.encodePacked(block.chainid, address(this), amount, block.number));
        }
        emit BridgedBackToBase(messageId, oftReceipt.amountSentLD, oftReceipt.amountReceivedLD, recipient);
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
        uint32 destinationEid,
        address recipient,
        BridgeParams memory params,
        BridgeApproval memory approval
    ) private {
        if (approval.deadline < block.timestamp) revert BridgeApprovalExpired(approval.deadline);
        if (bridgeApprovalNonceUsed[approval.nonce]) revert BridgeApprovalNonceUsed(approval.nonce);
        if (
            approval.independentApprover == address(0) || approval.teeApprover == address(0)
                || approval.independentApprover == approval.teeApprover || approval.amount != amount
                || approval.destinationEid != destinationEid || approval.recipient != recipient
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

    function withdrawBridgeFees(address payable recipient, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ETHRefundFailed();
    }

    receive() external payable {}
}
