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
import "../interfaces/ICvgControlTower.sol";
import "../interfaces/ICommonStruct.sol";

struct TokenAmountDecimal {
    IERC20Metadata token;
    uint256 amount;
    uint8 decimals;
}
struct StakingInfo {
    uint256 processorRewardsPercentage;
    ISdAssetGauge stakingAsset;
    ISdtStakingPositionService.CycleInfo cycleInfo;
    TokenAmountDecimal[] sdtRewardsDecimalsMinus1;
    TokenAmountDecimal[] sdtRewardsDecimalsMinus2;
}

error AprActualStakingsError(StakingInfo[] stakingInfos);

contract AprActualStakingInfo {
    constructor(uint256 cycleId, ISdtStakingPositionService[] memory _stakings) {
        getAprActualStakingInfos(cycleId, _stakings);
    }

    function getAprActualStakingInfos(uint256 cycleId, ISdtStakingPositionService[] memory _stakings) internal view {
        StakingInfo[] memory _stakingInfos = new StakingInfo[](_stakings.length);
        for (uint256 i; i < _stakings.length; i++) {
            ICommonStruct.TokenAmount[] memory _sdtRewardsCycleMinus1 = _stakings[i].getProcessedSdtRewards(cycleId);

            TokenAmountDecimal[] memory _sdtRewardsDecimalsMinus1 = new TokenAmountDecimal[](
                _sdtRewardsCycleMinus1.length
            );
            for (uint256 j; j < _sdtRewardsCycleMinus1.length; j++) {
                IERC20Metadata _token = IERC20Metadata(address(_sdtRewardsCycleMinus1[j].token));
                _sdtRewardsDecimalsMinus1[j] = TokenAmountDecimal({
                    token: _token,
                    amount: _sdtRewardsCycleMinus1[j].amount,
                    decimals: _token.decimals()
                });
            }

            ICommonStruct.TokenAmount[] memory _sdtRewardsCycleMinus2 = _stakings[i].getProcessedSdtRewards(
                cycleId - 1
            );

            TokenAmountDecimal[] memory _sdtRewardsDecimalsMinus2 = new TokenAmountDecimal[](
                _sdtRewardsCycleMinus2.length
            );
            for (uint256 j; j < _sdtRewardsCycleMinus2.length; j++) {
                IERC20Metadata _token = IERC20Metadata(address(_sdtRewardsCycleMinus2[j].token));
                _sdtRewardsDecimalsMinus2[j] = TokenAmountDecimal({
                    token: _token,
                    amount: _sdtRewardsCycleMinus2[j].amount,
                    decimals: _token.decimals()
                });
            }

            _stakingInfos[i] = StakingInfo({
                processorRewardsPercentage: _stakings[i].buffer().processorRewardsPercentage(),
                stakingAsset: _stakings[i].stakingAsset(),
                cycleInfo: _stakings[i].cycleInfo(cycleId),
                sdtRewardsDecimalsMinus1: _sdtRewardsDecimalsMinus1,
                sdtRewardsDecimalsMinus2: _sdtRewardsDecimalsMinus2
            });
        }
        revert AprActualStakingsError(_stakingInfos);
    }
}
