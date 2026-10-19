# Horizen production deployment

Chain **26514** · native gas **ETH** · checked at block **29048379**, 2026-10-19T21:34:22.690497+00:00.

| Contract / role | Endpoint | Current implementation | Endpoint deployment | Implementation deployment |
|---|---|---|---|---|
| LayrsPool — usdc-pool | [0xb412…d284](https://explorer.horizen.io/address/0xb412f63299ccff4fe57714ee580895cca74dd284) | [0x1bb1…ad5e](https://explorer.horizen.io/address/0x1bb19845d00eb16d7d9e7b27acebc1572f0bad5e) | [0xd1d2…69db](https://explorer.horizen.io/tx/0xd1d2f5c696f1facd486d04a1406cc1c0f424e79b888175e380282108238369db) | [0x98aa…d3e9](https://explorer.horizen.io/tx/0x98aac0d6c7da7c056d38b11aca81a321aa72baa66049ec58eefe4e242a24d3e9) |
| LayrsTeeReceiptRegistry — private-fills | [0x3f1d…6a96](https://explorer.horizen.io/address/0x3f1d32cd64ab362a7b4390e63229b2a7b8ec6a96) | Non-proxy | [0xf63d…ee04](https://explorer.horizen.io/tx/0xf63de8a3eca0de40c5435b9f6f5d204e597054973f847eee4aa09a3e5754ee04) | Same as endpoint |
| MarketRegistry — markets | [0x9c67…85b1](https://explorer.horizen.io/address/0x9c67176dfc30ad540f3ecbad8083e4d9ac1885b1) | [0xfccd…e71b](https://explorer.horizen.io/address/0xfccd0129d8c9a283ed2b7381179381b38b06e71b) | [0xeebd…3a7f](https://explorer.horizen.io/tx/0xeebdcc92a664b2e487cb3cd71889a82595dfcb982bc71445ede4bc1717f83a7f) | [0x795a…afcd](https://explorer.horizen.io/tx/0x795a9d775d086fa78697079f425751e7794bd76acd8c97f4132973bb340aafcd) |
| AdminOracle — settlement | [0x0237…0976](https://explorer.horizen.io/address/0x0237dfce14d1d66ca58948a6273e400cb3f00976) | [0xb125…6ca3](https://explorer.horizen.io/address/0xb125326f992c480fddcd976f6505721224a06ca3) | [0xe14e…412d](https://explorer.horizen.io/tx/0xe14ee2f6cfad15e41f30375f62ae8d0c0671932902382be499d74721e111412d) | [0x052a…ef76](https://explorer.horizen.io/tx/0x052a4aff2e58230930bc1b741aac6b66236dc6cdffb67daf306615b1215cef76) |
| LayrsAdmin — market-admin | [0x0e13…a4ed](https://explorer.horizen.io/address/0x0e1306daec0c7c5711ef2eb98d1f6ba26aeea4ed) | [0xabcd…515c](https://explorer.horizen.io/address/0xabcd153f2accae2c8cf8d5c7401c1b7ec4e0515c) | [0x24c6…8565](https://explorer.horizen.io/tx/0x24c60a2e7b8ec68bfac867f2242135651effeda1af8212d37359a692f86d8565) | [0x18c7…2c8a](https://explorer.horizen.io/tx/0x18c70f52ad6a4e52a600e6550ccb9f6182e7c16c5cee70648bcaca4bcee32c8a) |
| LayrsAdmin — pool-admin | [0x929c…2f11](https://explorer.horizen.io/address/0x929cc4d1d176e925b54b356c98ef9d376ec22f11) | [0x4959…9161](https://explorer.horizen.io/address/0x495955861a737a6a17eae4b7a762dcefbb409161) | [0x681d…c3ce](https://explorer.horizen.io/tx/0x681ded05e2ac03e7f6758b3a44b9558121add0febb67638ab83a6c5c1d43c3ce) | [0x15ff…1935](https://explorer.horizen.io/tx/0x15ffb3e54a291f4ab3af16544e00ee118bf7f1aaf891e615e2cc07d9669e1935) |

All source packages rebuilt with Solidity 0.8.25 and matched the recorded runtime bytecode, including metadata and UUPS self-address immutables. Proxy pointers, successful creation transactions and the three current administration relationships were checked on-chain. This is deployment/source verification, not a new security audit.

The USDC pool holds the external [USDC token](https://explorer.horizen.io/address/0xdf7108f8b10f9b9ec1aba01cca057268cbf86b6c). Only the six current-purpose Layrs endpoints above are included. Imported interfaces and OpenZeppelin libraries are compilation dependencies, not claims of additional deployed Layrs contracts.

See [machine-readable deployment details](deployment.json) and [reproduction instructions](README.md#source-and-verification).
