// SPDX-License-Identifier: MIT
/**
 _____
/  __ \
| /  \/ ___  _ ____   _____ _ __ __ _  ___ _ __   ___ ___
| |    / _ \| '_ \ \ / / _ \ '__/ _` |/ _ \ '_ \ / __/ _ \
| \__/\ (_) | | | \ V /  __/ | | (_| |  __/ | | | (_|  __/
 \____/\___/|_| |_|\_/ \___|_|  \__, |\___|_| |_|\___\___|
                                 __/ |
                                |___/
 */
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "../interfaces/ICrvPoolNg.sol";
import "../interfaces/ICvgControlTowerV2.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IStkCvg.sol";
contract StkCvg is ERC20Upgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Convergence control tower
    ICvgControlTowerV2 public constant cvgControlTower = ICvgControlTowerV2(0xB0Afc8363b8F36E0ccE5D54251e20720FfaeaeE7);

    /// @dev Convergence token
    IERC20 public constant CVG = IERC20(0x97efFB790f2fbB701D88f89DB4521348A2B77be8);
    /// @dev WETH token
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @dev Duration that rewards are streamed over
    uint256 public constant REWARDS_DURATION = 86400 * 30; // 1 month (30 days)

    /// @dev ID created for the reantrancy lock
    bytes32 constant LOCK = keccak256("LOCK");

    /// @dev LP CVG-ETH
    ICrvPoolNg public cvgEthLp;

    /// @dev List of reward tokens
    IERC20[] public rewardTokens;

    /// @dev Reward data associated to a reward token
    mapping(IERC20 => IStkCvg.Reward) public rewardData; // token => reward data

    /// @dev Reward redirection data
    mapping(address => address) public rewardRedirect; // owner => receiver

    /// @dev Addresses approved to notify reward amount
    mapping(IERC20 => mapping(address => bool)) public rewardDistributors; // reward token => distributor => is approved to add rewards

    /// @dev Reward amount already sent to an user for a reward token
    mapping(address => mapping(IERC20 => uint256)) public userRewardPerTokenPaid; // user => reward token => amount

    /// @dev Reward amount for a reward token for a user
    mapping(address => mapping(IERC20 => uint256)) public rewards; // user => reward token => amount

    event RewardNotified(IERC20 indexed _token, uint256 _reward);
    event Staked(address indexed _user, uint256 _amount, uint256 ethSold);
    event Withdrawn(address indexed _user, uint256 _amount);
    event RewardPaid(address indexed _user, IERC20 indexed _rewardToken, uint256 _reward);
    event Recovered(IERC20 _token, uint256 _amount);
    event RewardAdded(IERC20 indexed _rewardToken, address indexed _distributor);
    event RewardDistributorApproved(IERC20 indexed _reward, address indexed _distributor, bool _state);
    event RewardRedirected(address indexed _account, address _forward);

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        CONSTRUCTOR & INIT
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice initialize function
    function initialize(string memory _name, string memory _symbol, ICrvPoolNg _cvgEthLp) external initializer {
        __ERC20_init(_name, _symbol);

        cvgEthLp = _cvgEthLp;

        WETH.approve(address(_cvgEthLp), type(uint256).max);

        _transferOwnership(cvgControlTower.treasuryDao());
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        MODIFIERS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    modifier updateReward(address _account) {
        _updateReward(_account);
        _;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    EXTERNALS USER
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Set reward redirection address for the caller
     * @dev Set address to zero to disable
     * @param _to Address of the receiver
     */
    function setRewardRedirect(address _to) external {
        rewardRedirect[msg.sender] = _to;
        emit RewardRedirected(msg.sender, _to);
    }

    /**
     * @notice Stake CVG tokens, the user can enter with CVG and/or WETH and/or ETH.
     * @dev    A reentrancy guard is in place because the transaction is payable.
     * @param _cvgAmount        Amount of CVG to stake
     * @param _wethAmount       Amount of WETH to stake
     * @param _minOutCvgAmount  Minimum amount of CVG received after the swap in the CVG-ETH lp.
     * @param _receiver         Receiver of the stkCVG ERC20
     */
    function stake(
        uint256 _cvgAmount,
        uint256 _wethAmount,
        uint256 _minOutCvgAmount,
        address _receiver
    ) external payable {
        /// @dev Reentrancy lock check
        require(_tload(LOCK) == 0, "NOT_LOCKED");

        /// @dev Reentrancy lock set
        _tstore(LOCK, 1);

        uint256 totalCvgAdded = _cvgAmount;
        uint256 WEthToSell = msg.value;

        /// @dev If the user sends some ETH => we wrapped them into WETH
        if (msg.value != 0) {
            WETH.deposit{value: msg.value}();
        }

        /// @dev If the user sends some WETH
        if (_wethAmount != 0) {
            /// @dev We have to send them on the contract.
            WETH.transferFrom(msg.sender, address(this), _wethAmount);
            /// @dev Add it to the amount of WETH to sell for CVG
            WEthToSell += _wethAmount;
        }

        /// @dev If the sum of the ETH sent + WETH is greater than 0
        if (WEthToSell != 0) {
            /// @dev We perform a swap with this amount through the LP and add it to the amount of CVG sent
            totalCvgAdded += cvgEthLp.exchange(0, 1, WEthToSell, _minOutCvgAmount, address(this));
        }

        /// @dev Requires that some CVG are deposited or bought
        require(totalCvgAdded > 0, "AMOUNT_LTE");

        /// @dev Mint will call _updateReward
        _mint(_receiver, totalCvgAdded);

        if (_cvgAmount != 0) {
            /// @dev Transfer CVG from user to this contract
            CVG.transferFrom(msg.sender, address(this), _cvgAmount);
        }

        /// @dev Reentrancy lock clear
        _tstore(LOCK, 0);

        emit Staked(msg.sender, totalCvgAdded, WEthToSell);
    }

    /**
     * @notice Withdraw CVG tokens
     * @param _amount Amount to withdraw
     */
    function withdraw(uint256 _amount) external {
        require(_amount > 0, "AMOUNT_LTE");

        // @dev Burn will call _updateReward
        _burn(msg.sender, _amount);

        /// @dev Transfer CVG to user
        CVG.safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _amount);
    }

    /**
     * @notice Claim all pending rewards for an address
     * @dev Anyone can call this function for any address
     * @param _address Address to claim rewards for
     */
    function getReward(address _address) external updateReward(_address) {
        for (uint256 i; i < rewardTokens.length; ) {
            IERC20 _rewardToken = rewardTokens[i];
            uint256 reward = rewards[_address][_rewardToken];

            if (reward > 0) {
                rewards[_address][_rewardToken] = 0;
                if (rewardRedirect[_address] != address(0)) {
                    _rewardToken.safeTransfer(rewardRedirect[_address], reward);
                } else {
                    _rewardToken.safeTransfer(_address, reward);
                }

                emit RewardPaid(_address, _rewardToken, reward);
            }

            unchecked {
                ++i;
            }
        }
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    EXTERNALS DAO
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Add a new reward token to be distributed to users
     * @param _rewardToken Address of the reward token
     * @param _distributor Address of the distributor who will be allowed to notify reward amount
     */
    function addReward(IERC20 _rewardToken, address _distributor) external onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime == 0, "REWARD_TOKEN_ALREADY_EXISTS");
        require(_rewardToken != CVG && _rewardToken != IERC20(address(this)), "INVALID_TOKEN");

        rewardTokens.push(_rewardToken);
        rewardData[_rewardToken].lastUpdateTime = uint128(block.timestamp);
        rewardData[_rewardToken].periodFinish = uint128(block.timestamp);
        rewardDistributors[_rewardToken][_distributor] = true;

        emit RewardAdded(_rewardToken, _distributor);
    }

    /**
     * @notice Modify approval for an address to notify reward amount
     * @param _rewardToken Address of the reward token
     * @param _distributor Address of the distributor
     * @param _approved State of the approval
     */
    function approveRewardDistributor(IERC20 _rewardToken, address _distributor, bool _approved) external onlyOwner {
        require(rewardData[_rewardToken].lastUpdateTime > 0, "REWARD_TOKEN_NOT_FOUND");
        rewardDistributors[_rewardToken][_distributor] = _approved;

        emit RewardDistributorApproved(_rewardToken, _distributor, _approved);
    }

    /**
     * @notice Notify reward amount for a reward token
     * @param _rewardToken Address of the reward token
     * @param _reward Reward amount
     */
    function notifyRewardAmount(IERC20 _rewardToken, uint256 _reward) external updateReward(address(0)) {
        require(rewardDistributors[_rewardToken][msg.sender], "NOT_DISTRIBUTOR");
        require(_reward > 0 && _reward < 1e30, "INCORRECT_VALUE");

        _notifyReward(_rewardToken, _reward);

        /// @dev Handle the transfer of reward tokens via `transferFrom` to reduce the number
        /// @dev of transactions required and ensure correctness of the _reward amount
        _rewardToken.safeTransferFrom(msg.sender, address(this), _reward);

        emit RewardNotified(_rewardToken, _reward);
    }

    /**
     * @notice Transfer ERC20 tokens on this contract to the treasury DAO address
     * @dev Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
     * @param _tokenAddress Address of the token
     * @param _tokenAmount Amount to transfer
     */
    function recoverToken(IERC20 _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(rewardData[_tokenAddress].lastUpdateTime == 0, "CANNOT_WITHDRAW_REWARD_TOKEN");
        require(_tokenAddress != CVG, "CANNOT_WITHDRAW_STAKING_TOKEN");

        _tokenAddress.safeTransfer(cvgControlTower.treasuryDao(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                       INTERNALS
   =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Fetch the reward amount of a token based on the period
     * @param _rewardToken Address of the reward token
     * @return Total reward amount of the token
     */
    function _rewardPerToken(IERC20 _rewardToken) internal view returns (uint256) {
        if (totalSupply() == 0) return rewardData[_rewardToken].rewardPerTokenStored;

        return
            rewardData[_rewardToken].rewardPerTokenStored +
            (((_lastTimeRewardApplicable(rewardData[_rewardToken].periodFinish) -
                rewardData[_rewardToken].lastUpdateTime) *
                rewardData[_rewardToken].rewardRate *
                1e18) / totalSupply());
    }

    /**
     * @notice Fetch the amount earned
     * @param _user Address of the user
     * @param _rewardToken Address of the reward token
     * @param _balance Balance
     * @return Reward amount to claim for the user
     */
    function _earned(address _user, IERC20 _rewardToken, uint256 _balance) internal view returns (uint256) {
        return
            (_balance * (_rewardPerToken(_rewardToken) - userRewardPerTokenPaid[_user][_rewardToken])) /
            1e18 +
            rewards[_user][_rewardToken];
    }

    function _lastTimeRewardApplicable(uint128 _finishTime) internal view returns (uint128) {
        return block.timestamp < _finishTime ? uint128(block.timestamp) : uint128(_finishTime);
    }

    /**
     * @notice Update reward data for the specified reward token
     * @param _rewardToken Address of the reward token
     * @param _reward Reward amount
     */
    function _notifyReward(IERC20 _rewardToken, uint256 _reward) internal {
        IStkCvg.Reward storage rData = rewardData[_rewardToken];

        if (block.timestamp >= rData.periodFinish) {
            rData.rewardRate = _reward / REWARDS_DURATION;
        } else {
            uint256 remaining = rData.periodFinish - block.timestamp;
            uint256 leftover = remaining * rData.rewardRate;
            rData.rewardRate = (_reward + leftover) / REWARDS_DURATION;
        }

        rData.lastUpdateTime = uint128(block.timestamp);
        rData.periodFinish = uint128(block.timestamp + REWARDS_DURATION);
    }

    /**
     * @notice Update reward data for every reward tokens for an address
     * @param _account Address of the user
     */
    function _updateReward(address _account) internal {
        uint256 userBal = balanceOf(_account);
        uint256 rewardLength = rewardTokens.length;
        for (uint256 i; i < rewardLength; ) {
            IERC20 token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = _rewardPerToken(token);
            rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(rewardData[token].periodFinish);

            if (_account != address(0)) {
                rewards[_account][token] = _earned(_account, token, userBal);
                userRewardPerTokenPaid[_account][token] = rewardData[token].rewardPerTokenStored;
            }

            unchecked {
                ++i;
            }
        }
    }

    function lastTimeRewardApplicable(IERC20 _rewardToken) external view returns (uint256) {
        return _lastTimeRewardApplicable(rewardData[_rewardToken].periodFinish);
    }

    function rewardPerToken(IERC20 _rewardToken) external view returns (uint256) {
        return _rewardPerToken(_rewardToken);
    }

    function getRewardForDuration(IERC20 _rewardToken) external view returns (uint256) {
        return rewardData[_rewardToken].rewardRate * REWARDS_DURATION;
    }

    /**
     * @notice Get the claimable amount of all reward tokens for the given address
     * @param _account Address of the user
     * @return userRewards Array of rewards
     */
    function claimableRewards(address _account) external view returns (IStkCvg.EarnedData[] memory userRewards) {
        userRewards = new IStkCvg.EarnedData[](rewardTokens.length);

        for (uint256 i; i < userRewards.length; ) {
            IERC20 token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(_account, token, balanceOf(_account));

            unchecked {
                ++i;
            }
        }

        return userRewards;
    }

    function _beforeTokenTransfer(address _from, address _to, uint256) internal override {
        // checkpoint from and to, can skip if address 0 so no extra gas
        // is used when minting burning
        if (_from != address(0)) {
            _updateReward(_from);
        }

        if (_to != address(0)) {
            _updateReward(_to);
        }
    }

    function _tstore(bytes32 location, uint256 value) private {
        assembly {
            tstore(location, value)
        }
    }

    function _tload(bytes32 location) private view returns (uint256 value) {
        assembly {
            value := tload(location)
        }
    }
}
