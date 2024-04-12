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
import "../interfaces/ISdAssets.sol";

struct TokenFee {
    IERC20 token;
    uint96 fee;
}
struct SdAssetStakingInfos {
    ISdtStakingPositionService stakingService;
    ISdAssetGauge gaugeAsset;
    uint256 rewardCount;
    IERC20[] rewardTokens;
    SdtAprInfo sdtAprInfo;
    TokenFee[] bribeTokenFees;
}

struct CurveLpStakingInfos {
    ISdtStakingPositionService stakingService;
    ISdAssetGauge gaugeAsset;
    ISdAssetGauge curveGauge;
    uint256 rewardCount;
    IERC20[] rewardTokens;
    SdtAprInfo sdtAprInfo;
    CrvAprInfo crvAprInfo;
}

struct SdtAprInfo {
    uint256 weeklySdtRewards;
    uint256 convergenceTotalBalance;
    uint256 blackHoleWorkingBalance;
    uint256 workingSupply;
    uint256 stakeGaugeTotalSupply;
}
struct CrvAprInfo {
    uint256 weeklyCrvRewards;
    uint256 stakeDaoTotalBalance;
    uint256 stakeDaoWorkingBalance; //not mandatory
    uint256 workingSupply; //not mandatory
    uint256 curveGaugeTotalSupply;
}
struct CvgSdtAprInfo {
    uint256 veSdtTotalSupply;
    uint256 veSdtOwned;
    uint256 cvgSdtTotalStaked;
}

struct CvgAprStruct {
    GaugeView[] gaugeData;
    uint256 totalWeight;
}
struct AprProjectedStakingInfos {
    uint256 sdtFeesToCvgSdtBuffer;
    uint256 rootFees;
    SdAssetStakingInfos[] sdAssetStakingInfos;
    CurveLpStakingInfos[] curveLpStakingInfos;
    CvgSdtAprInfo cvgSdtAprInfos;
    CvgAprStruct cvgAprInfos;
}

error AprProjectedStakingInfosError(AprProjectedStakingInfos aprProjectedStakingInfos);

struct CurveLpStakingParams {
    ISdtStakingPositionService staking;
    ISdAssetGauge curveGauge;
}

struct SdAssetStakingParams {
    ISdtStakingPositionService staking;
}

interface InterfaceSdtBlackhole {
    function getBribeTokensForBuffer(address buffer) external view returns (TokenFee[] memory);
}

interface ICrv {
    function rate() external view returns (uint256);
}

interface IVe {
    function totalSupply() external view returns (uint256);

    function balanceOf(address) external view returns (uint256);
}

interface InterfaceSdtFeeCollector {
    struct CollectorFees {
        address receiver;
        uint96 feePercentage;
    }

    function rootFees() external view returns (uint256);

    function feesRepartition(uint256 index) external view returns (CollectorFees memory);
}
struct CvgContracts {
    InterfaceSdtBlackhole sdtBlackHole;
    ISdtStakingPositionService cvgSdtStaking;
    address veSdtMultisig;
    IGaugeController cvgGaugeController;
    InterfaceSdtFeeCollector sdtFeeCollector;
    ICvggRewards cvgRewards;
}
struct GaugeView {
    string symbol;
    address stakingAddress;
    uint256 weight;
    uint256 typeWeight;
    int128 gaugeType;
}

interface ICvggRewards {
    function getGaugeChunk(uint256 from, uint256 to) external view returns (GaugeView[] memory);

    function gaugesLength() external view returns (uint256);
}

