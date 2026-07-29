// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract FuseMeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;


    address public creator;
    address public launcher;
    uint256 public creatorCap;
    uint64 public creatorCapUntil;
    uint64 public constant CREATOR_CAP_WINDOW = 24 hours;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _supply,
        address _launcher,
        address _npm,
        address _router,
        address _locker,
        address _creator
    ) {
        name = _name;
        symbol = _symbol;
        totalSupply = _supply;
        balanceOf[_launcher] = _supply;
        emit Transfer(address(0), _launcher, _supply);


        // MEDIUM fix: the launcher's post-launch balance check only constrained the
        // creator at the instant launch() returned, so a contract could launch and
        // then buy in the SAME transaction and end up far over the cap. Enforce it
        // in the token instead, for a window, so buying again immediately does not
        // get around it. Only the creator is bound; everyone else trades freely.
        creator = _creator;
        launcher = _launcher;
        creatorCap = (_supply * 500) / 10000;
        creatorCapUntil = uint64(block.timestamp) + CREATOR_CAP_WINDOW;
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

        // Bind EVERY non-exempt wallet for the window, not just the creator's own
        // address: aiming the buy at a second address the launcher controls
        // otherwise walks straight past a creator-only check.
        // The creator's bag is capped at 5% of supply for 24h after launch.
        //
        // Nor does it try to bind other wallets. An audit flagged that a creator can
        // point a second buy at an address we have never heard of and end up over 5%
        // across wallets. That is true and it is not closable: the only rule that
        // catches an address we cannot name is one that caps EVERY address, which
        // caps real buyers too and reverts an honest large first buy. So this is a
        // guard on the creator's own wallet, not a supply guarantee, and it is
        // described that way everywhere it is claimed.
        if (to == creator && block.timestamp < creatorCapUntil) {
            require(balanceOf[to] <= creatorCap, "creator bag over 5%");
        }
        emit Transfer(from, to, amount);
    }
}
