// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IReceiver {
    function receiveTokens(address wallet, uint256 amount, address token, bytes memory data) external returns (bool success);
}

contract PlayWalletToken is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant LOCKER_ROLE = keccak256("LOCKER_ROLE");
    bytes32 public constant BLOCKER_ROLE = keccak256("BLOCKER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant MAX_TOTAL_SUPPLY = 100000000 * 10 ** 18; // 100,000,000 PLAYW

    event AccountBlocked(address indexed account);
    event AccountUnblocked(address indexed account);
    event LocksActiveChanged(bool activate);
    event BlacklistActiveChanged(bool activate);
    event LockSignal(address indexed account, bool indexed created, uint256 index, bool enabled, uint256 lockedAmount, uint256 unlockedAmount, uint256 lockedUp);
    event Donate(address indexed sender, uint256 value);
    event RecipientUpdated(address indexed recipient, bool allowed);
    event TokenSent(address indexed sender, address indexed recipient, uint256 amount, bytes data);

    struct LockEntity {
        bool enabled;
        uint256 lockedAmount;
        uint256 unlockedAmount;
        uint256 lockedUp; //unixtime unlock
    }

    mapping (address => LockEntity[]) private _locks;
    mapping (address => bool) private _blacklist;
    mapping (address => bool) private _recipients;

    bool public blacklistActive;
    bool public locksActive;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {
        __ERC20_init("PlayWallet Token", "PLAYW");
        __ERC20Burnable_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(LOCKER_ROLE, msg.sender);
        _grantRole(BLOCKER_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        blacklistActive = true;
        locksActive = true;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint256 amount) public whenNotPaused onlyRole(MINTER_ROLE) {
        require(MAX_TOTAL_SUPPLY >= totalSupply() + amount, "Amount is not valid");
        if (blacklistActive) {
            require(!_blacklist[to], "To address banned");
        }

        _mint(to, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        whenNotPaused
        override
    {
        require(amount > 0, "Amount is not valid");

        if (blacklistActive) {
            require(!_blacklist[from], "From address banned");
            require(!_blacklist[to], "To address banned");
        }
        
        if (locksActive) {
            uint256 lockedAmount = locksAmount(from);
            if (lockedAmount > 0) {
                require(balanceOf(from) - lockedAmount >= amount, "Transfer amount locked");
            }
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    function recipientUpdate(address recipient, bool allowed) public onlyRole(BLOCKER_ROLE) returns (bool) {
        _recipients[recipient] = allowed;
        emit RecipientUpdated(recipient, allowed);
        return true;
    }

    function blacklist(address account) public view returns (bool) {
        return _blacklist[account];
    }

    function blacklistActivate(bool activate) public onlyRole(DEFAULT_ADMIN_ROLE) returns (bool) {
        blacklistActive = activate;
        emit BlacklistActiveChanged(activate);
        return true;
    }

    function accountBlock(address account) public onlyRole(BLOCKER_ROLE) returns (bool) {
        _blacklist[account] = true;
        emit AccountBlocked(account);
        return true;
    }

    function accountUnblock(address account) public onlyRole(BLOCKER_ROLE) returns (bool) {
        _blacklist[account] = false;
        emit AccountUnblocked(account);
        return true;
    }

    function locksActivate(bool activate) public onlyRole(DEFAULT_ADMIN_ROLE) returns (bool) {
        locksActive = activate;
        emit LocksActiveChanged(activate);
        return true;
    }

    function tokensLock(address account, uint256 amount, uint256 lockedUp) public onlyRole(LOCKER_ROLE) returns (bool) {
        return _tokensLock(account, LockEntity(true, amount, 0, lockedUp));
    }

    function tokensLockEntity(address account, LockEntity memory lock) public onlyRole(LOCKER_ROLE) returns (bool) {
        return _tokensLock(account, lock);
    }

    function _tokensLock(address account, LockEntity memory lock) private returns (bool) {
        require(lock.enabled, "LockEntity is not valid");
        require(lock.lockedAmount > 0, "LockedAmount is not valid");
        require(lock.lockedUp > 0, "LockedUp is not valaid");
        
        _locks[account].push(lock);
        uint256 index = _locks[account].length;
        if (index > 0) {
            index--;
        }
        emit LockSignal(account, true, index, _locks[account][index].enabled, _locks[account][index].lockedAmount, _locks[account][index].unlockedAmount, _locks[account][index].lockedUp);
        return true;
    }

    function tokensUnlock(address account, uint256 amount) public onlyRole(LOCKER_ROLE) returns (uint256) {
        return _tokensUnlock(account, amount);
    }

    function _tokensUnlock(address account, uint256 amount) private returns (uint256) {
        uint256 unlockedAmount = 0;
        if (_locks[account].length > 0) {
            for (uint256 i = 0; i < _locks[account].length; i++) {
                if (_locks[account][i].enabled && _locks[account][i].lockedUp > block.timestamp && _locks[account][i].lockedAmount - _locks[account][i].unlockedAmount > 0) {
                    uint offsetAmount = _locks[account][i].lockedAmount - _locks[account][i].unlockedAmount;
                    if (amount == 0) {
                        unlockedAmount += offsetAmount;
                        _locks[account][i].enabled = false;
                        _locks[account][i].unlockedAmount = _locks[account][i].lockedAmount;
                    } else {
                        if (offsetAmount <= amount - unlockedAmount) {
                            unlockedAmount += offsetAmount;
                            _locks[account][i].enabled = false;
                            _locks[account][i].unlockedAmount = _locks[account][i].lockedAmount;
                        } else {
                            _locks[account][i].unlockedAmount += amount - unlockedAmount;
                            uint256 unlockAmount = amount - unlockedAmount;
                            unlockedAmount += unlockAmount;
                        }
                    }
                    emit LockSignal(account, false, i, _locks[account][i].enabled, _locks[account][i].lockedAmount, _locks[account][i].unlockedAmount, _locks[account][i].lockedUp);
                }
            }
        }
        return unlockedAmount;
    }

    function locksAmount(address account) public view returns (uint256) {
        uint256 amount = 0;
        if (account == address(0)) {
            return amount;
        } else {
            if (locksActive) {
                if (_locks[account].length > 0) {
                    for (uint256 i = 0; i < _locks[account].length; i++) {
                        if (_locks[account][i].enabled && _locks[account][i].lockedUp > block.timestamp) {
                            amount += (_locks[account][i].lockedAmount - _locks[account][i].unlockedAmount > 0) ?  _locks[account][i].lockedAmount - _locks[account][i].unlockedAmount : 0;
                        }
                    }
                }
            }

        return amount;
        }
    }

    function availableAmount(address account) public view returns (uint256) {
        uint256 amount = balanceOf(account);
        if (locksActive) {
            uint256 lockedAmount = locksAmount(account);
            if (amount >= lockedAmount) {
                amount -= lockedAmount;
            } else {
                amount = 0;
            }
        } 
        return amount;
    }

    function locksCount(address account) public view returns (uint256) {
        return _locks[account].length;
    }

    function lockByIndex(address account, uint256 index) public view returns (bool enabled, uint256 lockedAmount, uint256 unlockedAmount, uint256 lockedUp) {
        require(index < _locks[account].length, "Index is not valid");
        return (_locks[account][index].enabled, _locks[account][index].lockedAmount, _locks[account][index].unlockedAmount, _locks[account][index].lockedUp);
    }

    function lockEntityByIndex(address account, uint256 index) public view returns (LockEntity memory lock) {
        require(index < _locks[account].length, "Index is not valid");
        return _locks[account][index];
    }

    function lockUpdate(address account, uint256 index, bool enabled, uint256 unlockedAmount, uint256 lockedUp) public onlyRole(LOCKER_ROLE) returns (bool) {
        return _lockUpdate(account, index, enabled, unlockedAmount, lockedUp);
    }

    function _lockUpdate(address account, uint256 index, bool enabled, uint256 unlockedAmount, uint256 lockedUp) private returns (bool) {
        require(index < _locks[account].length, "Index is not valid");

        if (_locks[account][index].lockedAmount >= unlockedAmount) {
            _locks[account][index].enabled = enabled;
            _locks[account][index].unlockedAmount = unlockedAmount;
            _locks[account][index].lockedUp = lockedUp;
            emit LockSignal(account, false, index, _locks[account][index].enabled, _locks[account][index].lockedAmount, _locks[account][index].unlockedAmount, _locks[account][index].lockedUp);

            return true;
        } else {
            return false;
        }
    }

    function transferLock(address to, uint256 amount, uint256 lockedUp) 
        public 
        whenNotPaused
        onlyRole(LOCKER_ROLE) {
        _transferLock(to, amount, lockedUp);
    }

    function _transferLock(address to, uint256 amount, uint256 lockedUp) 
        private  {
        address sender = _msgSender();
        require(to != address(0), "To address is not valid");
        require(lockedUp > 0, "LockedUp is not valid");
        require(balanceOf(sender) >= amount, "Amount is not valid");

        LockEntity memory lock = LockEntity(true, amount, 0, lockedUp);
        _locks[to].push(lock);

        _transfer(sender, to, amount);

        uint256 index = _locks[to].length;
        if (index > 0) {
            index--;
        }
        emit LockSignal(to, true, index, _locks[to][index].enabled, _locks[to][index].lockedAmount, _locks[to][index].unlockedAmount, _locks[to][index].lockedUp);
    }

    function sendTokens(address recipient, uint256 amount, bytes memory data)
    public  
    whenNotPaused
    returns (bool) 
    {
        return _sendTokens(recipient, amount, data);
    }

    function _sendTokens(address recipient, uint256 amount, bytes memory data)
    private 
    returns (bool) 
    {
        require(_recipients[recipient], "Recipient unknown");

        if (approve(recipient, amount)) {
            require(IReceiver(recipient).receiveTokens(_msgSender(), amount, address(this), data), "Failed to send tokens");
            emit TokenSent(_msgSender(), recipient, amount, data);
            return true;
        } else {
            return false;
        }
    }

    function approve(address spender, uint256 amount) public whenNotPaused override returns (bool) {
        require(amount > 0, "Amount is not valid");

        if (locksActive) {
            uint256 lockedAmount = locksAmount(_msgSender());
            if (lockedAmount > 0) {
                require(balanceOf(_msgSender()) - lockedAmount >= amount, "Approve amount locked");
            }
        }

        if (blacklistActive) {
            require(!_blacklist[_msgSender()], "Sender address banned");
            require(!_blacklist[spender], "Spender address banned");
        }

        return super.approve(spender, amount);
    }

    function increaseAllowance(address spender, uint256 addedValue) public whenNotPaused override returns (bool) {
        require(addedValue > 0, "AddedValue is not valid");

        if (locksActive) {
            uint256 lockedAmount = locksAmount(_msgSender());
            if (lockedAmount > 0) {
                require(balanceOf(_msgSender()) - lockedAmount >= allowance(_msgSender(), spender) + addedValue, "Approve amount locked");
            }
        }

        if (blacklistActive) {
            require(!_blacklist[_msgSender()], "Sender address banned");
            require(!_blacklist[spender], "Spender address banned");
        }

        return super.increaseAllowance(spender, addedValue);
    }

    function withdraw(address token, uint value) public onlyRole(ADMIN_ROLE) {
        _withdraw(token, value);
    }

    function _withdraw(address token, uint value) private {
        address owner = _msgSender();
        if (token == address(0)) {
            if (value == 0) {
                payable(owner).transfer(address(this).balance);
            } else {
                payable(owner).transfer(value);
            }
        } else {
            if (value == 0) {
                IERC20Upgradeable(token).transfer(owner, IERC20Upgradeable(token).balanceOf(address(this)));
            } else {
                IERC20Upgradeable(token).transfer(owner, value);
            }
        }
    }

    fallback() external payable whenNotPaused () {
        emit Donate(_msgSender(), msg.value);
    }
    
    receive() external payable whenNotPaused () {
        emit Donate(_msgSender(), msg.value);
    }

    uint256[45] private __gap;
}