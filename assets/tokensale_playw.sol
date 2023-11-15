// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IOraclePrice {
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
    function latestRound() external view returns (uint256);
    function getAnswer(uint256 roundId) external view returns (int256);
    function getTimestamp(uint256 roundId) external view returns (uint256);
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns ( uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferLock(address to, uint256 amount, uint256 lockedUp) external;
}


contract PlayWalletTokenSale is Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    IOraclePrice public constant oraclePriceContract = IOraclePrice(0xcD2A119bD1F7DF95d706DE6F2057fDD45A0503E2); //base goerli eth/usd
    IERC20 public constant playwContract = IERC20(0x103162f19B73B1b1668C1280026a828b1431ee45);
    address public constant walletAddress = address(0x01360A27FE780Bf13fc0633C4bBb07c4e393f150);

    event TokensSold(address indexed buyer, uint256 saleId, uint256 price, uint256 discount, uint256 receiveAmount, uint256 sendAmount, uint256 created, uint256[12] lockedUps);

    struct Sale {
        address buyer;
        uint256 price;
        uint256 discount;
        uint256 receiveAmount;
        uint256 sendAmount;
        uint256[12] lockedUps;
        uint256 created;
    }

    mapping (uint256 => Sale) private _sales;
    mapping (address => uint256[]) private _buyerSaleIds;

    uint256 public minBuyAmount = 1; //$1
    uint256 public discount1 = 10000; //$10000 - 5%
    uint256 public discount2 = 25000; //$25000 - 7.5%
    uint256 public discount3 = 50000; //$50000 - 10%
    uint256 public nextSaleId = 1;
    uint256 public lockedUp = 1730419200; //0;

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

    function sele(uint256 saleId) public view returns (Sale memory sale) {
        return _sales[saleId];
    }

    function buyerSaleIds(address buyer) public view returns (uint256[] memory ids) {
        return _buyerSaleIds[buyer];
    }

    function buy() public payable whenNotPaused returns (bool) {
        return _buy();
    }

    function _buy() private returns (bool) {
        require(msg.value > 0, "Value is invalid");

        uint256 value = msg.value;
        uint8 decimalsCrypto = oraclePriceContract.decimals();
        (,int256 priceCrypto,,,) = oraclePriceContract.latestRoundData();

        uint256 amountUsd = ((value * uint256(priceCrypto) * 100) / 10**decimalsCrypto);
        require(amountUsd >= minBuyAmount * 100 * 1e18, "Minimum purchase amount is less than the allowable");

        (uint price, uint discount) = calcTokenPrice(amountUsd / 100 / 1e18);
        uint amountTokens = (amountUsd / price) * 1000;
        require(amountTokens > 0, "Amount tokens is invalid");
        
        uint256[12] memory locks = [uint256(lockedUp), 
            lockedUp + 30 days, 
            lockedUp + (2 * 30 days), 
            lockedUp + (3 * 30 days), 
            lockedUp + (4 * 30 days),
            lockedUp + (5 * 30 days),
            lockedUp + (6 * 30 days),
            lockedUp + (7 * 30 days),
            lockedUp + (8 * 30 days),
            lockedUp + (9 * 30 days),
            lockedUp + (10 * 30 days),
            lockedUp + (11 * 30 days)];

        Sale memory sale = Sale(_msgSender(), price, discount, value, amountTokens, locks, block.timestamp);
        _sales[nextSaleId] = sale;
        _buyerSaleIds[_msgSender()].push(nextSaleId);

        payable(walletAddress).transfer(value);

        uint256 amountTokensPart = amountTokens / 12;
        for (uint8 i = 1; i <= 12; i++) {
            if (i == 12) {
                playwContract.transferLock(_msgSender(), amountTokens - (amountTokensPart * 11), locks[i - 1]);
            } else {
                playwContract.transferLock(_msgSender(), amountTokensPart, locks[i - 1]);
            }
        }
        
        emit TokensSold(_msgSender(), nextSaleId, sale.price, sale.discount, sale.receiveAmount, sale.sendAmount, sale.created, sale.lockedUps);
        nextSaleId++;
        return true;
    }

    function calcTokenPrice(uint amountUsd) public view returns (uint price, uint discount) {
         require(amountUsd > 0, "Value is invalid");

        if (amountUsd < discount1) {
            price = 30000;
            discount = 0;
        } else if (amountUsd < discount2) {
            price = 28500;
            discount = 50; //5%
        } else if (amountUsd < discount3) {
            price = 27750 ;
            discount = 75; //7.5%
        } else if (amountUsd >= discount3) {
            price = 27000 ;
            discount = 100; //10%
        } else {
            price = 30000;
            discount = 0;
        }
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

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function update(uint8 id, uint value) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (id == 1) {
            lockedUp = value;
        } else if (id == 2) {
            minBuyAmount = value;
        } else if (id == 3) {
            discount1 = value;
        }  else if (id == 4) {
            discount2 = value;
        } else if (id == 5) {
            discount3 = value;
        } 
    }
}