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

Two venues, same design. Voltage runs two DEXes and a pool on one is not tradeable
on the other, so a launch picks where it lives.

**Voltage V3** — fixed 1% pool fee, trades on v3.voltage.finance

| Contract | Address |
| --- | --- |
| FuseMeLauncher | `0x8578fd02A069A135d149E02b7E2cC3a7827c5255` |
| FuseMeLocker | `0x997247463C4b87DF959A077C58DC4379396E2C5c` |
| FuseMeRouter | `0xF2d7D57ca98C696aAa9e9bdc07f94b8A57192696` |

**Voltage Algebra** — dynamic pool fee (0.01% to 1.5%, set by a volatility plugin),
trades on voltage.finance

| Contract | Address |
| --- | --- |
| FuseMeAlgebraLauncher | `0x0cA43434a658Beb100988D6e24DbeE5523aA68Cc` |
| FuseMeAlgebraLocker | `0x7903fde67D280B8E06214C030F13a9A7A777f570` |
| FuseMeAlgebraRouter | `0x121759CF14877c8f77054437c07Fea8D80D49545` |

All six are verified on Blockscout at [explorer.fuse.io](https://explorer.fuse.io).

The creator's first buy is executed inside the launch transaction and is capped at
5% of supply on both venues; a larger first buy reverts the launch.

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
