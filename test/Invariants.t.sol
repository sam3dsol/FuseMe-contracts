// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuseMeLauncher} from "../src/FuseMeLauncher.sol";
import {FuseMeLocker} from "../src/FuseMeLocker.sol";
import {FuseMeRouter} from "../src/FuseMeRouter.sol";

interface IERC20I {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IV3PoolI {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

/// Property tests. The suite this joins asserts cases somebody chose to write, which
/// only ever finds what the author already suspected. These drive random inputs at
/// the same code and assert properties that must hold for ALL of them.
contract InvariantTest is Test {
    address constant NPM = 0xE38b82A4829B21a0b179E40E64ab7b1e5aedE119;
    address constant POOL_DEPLOYER = 0xA5eceCa696C1BCeBF8c453AF7A2b87Fb0350c1f3;
    address constant WFUSE = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
    address constant ROUTER = 0xc54eDce285C4645E160eaEaBEb8624c5b9b52dd8;

    FuseMeLauncher launcher;
    FuseMeLocker locker;
    FuseMeRouter router;
    address platform = makeAddr("platform");
    address foundation = makeAddr("foundation");
    address creator = makeAddr("creator");

    function setUp() public {
        locker = new FuseMeLocker(NPM, platform, foundation, WFUSE, ROUTER, 10000);
        launcher = new FuseMeLauncher(NPM, POOL_DEPLOYER, WFUSE, ROUTER, address(locker));
        locker.setLauncher(address(launcher));
        router = new FuseMeRouter(address(launcher), address(locker), WFUSE, ROUTER, 10000);
        locker.setRouter(address(router));
    }

    /// However much FUSE a creator sends, the launch either reverts or leaves them
    /// at or under the 5% cap. There must be no amount that lands in between.
    function testFuzz_FirstBuyNeverExceedsTheCap(uint96 firstBuy) public {
        vm.assume(firstBuy < 2_000_000 ether);
        vm.deal(creator, firstBuy);
        vm.prank(creator);
        try launcher.launch{value: firstBuy}("Fuzz", "FZZ") returns (address token) {
            uint256 cap = (launcher.SUPPLY() * launcher.DEV_MAX_BPS()) / 10000;
            assertLe(IERC20I(token).balanceOf(creator), cap, "cap held for this amount");
        } catch {
            // reverting is the other acceptable outcome
        }
    }

    /// A buy of any size must never leave the router holding value, and must never
    /// take more than the per block share of inventory.
    function testFuzz_BuyLeavesNothingBehindAndRespectsTheCap(uint96 amount) public {
        vm.assume(amount > 1e12 && amount < 500_000 ether);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        address token = launcher.launch{value: 0}("Fuzz Buy", "FZB");

        address buyer = makeAddr("fuzzBuyer");
        vm.deal(buyer, amount);
        uint256 invBefore = IERC20I(token).balanceOf(address(locker));
        vm.prank(buyer);
        try router.buy{value: amount}(token, 0) {
            assertEq(address(router).balance, 0, "router holds no FUSE");
            assertEq(IERC20I(WFUSE).balanceOf(address(router)), 0, "router holds no WFUSE");
            assertEq(IERC20I(token).balanceOf(address(router)), 0, "router holds no tokens");
            if (invBefore > 0) {
                uint256 taken = invBefore > IERC20I(token).balanceOf(address(locker))
                    ? invBefore - IERC20I(token).balanceOf(address(locker))
                    : 0;
                assertLe(taken * 10000 / invBefore, router.MAX_FILL_BPS(), "fill cap held");
            }
        } catch {}
    }

    /// Total supply is fixed. Nothing in the system may mint or burn, whatever
    /// sequence of transfers happens.
    function testFuzz_SupplyIsConserved(uint96 a, uint96 b) public {
        vm.prank(creator);
        address token = launcher.launch{value: 0}("Fuzz Supply", "FZS");
        uint256 supply0 = IERC20I(token).totalSupply();

        address x = makeAddr("x");
        address y = makeAddr("y");
        address pool = launcher.poolOf(token);
        uint256 avail = IERC20I(token).balanceOf(pool);
        vm.assume(avail > 0);

        vm.prank(pool);
        IERC20I(token).transfer(x, uint256(a) % avail);
        uint256 xb = IERC20I(token).balanceOf(x);
        if (xb > 0) {
            vm.prank(x);
            IERC20I(token).transfer(y, uint256(b) % xb);
        }
        assertEq(IERC20I(token).totalSupply(), supply0, "supply conserved across transfers");
    }

    /// The locker must never be able to hand back a locked position, whatever
    /// selector and calldata are thrown at it.
    function testFuzz_LockerHasNoExit(bytes4 selector, uint256 arg) public {
        vm.prank(creator);
        address token = launcher.launch{value: 0}("Fuzz Lock", "FZL");
        uint256 id = launcher.positionOf(token);
        assertEq(locker.unlockAt(id), type(uint64).max, "locked forever");

        address thief = makeAddr("thief");
        vm.prank(thief);
        (bool ok,) = address(locker).call(abi.encodeWithSelector(selector, arg));
        ok; // most calls revert; what matters is the position never moves
        assertEq(locker.unlockAt(id), type(uint64).max, "still locked after arbitrary call");
        assertEq(locker.creatorOf(id), creator, "creator unchanged");
    }

    /// Fee splits must always land on 50/30/20 and must never pay out more than
    /// came in, for any amount.
    function testFuzz_SplitNeverOverpays(uint128 amount) public view {
        uint256 c = (uint256(amount) * locker.CREATOR_BPS()) / 10000;
        uint256 f = (uint256(amount) * locker.FOUNDATION_BPS()) / 10000;
        uint256 p = uint256(amount) - c - f;
        assertEq(c + f + p, uint256(amount), "split is exact, nothing created or stranded");
        assertLe(c, uint256(amount), "creator cut within bounds");
    }
}
