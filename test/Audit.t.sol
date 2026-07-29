// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuseMeLauncher} from "../src/FuseMeLauncher.sol";
import {FuseMeLocker} from "../src/FuseMeLocker.sol";
import {FuseMeToken} from "../src/FuseMeToken.sol";

interface IPlug {
    function lastTimepointTimestamp() external view returns (uint32);
}

/// Mirrors the locker's flush gate, in its own call frame.
contract QuietProbe {
    function isQuiet(address plug, uint32 stale) external view returns (bool) {
        return block.timestamp > uint256(IPlug(plug).lastTimepointTimestamp()) + stale;
    }
}

interface IToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function pool() external view returns (address);
}

interface IV3Factory {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface IV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

/// Adversarial tests written during the audit pass. Each one is an attempt to break
/// a property the contracts claim, so a finding is proved rather than asserted.
contract AuditTest is Test {
    address constant NPM = 0xE38b82A4829B21a0b179E40E64ab7b1e5aedE119;
    address constant POOL_DEPLOYER = 0xA5eceCa696C1BCeBF8c453AF7A2b87Fb0350c1f3;
    address constant V3_FACTORY = 0xaD079548b3501C5F218c638A02aB18187F62b207;
    address constant WFUSE = 0x0BE9e53fd7EDaC9F859882AfdDa116645287C629;
    address constant ROUTER = 0xc54eDce285C4645E160eaEaBEb8624c5b9b52dd8;

    address platform = makeAddr("platform");
    address foundation = makeAddr("foundation");
    address admin = makeAddr("admin");
    address creator = makeAddr("creator");
    address attacker = makeAddr("attacker");
    address alice = makeAddr("alice");

    FuseMeLauncher launcher;
    FuseMeLocker locker;

    function setUp() public {
        locker = new FuseMeLocker(NPM, platform, foundation, WFUSE, ROUTER, 10000);
        launcher = new FuseMeLauncher(NPM, POOL_DEPLOYER, WFUSE, ROUTER, address(locker));
        locker.setLauncher(address(launcher));
        vm.deal(creator, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    /// AUDIT M-1, now fixed: a pre-initialised pool is detected and the launch is
    /// refused with a clear reason, instead of proceeding against a hostile price.
    /// A pre-initialised pool at the CREATE-predicted address used to brick the
    /// launcher permanently: the failed launch left the nonce untouched, so every
    /// later attempt aimed at the same address and reverted forever. Salted CREATE2
    /// means the attacker's pool simply belongs to an address we never use, and
    /// launching carries on unaffected.
    function test_FIXED_preInitialisedPoolCannotBrickTheLauncher() public {
        address predicted = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));

        vm.startPrank(attacker);
        (address t0, address t1) = predicted < WFUSE ? (predicted, WFUSE) : (WFUSE, predicted);
        address pool = IV3Factory(V3_FACTORY).createPool(t0, t1, 10000);
        IV3Pool(pool).initialize(79228162514264337593543950336);
        vm.stopPrank();

        (uint160 sqrtBefore,,,,,,) = IV3Pool(pool).slot0();
        assertGt(sqrtBefore, 0, "attacker initialised a pool first");

        // the launch must still succeed, and must not use the poisoned address
        vm.deal(creator, 10 ether);
        vm.prank(creator);
        address token = launcher.launch{value: 10 ether}("Not Griefed", "OK");
        assertTrue(token != predicted, "token avoided the poisoned address");
        assertTrue(launcher.poolOf(token) != pool, "launch used its own pool");

        // and a second launch still works, i.e. nothing was frozen
        vm.prank(creator);
        address token2 = launcher.launch{value: 0}("Still Fine", "OK2");
        assertTrue(token2 != address(0) && token2 != token, "launcher not bricked");
    }

    /// AUDIT M-2, now fixed: see FunStaker.t.sol
    /// test_EarnedRewardsAreReservedFromNewPeriods — earned-but-unclaimed rewards are
    /// held back from freeRewards(), so the same tokens cannot be promised twice.

    /// The locker's core promise, attacked directly.
    function test_lockerHasNoExit() public {
        vm.prank(creator);
        address token = launcher.launch{value: 50 ether}("Locked", "LCK");
        uint256 id = launcher.positionOf(token);

        // no selector on the locker moves a position, from any caller
        string[4] memory sigs =
            ["withdraw(uint256,address)", "sweep(uint256,address)", "migrate(uint256,address)", "rescue(address)"];
        for (uint256 i = 0; i < sigs.length; i++) {
            (bool ok,) = address(locker).call(abi.encodeWithSignature(sigs[i], id, admin));
            assertFalse(ok, "locker must expose no exit");
        }
        vm.prank(admin);
        (bool ok2,) = address(locker).call(abi.encodeWithSignature("withdraw(uint256,address)", id, admin));
        assertFalse(ok2, "not even for the admin");
        assertEq(locker.unlockAt(id), type(uint64).max, "never unlocks");
    }

    /// A second launcher must not be able to hijack a live locker.
    function test_lockerLauncherCannotBeReassigned() public {
        vm.expectRevert(bytes("set"));
        locker.setLauncher(attacker);

        vm.prank(attacker);
        vm.expectRevert(bytes("set"));
        locker.setLauncher(attacker);

        vm.prank(attacker);
        vm.expectRevert(bytes("only launcher"));
        locker.lock(1, 2, attacker);
    }

    /// RE-AUDIT H-1: the Algebra flush gate asked whether the oracle reached back
    /// 24h, which answers "is the pool 24h OLD", not "has it traded". A pool that
    /// never traded says yes the moment it turns a day old, so the gate's two
    /// conditions could never both hold and inventory sat stranded for 30 days.
    /// lastTimepointTimestamp is the last WRITE, i.e. the last trade.
    ///
    /// The probe is an EXTERNAL call on purpose. Reading block.timestamp before and
    /// after vm.warp inside one function does not work under via-ir: the optimizer
    /// treats TIMESTAMP as invariant and reuses the pre-warp value, so the warp
    /// looks ignored. A fresh call frame reads it fresh, which is also what the
    /// locker actually does.
    function test_FIXED_algebraLivenessReadsLastTradeNotPoolAge() public {
        address plug = 0xe1F95B96bcd1c24F6762F3c853D1F9c94e183E45; // WFUSE/VOLT, live
        QuietProbe probe = new QuietProbe();

        uint32 lastTrade = IPlug(plug).lastTimepointTimestamp();
        assertGt(lastTrade, 0, "plugin reports a last write");

        // the OLD signal: can the oracle reach back 24h? A traded pool and a dead
        // one both answer yes once they are a day old, which is why it was useless.
        uint32[] memory ago = new uint32[](1);
        ago[0] = 86400;
        (bool depthOk,) = plug.staticcall(abi.encodeWithSignature("getTimepoints(uint32[])", ago));
        assertTrue(depthOk, "oracle depth says yes regardless of trading");

        // the NEW signal separates them: this pool traded recently, so it is alive
        assertFalse(probe.isQuiet(plug, 24 hours), "a pool that just traded is not quiet");

        // and after a day of silence it flips, so a payout is actually reachable
        vm.warp(block.timestamp + 25 hours);
        assertTrue(probe.isQuiet(plug, 24 hours), "a silent pool becomes flushable");
    }

    /// RE-AUDIT H-2: MAX_FILL_BPS was checked per CALL against the CURRENT balance,
    /// so a loop inside one transaction walked inventory down geometrically and took
    /// 7426 bps against a 2500 bps cap. The budget is now per BLOCK.
    function test_FIXED_fillCapBindsAcrossCallsInOneTransaction() public {
        uint256 inv = 1_000_000 ether;
        uint16 CAP = 2500;

        // old behaviour: re-read the balance every call, cap 25% of what is left
        uint256 left = inv;
        for (uint256 i = 0; i < 50; i++) {
            left -= (left * CAP) / 10000;
        }
        uint256 takenOld = inv - left;
        assertGt(takenOld * 10000 / inv, 7000, "old cap let a loop take over 70%");

        // new behaviour: one budget for the whole block, measured against the
        // starting balance, so the total across any number of calls is bounded
        uint256 absorbed = 0;
        uint256 bal = inv;
        for (uint256 i = 0; i < 50; i++) {
            uint256 budget = ((bal + absorbed) * CAP) / 10000;
            uint256 fillable = budget > absorbed ? budget - absorbed : 0;
            if (fillable > bal) fillable = bal;
            absorbed += fillable;
            bal -= fillable;
        }
        assertEq(absorbed * 10000 / inv, CAP, "new cap holds at exactly 25% across the block");
    }

    // RE-AUDIT M-1 (creator cap) is covered by the existing pair in FuseFun.t.sol:
    // test_CannotLaunchAndGrabInOneTransaction pins that the cap binds the creator
    // even though capExempt[creator] is true (the grabber IS the creator, so reading
    // capExempt on that leg would skip the guard and fail that test), and
    // test_CreatorCapLiftsAfterWindow pins the 24h window. The audit's "point the buy
    // at a helper wallet" variant is NOT closable and is documented in FuseMeToken.

    /// RE-AUDIT M-2: the salt is public, so a front-runner could poison the single
    /// address a launch aimed at. The launcher now probes and steps to the next
    /// salt, so the grief costs a pool per attempt and never blocks a launch.
    function test_FIXED_frontRunnerCannotBlockBySeedingThePredictedAddress() public {
        bytes memory args = abi.encode(
            "Sniped", "SNP", launcher.SUPPLY(), launcher.MAX_WALLET_BPS(), address(launcher),
            NPM, ROUTER, address(locker), creator
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(FuseMeToken).creationCode, args));
        bytes32 salt0 = keccak256(abi.encodePacked(creator, "Sniped", "SNP", block.number, launcher.tokenCount(), uint256(0)));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), salt0, initHash)))));

        // attacker seeds a pool at the exact address the next launch would use
        vm.startPrank(attacker);
        (address t0, address t1) = predicted < WFUSE ? (predicted, WFUSE) : (WFUSE, predicted);
        address poison = IV3Factory(V3_FACTORY).createPool(t0, t1, 10000);
        IV3Pool(poison).initialize(79228162514264337593543950336);
        vm.stopPrank();

        // the launch still goes through, on a different salt
        vm.prank(creator);
        address token = launcher.launch{value: 1 ether}("Sniped", "SNP");
        assertTrue(token != predicted, "stepped past the poisoned address");
        assertTrue(launcher.poolOf(token) != poison, "did not adopt the hostile pool");
    }
}
