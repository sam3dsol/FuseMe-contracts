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
| FuseMeLauncher | `0x54DDb632E388Afe257a567c42ee362Ab5fAb6aE6` |
| FuseMeLocker | `0x599018E2cf6C593B33b33D8aE313591C80F71947` |
| FuseMeRouter | `0xD2C548d79D01D7E181A642f3E31A5caa4010Bcc7` |

**Voltage Algebra** — dynamic pool fee (0.01% to 1.5%, set by a volatility plugin),
trades on voltage.finance

| Contract | Address |
| --- | --- |
| FuseMeAlgebraLauncher | `0x8510F3b95540d0f7e1F036AEF99E3348daA10b2b` |
| FuseMeAlgebraLocker | `0xC3D7eD206C4216AAB462E0Ef8654AECEB72C6a14` |
| FuseMeAlgebraRouter | `0x3D5C9450EF77AbC0D19E46bF68fa20681740C560` |

All six are verified on Blockscout at [explorer.fuse.io](https://explorer.fuse.io), and the
source in `src/` is byte-identical to the verified source at those addresses. Earlier
generations are still on chain and still hold live tokens, but they are superseded: these
six are what fuseme.fun uses. `AUDIT.md` has the comparison command and the security review.

The creator's first buy is executed inside the launch transaction and reverts if it
would take more than 5% of supply. This bounds the opening buy only: nothing prevents
the creator buying more afterwards at the going price.

The system never sells. The token side of fees is held as inventory and absorbed into
later buys at the pool price. Inventory nobody has absorbed for 24 hours can be flushed
by anyone, and a flush pays those tokens out in kind, 50/30/20, rather than selling them
into the token's own pool, so fee value is never stranded and nothing the protocol does
prints on a chart. A flush needs both clocks quiet, the router and the pool, with a
30 day backstop so a griefer can delay a payout but never prevent one.

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
