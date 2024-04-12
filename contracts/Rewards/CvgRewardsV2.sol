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
import "../interfaces/ICvgAssetStaking.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Cvg-Finance - CvgRewardsV2
/// @notice Distribute rewards among staking contracts
/// @dev The function in charge of distributing CVG rewards is following th estate machine pattern
contract CvgRewardsV2 is Ownable2StepUpgradeable {
    enum State {
        CHECKPOINT,
        DISTRIBUTE,
        CONTROL_TOWER_SYNC
    }

    struct InflationInfo {
        address gauge;
        uint256 cvgDistributed;
        uint256 gaugeWeight;
    }

    struct CvgRewardsConfig {
        uint128 maxChunkCheckpoint;
        uint128 maxChunkDistribute;
    }

    event Checkpoints();
    event SetTotalWeight(uint256 cvgCycle, uint256 totalWeight);
    event EventChunkWriteStakingRewards(uint256 cvgCycle, uint256 totalGaugeWeight, InflationInfo[] inflationInfos);
    event InflationAdjustment(uint256 indexed cycleId, uint256 adjustment);
    event StakingDistribution(uint256 indexed cycleId, address indexed gaugeAddress, uint256 amount);

    /// @dev 60,576.92 CVG distributed each cycle on the first 105 cycles
    uint256 public constant INITIAL_CYCLE_INFLATION = 60576923076923076923076;

    /// @dev On cycle 1041, inflation doesn't reduce anymore
    uint256 public constant END_INFLATION_CYCLE = 1041;

    /// @dev After the 1041 cycle, 1893.028846 CVG are distributed by cycle
    uint256 public constant END_INFLATION_AMOUNT = 1893028846153846164575;

    /// @dev approximation value for square root of 2
    uint256 private constant SQRT_2 = 1414213562373095048;

    /// @dev each 105 cycles, inflation is reduced by SRQT2
    uint256 private constant INFLATION_CHANGE_INTERVAL_CYCLE = 105;

    /// @dev convergence ecosystem address
    ICvgControlTower public cvgControlTower;

    /// @dev Gauge Controller
    IGaugeController public gaugeController;

    /// @dev Percentage of CVG to distribute weekly. Can be between 80% and 120% of the planned inflation.
    ///      This can be used to augment or reduce the APR in CVG after votes from the DAO.
    uint256 public inflationRatio;

    /// @dev current rewards distribution state
    State public state;

    /// @dev current cursor, used to determine the starting index of the next chunk
    uint128 public cursor;

    /// @dev timestamp corresponding to the last update of the cvg cycle
    uint256 public lastUpdatedTimestamp;

    /// @dev Timestamp in second of the beginning of the first cycle.
    uint256 public firstCycleStartTimestamp;

    /// @dev configuration of the distribution process, contains chunks length to process
    CvgRewardsConfig public cvgRewardsConfig;

    /// @dev array containing the addresses of all gauges
    address[] public gauges;

    /// @dev mapping containing the ID of a gauge by its address
    mapping(address => uint256) public gaugesId; // gauge address => ID

    ///@dev STORAGE V2 STARTS HERE

    /// @dev Total weight stored during last distribution
    uint256 public lastTotalWeight;

    /// @dev mapping weight gauges on last cycle triggering
    mapping(address => uint256) public lastWeights; // gauge address => weight on last snapshot

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        ADMIN FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    /**
     *  @notice update rewards distribution's configuration of chunks length
     *  @param newConfig distribution's configuration
     */
    function setMaxChunkConfigs(CvgRewardsConfig calldata newConfig) external onlyOwner {
        cvgRewardsConfig = newConfig;
    }

    /**
     *  @notice Add a gauge in the gauge list
     *  @param gaugeAddress gaugeAddress to add
     */
    function addGauge(address gaugeAddress) external {
        require(address(gaugeController) == msg.sender, "NOT_GAUGE_CONTROLLER");
        gauges.push(gaugeAddress);
        gaugesId[gaugeAddress] = gauges.length - 1;
    }

    /**
     *  @notice Remove a gauge from the array, replace it by the last gauge of the array
     *  @param gaugeAddress gaugeAddress to remove
     */
    function removeGauge(address gaugeAddress) external {
        require(address(gaugeController) == msg.sender, "NOT_GAUGE_CONTROLLER");
        uint256 idGaugeToRemove = gaugesId[gaugeAddress];
        address lastGauge = gauges[gauges.length - 1];

        /// @dev replace id of last gauge by deleted one
        gaugesId[lastGauge] = idGaugeToRemove;
        /// @dev Set ID of gauge as 0
        gaugesId[gaugeAddress] = 0;

        /// @dev moove last gauge address to the id of the deleted one
        gauges[idGaugeToRemove] = lastGauge;

        /// @dev remove last array element
        gauges.pop();
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        VIEW FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice Compute the amount of CVG to be distributed through staking gauge contracts.
                Made by subtracting the lastInflation with the one with the active stakingCycle
     *  @param stakingCycle uint256
     */
    function stakingInflationAtCycle(uint256 stakingCycle) public view returns (uint256) {
        if (stakingCycle <= 1) return 0;
        if (stakingCycle >= END_INFLATION_CYCLE) return (END_INFLATION_AMOUNT * inflationRatio) / 10_000;

        uint256 inflationTarget = INITIAL_CYCLE_INFLATION;
        uint256 inflationCycle = stakingCycle / INFLATION_CHANGE_INTERVAL_CYCLE;

        for (uint256 i; i < inflationCycle; ) {
            inflationTarget = (inflationTarget * 10 ** 18) / SQRT_2;
            unchecked {
                ++i;
            }
        }

        return (inflationTarget * inflationRatio) / 10_000;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    EXTERNAL FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    /// @notice start or continue the rewards distribution process
    function writeStakingRewards(uint256 stepAmount) external {
        for (uint256 i; i < stepAmount; ) {
            State _state = state;
            if (_state == State.CHECKPOINT) {
                _checkpoints();
            } else if (_state == State.DISTRIBUTE) {
                _distributeCvgRewards();
            } else {
                _triggerCvgCycle();
            }
            unchecked {
                ++i;
            }
        }
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    INTERNAL FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /// @notice Refresh in a chunked way, all gauge weights in GaugeController
    function _checkpoints() internal {
        require(lastUpdatedTimestamp + 1 weeks <= block.timestamp, "NEED_WAIT_7_DAYS");

        IGaugeController _gaugeController = gaugeController;
        uint128 _cursor = cursor;
        uint128 _totalGaugeNumber = uint128(_gaugeController.n_gauges());

        /// @dev if first chunk, to don't break gauges votes if someone votes between 2 writeStakingRewards chunks we need to lock the gauge votes on GaugeController
        if (_cursor == 0) {
            /// @dev Lock votes
            _gaugeController.set_lock(true);
        }

        /// @dev compute the theoretical end of the chunk
        uint128 _maxEnd = _cursor + cvgRewardsConfig.maxChunkCheckpoint;
        /// @dev compute the real end of the chunk regarding the length of the array
        uint128 _endChunk = _maxEnd < _totalGaugeNumber ? _maxEnd : _totalGaugeNumber;

        /// @dev if last chunk of the checkpoint process
        if (_endChunk == _totalGaugeNumber) {
            /// @dev reset the cursor to 0 for _setTotalWeight
            cursor = 0;
            /// @dev set the step as DISTRIBUTE for reward distribution
            state = State.DISTRIBUTE;
        } else {
            /// @dev setup the cursor at the index start for the next chunk
            cursor = _endChunk;
        }

        /// @dev updates the weight of the chunked gauges
        _gaugeController.gauge_relative_weight_writes(_cursor, _endChunk - _cursor);

        /// @dev emit the event only at the last chunk
        if (_endChunk == _totalGaugeNumber) {
            emit Checkpoints();
        }
    }

    /**
     *  @notice Compute the amount of CVG to be distributed through staking gauge contracts.
     *  Made by getting the inflation of the current CVG cycle and dispersing tokens to staking contracts
     *  according to the weight of their associated gauge
     */
    function _distributeCvgRewards() internal {
        uint256 _cvgCycle = cvgControlTower.cvgCycle();

        /// @dev number of gauge in GaugeController
        uint128 _totalGaugeNumber = uint128(gauges.length);
        uint128 _cursor = cursor;

        /// @dev cursor of the end of the actual chunk
        uint128 cursorEnd = _cursor + cvgRewardsConfig.maxChunkDistribute;

        /// @dev if the new cursor is higher than the number of gauge, cursor become the number of gauge
        if (cursorEnd > _totalGaugeNumber) {
            cursorEnd = _totalGaugeNumber;
        }

        /// @dev reset the cursor if the distribution has been done
        if (cursorEnd == _totalGaugeNumber) {
            cursor = 0;

            /// @dev update the states to the control_tower sync
            state = State.CONTROL_TOWER_SYNC;
        }
        /// @dev update the global cursor in order to be taken into account on next chunk
        else {
            cursor = cursorEnd;
        }

        uint256 stakingInflation = stakingInflationAtCycle(_cvgCycle);
        uint256 cvgDistributed;
        bool isTakingLastWeight = _cvgCycle != 4;
        InflationInfo[] memory inflationInfos = new InflationInfo[](cursorEnd - _cursor);
        address[] memory addresses = _getGaugeChunk(_cursor, cursorEnd);
        /// @dev fetch weight of gauge relative to the cursor
        (uint256[] memory gaugeWeights, uint256 actualTotalWeight) = gaugeController.get_gauge_weights(addresses);
        /// @dev After the modification made in cycle 4, we take the total gauge weight based on the last cycle and no longer when triggering cycle.
        uint256 totalWeight = isTakingLastWeight ? lastTotalWeight : actualTotalWeight;
        bool isTotalWeightZero = totalWeight != 0;
        /// @dev store actual totalWeight for the next distribution

        for (uint256 i; i < gaugeWeights.length; ) {
            address gaugeAddress = addresses[i];
            uint256 actualGaugeWeight = gaugeWeights[i];
            /// @dev After the modification made in cycle 4, we take the votes on the last cycle and not anymore votes on triggering of cycle.
            uint256 gaugeVote = isTakingLastWeight ? lastWeights[gaugeAddress] : actualGaugeWeight;
            /// @dev compute the amount of CVG to distribute in the gauge
            cvgDistributed = isTotalWeightZero ? (stakingInflation * gaugeVote) / totalWeight : 0;

            /// @dev We store the actual gauge weights for the next distribution.
            lastWeights[gaugeAddress] = actualGaugeWeight;

            /// @dev Write the amount of CVG to distribute in the staking contract
            ICvgAssetStaking(gaugeAddress).processStakersRewards(cvgDistributed);

            inflationInfos[i] = InflationInfo({
                gauge: gaugeAddress,
                cvgDistributed: cvgDistributed,
                gaugeWeight: gaugeVote
            });

            unchecked {
                ++i;
            }
        }

        lastTotalWeight = actualTotalWeight;

        emit EventChunkWriteStakingRewards(_cvgCycle, totalWeight, inflationInfos);
    }

    /// @notice Synchronize the Global Cvg Cycle on the CvgControlTower
    function _triggerCvgCycle() internal {
        ICvgControlTower _cvgControlTower = cvgControlTower;
        _cvgControlTower.updateCvgCycle();
        _cvgControlTower.lockingPositionService().updateYsTotalSupply();
        state = State.CHECKPOINT;
        lastUpdatedTimestamp += 1 weeks;

        /// @dev unlock the votes after that distribution is done
        gaugeController.set_lock(false);
    }

    function _getGaugeChunk(uint256 from, uint256 to) internal view returns (address[] memory) {
        address[] memory chunk = new address[](to - from);
        for (uint256 i = from; i < to; ) {
            chunk[i - from] = gauges[i];
            unchecked {
                ++i;
            }
        }
        return chunk;
    }

    struct GaugeView {
        string symbol;
        address stakingAddress;
        uint256 weight;
        uint256 typeWeight;
        int128 gaugeType;
    }

    /**
     * @notice Get the cycle id regarding the timestamp
     * @param timestamp Timestamp we want to check the cycle ID corresponding
     * @return number of gauges
     */
    function getCycleLocking(uint256 timestamp) public view returns (uint256) {
        return ((timestamp - firstCycleStartTimestamp) / 1 weeks) + 1;
    }

    /**
     * @notice get the total number of gauges
     * @return number of gauges
     */
    function gaugesLength() external view returns (uint256) {
        return gauges.length;
    }

    /**
     * @notice get a list of gauges with pagination
     * @param from beginning of the pagination
     * @param to end of the pagination
     * @return array containing gauges information
     */
    function getGaugeChunk(uint256 from, uint256 to) external view returns (GaugeView[] memory) {
        uint256 _gaugesLength = gauges.length;
        address[] memory chunk = _getGaugeChunk(from, to > _gaugesLength ? _gaugesLength : to);
        uint256 chunkLength = chunk.length;
        IGaugeController.WeightType[] memory votes = gaugeController.get_gauge_weights_and_types(chunk);

        GaugeView[] memory gaugesView = new GaugeView[](chunkLength);
        for (uint256 i; i < chunk.length; ) {
            gaugesView[i] = GaugeView({
                symbol: ICvgAssetStaking(chunk[i]).symbol(),
                stakingAddress: chunk[i],
                weight: votes[i].weight,
                gaugeType: votes[i].gauge_type,
                typeWeight: votes[i].type_weight
            });
            unchecked {
                ++i;
            }
        }
        return gaugesView;
    }

    /**
     * @notice Set up the inflation ratio of the staking inflation.
     *         Callable only by the DAO.
     * @param _inflationRatio New inflation ratio, between 80% and 120%.
     */
    function setInflationRatio(uint256 _inflationRatio) external onlyOwner {
        require(_inflationRatio >= 8_000 && _inflationRatio <= 12_000, "RATIO_OUT_OF_RANGE");
        inflationRatio = _inflationRatio;
    }
}
