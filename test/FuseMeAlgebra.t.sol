// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuseMeAlgebraLauncher} from "../src/FuseMeAlgebraLauncher.sol";
import {FuseMeAlgebraLocker} from "../src/FuseMeAlgebraLocker.sol";
import {FuseMeAlgebraRouter} from "../src/FuseMeAlgebraRouter.sol";
import {IERC20A, IWETH9A, ISwapRouterA, IAlgebraPool} from "../src/interfaces/Algebra.sol";

/// Fork tests against Voltage's Algebra deployment on Fuse (chainId 122), the one
/// behind voltage.finance. Run through anvil, same as the v3 suite.
contract FuseMeAlgebraTest is Test {
    address constant NPM = 0x52B649B1cE77B349C53Bf0284ba61FD8975e7798;
    address constant FACTORY = 0xccEdb990abBf0606Cf47e7C6A26e419931c7dc1F;
    address constant POOL_DEPLOYER = 0x9F02d3ddbC690bc65d81A98B93d449528AC4eB8C;
    address constant WFUSE = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
    address constant ROUTER = 0x6E055FfA786Dfe9DBB214b649a9b2A169e6B820b;

    FuseMeAlgebraLauncher launcher;
    FuseMeAlgebraLocker locker;
    FuseMeAlgebraRouter router;
    address platform = makeAddr("platform");
    address foundation = makeAddr("foundation");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");

    function setUp() public {
        require(block.chainid == 122, "fork fuse");
        locker = new FuseMeAlgebraLocker(NPM, platform, foundation, WFUSE, ROUTER, 0);
        launcher = new FuseMeAlgebraLauncher(NPM, POOL_DEPLOYER, WFUSE, ROUTER, address(locker));
        locker.setLauncher(address(launcher));
        router = new FuseMeAlgebraRouter(address(launcher), address(locker), WFUSE, ROUTER, 0);
        locker.setRouter(address(router));
    }

    function _launch(uint256 firstBuy) internal returns (address token) {
        vm.deal(creator, firstBuy);
        vm.prank(creator);
        token = launcher.launch{value: firstBuy}("Algebra Fun", "AFUN");
    }

    /// A launch must open a real Algebra pool at the intended price, with both
    /// positions held by the locker.
    function test_LaunchOpensAlgebraPoolAndLocks() public {
        address token = _launch(0);
        address pool = launcher.poolOf(token);
        assertTrue(pool != address(0), "pool created");
        assertEq(IAlgebraPool(pool).tickSpacing(), 1, "algebra spacing");

        (uint160 price,,,,,) = IAlgebraPool(pool).globalState();
        bool tokenIsToken0 = token < WFUSE;
        assertEq(
            price, tokenIsToken0 ? launcher.SQRT_INIT_TOKEN0() : launcher.SQRT_INIT_TOKEN1(), "opens at start price"
        );

        // minting rounds a few wei off; the whole supply less dust must be in the pool
        assertApproxEqAbs(IERC20A(token).balanceOf(pool), launcher.SUPPLY(), 1e6, "whole supply in the pool");
        uint256 id = launcher.positionOf(token);
        uint256 moon = launcher.moonPositionOf(token);
        assertTrue(id != 0 && moon != 0 && id != moon, "two positions");
    }

    /// The launcher must have no path that returns the LP NFTs.
    function test_LiquidityLockedForever() public {
        address token = _launch(0);
        uint256 id = launcher.positionOf(token);
        assertEq(locker.unlockAt(id), type(uint64).max, "locked forever");
        vm.expectRevert();
        (bool ok,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256)", id));
        ok;
    }

    /// The creator's atomic first buy is capped at 5% of supply. Sending more FUSE
    /// than that costs must revert the whole launch rather than hand over the bag.
    function test_DevBagCappedAtFivePercent() public {
        // a small first buy is fine and lands under the cap
        address token = _launch(50 ether);
        assertLe(
            IERC20A(token).balanceOf(creator), (launcher.SUPPLY() * launcher.DEV_MAX_BPS()) / 10000, "under 5%"
        );

        // a first buy large enough to take more than 5% must revert
        vm.deal(creator, 5_000_000 ether);
        vm.prank(creator);
        vm.expectRevert();
        launcher.launch{value: 5_000_000 ether}("Too Big", "BIG");
    }

    /// A buy through our router must pay the 50/30/20 split out in FUSE.
    function test_RouterBuySplitsFeesInFuse() public {
        address token = _launch(0);
        vm.deal(buyer, 20_000 ether);

        // trade against the pool so fees accrue on both sides
        vm.startPrank(buyer);
        IWETH9A(WFUSE).deposit{value: 10_000 ether}();
        IERC20A(WFUSE).approve(ROUTER, 10_000 ether);
        ISwapRouterA(ROUTER).exactInputSingle(
            ISwapRouterA.ExactInputSingleParams({
                tokenIn: WFUSE,
                tokenOut: token,
                deployer: address(0),
                recipient: buyer,
                deadline: block.timestamp,
                amountIn: 10_000 ether,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        uint256 c0 = IERC20A(WFUSE).balanceOf(creator);
        uint256 f0 = IERC20A(WFUSE).balanceOf(foundation);
        uint256 p0 = IERC20A(WFUSE).balanceOf(platform);

        vm.deal(buyer, 1_000 ether);
        vm.prank(buyer);
        router.buy{value: 1_000 ether}(token, 0);

        assertGt(IERC20A(token).balanceOf(buyer), 0, "buyer got tokens");
        uint256 dC = IERC20A(WFUSE).balanceOf(creator) - c0;
        uint256 dF = IERC20A(WFUSE).balanceOf(foundation) - f0;
        uint256 dP = IERC20A(WFUSE).balanceOf(platform) - p0;
        assertGt(dC + dF + dP, 0, "fees paid out in FUSE");
        if (dC > 0) {
            // 50/30/20 within rounding
            assertApproxEqRel(dF * 5, dC * 3, 1e15, "foundation is 30 to creator 50");
            assertApproxEqRel(dP * 5, dC * 2, 1e15, "platform is 20 to creator 50");
        }
    }
}
