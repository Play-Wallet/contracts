// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface INFTMINTABLE {
    function mintToken(address to, uint8 rarity) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferLock(address to, uint256 amount, uint256 lockedUp) external;
}

contract PlayWalletNFTTokenSale is Pausable, AccessControl{
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    INFTMINTABLE public constant playwNftContract = INFTMINTABLE(0x045d679A92c7e8941D92559430Dc61847dBF07d7);
    address public constant walletAddress = address(0x01360A27FE780Bf13fc0633C4bBb07c4e393f150);

    enum Rarity { None, Common, Uncommon, Rare, Legendary }

    event NftSold(address indexed wallet, uint256 amount, Rarity rarity, uint256 created);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    fallback() external payable {
        buy();
    }
    
    receive() external payable {
        buy();
    }

    function buy() public payable whenNotPaused {
        _buy();
    }

    function _buy() private {
        Rarity rarity = Rarity.None;
        if (msg.value == 6 * 1e16)
        {
            rarity = Rarity.Common;
        } else if (msg.value == 1e17)
        {
            rarity = Rarity.Uncommon;
        } else if (msg.value == 2 * 1e17)
        {
            rarity = Rarity.Rare;
        } else if (msg.value == 6 * 1e17)
        {
            rarity = Rarity.Legendary;
        } else {
            revert("Value is invalid");
        }

        playwNftContract.mintToken(msg.sender, uint8(rarity));
        emit NftSold(msg.sender, msg.value, rarity, block.timestamp);

        payable(walletAddress).transfer(msg.value);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function withdraw(address token, uint value) public onlyRole(DEFAULT_ADMIN_ROLE) {
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
                IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
            } else {
                IERC20(token).transfer(owner, value);
            }
        }
    }
}