// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FuseMeLauncher} from "../src/FuseMeLauncher.sol";
import {FuseMeLocker} from "../src/FuseMeLocker.sol";

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
    function test_FIXED_launchRefusesPreInitialisedPool() public {
        address predicted = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));

        vm.startPrank(attacker);
        (address t0, address t1) = predicted < WFUSE ? (predicted, WFUSE) : (WFUSE, predicted);
        address pool = IV3Factory(V3_FACTORY).createPool(t0, t1, 10000);
        // a price far above where the launch curve is meant to open
        IV3Pool(pool).initialize(t0 == predicted ? 79228162514264337593543950336 : 79228162514264337593543950336);
        vm.stopPrank();

        (uint160 sqrtBefore,,,,,,) = IV3Pool(pool).slot0();
        assertGt(sqrtBefore, 0, "attacker initialised the pool first");

        vm.prank(creator);
        vm.expectRevert(bytes("pool pre-initialised"));
        launcher.launch{value: 10 ether}("Griefed", "GRF");

        (uint160 sqrtAfter,,,,,,) = IV3Pool(pool).slot0();
        assertEq(sqrtAfter, sqrtBefore, "the hostile price was never corrected");
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
}
