// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";

interface IERC20MINTABLE {
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PlayWalletNFT is Initializable, ERC721Upgradeable, ERC721EnumerableUpgradeable, PausableUpgradeable, AccessControlUpgradeable, ERC721BurnableUpgradeable, EIP712Upgradeable, ERC721VotesUpgradeable, UUPSUpgradeable {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BLOCKER_ROLE = keccak256("BLOCKER_ROLE");
    bytes32 public constant LOCKER_ROLE = keccak256("LOCKER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant MAX_TOTAL_SUPPLY = 10000; // 10000 PLAYWNFT
    CountersUpgradeable.Counter private _tokenIdCounter;

    event AccountBlocked(address indexed account);
    event AccountUnblocked(address indexed account);
    event BlacklistActiveChanged(bool activate);
    event Donate(address indexed sender, uint256 value);
    event NftMinted(address indexed owner, uint256 indexed tokenId, Rarity rarity);
    event NftBurned(address indexed owner, uint256 indexed tokenId, Rarity rarity, uint256 reward);
    event Locked(uint256 tokenId);
    event Locked(uint256 tokenId, uint256 lockTime);
    event Unlocked(uint256 tokenId);
    event LocksActiveChanged(bool activate);

    enum Rarity { None, Common, Uncommon, Rare, Legendary }

    mapping (address => bool) private _blacklist;
    mapping (uint256 => Rarity) private _rarities;
    mapping (Rarity => uint256) private _raritiesCount;
    mapping (uint256 => uint256) private _locks;

    bool public blacklistActive;
    bool public locksActive;

    address public PlayWalletToken = address(0x103162f19B73B1b1668C1280026a828b1431ee45);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {
        __ERC721_init("PlayWallet NFT", "PLAYWNFT");
        __ERC721Enumerable_init();
        __Pausable_init();
        __AccessControl_init();
        __ERC721Burnable_init();
        __EIP712_init("PlayWallet NFT", "1");
        __ERC721Votes_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(BLOCKER_ROLE, msg.sender);
        _grantRole(LOCKER_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _tokenIdCounter.increment();

        blacklistActive = true;
        locksActive = true;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://dev-api.playw.io/v1/nft/";
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mintToken(address to, Rarity rarity) public onlyRole(MINTER_ROLE) {
        if (blacklistActive) {
            require(!_blacklist[to], "To address banned");
        }
        require(MAX_TOTAL_SUPPLY > _tokenIdCounter.current(), "Nft is over");
        if (rarity == Rarity.Common) {
            require(_raritiesCount[rarity] < 4000, "Rarity Common is over");
        } else if (rarity == Rarity.Uncommon) {
            require(_raritiesCount[rarity] < 3000, "Rarity Uncommon is over");
        } else if (rarity == Rarity.Rare) {
            require(_raritiesCount[rarity] < 2000, "Rarity Rare is over");
        } else if (rarity == Rarity.Legendary) {
            require(_raritiesCount[rarity] < 1000, "Rarity Legendary is over");
        } else {
            revert("Rarity is not valid");
        }

        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        _safeMint(to, tokenId);
        _rarities[tokenId] = rarity;
        _raritiesCount[rarity]++;
        emit NftMinted(to, tokenId, rarity);
    }

    function burnToken(uint256 tokenId, uint256 reward) public onlyRole(BURNER_ROLE) {
        address owner = _ownerOf(tokenId);
        Rarity rarity = _rarities[tokenId];
        _burn(tokenId);
        _raritiesCount[rarity]--;
        delete _rarities[tokenId];

        if (reward > 0)
        {
            if (IERC20MINTABLE(PlayWalletToken).balanceOf(address(this)) >= reward) {
                IERC20MINTABLE(PlayWalletToken).transfer(owner, reward);
            } else {
                IERC20MINTABLE(PlayWalletToken).mint(owner, reward);
            }
        }

        emit NftBurned(owner, tokenId, rarity, reward);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        whenNotPaused
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        if (blacklistActive) {
            require(!_blacklist[from], "From address banned");
            require(!_blacklist[to], "To address banned");
        }
        if (locksActive) {
            require(_locks[tokenId] <= block.timestamp, "Token locked");
        }

        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    function _afterTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize)
        internal
        override(ERC721Upgradeable, ERC721VotesUpgradeable)
    {
        super._afterTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function locks(uint256 tokenId) public view returns (uint256) {
        return _locks[tokenId];
    }

    function tokenLock(uint256 tokenId, uint256 lockTime) public onlyRole(LOCKER_ROLE) {
        _locks[tokenId] = lockTime;

        emit Locked(tokenId);
        emit Locked(tokenId, lockTime);
    }

    function tokenUnlock(uint256 tokenId) public onlyRole(LOCKER_ROLE) {
        delete _locks[tokenId];

        emit Unlocked(tokenId);
    }

    function locksActivate(bool activate) public onlyRole(DEFAULT_ADMIN_ROLE) returns (bool) {
        locksActive = activate;
        emit LocksActiveChanged(activate);
        return true;
    }

    function tokenRarity(uint256 tokenId) public view returns (Rarity) {
        return _rarities[tokenId];
    }

    function raritiesCount(Rarity rarity) public view returns (uint256) {
        return _raritiesCount[rarity];
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

    function updateTokenAddress(address token) public onlyRole(ADMIN_ROLE) {
        PlayWalletToken = token;
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
                IERC20MINTABLE(token).transfer(owner, IERC20MINTABLE(token).balanceOf(address(this)));
            } else {
                IERC20MINTABLE(token).transfer(owner, value);
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
