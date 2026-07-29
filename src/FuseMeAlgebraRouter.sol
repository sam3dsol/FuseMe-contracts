// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20A, IWETH9A, ISwapRouterA, IAlgebraPool, IAlgebraPlugin} from "./interfaces/Algebra.sol";
import {FuseMeAlgebraLauncher} from "./FuseMeAlgebraLauncher.sol";
import {FuseMeAlgebraLocker} from "./FuseMeAlgebraLocker.sol";

contract FuseMeAlgebraRouter {
    FuseMeAlgebraLauncher public immutable launcher;
    FuseMeAlgebraLocker public immutable locker;
    IWETH9A public immutable weth;
    ISwapRouterA public immutable swapRouter;
    uint24 public immutable poolFee;
    address public immutable foundation;
    address public immutable platform;

    uint16 public constant CREATOR_BPS = 5000;
    uint16 public constant FOUNDATION_BPS = 3000;

    uint32 public constant TWAP_WINDOW = 120;
    /// Most of the inventory one buy may absorb, in basis points. Without a cap a
    /// single fill takes the entire balance at the flat marginal price, paying no
    /// price impact and no pool fee: the difference against buying the same size
    /// from the pool is value taken from the fee recipients.
    uint16 public constant MAX_FILL_BPS = 2500;
    int24 public constant TWAP_MAX_TICK_DEV = 100;

    uint256 public cursor;

    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    event InventoryAbsorbed(address indexed token, address indexed buyer, uint256 tokensOut, uint256 fuseIn);

    constructor(address _launcher, address _locker, address _weth, address _swapRouter, uint24 _poolFee) {
        require(
            _launcher != address(0) && _locker != address(0) && _weth != address(0) && _swapRouter != address(0),
            "zero"
        );
        launcher = FuseMeAlgebraLauncher(_launcher);
        locker = FuseMeAlgebraLocker(_locker);
        weth = IWETH9A(_weth);
        swapRouter = ISwapRouterA(_swapRouter);
        poolFee = _poolFee;
        foundation = FuseMeAlgebraLocker(_locker).foundation();
        platform = FuseMeAlgebraLocker(_locker).platform();
    }

    /// Algebra's fee floats, so the inventory leg has to read what the pool would
    /// actually charge right now rather than assume a fixed tier.
    function _currentFee(address pool) internal view returns (uint16) {
        (,, uint16 lastFee,,,) = IAlgebraPool(pool).globalState();
        return lastFee;
    }

    function buy(address token, uint256 minOut) external payable nonReentrant returns (uint256 out) {
        require(msg.value > 0, "zero in");
        address creator = launcher.creatorOf(token);
        require(creator != address(0), "not fuseme");
        address pool = launcher.poolOf(token);

        locker.collect(launcher.positionOf(token));
        locker.collect(launcher.moonPositionOf(token));

        uint256 fuseIn = msg.value;
        uint256 useFuse = 0;
        uint256 fromInv = 0;
        uint256 inv = IERC20A(token).balanceOf(address(locker));
        if (inv > 0 && _spotAgreesWithTwap(pool)) {
            (uint160 sqrtP,,,,,) = IAlgebraPool(pool).globalState();

            uint256 want = token < address(weth)
                ? (((fuseIn << 96) / sqrtP) << 96) / sqrtP
                : ((fuseIn * sqrtP) >> 96) * sqrtP >> 96;
            // Filling from inventory skips the pool, so without this the buyer paid
            // NO fee for the inventory leg and an inventory fill was strictly cheaper
            // than the same size through the pool. That difference came straight out
            // of the fee recipients. Charge Algebra's current dynamic fee so filling
            // from inventory is never the cheaper route.
            want = (want * (1_000_000 - uint256(_currentFee(pool)))) / 1_000_000;
            if (want == 0) {

                fromInv = 0;
            } else {
                // Budget is per BLOCK, not per call: a loop inside one transaction
                // used to drain the balance geometrically because inv was re-read
                // each time and the cap only ever applied to the current balance.
                uint256 already = locker.absorbedThisBlock(token);
                uint256 budget = ((inv + already) * MAX_FILL_BPS) / 10000;
                uint256 fillable = budget > already ? budget - already : 0;
                if (fillable > inv) fillable = inv;
                if (want <= fillable) {
                    fromInv = want;
                    useFuse = fuseIn;
                } else {
                    fromInv = fillable;
                    useFuse = (fuseIn * fillable) / want;
                }
                // A fill priced at zero would hand inventory over for nothing, so
                // skip the inventory leg entirely and let the buy go to the pool.
                if (useFuse == 0) fromInv = 0;
            }
            if (fromInv > 0) {
                weth.deposit{value: useFuse}();
                uint256 creatorCut = (useFuse * CREATOR_BPS) / 10000;
                uint256 foundationCut = (useFuse * FOUNDATION_BPS) / 10000;
                require(IERC20A(address(weth)).transfer(creator, creatorCut), "creator xfer");
                require(IERC20A(address(weth)).transfer(foundation, foundationCut), "foundation xfer");
                require(
                    IERC20A(address(weth)).transfer(platform, useFuse - creatorCut - foundationCut), "platform xfer"
                );
                locker.sellInventory(token, msg.sender, fromInv);
                emit InventoryAbsorbed(token, msg.sender, fromInv, useFuse);
            }
        }

        uint256 rest = fuseIn - useFuse;
        uint256 swapOut = 0;
        if (rest > 0) {
            swapOut = swapRouter.exactInputSingle{value: rest}(
                ISwapRouterA.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: token,
                    deployer: address(0),
                    recipient: msg.sender,
                    deadline: block.timestamp,
                    amountIn: rest,
                    amountOutMinimum: 0,
                    limitSqrtPrice: 0
                })
            );
        }
        out = fromInv + swapOut;
        require(out >= minOut, "slippage");

        uint256 n = launcher.tokenCount();
        if (n > 0) {
            address other = launcher.allTokens(cursor % n);
            cursor++;
            if (other != token) {
                try locker.flush(other) {} catch {}
            }
        }
    }

    function _spotAgreesWithTwap(address pool) internal view returns (bool) {
        (, int24 spotTick,,,,) = IAlgebraPool(pool).globalState();
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        address plug = IAlgebraPool(pool).plugin();
        // A call to a codeless address succeeds with empty returndata and the decode
        // then reverts in the SUCCESS path, where catch cannot see it. Check first so
        // a pool without a plugin skips the inventory fill instead of reverting the buy.
        if (plug.code.length == 0) return false;
        try IAlgebraPlugin(plug).getTimepoints(ago) returns (int56[] memory tc, uint88[] memory) {
            int24 avgTick = int24((tc[1] - tc[0]) / int56(int32(TWAP_WINDOW)));
            int24 dev = spotTick > avgTick ? spotTick - avgTick : avgTick - spotTick;
            return dev <= TWAP_MAX_TICK_DEV;
        } catch {
            return false;
        }
    }
}
