// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IWETH9, ISwapRouter} from "./interfaces/Uniswap.sol";
import {FuseMeLauncher} from "./FuseMeLauncher.sol";
import {FuseMeLocker} from "./FuseMeLocker.sol";

interface IV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);
}

contract FuseMeRouter {
    FuseMeLauncher public immutable launcher;
    FuseMeLocker public immutable locker;
    IWETH9 public immutable weth;
    ISwapRouter public immutable swapRouter;
    uint24 public immutable poolFee;
    address public immutable foundation;
    address public immutable platform;

    uint16 public constant CREATOR_BPS = 5000;
    uint16 public constant FOUNDATION_BPS = 3000;

    uint32 public constant TWAP_WINDOW = 120;
    int24 public constant TWAP_MAX_TICK_DEV = 300;

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
        launcher = FuseMeLauncher(_launcher);
        locker = FuseMeLocker(_locker);
        weth = IWETH9(_weth);
        swapRouter = ISwapRouter(_swapRouter);
        poolFee = _poolFee;
        foundation = FuseMeLocker(_locker).foundation();
        platform = FuseMeLocker(_locker).platform();
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
        uint256 inv = IERC20(token).balanceOf(address(locker));
        if (inv > 0 && _spotAgreesWithTwap(pool)) {
            (uint160 sqrtP,,,,,,) = IV3Pool(pool).slot0();

            uint256 want = token < address(weth)
                ? (((fuseIn << 96) / sqrtP) << 96) / sqrtP
                : ((fuseIn * sqrtP) >> 96) * sqrtP >> 96;
            if (want == 0) {

                fromInv = 0;
            } else if (want <= inv) {
                fromInv = want;
                useFuse = fuseIn;
            } else {
                fromInv = inv;
                useFuse = (fuseIn * inv) / want;
            }
            if (fromInv > 0) {
                weth.deposit{value: useFuse}();
                uint256 creatorCut = (useFuse * CREATOR_BPS) / 10000;
                uint256 foundationCut = (useFuse * FOUNDATION_BPS) / 10000;
                require(IERC20(address(weth)).transfer(creator, creatorCut), "creator xfer");
                require(IERC20(address(weth)).transfer(foundation, foundationCut), "foundation xfer");
                require(
                    IERC20(address(weth)).transfer(platform, useFuse - creatorCut - foundationCut), "platform xfer"
                );
                locker.sellInventory(token, msg.sender, fromInv);
                emit InventoryAbsorbed(token, msg.sender, fromInv, useFuse);
            }
        }

        uint256 rest = fuseIn - useFuse;
        uint256 swapOut = 0;
        if (rest > 0) {
            swapOut = swapRouter.exactInputSingle{value: rest}(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: token,
                    fee: poolFee,
                    recipient: msg.sender,
                    deadline: block.timestamp,
                    amountIn: rest,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
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
        (, int24 spotTick,,,,,) = IV3Pool(pool).slot0();
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        try IV3Pool(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            int24 avgTick = int24((tc[1] - tc[0]) / int56(int32(TWAP_WINDOW)));
            int24 dev = spotTick > avgTick ? spotTick - avgTick : avgTick - spotTick;
            return dev <= TWAP_MAX_TICK_DEV;
        } catch {
            return false;
        }
    }
}
