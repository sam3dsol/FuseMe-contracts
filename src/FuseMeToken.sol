// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract FuseMeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable maxWallet;

    address public immutable feeSource;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public capExempt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // Voltage v3 pool creation code hash. Pools are CREATE2-deployed by the pool
    // deployer (0xA5eceCa696C1BCeBF8c453AF7A2b87Fb0350c1f3), NOT the factory, so
    // _computePool takes the deployer address (verified against the live
    // WFUSE/USDC 0.3% pool 0x6D69564B170Ba600A11966978f8400f07D9D620d).
    bytes32 private constant POOL_INIT_HASH = 0x5e94a88ee743ee75a19e39ce7782cfe925a2f48dae686faabe5e621160dafaca;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _supply,
        uint16 _maxBps,
        address _launcher,
        address _poolDeployer,
        address _weth,
        uint24 _fee,
        address _npm,
        address _router,
        address _locker,
        address _creator
    ) {
        name = _name;
        symbol = _symbol;
        totalSupply = _supply;
        maxWallet = (_supply * _maxBps) / 10000;
        feeSource = _locker;
        balanceOf[_launcher] = _supply;
        emit Transfer(address(0), _launcher, _supply);

        capExempt[_launcher] = true;
        capExempt[_npm] = true;
        capExempt[_router] = true;
        capExempt[_locker] = true;
        capExempt[_creator] = true;
        capExempt[_computePool(_poolDeployer, address(this), _weth, _fee)] = true;
    }

    function _computePool(address deployer, address tokenA, address tokenB, uint24 fee)
        internal
        pure
        returns (address)
    {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encode(t0, t1, fee));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, POOL_INIT_HASH)))));
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "to zero");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }

        if (!capExempt[to] && from != feeSource) require(balanceOf[to] <= maxWallet, "max wallet");
        emit Transfer(from, to, amount);
    }
}
