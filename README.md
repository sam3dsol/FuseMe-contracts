# fuseme contracts

The launchpad contracts behind [fuseme.fun](https://fuseme.fun), deployed on
Fuse (chain 122) against Voltage v3.

A launch is one transaction: the token is deployed, a 1% WFUSE pool is created
and seeded with two single-sided positions, and the token is tradeable in the
same block. Both position NFTs are transferred to the locker, which exposes no
withdraw, migrate, sweep or rescue path and has no upgrade mechanism, so launch
liquidity cannot be removed.

Trading fees are split 50% creator / 30% Fuse Foundation / 20% platform. The
split is a constant in the contract and collection is permissionless. Payouts
are made in FUSE: the WFUSE side settles immediately, and the token side is held
as locker inventory and absorbed into later buys at the live pool price, so the
system never places a sell of its own. Inventory nobody absorbs for 24 hours can
be flushed by anyone, so fee value is never stranded.

## Deployed (Fuse, chain 122)

| Contract | Address |
| --- | --- |
| FuseMeLauncher | `0xd8723241EeBC3c84a60306Ef160AC01c27054eF6` |
| FuseMeLocker | `0xAE9E69961c1145615dbB30774D4dDEf631913EEc` |
| FuseMeRouter | `0x3D7913fCE681d0Bd4e4d8E3fA2e40Fd34b73C99e` |

All three are verified on Blockscout at
[explorer.fuse.io](https://explorer.fuse.io).

## Build and test

```
forge install foundry-rs/forge-std
forge build
```

Fuse block headers omit `prevrandao`, so forge cannot fork `rpc.fuse.io`
directly. Run the suite through anvil:

```
anvil --fork-url https://rpc.fuse.io --port 8547 &
cast rpc evm_mine --rpc-url http://127.0.0.1:8547
forge test --fork-url http://127.0.0.1:8547
```

## Licence

MIT
