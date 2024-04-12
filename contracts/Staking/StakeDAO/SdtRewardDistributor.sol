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

/// @title  Cvg-Finance - SdtRewardDistributor
/// @notice Receives all StakeDAO rewards from SdtBuffer & CvgSdtBuffer.
/// @dev Optimize gas cost on claim on several contract by limiting ERC20 transfers.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/ISdtStakingPositionService.sol";
import "../../interfaces/ISdtStakingPositionManager.sol";
import "../../interfaces/ISdAssets.sol";
import "../../interfaces/ICvgControlTower.sol";
import "../../interfaces/ICvg.sol";
import "../../interfaces/ICrvPoolPlain.sol";

contract SdtRewardDistributor is Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Convergence Control Tower
    ICvgControlTower public cvgControlTower;

    /// @dev StakeDao token
    IERC20 public sdt;

    /// @dev Convergence token
    ICvg public cvg;

    /// @notice CvgSdt token contract
    IERC20Mintable public cvgSdt;

    /// @notice CvgSdt/Sdt stable pool contract on Curve
    ICrvPoolPlain public poolCvgSDT;

    ISdtStakingPositionManager public sdtStakingPositionManager;

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        INITIALIZE
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        IERC20 _sdt = _cvgControlTower.sdt();
        address treasuryDao = _cvgControlTower.treasuryDao();
        ICvg _cvg = _cvgControlTower.cvgToken();
        IERC20Mintable _cvgSdt = _cvgControlTower.cvgSDT();
        ISdtStakingPositionManager _sdtStakingPositionManager = _cvgControlTower.sdtStakingPositionManager();

        require(address(_sdt) != address(0), "SDT_ZERO");
        sdt = _sdt;

        require(address(_cvg) != address(0), "CVG_ZERO");
        cvg = _cvg;

        require(address(_cvgSdt) != address(0), "CVG_SDT_ZERO");
        cvgSdt = _cvgSdt;

        require(address(_sdtStakingPositionManager) != address(0), "SDT_POSITION_MNGR_ZERO");
        sdtStakingPositionManager = _sdtStakingPositionManager;

        require(treasuryDao != address(0), "TREASURY_DAO_ZERO");
        _transferOwnership(treasuryDao);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Mint CVG & distribute StakeDao rewards for a receiver, owner of a Staking Position
     * @dev    Function used when only one Staking Position is involved for a claiming.
     * @param receiver List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param totalCvgClaimable List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param totalSdtRewardsClaimable List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param minCvgSdtAmountOut If greater than 0, converts all SDT into CvgSDT. Minimum amount to receive.
     * @param isConvert If true, converts all SDT into CvgSDT.
     */
    function claimCvgSdtSimple(
        address receiver,
        uint256 totalCvgClaimable,
        ICommonStruct.TokenAmount[] memory totalSdtRewardsClaimable,
        uint256 minCvgSdtAmountOut,
        bool isConvert
    ) external {
        require(cvgControlTower.isStakingContract(msg.sender), "NOT_STAKING");
        _withdrawRewards(receiver, totalCvgClaimable, totalSdtRewardsClaimable, minCvgSdtAmountOut, isConvert);
    }

    /**
     * @notice Claims rewards from StakeDao integration on several cycles for several tokenID on different SdtStakingPositionService.
     *         Allows the users to claim all the rewards from the StakeDao integration in 1 Tx.
     *         All CVG to mint are accumulated in one value.
     *         All StakeDao rewards are merged in one array.
     * @param claimContracts  List of contracts having a list of tokenID with a list of cycleID to claim rewards on.
     * @param minCvgSdtAmountOut If greater than 0, converts all SDT into CvgSDT through the pool.If equals to 0 mint through the cvgSDT contract. Minimum amount to receive.
     * @param isConvert          If true, converts all SDT into CvgSDT.
     * @param sdtRewardCount This parameter must be configured through the front-end.
     */
    function claimMultipleStaking(
        ISdtStakingPositionManager.ClaimSdtStakingContract[] calldata claimContracts,
        uint256 minCvgSdtAmountOut,
        bool isConvert,
        uint256 sdtRewardCount
    ) external {
        require(claimContracts.length != 0, "NO_STAKING_SELECTED");
        /// @dev Checks for all positions input in data : Token ownership & verify positions are linked to the right staking service & verify timelocking
        sdtStakingPositionManager.checkMultipleClaimCompliance(claimContracts, msg.sender);

        /// @dev Accumulates amounts of CVG coming from all claims.
        uint256 _totalCvgClaimable;

        /// @dev Array merging & accumulating rewards coming from different claims.
        ICommonStruct.TokenAmount[] memory _totalSdtClaimable = new ICommonStruct.TokenAmount[](sdtRewardCount);

        /// @dev Iterate over all staking service
        for (uint256 stakingIndex; stakingIndex < claimContracts.length; ) {
            ISdtStakingPositionService sdtStaking = claimContracts[stakingIndex].stakingContract;
            uint256 tokensLength = claimContracts[stakingIndex].tokenIds.length;
            require(tokensLength != 0, "NO_STAKING_POSITIONS_SELECTED");

            /// @dev Iterate over all tokens linked to the iterated cycle.
            for (uint256 tokenIdIndex; tokenIdIndex < tokensLength; ) {
                /** @dev Claims Cvg & Sdt
                 *       Returns the amount of CVG claimed on the position.
                 *       Returns the array of all SDT rewards claimed on the position.
                 */
                (uint256 cvgClaimable, ICommonStruct.TokenAmount[] memory _sdtRewards) = sdtStaking.claimCvgSdtMultiple(
                    claimContracts[stakingIndex].tokenIds[tokenIdIndex],
                    msg.sender
                );
                /// @dev increments the amount to mint at the end of function
                _totalCvgClaimable += cvgClaimable;

                uint256 sdtRewardsLength = _sdtRewards.length;
                /// @dev Iterate over all SDT rewards claimed on the iterated position
                for (uint256 positionRewardIndex; positionRewardIndex < sdtRewardsLength; ) {
                    /// @dev Is the claimable amount is 0 on this token
                    ///      We bypass the process to save gas
                    if (_sdtRewards[positionRewardIndex].amount != 0) {
                        /// @dev Iterate over the final array to merge the iterated SdtRewards in the totalSdtClaimable
                        for (uint256 totalRewardIndex; totalRewardIndex < sdtRewardCount; ) {
                            address iteratedTotalClaimableToken = address(_totalSdtClaimable[totalRewardIndex].token);
                            /// @dev If the token is not already in the totalSdtClaimable.
                            if (iteratedTotalClaimableToken == address(0)) {
                                /// @dev Set token data in the totalClaimable array.
                                _totalSdtClaimable[totalRewardIndex] = ICommonStruct.TokenAmount({
                                    token: _sdtRewards[positionRewardIndex].token,
                                    amount: _sdtRewards[positionRewardIndex].amount
                                });

                                /// @dev Pass to the next token
                                break;
                            }
                            /// @dev If the token is already in the totalSdtClaimable.
                            if (iteratedTotalClaimableToken == address(_sdtRewards[positionRewardIndex].token)) {
                                /// @dev Increments the claimable amount.
                                _totalSdtClaimable[totalRewardIndex].amount += _sdtRewards[positionRewardIndex].amount;
                                /// @dev Pass to the next token
                                break;
                            }

                            /// @dev If the token is not found in the totalRewards and we are at the end of the array.
                            ///      it means the sdtRewardCount is not properly configured.
                            require(totalRewardIndex != sdtRewardCount - 1, "REWARD_COUNT_TOO_SMALL");

                            unchecked {
                                ++totalRewardIndex;
                            }
                        }
                    }

                    unchecked {
                        ++positionRewardIndex;
                    }
                }

                unchecked {
                    ++tokenIdIndex;
                }
            }
            unchecked {
                ++stakingIndex;
            }
        }

        _withdrawRewards(msg.sender, _totalCvgClaimable, _totalSdtClaimable, minCvgSdtAmountOut, isConvert);
    }

    /** @dev Mint accumulated CVG & Transfers StakeDao rewards to the claimer of Stakings
     *  @param receiver                 Receiver of the claim
     *  @param totalCvgClaimable        Amount of CVG to mint to the receiver
     *  @param totalSdtRewardsClaimable Array of all StakeDao rewards to send to the receiver
     *  @param minCvgSdtAmountOut       Minimum amount of cvgSDT to receive in case of a pool exchange
     *  @param isConvert                If true, converts all SDT into CvgSDT.
     *
     */
    function _withdrawRewards(
        address receiver,
        uint256 totalCvgClaimable,
        ICommonStruct.TokenAmount[] memory totalSdtRewardsClaimable,
        uint256 minCvgSdtAmountOut,
        bool isConvert
    ) internal {
        /// @dev Mints accumulated CVG and claim StakeDao rewards
        IERC20 _sdt = sdt;
        if (totalCvgClaimable > 0) {
            cvg.mintStaking(receiver, totalCvgClaimable);
        }
        for (uint256 i; i < totalSdtRewardsClaimable.length; ) {
            uint256 rewardAmount = totalSdtRewardsClaimable[i].amount;
            if (rewardAmount > 0) {
                /// @dev If the token is SDT & we want to convert it in CvgSDT
                if (isConvert && totalSdtRewardsClaimable[i].token == _sdt) {
                    if (minCvgSdtAmountOut == 0) {
                        /// @dev Mint cvgSdt 1:1 via CvgToke contract
                        cvgSdt.mint(receiver, rewardAmount);
                    }
                    /// @dev Else it's a swap
                    else {
                        poolCvgSDT.exchange(0, 1, rewardAmount, minCvgSdtAmountOut, receiver);
                    }
                }
                /// @dev Else transfer the ERC20 to the receiver
                else {
                    totalSdtRewardsClaimable[i].token.safeTransfer(receiver, rewardAmount);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     *  @notice Set the CvgSdt/Sdt stable pool. Approve SDT tokens to be transferred from the CvgSdt LP.
     *  @dev    The approval has to be done to perform swaps from SDT to CvgSdt during claims.
     *  @param _poolCvgSDT Address of the CvgSdt/Sdt stable pool to set
     *  @param amount      Amount of SDT to approve on the Stable pool
     */
    function setPoolCvgSdtAndApprove(ICrvPoolPlain _poolCvgSDT, uint256 amount) external onlyOwner {
        /// @dev Remove approval from previous pool
        if (address(poolCvgSDT) != address(0)) sdt.approve(address(poolCvgSDT), 0);

        poolCvgSDT = _poolCvgSDT;
        sdt.approve(address(_poolCvgSDT), amount);
        sdt.approve(address(cvgSdt), amount);
    }
}
