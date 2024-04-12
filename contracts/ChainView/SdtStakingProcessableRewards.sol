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
/**
 * @dev Structure for each staking rows.
 **/
struct SdtHarvesterInfo {
    address stakingContract;
    string stakingName;
    uint256 harvesterPercentage;
    bool isSdtProcessed;
    ICommonStruct.TokenAmount[] tokenAmounts;
}

error SdtStakingProcessableRewardsErr(SdtHarvesterInfo[] harvesterInfos);

contract SdtStakingProcessableRewards {
    /// @notice Convergence ecosystem address
    ICvgControlTower constant cvgControlTower = ICvgControlTower(0xB0Afc8363b8F36E0ccE5D54251e20720FfaeaeE7);
    IERC20 constant sdt = IERC20(0x73968b9a57c6E53d41345FD57a6E6ae27d6CDB2F);
    IERC20 constant cvgSDT = IERC20(0x830614aE209FF9d8706d386fcdBc7a55206fcffC);

    constructor(ISdtStakingPositionService[] memory sdtStakings) {
        getProcessableDataGaugeContracts(sdtStakings);
    }

    /// @notice This function returns all the StakeDao rewards processable
    function getProcessableDataGaugeContracts(ISdtStakingPositionService[] memory sdtStakings) internal view {
        uint256 lastCycleId = cvgControlTower.cvgCycle() - 1;
        ISdtBlackHole sdtBlackHole = cvgControlTower.sdtBlackHole();
        /// @dev we add +1 for the cvgSDT
        SdtHarvesterInfo[] memory processableRewards = new SdtHarvesterInfo[](sdtStakings.length + 1);

        /// @dev iterates on each staking contract
        for (uint256 i; i < sdtStakings.length; ) {
            ISdtStakingPositionService stakingService = sdtStakings[i];
            ISdAssetGauge gaugeAsset = stakingService.stakingAsset();
            /// @dev get the number of reward tokens for this token
            uint256 rewardCount = gaugeAsset.reward_count();

            ISdtBuffer buffer = stakingService.buffer();

            IERC20[] memory bribeTokens = sdtBlackHole.getBribeTokensForBuffer(address(buffer));

            /// @dev iterate on reward tokens to get the processable amount of each instance
            ICommonStruct.TokenAmount[] memory processableData = new ICommonStruct.TokenAmount[](
                rewardCount + bribeTokens.length
            );
            uint256 counter;
            /// @dev Rewards from gauges
            for (; counter < rewardCount; ) {
                IERC20 rewardToken = gaugeAsset.reward_tokens(counter);

                /// @dev get the processable amount for this reward token + the balance of this token on the buffer
                uint256 processableAmount = gaugeAsset.claimable_reward(address(sdtBlackHole), address(rewardToken)) +
                    rewardToken.balanceOf(address(buffer));

                processableData[counter] = ICommonStruct.TokenAmount({token: rewardToken, amount: processableAmount});

                unchecked {
                    ++counter;
                }
            }

            /// @dev Rewards from Bribes
            for (uint256 j; j < bribeTokens.length; ) {
                processableData[counter] = ICommonStruct.TokenAmount({
                    token: bribeTokens[j],
                    amount: bribeTokens[j].balanceOf(address(sdtBlackHole))
                });

                unchecked {
                    ++j;
                    ++counter;
                }
            }

            processableRewards[i] = SdtHarvesterInfo({
                stakingContract: address(stakingService),
                stakingName: gaugeAsset.name(),
                harvesterPercentage: buffer.processorRewardsPercentage(),
                tokenAmounts: processableData,
                isSdtProcessed: stakingService.cycleInfo(lastCycleId).isSdtProcessed
            });

            unchecked {
                ++i;
            }
        }
        /// @dev cvgSDT buffer projection
        processableRewards[processableRewards.length - 1] = getCvgSdtProcessableRewards(lastCycleId);

        revert SdtStakingProcessableRewardsErr(processableRewards);
    }

    function getCvgSdtProcessableRewards(uint256 lastCycleId) internal view returns (SdtHarvesterInfo memory) {
        ISdtBuffer cvgSdtBuffer = cvgControlTower.cvgSdtBuffer();

        /// @dev doing some black magic here in order to be able
        ISdtFeeCollector feeCollector = cvgControlTower.sdtFeeCollector();

        ICommonStruct.TokenAmount[] memory processableData = new ICommonStruct.TokenAmount[](2);

        /// @dev Platform fees + boost for SDT
        processableData[0] = ICommonStruct.TokenAmount({
            token: sdt,
            amount: ((sdt.balanceOf(address(feeCollector)) * feeCollector.feesRepartition(0) * 100) / 10_000_000) +
                sdt.balanceOf(address(cvgSdtBuffer))
        });

        /// @dev  boost only for cvgSDT
        processableData[1] = ICommonStruct.TokenAmount({
            token: cvgSDT,
            amount: cvgSDT.balanceOf(address(cvgSdtBuffer))
        });
        ISdtStakingPositionService cvgSdtStakingService = cvgControlTower.cvgSdtStaking();
        return
            SdtHarvesterInfo({
                stakingContract: address(cvgSdtStakingService),
                stakingName: "cvgSDT",
                harvesterPercentage: cvgSdtBuffer.processorRewardsPercentage(),
                tokenAmounts: processableData,
                isSdtProcessed: cvgSdtStakingService.cycleInfo(lastCycleId).isSdtProcessed
            });
    }
}
