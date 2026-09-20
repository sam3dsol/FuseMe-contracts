# Security review — fuseme.fun launchpad contracts

Review date: 2026-09-20 · Chain: Fuse Mainnet (122) · Compiler: `solc 0.8.26+commit.8a97fa7a`,
optimizer on, 200 runs.

This is an **internal review, not a third-party audit.** It is written to be checked rather
than believed: every claim below is either a line of source in this repository, a value
readable on chain, or a test in `test/` that fails if the claim stops being true. It is
handed over so an external auditor can start from the known state instead of rediscovering
it, and it names residual risk rather than only listing repairs.

## 1. Scope

Seven contracts, two venues, ~1,200 lines of Solidity:

| File | Role |
| --- | --- |
| `src/FuseMeLauncher.sol` | one-transaction launch: deploy token, open and seed the pool, lock |
| `src/FuseMeLocker.sol` | holds both position NFTs forever, collects and splits fees |
| `src/FuseMeRouter.sol` | buy path that absorbs fee inventory before touching the pool |
| `src/FuseMeToken.sol` | the launched ERC-20 |
| `src/FuseMeAlgebra{Launcher,Locker,Router}.sol` | the same design against Voltage's Algebra DEX |

Out of scope, and not in this repository: the fuseme.fun frontend, the off-chain contract
verifier, the indexer, and all pricing and analytics.

## 2. The source here is the code that is deployed

Every file in `src/` is **byte-identical** to the Blockscout-verified source at the
addresses below, checked on 2026-09-20 (trailing whitespace normalised, no other
differences). These six are what fuseme.fun uses today.

**Voltage V3** — fixed 1% pool fee

| Contract | Address |
| --- | --- |
| FuseMeLauncher | `0x54DDb632E388Afe257a567c42ee362Ab5fAb6aE6` |
| FuseMeLocker | `0x599018E2cf6C593B33b33D8aE313591C80F71947` |
| FuseMeRouter | `0xD2C548d79D01D7E181A642f3E31A5caa4010Bcc7` |

**Voltage Algebra** — dynamic pool fee set by a volatility plugin

| Contract | Address |
| --- | --- |
| FuseMeAlgebraLauncher | `0x8510F3b95540d0f7e1F036AEF99E3348daA10b2b` |
| FuseMeAlgebraLocker | `0xC3D7eD206C4216AAB462E0Ef8654AECEB72C6a14` |
| FuseMeAlgebraRouter | `0x3D5C9450EF77AbC0D19E46bF68fa20681740C560` |

To reproduce the comparison for any one of them:

```
curl -s https://explorer.fuse.io/api/v2/smart-contracts/<address> \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["source_code"])' \
  | diff - src/<Contract>.sol
```

Earlier generations are still on chain and still hold live tokens. They are **not** the
subject of this review; a reviewer looking at any address other than the six above is
looking at superseded code.

## 3. Trust model

Every constant in this section was read back from the live contracts, not from source.

- **No owner, no admin, no upgrade path, no proxy.** None of the seven contracts has an
  ownership or pause mechanism, a `delegatecall`, a `selfdestruct`, or an upgrade hook.
- **No mint, no burn, no blacklist, no transfer hook** in `FuseMeToken` beyond the creator
  cap described in M-1. Supply is fixed at construction: 1,000,000,000 × 10¹⁸.
- **Locked liquidity has no exit.** Both position NFTs are minted to the locker and the
  locker never calls `decreaseLiquidity`, `burn`, or any NFT transfer. Its only calls into
  Voltage's position manager are `collect` (fees) and the `positions` view. `unlockAt` is
  set to `type(uint64).max` and `PERMANENT_LOCK()` reads `true`.
- **Fee split is a constant.** `CREATOR_BPS = 5000`, `FOUNDATION_BPS = 3000`, remainder to
  the platform — 50/30/20, immutable, on both lockers. Collection is permissionless:
  anyone may call `collect(tokenId)`, and the money can only move to the three recipients.
- **Recipients are immutable.** `platform` and `foundation` are constructor immutables.
  There is no setter, so the payout destinations cannot be changed after deployment.
