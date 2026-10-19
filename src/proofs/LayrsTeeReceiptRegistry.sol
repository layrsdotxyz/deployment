// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title LayrsTeeReceiptRegistry
/// @notice Append-only publication rail for privacy-preserving batches of
///         enclave-signed command receipts.
/// @dev The contract intentionally stores only commitments. Exact orders,
///      identities, prices, sides, timestamps and batch sizes remain private.
///      A user proves inclusion off-chain with their signed receipt and Merkle
///      path. This contract never custodies assets or mutates trading state.
contract LayrsTeeReceiptRegistry is AccessControl {
    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    struct ReceiptBatch {
        bytes32 receiptRoot;
        bytes32 releaseManifestHash;
        bytes32 pcr0Hash;
        bytes32 receiptPublicKeyHash;
        uint64 publishedAt;
    }

    mapping(bytes32 batchId => ReceiptBatch) private batches;

    event ReceiptBatchPublished(
        bytes32 indexed batchId,
        bytes32 indexed receiptRoot,
        bytes32 indexed releaseManifestHash,
        bytes32 pcr0Hash,
        bytes32 receiptPublicKeyHash,
        address publisher
    );

    error ZeroAddress();
    error ZeroCommitment();
    error BatchAlreadyPublished();

    constructor(address admin, address publisher) {
        if (admin == address(0) || publisher == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PUBLISHER_ROLE, publisher);
    }

    function publishReceiptBatch(
        bytes32 batchId,
        bytes32 receiptRoot,
        bytes32 releaseManifestHash,
        bytes32 pcr0Hash,
        bytes32 receiptPublicKeyHash
    ) external onlyRole(PUBLISHER_ROLE) {
        if (
            batchId == bytes32(0) || receiptRoot == bytes32(0) || releaseManifestHash == bytes32(0)
                || pcr0Hash == bytes32(0) || receiptPublicKeyHash == bytes32(0)
        ) revert ZeroCommitment();
        if (batches[batchId].publishedAt != 0) revert BatchAlreadyPublished();

        batches[batchId] = ReceiptBatch({
            receiptRoot: receiptRoot,
            releaseManifestHash: releaseManifestHash,
            pcr0Hash: pcr0Hash,
            receiptPublicKeyHash: receiptPublicKeyHash,
            publishedAt: uint64(block.timestamp)
        });

        emit ReceiptBatchPublished(
            batchId, receiptRoot, releaseManifestHash, pcr0Hash, receiptPublicKeyHash, msg.sender
        );
    }

    function receiptBatch(bytes32 batchId) external view returns (ReceiptBatch memory) {
        return batches[batchId];
    }

    function isPublished(bytes32 batchId) external view returns (bool) {
        return batches[batchId].publishedAt != 0;
    }
}
