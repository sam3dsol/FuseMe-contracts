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
| FuseMeLauncher | `0x4D8931FdcFd89eD6Ba75eE9D49bd59a2cc3Bf22B` |
| FuseMeLocker | `0x9936E3e7235fd6cd92d8e028091cF2B5C6589FD8` |
| FuseMeRouter | `0x66c9C7aC755e2D115F995d3BB86cEc330F762816` |

**Voltage Algebra** — dynamic pool fee (0.01% to 1.5%, set by a volatility plugin),
trades on voltage.finance

| Contract | Address |
| --- | --- |
| FuseMeAlgebraLauncher | `0xA924531A4E7C9eFaEb25C04b31cA76e9F2FCc5F4` |
| FuseMeAlgebraLocker | `0x179b31A91041243993BC7deC18F8C6Cc3Aa17DfD` |
| FuseMeAlgebraRouter | `0x9e4127CcE02281960E5D46718D83553D66e09d5A` |

All six are verified on Blockscout at [explorer.fuse.io](https://explorer.fuse.io).

The creator's first buy is executed inside the launch transaction and reverts if it
would take more than 5% of supply. This bounds the opening buy only: nothing prevents
the creator buying more afterwards at the going price.

The system does not sell in ordinary operation. The token side of fees is held as
inventory and absorbed into later buys at the pool price. The exception is deliberate:
inventory nobody has absorbed for 24 hours can be liquidated by anyone, which is a
real sell, so fee value is never stranded.

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
