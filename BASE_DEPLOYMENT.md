# Base Mainnet deployment details

Base is Layrs' current production network for USDC pool custody and private-fill,
market-registration and market-settlement publication. **Chain ID: 8453. Gas: ETH.**

On-chain records below were checked at finalized block
[53163058](https://basescan.org/block/53163058), **27 October 2026, 15:37:43 UTC**.
This is the verification snapshot, not the contracts' deployment date.
Full addresses, runtime SHA-256 hashes and the block hash are in
[base-deployment.json](base-deployment.json).

## Current production contracts

| Contract and function | Endpoint | Current implementation | Source |
|---|---|---|---|
| USDC LayrsPool — participant deposits and withdrawals | [0xb076…a35f](https://basescan.org/address/0xb07627b0d646f5c82c8e30975a37650dc272a35f) | [0x1df8…611d](https://basescan.org/address/0x1df899111e5da617b0c5fb351f538688fa35611d) | [LayrsPool.sol](src/LayrsPool.sol) |
| LayrsTeeReceiptRegistry — private-fill receipt commitments | [0x342d…af2f](https://basescan.org/address/0x342def5ae7f6b4d52a8d3c4a64085bb098a5af2f) | Non-proxy | [LayrsTeeReceiptRegistry.sol](src/proofs/LayrsTeeReceiptRegistry.sol) |
| MarketRegistry — traded-market registration | [0xebde…3db7](https://basescan.org/address/0xebde1b32a86a5b2ff782e075b40e58f96b8b3db7) | [0x4809…37dd](https://basescan.org/address/0x48095c6d5c4385ec4e4b0d0006f15504d91e37dd) | [MarketRegistry.sol](src/core/MarketRegistry.sol) |
| AdminOracle — traded-market outcome publication | [0xbf82…18c7](https://basescan.org/address/0xbf820a025d5e4f887470c7c86f997e9899c718c7) | [0x1bb1…ad5e](https://basescan.org/address/0x1bb19845d00eb16d7d9e7b27acebc1572f0bad5e) | [AdminOracle.sol](src/core/AdminOracle.sol) |

The pool address matches the production BFF configuration; the receipt registry
matches the production publication manifest. The market endpoints match the
production resolver, whose settlement chain is Base. Proxy implementation pointers
were independently reread using EIP-1967 storage. Historical or newer-looking
deployment records do not override these observed production bindings.

USDC is the external collateral token
[0x8335…2913](https://basescan.org/address/0x833589fcd6edb6e08f4c7c32d4f71b54bda02913),
not a Layrs-deployed contract. The participant deposit pool is **not** the separate
USDC yield vault below.

## Other recorded Base deployments

These contracts have code and implementation readbacks at the same block. They are
not presented as additional active campaign contracts or a certification of funded
staking, ZEN trading, or cross-chain strategy operation.

| Role | Endpoint | Current implementation |
|---|---|---|
| ZEN LayrsPool — prediction-market trading collateral | [0xd251…edf8](https://basescan.org/address/0xd251fc236e31a122a41b58f56cce81dd7374edf8) | [0xfaa9…6328](https://basescan.org/address/0xfaa9c7f2c6364ed4b8439f3250b11a450b556328) |
| ZEN LPVault — separate staking/yield vault | [0x63f0…b91a](https://basescan.org/address/0x63f0bbf84f4c2bf79518bc62904ccb113dfeb91a) | [0xc623…4ad1](https://basescan.org/address/0xc623bff1ac60d8f8c5942c057c9338ed04d04ad1) |
| USDC LPVault — separate yield vault | [0x5ef8…a3d](https://basescan.org/address/0x5ef8283011e57a5d046511b48f3cce6e86e7aa3d) | [0x28c7…9e87](https://basescan.org/address/0x28c721a4bb8abefc70ad5bf4dce4ed6d9a729e87) |
| Registration-attestation registry — configured dependency, not MarketRegistry | [0x0d07…b94d](https://basescan.org/address/0x0d0716786a6c0abf3226820a23211892336cb94d) | Non-proxy |

Both ZEN contracts report the external Base ZEN asset
[0xf43e…9229](https://basescan.org/address/0xf43eb8de897fbc7f2502483b2bef7bb9ea179229).
One is for prediction-market collateral; the other is a separate liquidity/yield
vault. Their balances or users must not be double-counted.

## Verification

Use Python 3.10+ and **Solidity 0.8.25+commit.b61c2a91**:

```sh
python3 verify.py --network base --solc /path/to/solc-0.8.25
```

Set `BASE_RPC_URL` in your environment to also verify the chain ID, pinned block hash,
deployed bytecode, current implementation pointers and the additional deployments'
recorded asset getters. Use a provider that serves historical Base state at the
recorded block. No private key, transaction submission or gas is required.

- **USDC pool, MarketRegistry and AdminOracle:** full compiled runtime matches,
  including Solidity metadata, for each implementation and proxy. UUPS `__self`
  immutables are resolved to the recorded implementation addresses.
- **Private-fill registry:** published source compiles to the same executable
  runtime. The metadata suffix differs from the historical build configuration;
  this is explicitly reported as `executable-without-metadata`, not an exact full
  source-build match. With RPC enabled, the full deployed runtime is independently
  checked against its recorded hash as well.
- **Other recorded deployments:** code hashes, proxy pointers and asset getters
  only. This package does not claim source-build equivalence for that additional list.

The manifest records observed deployment identities, not a replayable production
deployment procedure. Base creation transactions are not reconstructed in this
update; explorer links expose the public contract histories. Existing Horizen
creation-transaction records remain in [DEPLOYMENT.md](DEPLOYMENT.md).

Receipt commitments enable inclusion verification when accompanied by signed
receipts and Merkle paths. Contract bytecode and publication alone do not establish
unique-human ownership, independent enclave attestation or correctness of every
off-chain execution. This repository update does not change any live contract,
wallet, permission, balance or production service.
