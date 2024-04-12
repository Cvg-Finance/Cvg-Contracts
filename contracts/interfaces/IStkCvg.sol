// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IStkCvg is IERC20Metadata {
    struct Reward {
        uint128 lastUpdateTime;
        uint128 periodFinish;
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
    }

    struct EarnedData {
        IERC20 token;
        uint256 amount;
    }

    function claimableRewards(address _account) external view returns (EarnedData[] memory userRewards);

    function getRewardForDuration(IERC20 _rewardToken) external view returns (uint256);

    function rewardTokens(uint256 index) external view returns (IERC20);

    function userRewardPerTokenPaid(address account, IERC20 reward) external view returns (uint256);
}
