// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuseMeLauncher} from "../src/FuseMeLauncher.sol";
import {FuseMeLocker} from "../src/FuseMeLocker.sol";
import {FuseMeRouter} from "../src/FuseMeRouter.sol";
import {FuseMeToken} from "../src/FuseMeToken.sol";
import {
    INonfungiblePositionManager,
    IUniswapV3Factory,
    IUniswapV3Pool,
    IWETH9,
    IERC20,
    ISwapRouter
} from "../src/interfaces/Uniswap.sol";

/// Fork tests against the real Voltage v3 on Fuse (chainId 122).
/// Fuse POA headers break direct forking — run through anvil:
///   anvil --fork-url https://rpc.fuse.io --port 8547 &
///   cast rpc evm_mine --rpc-url http://127.0.0.1:8547
///   forge test --fork-url http://127.0.0.1:8547 -vv
contract FuseFunTest is Test {
    address constant NPM = 0xE38b82A4829B21a0b179E40E64ab7b1e5aedE119;
    address constant FACTORY = 0xaD079548b3501C5F218c638A02aB18187F62b207;
    address constant POOL_DEPLOYER = 0xA5eceCa696C1BCeBF8c453AF7A2b87Fb0350c1f3;
    address constant WFUSE = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
    address constant ROUTER = 0xc54eDce285C4645E160eaEaBEb8624c5b9b52dd8;

    FuseMeLauncher launcher;
    FuseMeLocker locker;
    FuseMeRouter router;
    address platform = makeAddr("platform");
    address foundation = makeAddr("foundation");
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address cranker = makeAddr("cranker");

    function setUp() public {
        require(block.chainid == 122, "fork fuse");
        locker = new FuseMeLocker(NPM, platform, foundation, WFUSE, ROUTER, 10000);
        launcher = new FuseMeLauncher(NPM, POOL_DEPLOYER, WFUSE, ROUTER, address(locker));
        locker.setLauncher(address(launcher));
        router = new FuseMeRouter(address(launcher), address(locker), WFUSE, ROUTER, 10000);
        locker.setRouter(address(router));
    }

    function _launch(uint256 firstBuy) internal returns (address token, uint256 tokenId) {
        vm.deal(creator, firstBuy);
        vm.prank(creator);
        token = launcher.launch{value: firstBuy}("Fuse Fun", "FFUN");
        tokenId = launcher.positionOf(token);
    }

    function _buyFrom(address who, address token, uint256 fuseIn) internal returns (uint256 out, bool ok) {
        vm.deal(who, fuseIn);
        vm.startPrank(who);
        IWETH9(WFUSE).deposit{value: fuseIn}();
        IERC20(WFUSE).approve(ROUTER, fuseIn);
        try ISwapRouter(ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WFUSE, tokenOut: token, fee: 10000, recipient: who,
                deadline: block.timestamp, amountIn: fuseIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 o) { out = o; ok = true; } catch { out = 0; ok = false; }
        vm.stopPrank();
    }

    function _sellFrom(address who, address token, uint256 tokenIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(token).approve(ROUTER, tokenIn);
        out = ISwapRouter(ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: token, tokenOut: WFUSE, fee: 10000, recipient: who,
                deadline: block.timestamp, amountIn: tokenIn, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
    }

    function test_LaunchCreatesPoolAtStartPriceAndLocks() public {
        (address token, uint256 tokenId) = _launch(0);
        uint256 moonId = launcher.moonPositionOf(token);

        address pool = launcher.poolOf(token);
        assertEq(IUniswapV3Factory(FACTORY).getPool(token, WFUSE, 10000), pool, "factory pool");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        bool tokenIsToken0 = token < WFUSE;
        assertEq(tick, tokenIsToken0 ? int24(-59800) : int24(59800), "start tick");

        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), address(locker), "curve LP in locker");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(moonId), address(locker), "moon LP in locker");
        assertEq(locker.creatorOf(tokenId), creator, "creator");
        assertEq(locker.creatorOf(moonId), creator, "moon creator");
        assertEq(locker.unlockAt(tokenId), type(uint64).max, "unlock never");
        assertEq(locker.unlockAt(moonId), type(uint64).max, "moon unlock never");
        assertEq(locker.tokenOf(tokenId), token, "tokenOf");
        assertEq(locker.tokenOf(moonId), token, "moon tokenOf");
        assertEq(launcher.tokenCount(), 1, "count");
    }


    function test_FreeLaunchNoFee() public {
        vm.prank(creator);
        address token = launcher.launch{value: 0}("Free", "FREE");
        assertTrue(token != address(0), "zero-FUSE launch works");
    }

    function test_AtomicFirstBuy() public {
        (address token,) = _launch(1_000 ether);
        uint256 bal = IERC20(token).balanceOf(creator);
        // ~1000 FUSE (~$3) from the ~$7.8k FDV start buys ~390k tokens in the launch tx
        assertGt(bal, 300_000e18, "creator bought in launch tx");
    }

    /// Price gain factor (x1e4) implied by two sqrt prices: (spHi/spLo)^2 * 1e4.
    /// For token0-side tokens buys push sqrtP up (pass sp0, sp1); for token1-side
    /// tokens FUSE-per-token is the inverse, so callers pass the pair swapped.
    function _gainX1e4(uint160 spLo, uint160 spHi) internal pure returns (uint256) {
        return (uint256(spHi) * uint256(spHi) / uint256(spLo)) * 1e4 / uint256(spLo);
    }

    /// The reason this generation exists. Gens 1-4 doubled the price on ~29.6k FUSE
    /// (~$90) of buying, which meant an equally violent exit on the way back down.
    /// This ramp needs ~147k FUSE (~$450) for the same move: 4.98x deeper. Measured
    /// against the live pool, not against the model that picked the ticks.
    function test_CurveIsFiveTimesCalmer() public {
        (address token,) = _launch(0);
        address pool = launcher.poolOf(token);
        bool tokenIsToken0 = token < WFUSE;
        (uint160 sp0,,,,,,) = IUniswapV3Pool(pool).slot0();

        // the buy that used to double the price now barely moves it
        (, bool okA) = _buyFrom(buyer, token, 29_610 ether);
        assertTrue(okA, "old doubling buy lands");
        (uint160 spA,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 gA = tokenIsToken0 ? _gainX1e4(sp0, spA) : _gainX1e4(spA, sp0);
        assertLt(gA, 13_000, "old doubling size now worth under +30%");

        // ~147k FUSE in total is what doubles it now
        (, bool okB) = _buyFrom(cranker, token, 117_704 ether);
        assertTrue(okB, "top-up buy lands");
        (uint160 spB,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 gB = tokenIsToken0 ? _gainX1e4(sp0, spB) : _gainX1e4(spB, sp0);
        assertGt(gB, 19_500, "~147k FUSE doubles the price");
        assertLt(gB, 20_500, "and only just doubles it");
    }

    /// Same shape as before, one range deeper: ~$1k of buys is a few x rather than a
    /// sweep, ~1.7M FUSE (~$5k) sweeps the ramp end to end, and the moon range still
    /// takes buys afterwards instead of walling off.
    function test_RampSweepsAndMoonRunwayHolds() public {
        (address token,) = _launch(0);
        address pool = launcher.poolOf(token);
        bool tokenIsToken0 = token < WFUSE;

        (uint160 sp0,,,,,,) = IUniswapV3Pool(pool).slot0();
        (, bool ok1) = _buyFrom(buyer, token, 343_670 ether);
        assertTrue(ok1, "~$1k buy lands");
        (uint160 sp1,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 g1 = tokenIsToken0 ? _gainX1e4(sp0, sp1) : _gainX1e4(sp1, sp0);
        assertGt(g1, 30_000, "~$1k is 3x+");
        (, int24 midTick,,,,,) = IUniswapV3Pool(pool).slot0();
        if (tokenIsToken0) assertLt(midTick, int24(-24800), "~$1k stays inside the ramp");
        else assertGt(midTick, int24(24800), "~$1k stays inside the ramp");

        // ~1.7M FUSE total (~$5k) sweeps the ramp into the moon range (past -24800)
        (, bool ok2) = _buyFrom(cranker, token, 1_400_000 ether);
        assertTrue(ok2, "sweep buy lands");
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        if (tokenIsToken0) assertGt(tick, int24(-24800), "price past ramp top (~$257k FDV)");
        else assertLt(tick, int24(24800), "price past ramp top (~$257k FDV)");

        // runway: buys keep landing in the moon range instead of hitting a wall
        (, bool ok3) = _buyFrom(buyer, token, 200_000 ether);
        assertTrue(ok3, "moon-range buy lands");
        (uint160 sp3,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 g3 = tokenIsToken0 ? _gainX1e4(sp0, sp3) : _gainX1e4(sp3, sp0);
        assertGt(g3, 300_000, "30x+ from launch once the ramp is swept");
    }

    /// Fees pay out in FUSE ONLY: the WFUSE side splits 50/30/20 exactly, and the
    /// token side lands in the locker as inventory (never sold, never sent to a
    /// recipient) waiting to be absorbed by a future buy.
    function test_CollectSplits_50_30_20_FuseOnly() public {
        (address token, uint256 tokenId) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 10_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2); // sell fees accrue in the token

        (uint256 amount0, uint256 amount1) = locker.collect(tokenId);
        bool wethIs0 = WFUSE < token;
        uint256 fuseOut = wethIs0 ? amount0 : amount1;
        uint256 tokOut = wethIs0 ? amount1 : amount0;
        assertGt(fuseOut, 0, "buy-side fees accrued in WFUSE");
        assertGt(tokOut, 0, "sell-side fees collected as inventory");

        uint256 c = IERC20(WFUSE).balanceOf(creator);
        uint256 f = IERC20(WFUSE).balanceOf(foundation);
        uint256 p = IERC20(WFUSE).balanceOf(platform);
        assertEq(c, (fuseOut * 5000) / 10000, "creator 50% in FUSE");
        assertEq(f, (fuseOut * 3000) / 10000, "foundation 30% in FUSE");
        assertEq(p, fuseOut - c - f, "platform 20% in FUSE");
        assertEq(IERC20(token).balanceOf(creator), 0, "no token to creator");
        assertEq(IERC20(token).balanceOf(foundation), 0, "no token to foundation");
        assertEq(IERC20(token).balanceOf(platform), 0, "no token to platform");
        assertEq(IERC20(token).balanceOf(address(locker)), tokOut, "token side held as inventory");
        assertEq(IERC20(WFUSE).balanceOf(address(locker)), 0, "locker keeps no WFUSE");
    }

    /// The buy path: inventory is absorbed into a real purchase at the live pool
    /// price. A buy small enough to be covered by inventory leaves the pool price
    /// COMPLETELY untouched (no swap, so nothing can print on a chart), pays the
    /// splits in FUSE immediately, and drains the inventory.
    // Let the pool build TWAP history: warp past the router's window and write a
    // fresh observation with a tiny trade, so observe([TWAP_WINDOW,0]) succeeds.
    function _ageForTwap(address token) internal {
        vm.warp(block.timestamp + 200);
        _buyFrom(buyer, token, 1 ether);
    }

    function test_RouterBuyAbsorbsInventoryWithoutTouchingPool() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 20_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);
        _ageForTwap(token);

        vm.deal(cranker, 10 ether);
        vm.prank(cranker);
        uint256 out1 = router.buy{value: 1 ether}(token, 0);
        assertGt(out1, 0, "first buy delivered");
        uint256 inv = IERC20(token).balanceOf(address(locker));
        assertGt(inv, 0, "inventory present");

        address pool = launcher.poolOf(token);
        (uint160 spBefore,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 cW = IERC20(WFUSE).balanceOf(creator);
        uint256 fW = IERC20(WFUSE).balanceOf(foundation);
        uint256 pW = IERC20(WFUSE).balanceOf(platform);

        vm.prank(cranker);
        uint256 out2 = router.buy{value: 0.5 ether}(token, 0);
        assertGt(out2, 0, "second buy delivered");

        (uint160 spAfter,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(spAfter, spBefore, "pool price untouched: no swap printed");
        assertGt(IERC20(WFUSE).balanceOf(creator), cW, "creator paid in FUSE");
        assertGt(IERC20(WFUSE).balanceOf(foundation), fW, "foundation paid in FUSE");
        assertGt(IERC20(WFUSE).balanceOf(platform), pW, "platform paid in FUSE");
        assertLt(IERC20(token).balanceOf(address(locker)), inv, "inventory drained");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router holds nothing");
        assertEq(address(router).balance, 0, "router holds no FUSE");
    }

    /// H-1 guard: if spot is slammed away from the TWAP inside the buy, the router
    /// refuses to hand out inventory at the manipulated price and routes to the
    /// pool instead. This is the fix for the spot-price inventory drain.
    function test_RouterSkipsInventoryWhenSpotManipulated() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 20_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);
        _ageForTwap(token);

        // materialise the token-side fees into the locker as inventory
        locker.collect(launcher.positionOf(token));
        uint256 invBefore = IERC20(token).balanceOf(address(locker));
        assertGt(invBefore, 0, "inventory present");

        // attacker crashes spot far from the TWAP by dumping a large slug of token
        _sellFrom(buyer, token, got / 4);

        // a buy now must NOT sell inventory at the manipulated price: the guard
        // trips and the whole buy routes to the pool. (collect() still pays the
        // WFUSE-side fees, that is real earned revenue and unrelated to the fill.)
        vm.deal(cranker, 5 ether);
        vm.prank(cranker);
        uint256 out = router.buy{value: 1 ether}(token, 0);
        assertGt(out, 0, "buy still delivers via the pool");

        uint256 invAfter = IERC20(token).balanceOf(address(locker));
        // inventory only grows (fresh token-side fees), never shrinks at a bad price
        assertGe(invAfter, invBefore, "inventory not sold at the manipulated price");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router holds nothing");
        assertEq(address(router).balance, 0, "router holds no FUSE");
    }

    /// A market with zero trades for 24 hours is dead: flush() liquidates its fee
    /// inventory into the pool and pays the split out in FUSE, so nothing strands.
    /// While the market is alive, flush refuses.
    function test_FlushDeadTokenPaysOutInFuseAndRefusesWhileAlive() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 10_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);

        vm.expectRevert(bytes("market alive"));
        locker.flush(token);

        vm.warp(block.timestamp + 25 hours);
        uint256 fW = IERC20(WFUSE).balanceOf(foundation);
        locker.flush(token);
        assertGt(IERC20(WFUSE).balanceOf(foundation), fW, "foundation paid in FUSE from dead inventory");
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "inventory fully liquidated");
        assertEq(IERC20(WFUSE).balanceOf(address(locker)), 0, "locker keeps no WFUSE");
    }

    /// GRIEF REGRESSION: a few-cents bot swapping straight on Voltage refreshes the
    /// pool's own oracle, which the old gate read, and could hold flush off forever
    /// without ever absorbing inventory. The gate now reads lastAbsorbAt, which only
    /// a real fill moves, so pool-side dust is irrelevant.
    function test_DustSwapsOnPoolCannotBlockFlush() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 10_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);
        locker.collect(launcher.positionOf(token));
        locker.collect(launcher.moonPositionOf(token));
        assertGt(IERC20(token).balanceOf(address(locker)), 0, "inventory accrued");

        // Well past STALE, then a dust swap straight on the pool: this refreshes the
        // pool's oracle (what the old gate read) but absorbs no inventory.
        uint256 t = block.timestamp + 30 hours;
        vm.warp(t);
        _sellFrom(buyer, token, 1e12);
        assertEq(block.timestamp, t, "warp held");

        // Pool oracle is fresh; our clock is not. Flush must still work.
        uint256 fW = IERC20(WFUSE).balanceOf(foundation);
        locker.flush(token);
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "grief cannot strand inventory");
        assertGt(IERC20(WFUSE).balanceOf(foundation), fW, "foundation still paid");
    }

    /// A dust fill through the router must NOT refresh the flush clock either,
    /// otherwise the same grief just moves to our own front door.
    function test_DustAbsorbDoesNotRefreshFlushClock() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 10_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);

        vm.warp(block.timestamp + 25 hours);
        locker.collect(launcher.positionOf(token));
        locker.collect(launcher.moonPositionOf(token));
        uint256 invBefore = IERC20(token).balanceOf(address(locker));
        assertGt(invBefore, 0, "inventory present");

        // A buy small enough to take well under 1% of the inventory.
        vm.deal(cranker, 1 ether);
        vm.prank(cranker);
        router.buy{value: 0.02 ether}(token, 0);
        uint256 absorbed = invBefore - IERC20(token).balanceOf(address(locker));
        assertGt(absorbed, 0, "dust buy did absorb something");
        assertLt(absorbed * 100, invBefore, "and it was under 1% of inventory");

        // The clock did not move, so the token is still flushable immediately.
        locker.flush(token);
        assertEq(IERC20(token).balanceOf(address(locker)), 0, "dust absorb did not shield inventory");
    }

    /// Any buy of any token advances the cursor and flushes one stale token, so
    /// dead-inventory cleanup runs on the platform's own activity, keeperless.
    function test_RouterBuyFlushesOtherDeadToken() public {
        (address tokenA,) = _launch(0);
        vm.prank(creator);
        address tokenB = launcher.launch{value: 0}("Dead Soon", "DEAD");
        (uint256 got, bool ok) = _buyFrom(buyer, tokenB, 5_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, tokenB, got / 2);

        vm.warp(block.timestamp + 25 hours);
        vm.deal(cranker, 5 ether);
        vm.startPrank(cranker);
        router.buy{value: 1 ether}(tokenA, 0);   // cursor 0 -> tokenA itself, skipped
        uint256 fW = IERC20(WFUSE).balanceOf(foundation);
        router.buy{value: 1 ether}(tokenA, 0);   // cursor 1 -> tokenB, flushed
        vm.stopPrank();
        assertEq(IERC20(tokenB).balanceOf(address(locker)), 0, "dead token inventory flushed");
        assertGt(IERC20(WFUSE).balanceOf(foundation), fW, "foundation paid from the flush");
    }

    function test_LiquidityLockedForever() public {
        (address token, uint256 tokenId) = _launch(0);
        uint256 moonId = launcher.moonPositionOf(token);

        assertTrue(locker.PERMANENT_LOCK(), "permanent");
        assertEq(locker.unlockAt(tokenId), type(uint64).max, "never unlocks");
        assertEq(locker.unlockAt(moonId), type(uint64).max, "moon never unlocks");

        // The old escape hatch is gone: nothing answers that selector any more.
        (bool ok,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256,address)", tokenId, admin));
        assertFalse(ok, "withdraw must not exist");

        // A century later the positions are still exactly where they were minted.
        vm.warp(block.timestamp + 36500 days);
        assertEq(INonfungiblePositionManager(NPM).ownerOf(tokenId), address(locker), "curve LP still locked");
        assertEq(INonfungiblePositionManager(NPM).ownerOf(moonId), address(locker), "moon LP still locked");

        // And the lock does not freeze the economics: fees still collect and split.
        _buyFrom(buyer, token, 200 ether);
        uint256 creatorBefore = IERC20(WFUSE).balanceOf(creator);
        locker.collect(tokenId);
        assertGt(IERC20(WFUSE).balanceOf(creator), creatorBefore, "creator still earns after lock would have expired");
    }

    /// The creator's atomic first buy is capped at 5% of supply on v3 too.
    function test_DevBagCappedAtFivePercent() public {
        (address token,) = _launch(50 ether);
        assertLe(IERC20(token).balanceOf(creator), (launcher.SUPPLY() * launcher.DEV_MAX_BPS()) / 10000, "under 5%");

        vm.deal(creator, 5_000_000 ether);
        vm.prank(creator);
        // the cap now trips inside the token transfer, so the DEX router surfaces
        // its own failure rather than our string: assert it reverts, not how.
        vm.expectRevert();
        launcher.launch{value: 5_000_000 ether}("Too Big", "BIG");
    }

    /// REGRESSION: with plain CREATE a reverted launch left the next attempt aimed
    /// at the same address, so one pre-initialised pool could brick the launcher
    /// forever. Salted CREATE2 must give a different address per attempt.
    function test_RevertedLaunchDoesNotFreezeTheNextAddress() public {
        // two launches from different creators must not collide
        vm.deal(creator, 0);
        vm.prank(creator);
        address a = launcher.launch{value: 0}("One", "ONE");

        address other = makeAddr("other");
        vm.prank(other);
        address b = launcher.launch{value: 0}("Two", "TWO");
        assertTrue(a != b, "distinct tokens");

        // same creator, same metadata, different block: different address
        vm.roll(block.number + 1);
        vm.prank(creator);
        address c = launcher.launch{value: 0}("One", "ONE");
        assertTrue(c != a && c != b, "address varies per block");
    }

    /// REGRESSION: launching and buying inside one transaction used to defeat the
    /// cap entirely, because the launcher only read the creator's balance at the
    /// instant launch() returned. The token now enforces it, so the buy reverts.
    function test_CannotLaunchAndGrabInOneTransaction() public {
        LaunchAndGrab bot = new LaunchAndGrab();
        vm.deal(address(bot), 400_000 ether);
        vm.expectRevert();
        bot.run(address(launcher), ROUTER, WFUSE, 400_000 ether);
    }

    /// And the cap lifts once the window has passed, so it is a launch guard, not
    /// a permanent restriction on the creator.
    function test_CreatorCapLiftsAfterWindow() public {
        (address token,) = _launch(50 ether);
        uint256 cap = (launcher.SUPPLY() * 500) / 10000;
        assertLe(IERC20(token).balanceOf(creator), cap, "capped at launch");
        vm.warp(block.timestamp + 25 hours);
        (uint256 got,) = _buyFrom(creator, token, 300_000 ether);
        assertGt(IERC20(token).balanceOf(creator), cap, "cap no longer binds after the window");
        got;
    }

    /// REGRESSION: one buy could absorb the ENTIRE fee inventory at the flat
    /// marginal price, with no impact and no pool fee. Cap it so the rest stays.
    function test_SingleBuyCannotTakeAllInventory() public {
        (address token,) = _launch(0);
        (uint256 got, bool ok) = _buyFrom(buyer, token, 10_000 ether);
        assertTrue(ok);
        _sellFrom(buyer, token, got / 2);
        locker.collect(launcher.positionOf(token));
        locker.collect(launcher.moonPositionOf(token));
        uint256 inv = IERC20(token).balanceOf(address(locker));
        assertGt(inv, 0, "inventory accrued");

        vm.deal(cranker, 500_000 ether);
        vm.prank(cranker);
        router.buy{value: 400_000 ether}(token, 0);

        uint256 left = IERC20(token).balanceOf(address(locker));
        assertGt(left, 0, "a single buy did not drain the inventory");
        uint256 took = inv - left;
        assertLe(took * 10000, inv * 2600, "took no more than the 25% cap, allowing rounding");
    }
}

/// The exact bypass an auditor demonstrated: launch and then buy in ONE transaction,
/// so the launcher's post-launch balance check sees a balance of zero and passes.
contract LaunchAndGrab {
    function run(address launcher, address router, address weth, uint256 buyWith) external payable returns (address token) {
        token = FuseMeLauncher(launcher).launch{value: 0}("Grab", "GRAB");
        IWETH9(weth).deposit{value: buyWith}();
        IERC20(weth).approve(router, buyWith);
        ISwapRouter(router).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: weth, tokenOut: token, fee: 10000, recipient: address(this),
                deadline: block.timestamp, amountIn: buyWith, amountOutMinimum: 0, sqrtPriceLimitX96: 0
            })
        );
    }
}