contract AprProjectedStakingInfo {
    uint256 constant WEEKLY_LP_SDT_INFLATION = 15_120 * 10 ** 18;
    uint256 constant WEEKLY_SDT_INFLATION = 20_160 * 10 ** 18;
    address constant SDT_VOTER_ADDRESS_ON_CRV = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;
    address constant veSdtMultisig = 0x6ceE94bFCD5a7dEFDBEF337Bf79fE31D0982CF2A;
    IGaugeController constant STAKE_LP_GAUGE_CONTROLLER = IGaugeController(0x3F3F0776D411eb97Cfa4E3eb25F33c01ca4e7Ca8);
    IGaugeController constant STAKE_GAUGE_CONTROLLER = IGaugeController(0x75f8f7fa4b6DA6De9F4fE972c811b778cefce882);
    IGaugeController constant CURVE_GAUGE_CONTROLLER = IGaugeController(0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB);
    ICrv constant CRV = ICrv(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IVe constant VESDT = IVe(0x0C30476f66034E11782938DF8e4384970B6c9e8a);

    constructor(
        SdAssetStakingParams[] memory _sdAssetStakings,
        CurveLpStakingParams[] memory _curveLpStakings,
        CvgContracts memory _cvgContracts
    ) {
        getAprProjectedStakingInfos(_sdAssetStakings, _curveLpStakings, _cvgContracts);
    }

    function getAprProjectedStakingInfos(
        SdAssetStakingParams[] memory _sdAssetStakings,
        CurveLpStakingParams[] memory _curveLpStakings,
        CvgContracts memory _cvgContracts
    ) internal view {
        /// @dev SD Assets
        SdAssetStakingInfos[] memory _sdAssetStakingInfos = new SdAssetStakingInfos[](_sdAssetStakings.length);

        for (uint256 i; i < _sdAssetStakings.length; i++) {
            ISdAssetGauge _gaugeAsset = _sdAssetStakings[i].staking.stakingAsset();

            uint256 _rewardsCount = _gaugeAsset.reward_count();
            IERC20[] memory _rewardTokens = new IERC20[](_rewardsCount);
            for (uint256 j; j < _rewardsCount; j++) {
                _rewardTokens[j] = _gaugeAsset.reward_tokens(j);
            }

            _sdAssetStakingInfos[i] = SdAssetStakingInfos({
                stakingService: _sdAssetStakings[i].staking,
                gaugeAsset: _gaugeAsset,
                rewardCount: _rewardsCount,
                rewardTokens: _rewardTokens,
                sdtAprInfo: _getSdtAPRInfo(_gaugeAsset, false, address(_cvgContracts.sdtBlackHole)),
                bribeTokenFees: _cvgContracts.sdtBlackHole.getBribeTokensForBuffer(
                    address(_sdAssetStakings[i].staking.buffer())
                )
            });
        }
        /// @dev Curve Lp Assets
        CurveLpStakingInfos[] memory _curveLpStakingInfos = new CurveLpStakingInfos[](_curveLpStakings.length);
        uint256 weeklyCrvInflation = CRV.rate() * 1 weeks;

        for (uint256 i; i < _curveLpStakings.length; i++) {
            ISdAssetGauge _gaugeAsset = _curveLpStakings[i].staking.stakingAsset();

            CrvAprInfo memory _crvAprInfo = _getCrvAPRInfo(_curveLpStakings[i].curveGauge, weeklyCrvInflation);

            uint256 _rewardsCount = _gaugeAsset.reward_count();
            IERC20[] memory _rewardTokens = new IERC20[](_rewardsCount);
            for (uint256 j; j < _rewardsCount; j++) {
                _rewardTokens[j] = _gaugeAsset.reward_tokens(j);
            }

            _curveLpStakingInfos[i] = CurveLpStakingInfos({
                stakingService: _curveLpStakings[i].staking,
                gaugeAsset: _gaugeAsset,
                curveGauge: _curveLpStakings[i].curveGauge,
                rewardCount: _rewardsCount,
                rewardTokens: _rewardTokens,
                sdtAprInfo: _getSdtAPRInfo(_gaugeAsset, true, address(_cvgContracts.sdtBlackHole)),
                crvAprInfo: _crvAprInfo
            });
        }

        uint256 rootFees = _cvgContracts.sdtFeeCollector.rootFees();
        revert AprProjectedStakingInfosError(
            AprProjectedStakingInfos({
                rootFees: rootFees,
                sdtFeesToCvgSdtBuffer: (rootFees * _cvgContracts.sdtFeeCollector.feesRepartition(0).feePercentage) /
                    100_000,
                sdAssetStakingInfos: _sdAssetStakingInfos,
                curveLpStakingInfos: _curveLpStakingInfos,
                cvgSdtAprInfos: CvgSdtAprInfo({
                    veSdtTotalSupply: VESDT.totalSupply(),
                    veSdtOwned: VESDT.balanceOf(veSdtMultisig),
                    cvgSdtTotalStaked: _cvgContracts
                        .cvgSdtStaking
                        .cycleInfo(_cvgContracts.cvgSdtStaking.stakingCycle() + 1)
                        .totalStaked
                }),
                cvgAprInfos: _getCvgAprInfo(_cvgContracts)
            })
        );
    }

    function _getCvgAprInfo(CvgContracts memory _cvgContracts) internal view returns (CvgAprStruct memory) {
        ICvggRewards cvgRewards = _cvgContracts.cvgRewards;
        return
            CvgAprStruct({
                gaugeData: cvgRewards.getGaugeChunk(0, cvgRewards.gaugesLength()),
                totalWeight: _cvgContracts.cvgGaugeController.get_total_weight()
            });
    }

    //FOR LP & SD
    function _getSdtAPRInfo(
        ISdAssetGauge _gaugeAsset,
        bool _isLp,
        address sdtBlackHole
    ) internal view returns (SdtAprInfo memory) {
        uint256 blackHoleWorkingBalance = _gaugeAsset.working_balances(sdtBlackHole);
        uint256 workingSupply = _gaugeAsset.working_supply();
        uint256 convergenceTotalBalance = _gaugeAsset.balanceOf(sdtBlackHole);
        uint256 gaugeRelativeWeight;
        uint256 weeklyInflation;
        if (_isLp) {
            weeklyInflation = WEEKLY_LP_SDT_INFLATION;
            gaugeRelativeWeight = STAKE_LP_GAUGE_CONTROLLER.gauge_relative_weight(
                address(_gaugeAsset),
                block.timestamp
            );
        } else {
            weeklyInflation = WEEKLY_SDT_INFLATION;
            gaugeRelativeWeight = STAKE_GAUGE_CONTROLLER.gauge_relative_weight(address(_gaugeAsset), block.timestamp);
        }

        uint256 weeklySdtAmount = gaugeRelativeWeight * weeklyInflation;
        uint256 weeklySdtRewards = workingSupply == 0 ? 0 : (weeklySdtAmount * blackHoleWorkingBalance) / workingSupply;

        return
            SdtAprInfo({
                weeklySdtRewards: weeklySdtRewards / 10 ** 18,
                convergenceTotalBalance: convergenceTotalBalance,
                blackHoleWorkingBalance: blackHoleWorkingBalance,
                workingSupply: workingSupply,
                stakeGaugeTotalSupply: _gaugeAsset.totalSupply()
            });
    }

    //ONLY FOR LP
    function _getCrvAPRInfo(
        ISdAssetGauge _gaugeAsset,
        uint256 weeklyCrvInflation
    ) internal view returns (CrvAprInfo memory) {
        uint256 stakeDaoWorkingBalance = _gaugeAsset.working_balances(SDT_VOTER_ADDRESS_ON_CRV);
        uint256 workingSupply = _gaugeAsset.working_supply();
        uint256 stakeDaoTotalBalance = _gaugeAsset.balanceOf(SDT_VOTER_ADDRESS_ON_CRV);

        uint256 gaugeRelativeWeight = CURVE_GAUGE_CONTROLLER.gauge_relative_weight(
            address(_gaugeAsset),
            block.timestamp
        );

        uint256 weeklyCrvAmount = gaugeRelativeWeight * weeklyCrvInflation;
        uint256 weeklyCrvRewards = workingSupply == 0 ? 0 : (weeklyCrvAmount * stakeDaoWorkingBalance) / workingSupply;

        return
            CrvAprInfo({
                weeklyCrvRewards: weeklyCrvRewards / 10 ** 18,
                stakeDaoTotalBalance: stakeDaoTotalBalance,
                stakeDaoWorkingBalance: stakeDaoWorkingBalance,
                workingSupply: workingSupply,
                curveGaugeTotalSupply: _gaugeAsset.totalSupply()
            });
    }
}