- **The deployer's power is already spent.** `setLauncher` and `setRouter` are one-shot and
  deployer-only (`launcher == address(0)` in the require). On both live lockers they are
  set, so both calls now revert for everyone including the deployer. Verify with
  `cast call <locker> "launcher()(address)"` and `"router()(address)"`.

The residual privilege in the system is therefore not on chain: it is the platform fee
wallet receiving its 20% leg, and whoever can deploy a *new* generation and repoint the
frontend at it. Tokens already launched are unaffected by that — their pool, their locker,
and their split are fixed at launch.

## 4. Findings

All findings below were raised in earlier review rounds and are closed in the deployed
code. Severity is the severity at the time it was found. "Pinned by" names the test that
fails if the fix regresses.

| ID | Severity | Issue | Status |
| --- | --- | --- | --- |
| C-1 | Critical | Launcher permanently brickable for the price of one pool | Fixed |
| H-1 | High | Fee inventory priced off manipulable spot price | Fixed |
| H-2 | High | A single buy could take all inventory, paying no fee and no price impact | Fixed |
| M-1 | Medium | Creator cap was a one-instant check, bypassed by launch-and-buy in one tx | Fixed |
| M-2 | Medium | `buy()` could strand `msg.value` on a dust fill | Fixed |
| M-3 | Medium | `flush()` sold fee inventory into the token's own pool with no slippage bound | Fixed |
| M-4 | Medium | Liveness read only our own clock, so live tokens were declared dead | Fixed |
| M-5 | Medium | Algebra pool with no plugin reverted every buy | Fixed |
| L-1 | Low | Dead `admin` immutable read like a backdoor | Removed |
| L-2 | Low | `MAX_WALLET_BPS` dead code | Removed |
| L-3 | Low | `collect()` called twice per buy | Accepted, §5 |
| L-4 | Low | Buyers subsidise one opportunistic `flush` of an unrelated token | Accepted, §5 |
| I-1 | Info | A comment in `FuseMeToken` overstates what the creator cap binds | Open, §5 |

### C-1 — Launcher permanently brickable for the price of one pool

The token address came from `CREATE(launcher, nonce)`, and a nonce only advances on a
*successful* create. One reverted launch therefore left the next attempt aimed at the same
address, where anyone could pre-create the pool at a hostile price and revert every launch
that followed — forever, for roughly 0.23 FUSE.

Fixed in `FuseMeLauncher.launch`: the token is created with `CREATE2` under a salt derived
from caller, metadata, block number and launch index, and the launcher **probes up to 32
salts**, stepping past any address that already has a pool (`MAX_SALT_TRIES = 32`). A
griefer must now fund a pool per attempt and still cannot stop the launch. The
`require(gotSqrt == wantSqrt, "pool pre-initialised")` check remains as the last line of
defence. *Pinned by* `test_FIXED_preInitialisedPoolCannotBrickTheLauncher`,
`test_FIXED_frontRunnerCannotBlockBySeedingThePredictedAddress`,
`test_RevertedLaunchDoesNotFreezeTheNextAddress`.

An earlier round saw this same surface and filed it as low-value grief, because it never
asked what address the *retry* targets. Worth stating for the incoming reviewer: score the
state after the revert, not the line of code.

### H-1 — Fee inventory priced off manipulable spot price

`buy()` fills the buyer from locker inventory at the instantaneous pool price. With no
oracle, one atomic transaction could crash spot into the thin discovery range, drain the
inventory cheap, then buy back to restore it. Fee value, not locked principal, was at risk.

Fixed with a TWAP gate in `_spotAgreesWithTwap`: the inventory leg is skipped entirely
unless spot agrees with a **120-second TWAP to within 100 ticks** (`TWAP_WINDOW = 120`,
`TWAP_MAX_TICK_DEV = 100`, both confirmed on chain). Observation cardinality is raised to
60 at launch so the window exists from the first block. The gate **fails closed**: if
`observe` reverts, or on Algebra if the pool has no plugin, the fill is skipped and the buy
goes to the pool. *Pinned by* `test_RouterSkipsInventoryWhenSpotManipulated`.

### H-2 — A single buy could take all inventory at the flat marginal price

An inventory fill skips the pool, so it paid no pool fee and no price impact: taking the
whole balance in one fill was strictly cheaper than buying the same size from the pool, and
the difference came out of the fee recipients. Two independent fixes:

1. `MAX_FILL_BPS = 2500` — at most 25% of inventory per fill, and the budget is accounted
   **per block in the locker** (`absorbedInBlock` / `absorbBlock`), because a loop inside
   one transaction re-read the balance each time and drained it geometrically against a
   per-call cap.
2. The fill is charged the pool's fee — the fixed 1% tier on V3, and on Algebra the
   pool's *current* dynamic fee read from `globalState()` — so filling from inventory is
   never the cheaper route.

*Pinned by* `test_SingleBuyCannotTakeAllInventory`,
`test_FIXED_fillCapBindsAcrossCallsInOneTransaction`,
`test_RouterBuyAbsorbsInventoryWithoutTouchingPool`.

### M-1 — Creator cap was a one-instant check

`require(balanceOf(msg.sender) <= 5%)` at the end of `launch()` constrained the creator only
at the instant the call returned. A contract that launched and then bought in the *same*
transaction ended up holding 13.05% of supply.

Fixed by moving the cap into `FuseMeToken._transfer`, where it binds the creator's address
for a 24-hour window (`creatorCap = 5% of supply`, `CREATOR_CAP_WINDOW = 24 hours`). The
launcher's post-launch check is kept as a second, cheaper assertion. *Pinned by*
`test_CannotLaunchAndGrabInOneTransaction`, `test_CreatorCapLiftsAfterWindow`,
`test_DevBagCappedAtFivePercent`, `testFuzz_FirstBuyNeverExceedsTheCap`.

**This is a snipe guard on the creator's own wallet, not a supply guarantee.** See §5.

### M-2 — `buy()` could strand FUSE

On a dust buy where the wanted amount rounded to zero, the FUSE-spent variable was set
while the inventory branch was skipped, so `msg.value` stayed in the ownerless router
forever. Fixed: the inventory leg is entered only when it actually fills
(`if (want == 0) fromInv = 0`, and `if (useFuse == 0) fromInv = 0`), and everything not
spent on inventory is forwarded to the pool swap. *Pinned by*
`testFuzz_BuyLeavesNothingBehindAndRespectsTheCap` (256 runs).

### M-3 — `flush()` sold into the token's own pool with `amountOutMinimum: 0`

The stale-inventory path dumped the entire token-side balance into the token's own thin
pool with no slippage bound, inside an unrelated buyer's transaction.

Fixed by removing the sell. `flush` now **pays the inventory out in kind**, 50/30/20, to
the creator, the foundation and the platform. This was the only path in the system that put
a creator's token into their own pool; with it gone, the protocol never places a sell of its
own. *Pinned by* `test_FlushDeadTokenPaysOutInFuseAndRefusesWhileAlive`.

### M-4 — Liveness read only our own clock

`flush` gated on the last absorb through *our* router. Almost all volume arrives straight on
Voltage, so actively traded tokens were declared dead. Gating on the pool alone had the
opposite failure: a few-cents bot could hold the flush off forever.

Fixed: a token is flushable only when **both** clocks are quiet for `STALE = 24 hours` —
no absorb through our router, and no trade on the pool itself, read from the pool's own
latest observation — with a `HARD_STALE = 30 days` backstop so a griefer can delay a payout
but never prevent one. Both values confirmed on chain (86,400 / 2,592,000). A dust absorb
does not refresh the clock (the locker only refreshes it when a fill is ≥1% of inventory).
*Pinned by* `test_DustSwapsOnPoolCannotBlockFlush`, `test_DustAbsorbDoesNotRefreshFlushClock`,
`test_FIXED_algebraLivenessReadsLastTradeNotPoolAge`.

### M-5 — Algebra pool with no plugin reverted every buy

A staticcall to a codeless address succeeds with empty returndata, and the ABI decode then
reverts in the **success** path, where `catch` cannot see it — so a pool whose plugin was
absent bricked its own buy path. Fixed with an explicit `plug.code.length == 0` check before
the call, which returns `false` and skips the inventory fill instead of reverting the buy.

### I-1 — A comment overstates what the creator cap binds (open)

In `FuseMeToken._transfer`, the first comment paragraph says the cap binds "EVERY
non-exempt wallet for the window". The code binds only `to == creator`, and the paragraph
directly below it correctly explains why binding unknown wallets is not closable. The
comment is stale and contradicts both the code and the honest paragraph beneath it.

