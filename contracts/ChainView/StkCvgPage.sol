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
import "../interfaces/IWETH.sol";

import "../interfaces/IStkCvg.sol";
/**
 * @dev Structure for each staking rows.
 **/
struct StkContractInfo {
    address stakingContract;
    string stakingName;
    uint256 totalSupply;
    uint256 stkCvgBalance;
    uint256 cvgAllowance;
    uint256 wethAllowance;
    uint256 rewardRateForDuration;
    uint256 claimableRewards;
    uint256 userRewardPerTokenPaid;
}

struct CommonInfos {
    uint256 cvgBalance;
    uint256 ethBalance;
    uint256 wETHBalance;
}

error StkContractInfoErr(StkContractInfo[] contractInfos, CommonInfos globalInfos);
contract StkCvgPage {
    /// @dev Convergence token
    IERC20 public constant CVG = IERC20(0x97efFB790f2fbB701D88f89DB4521348A2B77be8);
    /// @dev WETH token
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    constructor(IStkCvg[] memory sdtStakings, address account) {
        getInitData(sdtStakings, account);
    }

    function getInitData(IStkCvg[] memory stkCvgs, address account) internal view {
        CommonInfos memory _commonInfos;

        StkContractInfo[] memory _stkCvgInfos = new StkContractInfo[](stkCvgs.length);
        if (account != address(0)) {
            _commonInfos.cvgBalance = CVG.balanceOf(account);
            _commonInfos.ethBalance = account.balance;
            _commonInfos.wETHBalance = WETH.balanceOf(account);
        }
        for (uint256 i; i < stkCvgs.length; ) {
            IStkCvg _stkCvg = stkCvgs[i];
            IERC20 reward = _stkCvg.rewardTokens(0);

            _stkCvgInfos[i] = StkContractInfo({
                stakingContract: address(_stkCvg),
                stakingName: _stkCvg.name(),
                totalSupply: _stkCvg.totalSupply(),
                stkCvgBalance: _stkCvg.balanceOf(account),
                cvgAllowance: CVG.allowance(account, address(_stkCvg)),
                wethAllowance: WETH.allowance(account, address(_stkCvg)),
                rewardRateForDuration: _stkCvg.getRewardForDuration(reward),
                claimableRewards: _stkCvg.claimableRewards(account)[0].amount,
                userRewardPerTokenPaid: _stkCvg.userRewardPerTokenPaid(account, reward)
            });
            unchecked {
                ++i;
            }
        }
        revert StkContractInfoErr(_stkCvgInfos, _commonInfos);
    }
}

interface StkCvgInterface {}
