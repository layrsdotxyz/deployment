# Layrs · Contract deployments

**Base Mainnet is the current production network for USDC custody and private-trade,
market-registration and market-settlement publication.** Horizen deployment records
are retained below as historical evidence, not as the current trading network.

## Base Mainnet — current production

Chain ID **8453** · Gas token **ETH** · [Deployment details](BASE_DEPLOYMENT.md) ·
[Machine-readable manifest](base-deployment.json)

| Contract | Purpose | Base address |
|---|---|---|
| USDC LayrsPool | Participant USDC deposits and withdrawals | [0xb076…a35f](https://basescan.org/address/0xb07627b0d646f5c82c8e30975a37650dc272a35f) |
| LayrsTeeReceiptRegistry | Private-fill receipt commitments | [0x342d…af2f](https://basescan.org/address/0x342def5ae7f6b4d52a8d3c4a64085bb098a5af2f) |
| MarketRegistry | Traded-market registration | [0xebde…3db7](https://basescan.org/address/0xebde1b32a86a5b2ff782e075b40e58f96b8b3db7) |
| AdminOracle | Traded-market settlement outcomes | [0xbf82…18c7](https://basescan.org/address/0xbf820a025d5e4f887470c7c86f997e9899c718c7) |

Base records include current implementation addresses and pinned on-chain bytecode
checks. The ZEN trading pool and separate staking/yield vault are distinguished in
the Base deployment details; their existence is not a claim of current campaign use.

```sh
python3 verify.py --network base --solc /path/to/solc-0.8.25
```

Set `BASE_RPC_URL` to independently recheck Base at the manifest's recorded block.
See [verification scope and limits](BASE_DEPLOYMENT.md#verification) before interpreting
source-build checks. No wallet, private key, signing or gas is needed.

## Horizen Mainnet — historical deployment archive

Historical Solidity source and deployment details for Layrs' trading, proof publication,
ZEN custody and staking/strategy contracts on **Horizen Mainnet (chain ID 26514;
gas token ETH)**. The latest applicable deployment is listed for each role and
collateral. Deployment, production references and verified active use are not
treated as interchangeable. References to current use in this archive describe its
19 October 2026 snapshot; they do not describe today's production routing.

## Deployed contracts

| Contract | Purpose | Mainnet address | Source |
|---|---|---|---|
| LayrsPool | Participant USDC deposits and withdrawals | [0xb412…d284](https://explorer.horizen.io/address/0xb412f63299ccff4fe57714ee580895cca74dd284) | [LayrsPool.sol](src/LayrsPool.sol) |
| LayrsTeeReceiptRegistry | Private-fill receipt batch publication | [0x3f1d…6a96](https://explorer.horizen.io/address/0x3f1d32cd64ab362a7b4390e63229b2a7b8ec6a96) | [LayrsTeeReceiptRegistry.sol](src/proofs/LayrsTeeReceiptRegistry.sol) |
| MarketRegistry | Traded-market registration | [0x9c67…85b1](https://explorer.horizen.io/address/0x9c67176dfc30ad540f3ecbad8083e4d9ac1885b1) | [MarketRegistry.sol](src/core/MarketRegistry.sol) |
| AdminOracle | Traded-market outcome publication | [0x0237…0976](https://explorer.horizen.io/address/0x0237dfce14d1d66ca58948a6273e400cb3f00976) | [AdminOracle.sol](src/core/AdminOracle.sol) |
| LayrsAdmin — markets | Administration of MarketRegistry and AdminOracle | [0x0e13…a4ed](https://explorer.horizen.io/address/0x0e1306daec0c7c5711ef2eb98d1f6ba26aeea4ed) | [LayrsAdmin.sol](src/LayrsAdmin.sol) |
| LayrsAdmin — USDC pool | Administration of the USDC pool | [0x929c…2f11](https://explorer.horizen.io/address/0x929cc4d1d176e925b54b356c98ef9d376ec22f11) | [LayrsAdmin.sol](src/LayrsAdmin.sol) |
| ZEN LayrsPool — trading | Collateral for ZEN-denominated prediction markets | [0x4b31…52a0](https://explorer.horizen.io/address/0x4b31ad17e964cb6da440b28405ab110eaf7b52a0) | [LayrsPool.sol](src/LayrsPool.sol) |
| ZEN LPVault — liquidity/yield | Separate ERC-4626 vault for liquidity and yield strategies | [0xa5ff…8a87](https://explorer.horizen.io/address/0xa5fffcc49326d0e4a99b2d076a5ce6f256a98a87) | [LPVault.sol](src/vault/LPVault.sol) |
| ZenStakerAdapter | ZEN staking for its registered vault | [0x3d1c…5e2d](https://explorer.horizen.io/address/0x3d1c5104908bba3918ad53fad4d1da13fee25e2d) | [ZenStakerAdapter.sol](src/adapters/ZenStakerAdapter.sol) |
| HorizenZenStrategyReceiver | Horizen side of the cross-chain ZEN strategy | [0xd1a2…3ca9](https://explorer.horizen.io/address/0xd1a230267836eb3d6bf643c7c58457511e783ca9) | [HorizenZenStrategyReceiver.sol](src/strategies/HorizenZenStrategyReceiver.sol) |
| ZenStakerFeeAdapter | Fee-aware staking adapter for the strategy receiver | [0xfec1…8fb3](https://explorer.horizen.io/address/0xfec1ab30940d64fa5efeab59e8a190d5088a8fb3) | [ZenStakerFeeAdapter.sol](src/adapters/ZenStakerFeeAdapter.sol) |
| MatchSettlement | Indexed settlement contract; not the private-fill publication route | [0x4067…8beb](https://explorer.horizen.io/address/0x406716f6ca3578715622250c47efb88728b98beb) | [MatchSettlement.sol](src/core/MatchSettlement.sol) |

The two administrators serve different current roles; they are not alternative
versions of the same active endpoint. Each upgradeable endpoint's current
implementation and clickable deployment transactions are listed in [DEPLOYMENT.md](DEPLOYMENT.md), with full machine-readable details in [deployment.json](deployment.json).

### Two separate ZEN functions

- **Prediction markets:** users deposit ZEN as trading collateral in the ZEN LayrsPool, analogous to the USDC LayrsPool.
- **Staking/yield:** ZEN vaults and adapters manage liquidity and staking positions separately. A staking adapter need not be registered in the prediction-market trading pool.

### Configuration evidence

- `ZenStakerAdapter` is bound to and registered with the [earlier ZEN vault](https://explorer.horizen.io/address/0xa4bf62c6cae3d3533d65b2d04e62cb6e757d57a7). It is **not registered with the latest ZEN pool or vault above**. That earlier address is retained as a dependency reference, not as another latest deployment.
- `ZenStakerFeeAdapter` is bound to the strategy receiver. Both adapters have an existing staking-deposit flag; that alone does not establish current funded activity.
- The receiver's current Base strategy-manager reference and the vault/pool configuration are recorded at the verification block. This package does not certify a funded cross-chain strategy round trip.

## Source and verification

- `src/`: exact Solidity source retrieved from the verified Horizen explorer records.
- `lib/`: only imported third-party Solidity dependencies, preserving original source and SPDX notices.
- `builds/`: exact compiler settings, source hashes and immutable constants for each deployed implementation or proxy. Any differing imported source required by a deployed build is retained under `builds/source-variants/`; it is not an additional claimed deployment.
- `deployment.json`: full addresses, explorer links, creation transactions, current implementations, runtime hashes and the verification block.
- `verify.py`: reproducible Solidity compilation and runtime-bytecode comparison.

Use **Solidity 0.8.25+commit.b61c2a91** and Python 3.10 or later:

```sh
python3 verify.py --solc /path/to/solc-0.8.25
```

To also reread mainnet code and implementation pointers at the recorded block,
set `HORIZEN_RPC_URL` in your environment before running the same command. No
private key, signed transaction or gas is required. UUPS `__self` immutables are
resolved to the deployed implementation address. Staking/strategy constructor
immutables use values read from compiler-declared mainnet bytecode locations;
public immutable getters are additionally checked. Metadata is not stripped from
the runtime comparison. With RPC enabled, the recorded configuration and adapter
registration reads are also reproduced at the pinned block.

This is a focused source snapshot, not a new security audit. Proof publication
does not by itself verify the off-chain enclave, user identity or trade execution.
USDC and bridging providers are external dependencies, not Layrs contracts.
Superseded replacement implementations and the application backend are intentionally
not included. Base deployments are documented separately above. The receiver imports `IStargateOFT` from
`BaseCrossChainZenStrategyManager.sol`; that file is retained only as a compilation
dependency, not as a listed Base deployment. Imported interfaces and third-party
libraries are compilation dependencies, not additional deployed Layrs contracts.