**Deliberately not fixed here.** Editing it would break the byte-for-byte match between
this repository and the deployed, verified contracts (§2), which is worth more to a reviewer
than a tidy comment. It is listed so nobody reads it as a claim the code makes.

## 5. Residual risk, accepted

These are live properties of the deployed system, not to-do items.

- **The creator cap is not a supply guarantee.** It caps the creator's *own* address at 5%
  for 24 hours. A creator can point a second buy at an address nobody can name and end up
  over 5% across wallets. The only rule that catches an unnamed address is one that caps
  *every* address, which also reverts an honest large first buy. So: snipe guard, not a
  distribution promise, and after 24 hours nothing binds the creator at all.
- **The TWAP gate bounds the inventory mispricing, it does not remove it.** A 100-tick band
  (~1%) remains, and within it inventory can be bought slightly cheap. The exposure is fee
  inventory only — never locked principal — and it is capped at 25% of inventory per block.
- **`flush` pays out in kind, so a dead token's fee tokens reach recipients who may sell
  them.** The protocol does not sell; what the three recipients do with tokens they now own
  is their own decision.
- **Every buyer through `FuseMeRouter` pays gas for two `collect()` calls and one
  opportunistic `flush()` of an unrelated token** (round-robin, `try/catch`). This is real
  gas cost pushed onto buyers for a housekeeping job, bounded by the catch. (L-3, L-4)
- **`buy()` has no deadline parameter**, only `minOut`. A held transaction executes
  whenever it lands, at whatever price, subject to `minOut`.
- **The pool leg of a buy uses `amountOutMinimum: 0`**, with the user's protection applied
  once at the end as `require(out >= minOut)`. The creator's first buy inside `launch()`
  also uses min-out 0, and that one has no sandwich window: it is atomic with pool creation.
- **Custody of the locked liquidity ultimately depends on Voltage.** The locker holds
  position NFTs; the underlying tokens sit in Voltage's position manager and pool. Our side
  has no exit, but the guarantee is only as strong as those contracts as deployed.
- **On Algebra, the fee charged on the pool leg is set by a third-party volatility plugin**
  and can move between the read and the swap. The inventory leg reads `globalState()` at
  call time, so a fee change between read and fill changes who is marginally better off.
- **Earlier generations remain on chain**, unwired but functional, still holding launched
  tokens. Anyone reviewing an address not listed in §2 is reviewing superseded code.

## 6. Tests

33 tests, 5 of them fuzz at 256 runs each, all passing at the time of this review
(2026-09-20). Fuse block headers omit `prevrandao`, so forge cannot fork `rpc.fuse.io`
directly — run the suite through anvil:

```
forge install foundry-rs/forge-std
anvil --fork-url https://rpc.fuse.io --port 8547 &
cast rpc evm_mine --rpc-url http://127.0.0.1:8547
forge test --fork-url http://127.0.0.1:8547
```

| Suite | Tests | Covers |
| --- | --- | --- |
| `test/FuseFun.t.sol` | 18 | launch, curve shape, lock permanence, 50/30/20 in FUSE, inventory absorb, flush liveness, creator cap |
| `test/Audit.t.sol` | 6 | one regression test per closed finding above |
| `test/Invariants.t.sol` | 5 fuzz | supply conservation, cap, split never overpays, locker has no exit, nothing left in the router |
| `test/FuseMeAlgebra.t.sol` | 4 | the Algebra venue end to end |

`testFuzz_LockerHasNoExit(bytes4,uint256)` fuzzes an arbitrary selector and token id against
the locker and asserts the position never leaves — the negative test behind the custody
claim in §3.

## 7. Where an external reviewer should look first

1. The inventory pricing math in `FuseMeRouter.buy` for **both** token orientations
   (`token < weth` and not) — this is the densest arithmetic in the system and it decides
   who is paying whom.
2. The width of the TWAP gate: 120 seconds and 100 ticks are judgement calls, not results.
3. `flush` liveness and the `HARD_STALE` backstop, as a griefing surface.
4. The launch tick math and initial sqrt prices, per orientation, against the intended curve.
5. On Algebra, the dynamic fee read versus the fee actually charged.
