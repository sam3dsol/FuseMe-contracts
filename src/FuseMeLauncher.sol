// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INonfungiblePositionManager, IWETH9, ISwapRouter, IUniswapV3Factory} from "./interfaces/Uniswap.sol";
import {FuseMeToken} from "./FuseMeToken.sol";
import {FuseMeLocker} from "./FuseMeLocker.sol";

interface IV3PoolInit {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

contract FuseMeLauncher {
    INonfungiblePositionManager public immutable npm;
    address public immutable poolDeployer;
    address public immutable weth;
    address public immutable router;
    FuseMeLocker public immutable locker;

    uint24 public constant FEE = 10000;
    uint256 public constant SUPPLY = 1_000_000_000e18;

    uint16 public constant MAX_WALLET_BPS = 10000;

    uint16 public constant DEV_MAX_BPS = 500;

    uint256 public constant CURVE_SUPPLY = 115_000_000e18;
    int24 public constant TICK_START = -59800;
    int24 public constant TICK_CURVE_END = -24800;
    int24 public constant TICK_MOON_END = 11600;
    uint160 public constant SQRT_INIT_TOKEN0 = 3984776849067268810482680323;
    uint160 public constant SQRT_INIT_TOKEN1 = 1575270579293790257055956259651;

    address[] public allTokens;
    mapping(address => address) public poolOf;
    mapping(address => address) public creatorOf;
    mapping(address => uint256) public positionOf;
    mapping(address => uint256) public moonPositionOf;

    bool private _locked;

    event Launched(
        address indexed token,
        address indexed creator,
        address pool,
        uint256 tokenId,
        uint256 moonTokenId,
        uint64 unlockAt,
        uint256 firstBuyIn,
        string name,
        string symbol
    );

    modifier nonReentrant() {
        require(!_locked, "reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _npm, address _poolDeployer, address _weth, address _router, address _locker) {
        require(
            _npm != address(0) && _poolDeployer != address(0) && _weth != address(0) && _router != address(0)
                && _locker != address(0),
            "zero"
        );
        npm = INonfungiblePositionManager(_npm);
        poolDeployer = _poolDeployer;
        weth = _weth;
        router = _router;
        locker = FuseMeLocker(_locker);
    }

    address public constant FACTORY = 0xaD079548b3501C5F218c638A02aB18187F62b207;
    uint256 public constant MAX_SALT_TRIES = 8;

    function launch(string calldata name, string calldata symbol)
        external
        payable
        nonReentrant
        returns (address token)
    {
        // CREATE2, not CREATE. With plain CREATE the token address is a pure
        // function of this contract's nonce, and a nonce only advances on a
        // SUCCESSFUL create: one reverted launch leaves the next attempt aimed at
        // the very same address, so anyone could pre-create a pool there at a
        // hostile price and revert every launch forever.
        //
        // The salt is still public, so a front-runner can poison the one address a
        // launch aims at. Reverting on that was the wrong answer: probe the address
        // and step to the next salt if a pool already sits there. The griefer then
        // has to fund a pool per attempt and still cannot stop the launch.
        bytes memory args = abi.encode(
            name, symbol, SUPPLY, MAX_WALLET_BPS, address(this), address(npm), router, address(locker), msg.sender
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(FuseMeToken).creationCode, args));
        bytes32 salt;
        for (uint256 i = 0; i < MAX_SALT_TRIES; i++) {
            salt = keccak256(abi.encodePacked(msg.sender, name, symbol, block.number, allTokens.length, i));
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
            if (IUniswapV3Factory(FACTORY).getPool(predicted, weth, FEE) == address(0)) break;
        }
        FuseMeToken t = new FuseMeToken{salt: salt}(
            name, symbol, SUPPLY, MAX_WALLET_BPS, address(this), address(npm), router, address(locker), msg.sender
        );
        token = address(t);

        bool tokenIsToken0 = token < weth;
        uint160 wantSqrt = tokenIsToken0 ? SQRT_INIT_TOKEN0 : SQRT_INIT_TOKEN1;
        address pool = npm.createAndInitializePoolIfNecessary(
            tokenIsToken0 ? token : weth, tokenIsToken0 ? weth : token, FEE, wantSqrt
        );

        (uint160 gotSqrt,,,,,,) = IV3PoolInit(pool).slot0();
        require(gotSqrt == wantSqrt, "pool pre-initialised");

        IV3PoolInit(pool).increaseObservationCardinalityNext(60);
        t.approve(address(npm), SUPPLY);
        uint256 tokenId =
            _mint(token, tokenIsToken0, TICK_START, TICK_CURVE_END, CURVE_SUPPLY);
        uint256 moonTokenId =
            _mint(token, tokenIsToken0, TICK_CURVE_END, TICK_MOON_END, SUPPLY - CURVE_SUPPLY);

        uint64 unlockAt = locker.lock(tokenId, moonTokenId, msg.sender);

        uint256 firstBuyIn = msg.value;
        if (firstBuyIn > 0) {

            IWETH9(weth).deposit{value: firstBuyIn}();
            IWETH9(weth).approve(router, firstBuyIn);
            ISwapRouter(router).exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: weth,
                    tokenOut: token,
                    fee: FEE,
                    recipient: msg.sender,
                    deadline: block.timestamp,
                    amountIn: firstBuyIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        require(t.balanceOf(msg.sender) <= (SUPPLY * DEV_MAX_BPS) / 10000, "dev bag over 5%");

        allTokens.push(token);
        poolOf[token] = pool;
        creatorOf[token] = msg.sender;
        positionOf[token] = tokenId;
        moonPositionOf[token] = moonTokenId;
        emit Launched(token, msg.sender, pool, tokenId, moonTokenId, unlockAt, firstBuyIn, name, symbol);
    }

    function _mint(address token, bool tokenIsToken0, int24 lower, int24 upper, uint256 amount)
        internal
        returns (uint256 tokenId)
    {
        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIsToken0 ? token : weth,
                token1: tokenIsToken0 ? weth : token,
                fee: FEE,
                tickLower: tokenIsToken0 ? lower : -upper,
                tickUpper: tokenIsToken0 ? upper : -lower,
                amount0Desired: tokenIsToken0 ? amount : 0,
                amount1Desired: tokenIsToken0 ? 0 : amount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(locker),
                deadline: block.timestamp
            })
        );
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }
}
