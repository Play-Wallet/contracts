// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}


contract PlayWalletTokenStake is Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    IERC20 public constant playwContract = IERC20(0x103162f19B73B1b1668C1280026a828b1431ee45);

    event TokensStaked(address indexed wallet, uint256 id, Period period, uint256 percent, uint256 amount, uint256 staked, uint256 unstaked);
    event TokensUnstaked(address indexed wallet, uint256 id, uint256 amount, uint256 unstaked);
    event TokensClaimed(address indexed wallet, uint256 id, uint256 daysCount, uint256 amount, uint256 claimed);

    enum Period { None, First, Second, Third, Fourth }

    struct Stake {
        bool active;
        address wallet;
        Period period;
        uint256 percent;
        uint256 tokensStaked;
        uint256 tokensUnstaked;
        uint256 tokensClaimed;
        uint256 staked;
        uint256 unstaked;
        uint256 claimed;
    }

    mapping (uint256 => Stake) private _stakes;
    mapping (address => uint256[]) private _walletStakesIds;
    mapping (Period => uint256) private _percents;
    mapping (Period => uint256) private _days;

    uint256 public nextStakeId = 1;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PAUSER_ROLE, _msgSender());

        _percents[Period.First] = 216;
        _percents[Period.Second] = 254;
        _percents[Period.Third] = 288;
        _percents[Period.Fourth] = 324;

        _days[Period.First] = 90;
        _days[Period.Second] = 180;
        _days[Period.Third] = 270;
        _days[Period.Fourth] = 360;
    }

    function stakeById(uint256 stakeId) public view returns (Stake memory stake) {
        return _stakes[stakeId];
    }

    function walletStakesIds(address wallet) public view returns (uint256[] memory ids) {
        return _walletStakesIds[wallet];
    }

    function percentByPeriod(Period period) public view returns (uint256 percent) {
        return _percents[period];
    }

    function daysByPeriod(Period period) public view returns (uint256 percent) {
        return _days[period];
    }

    function stakedAmount(address wallet) public view returns (uint256 amount) {
        require(wallet != address(0), "Wallet invalid");

        uint256 tokens = 0;

        if (_walletStakesIds[wallet].length > 0) {
            for (uint256 i = 0; i < _walletStakesIds[wallet].length; i++) {
                Stake memory stake = _stakes[_walletStakesIds[wallet][i]];
                if (stake.active) {
                    tokens += stake.tokensStaked;
                }
            }
        }

        return tokens;
    }

    function receiveTokens(address wallet, uint amount, address token, bytes memory data) public whenNotPaused returns (bool) {
        require(token == address(playwContract), "Token is different");
        require(amount > 0, "Amount is invalid");
        require(playwContract.balanceOf(wallet) >= amount, "Tokens not enough");
        require(playwContract.transferFrom(wallet, address(this), amount), "Transfer error");

        return _stake(wallet, amount, data);
    }

    function _stake(address wallet, uint amount, bytes memory data) private returns (bool) {
        Period period = Period(uint256(bytes32(data)));

        if (period == Period.None) {
            period = Period.Third; //year
        }

        uint256 percent = _percents[period];
        require(percent > 0, "Percent is invalid");

        uint256 daysPeriod = _days[period];
        require(daysPeriod > 0, "Days is invalid");

        Stake memory stake = Stake(true, wallet, period, percent, amount, 0, 0, block.timestamp, block.timestamp + (daysPeriod * 1 days), 0);

        _stakes[nextStakeId] = stake;
        _walletStakesIds[wallet].push(nextStakeId);

        emit TokensStaked(stake.wallet, nextStakeId, stake.period, stake.percent, stake.tokensStaked, stake.staked, stake.unstaked);

        nextStakeId++;
        return true;
    }

    function claim(uint256 stakeId) public whenNotPaused {
        require(stakeId > 0, "Stake id is required");
        
        _claim(stakeId);
    }

    function _claim(uint256 stakeId) private {
        uint256[] memory stakes = _walletStakesIds[_msgSender()];
        require(stakes.length > 0, "Stakes not found");

        bool stakeFound = false;
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i] == stakeId) {
                stakeFound = true;
                break;
            }
        }
        require(stakeFound, "Stake not found");

        Stake storage stake = _stakes[stakeId];
        require(stake.active, "Stake is inactive");

        uint256 time = (stake.unstaked > block.timestamp) ? block.timestamp : stake.unstaked;
        require(stake.claimed < time, "Stake period is over");

        uint256 claimDays = (stake.claimed > 0) ? (time - stake.claimed) / 1 days : (time - stake.staked) / 1 days;
        require(claimDays > 0, "Claim days invalid");

        uint tokensAmount = ((((stake.percent * 1000) / 360) * stake.tokensStaked) * claimDays) / 1000;
        require(tokensAmount > 0, "Claim tokens invalid");

        playwContract.mint(stake.wallet, tokensAmount);
        
        stake.tokensClaimed += tokensAmount;
        stake.claimed = time;
        
        emit TokensClaimed(_msgSender(), stakeId, claimDays, tokensAmount, time);
    }

    function unstake(uint256 stakeId) public whenNotPaused {
        require(stakeId > 0, "Stake id is required");

        _unstake(stakeId);
    }

    function _unstake(uint256 stakeId) private {
        uint256[] memory stakes = _walletStakesIds[_msgSender()];
        require(stakes.length > 0, "Stakes not found");

        bool stakeFound = false;
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i] == stakeId) {
                stakeFound = true;
                break;
            }
        }
        require(stakeFound, "Stake not found");

        Stake storage stake = _stakes[stakeId];
        require(stake.active, "Stake is inactive");
        require(stake.tokensUnstaked == 0, "Stake is already unstaked");
        
        uint256 tokens = stake.tokensStaked;
        if (stake.unstaked > block.timestamp) {
            uint256 daysStaked = (block.timestamp - stake.staked) / 1 days;
            require(daysStaked > 0, "Days staked error");

            uint256 percents = ((daysStaked * 10000) / ((_days[stake.period] * 10000) / 100));
            tokens = (stake.tokensStaked / 100) * percents;

            uint256 tokensBurn = stake.tokensStaked - tokens;
            playwContract.burn(tokensBurn);
        }

        if (tokens > 0) {
            if (playwContract.balanceOf(address(this)) >= tokens) {
                playwContract.transfer(stake.wallet, tokens);
            } else {
                playwContract.mint(stake.wallet, tokens);
            }
        }

        stake.tokensUnstaked = tokens;
        stake.active = false;

        emit TokensUnstaked(stake.wallet, stakeId, stake.tokensUnstaked, block.timestamp);
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
