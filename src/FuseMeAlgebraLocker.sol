// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INonfungiblePositionManagerA, IERC20A, IERC721ReceiverA, ISwapRouterA, IAlgebraPool, IAlgebraPlugin} from "./interfaces/Algebra.sol";

interface IFunLauncherLite {
    function poolOf(address token) external view returns (address);
    function creatorOf(address token) external view returns (address);
    function positionOf(address token) external view returns (uint256);
    function moonPositionOf(address token) external view returns (uint256);
}



contract FuseMeAlgebraLocker is IERC721ReceiverA {
    INonfungiblePositionManagerA public immutable npm;
    address public immutable platform;
    address public immutable foundation;
    address public immutable weth;
    address public immutable swapRouter;
    uint24 public immutable poolFee;
    address public immutable deployer;
    address public launcher;
    address public router;

    uint64 public constant NEVER = type(uint64).max;
    bool public constant PERMANENT_LOCK = true;
    uint16 public constant CREATOR_BPS = 5000;
    uint16 public constant FOUNDATION_BPS = 3000;

    mapping(uint256 => address) public creatorOf;
    mapping(uint256 => uint64) public unlockAt;
    mapping(uint256 => address) public tokenOf;

    mapping(address => uint32) public lastAbsorbAt;

    event LauncherSet(address indexed launcher);
    event Locked(uint256 indexed tokenId, address indexed creator, uint64 unlockAt);
    event FeesCollected(uint256 indexed tokenId, address indexed creator, uint256 amount0, uint256 amount1);

    constructor(
        address _npm,
        address _platform,
        address _foundation,
        address _weth,
        address _swapRouter,
        uint24 _poolFee
    ) {
        require(
            _npm != address(0) && _platform != address(0) && _foundation != address(0)
                && _weth != address(0) && _swapRouter != address(0),
            "zero"
        );
        npm = INonfungiblePositionManagerA(_npm);
        platform = _platform;
        foundation = _foundation;
        weth = _weth;
        swapRouter = _swapRouter;
        poolFee = _poolFee;
        deployer = msg.sender;
    }

    function setLauncher(address _launcher) external {
        require(msg.sender == deployer && launcher == address(0) && _launcher != address(0), "set");
        launcher = _launcher;
        emit LauncherSet(_launcher);
    }

    function setRouter(address _router) external {
        require(msg.sender == deployer && router == address(0) && _router != address(0), "set");
        router = _router;
    }

    function lock(uint256 tokenId, uint256 moonTokenId, address creator) external returns (uint64 u) {
        require(msg.sender == launcher, "only launcher");
        require(creator != address(0), "creator zero");
        require(tokenId != moonTokenId, "same id");
        require(creatorOf[tokenId] == address(0) && creatorOf[moonTokenId] == address(0), "locked");
        require(npm.ownerOf(tokenId) == address(this) && npm.ownerOf(moonTokenId) == address(this), "not owned");
        creatorOf[tokenId] = creator;
        creatorOf[moonTokenId] = creator;
        u = NEVER;
        unlockAt[tokenId] = u;
        unlockAt[moonTokenId] = u;

        (,, address t0, address t1,,,,,,,,) = npm.positions(tokenId);
        address token = t0 == weth ? t1 : t0;
        tokenOf[tokenId] = token;
        tokenOf[moonTokenId] = token;

        lastAbsorbAt[token] = uint32(block.timestamp);

        emit Locked(tokenId, creator, u);
        emit Locked(moonTokenId, creator, u);
    }

    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        address creator = creatorOf[tokenId];
        require(creator != address(0), "unknown");
        (,, address t0,,,,,,,,,) = npm.positions(tokenId);
        bool wethIsToken0 = t0 == weth;
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManagerA.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        _split(weth, wethIsToken0 ? amount0 : amount1, creator);
        emit FeesCollected(tokenId, creator, amount0, amount1);
    }

    function sellInventory(address token, address to, uint256 amount) external {
        require(msg.sender == router, "only router");
        uint256 inv = IERC20A(token).balanceOf(address(this));

        if (amount * 100 >= inv) lastAbsorbAt[token] = uint32(block.timestamp);
        require(IERC20A(token).transfer(to, amount), "inv xfer");
    }

    uint32 public constant STALE = 24 hours;
    uint32 public constant HARD_STALE = 30 days;

    function flush(address token) external {
        address creator = IFunLauncherLite(launcher).creatorOf(token);
        require(creator != address(0), "not fuseme");
        address pool = IFunLauncherLite(launcher).poolOf(token);

        // Dead only when BOTH clocks are quiet: no absorb through our router, and
        // no trade on the pool itself. Our clock alone declared live tokens dead
        // (most volume arrives straight on Voltage) and sold their inventory into
        // their own market; the pool alone let dust trades block payouts forever.
        // HARD_STALE means a griefer can delay a payout, never prevent it.
        bool ourClockQuiet = block.timestamp > uint256(lastAbsorbAt[token]) + STALE;
        bool poolQuiet = true;
        address plug = IAlgebraPool(pool).plugin();
        if (plug.code.length > 0) {
            uint32[] memory ago = new uint32[](1);
            ago[0] = STALE;
            try IAlgebraPlugin(plug).getTimepoints(ago) returns (int56[] memory, uint88[] memory) {
                poolQuiet = false; // the oracle still reaches back that far: it has traded
            } catch {
                poolQuiet = true; // no history that old
            }
        }
        bool backstop = block.timestamp > uint256(lastAbsorbAt[token]) + HARD_STALE;
        require((ourClockQuiet && poolQuiet) || backstop, "market alive");

        this.collect(IFunLauncherLite(launcher).positionOf(token));
        this.collect(IFunLauncherLite(launcher).moonPositionOf(token));
        uint256 inv = IERC20A(token).balanceOf(address(this));
        require(inv > 0, "no inventory");
        require(IERC20A(token).approve(swapRouter, inv), "approve");

        (uint160 sqrtP,,,,,) = IAlgebraPool(pool).globalState();
        bool zeroForOne = token < weth;
        uint160 limit = zeroForOne
            ? uint160((uint256(sqrtP) * 8944) / 10000)
            : uint160((uint256(sqrtP) * 10954) / 10000);

        uint256 out = ISwapRouterA(swapRouter).exactInputSingle(
            ISwapRouterA.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                deployer: address(0),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: inv,
                amountOutMinimum: 0,
                limitSqrtPrice: limit
            })
        );
        _split(weth, out, creator);
    }

    function _split(address token, uint256 amount, address creator) internal {
        if (amount == 0) return;
        uint256 creatorCut = (amount * CREATOR_BPS) / 10000;
        uint256 foundationCut = (amount * FOUNDATION_BPS) / 10000;
        uint256 platformCut = amount - creatorCut - foundationCut;
        if (creatorCut > 0) require(IERC20A(token).transfer(creator, creatorCut), "creator xfer");
        if (foundationCut > 0) require(IERC20A(token).transfer(foundation, foundationCut), "foundation xfer");
        if (platformCut > 0) require(IERC20A(token).transfer(platform, platformCut), "platform xfer");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
