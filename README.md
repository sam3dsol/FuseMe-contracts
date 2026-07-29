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
| FuseMeLauncher | `0xFbB0D0614ac3E4A5D2827DF65E9F6a7675252219` |
| FuseMeLocker | `0x5643Eefd1f6592cabBBd6f79DA69bC60D0bD9367` |
| FuseMeRouter | `0x927cE52f58159c0E7d1B96b79d280879A2FD3d11` |

**Voltage Algebra** — dynamic pool fee (0.01% to 1.5%, set by a volatility plugin),
trades on voltage.finance

| Contract | Address |
| --- | --- |
| FuseMeAlgebraLauncher | `0x9e45B9282c80BC91dAeDB1D1C7C0363cf24FEE99` |
| FuseMeAlgebraLocker | `0x37a59D36c0C3f2B4aBE40A71C380b98856856B8A` |
| FuseMeAlgebraRouter | `0x8A4B380098E7bbB3e3C06661afc83F6B2a7d5a32` |

All six are verified on Blockscout at [explorer.fuse.io](https://explorer.fuse.io).

The creator's first buy is executed inside the launch transaction and reverts if it
would take more than 5% of supply. This bounds the opening buy only: nothing prevents
the creator buying more afterwards at the going price.

The system does not sell in ordinary operation. The token side of fees is held as
inventory and absorbed into later buys at the pool price. The exception is deliberate:
inventory nobody has absorbed for 24 hours can be liquidated by anyone, which is a
real sell, so fee value is never stranded. A flush needs both clocks quiet, the
router and the pool, with a 30 day backstop so a griefer can delay a payout but
never prevent one.

A single buy may absorb at most 25% of the fee inventory, and inventory is only
filled while spot agrees with a 120 second TWAP to within 100 ticks.

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
