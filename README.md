# Layrs · Horizen production contracts

Solidity source and deployment details for the contracts used by Layrs' current
USDC trading system on **Horizen Mainnet (chain ID 26514; gas token ETH)**.

## Deployed contracts

| Contract | Purpose | Mainnet address | Source |
|---|---|---|---|
| LayrsPool | Participant USDC deposits and withdrawals | [0xb412…d284](https://explorer.horizen.io/address/0xb412f63299ccff4fe57714ee580895cca74dd284) | [LayrsPool.sol](src/LayrsPool.sol) |
| LayrsTeeReceiptRegistry | Private-fill receipt batch publication | [0x3f1d…6a96](https://explorer.horizen.io/address/0x3f1d32cd64ab362a7b4390e63229b2a7b8ec6a96) | [LayrsTeeReceiptRegistry.sol](src/proofs/LayrsTeeReceiptRegistry.sol) |
| MarketRegistry | Traded-market registration | [0x9c67…85b1](https://explorer.horizen.io/address/0x9c67176dfc30ad540f3ecbad8083e4d9ac1885b1) | [MarketRegistry.sol](src/core/MarketRegistry.sol) |
| AdminOracle | Traded-market outcome publication | [0x0237…0976](https://explorer.horizen.io/address/0x0237dfce14d1d66ca58948a6273e400cb3f00976) | [AdminOracle.sol](src/core/AdminOracle.sol) |
| LayrsAdmin — markets | Administration of MarketRegistry and AdminOracle | [0x0e13…a4ed](https://explorer.horizen.io/address/0x0e1306daec0c7c5711ef2eb98d1f6ba26aeea4ed) | [LayrsAdmin.sol](src/LayrsAdmin.sol) |
| LayrsAdmin — USDC pool | Administration of the USDC pool | [0x929c…2f11](https://explorer.horizen.io/address/0x929cc4d1d176e925b54b356c98ef9d376ec22f11) | [LayrsAdmin.sol](src/LayrsAdmin.sol) |

The two administrators serve different current roles; they are not alternative
versions of the same active endpoint. Each upgradeable endpoint's current
implementation and clickable deployment transactions are listed in [DEPLOYMENT.md](DEPLOYMENT.md), with full machine-readable details in [deployment.json](deployment.json).

## Source and verification

- `src/`: exact Solidity source retrieved from the verified Horizen explorer records.
- `lib/`: only imported third-party Solidity dependencies, preserving original source and SPDX notices.
- `builds/`: exact compiler settings and source hashes for each deployed implementation or proxy.
- `deployment.json`: full addresses, explorer links, creation transactions, current implementations, runtime hashes and the verification block.
- `verify.py`: reproducible Solidity compilation and runtime-bytecode comparison.

Use **Solidity 0.8.25+commit.b61c2a91** and Python 3.10 or later:

```sh
python3 verify.py --solc /path/to/solc-0.8.25
```

To also reread mainnet code and implementation pointers at the recorded block,
set `HORIZEN_RPC_URL` in your environment before running the same command. No
private key, signed transaction or gas is required. UUPS `__self` immutables are
resolved to the deployed implementation address before comparison; metadata is
not stripped from the runtime comparison.

This is a focused source snapshot, not a new security audit. Proof publication
does not by itself verify the off-chain enclave, user identity or trade execution.
USDC and bridging providers are external dependencies, not Layrs contracts.
Historical replacements, Base deployments, inactive yield contracts and the
application backend are intentionally not included.
