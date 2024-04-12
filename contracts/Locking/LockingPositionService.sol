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

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ICvgControlTower.sol";
import "../interfaces/ILockingPositionService.sol";

/**
 * @title Cvg-Finance - LockingPositionService
 * @notice Allows to lock CVG, gives yield and governance power.
 * @dev  When a position is minted, the amount can be split  between 2 different type of CVG :
 *       veCVG : used for voting power ( associated  with MgCVG meta-governance voting power )
 *       | ysCVG : used for treasury shares( allow the user to claim a part of the treasury at each TDE ( treasury distribution event ) )
 *       | the amount  of ys/Ve the user will receive for each CVG locked  is proportional with the duration of the lock.
 */
contract LockingPositionService is Ownable2StepUpgradeable {
    event MintLockingPosition(uint256 tokenId, ILockingPositionService.LockingPosition lockingPosition);
    event IncreaseLockAmount(uint256 tokenId, ILockingPositionService.LockingPosition lockingPosition);
    event IncreaseLockTime(
        uint256 tokenId,
        ILockingPositionService.LockingPosition lockingPosition,
        uint256 oldEndCycle
    );
    event IncreaseLockTimeAndAmount(
        uint256 tokenId,
        ILockingPositionService.LockingPosition lockingPosition,
        uint256 oldEndCycle
    );
    event UpdateTotalSupplies(uint256 newYsSupply, uint256 veCvgSupply, uint256 cycle);
    event LockingPositionBurn(uint256 tokenId);

    /// @dev Maximum locking time in cycle(weeks)
    uint256 internal constant MAX_LOCK = 96;

    uint256 internal constant MAX_PERCENTAGE = 100;

    uint256 internal constant MAX_LOCK_MUL_MAX_PERCENTAGE = 9_600;
    /// @dev TDE duration in weeks
    uint256 internal constant TDE_DURATION = 12;

    /// @dev percentage can only be set as multiple of this value
    uint256 internal constant RANGE_PERCENTAGE = 10;

    /// @dev Convergence ControlTower.
    ICvgControlTower public cvgControlTower;

    /// @dev Convergence CVG.
    ICvg public cvg;

    /// @dev Voting Power Escrow.
    IVotingPowerEscrow public veCvg;

    /// @dev Locking Position Manager
    ILockingPositionManager public lockingPositionManager;

    /// @dev Locking Position Delegate
    ILockingPositionDelegate public lockingPositionDelegate;

    /// @dev Cvg Rewards
    ICvgRewards public cvgRewards;

    /// @dev  Keeps global data of a LockingPosition.
    mapping(uint256 => ILockingPositionService.LockingPosition) public lockingPositions; // tokenId => LockingPosition

    mapping(uint256 => ILockingPositionService.Checkpoints[]) public checkpoints; // tokenId => ysCheckpoints

    /// @dev Keep track of the ySCvg supply changes for each cycle, so we can compute the totalSupply of ysCvg at each cycle.
    mapping(uint256 => ILockingPositionService.TrackingBalance) public totalSuppliesTracking;

    /// @dev Keep track of the ysCvg supply at each cycle.
    mapping(uint256 => uint256) public totalSupplyYsCvgHistories;

    /// @dev Multisig or contracts able to lock CVG
    mapping(address => bool) public isContractLocker; // Address => bool

    /// @dev Special contracts able to ( bonds for instance ) chaining locking.
    mapping(address => bool) public isSpecialLocker; // Address => bool

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with the ConvergenceControlTower address, set the cvgToken address, transfer ownership to the initializer.
     * @param _cvgControlTower ConvergenceControlTower address.
     */
    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        _transferOwnership(msg.sender);
        ICvg _cvg = _cvgControlTower.cvgToken();
        require(address(_cvg) != address(0), "CVG_ZERO");
        cvg = _cvg;

        ILockingPositionManager _lockingPositionManager = _cvgControlTower.lockingPositionManager();
        require(address(_lockingPositionManager) != address(0), "LOCKING_POSITION_MANAGER_ZERO");
        lockingPositionManager = _lockingPositionManager;

        ILockingPositionDelegate _lockingPositionDelegate = _cvgControlTower.lockingPositionDelegate();
        require(address(_lockingPositionDelegate) != address(0), "DELEGATION_ZERO");
        lockingPositionDelegate = _lockingPositionDelegate;
    }

    /**
     * @dev Some methods that are called by wallet ,
     * can also be called by cvgUtilities meta functionalities
     * this modifier allow to check both case.
     */
    modifier onlyWalletOrWhiteListedContract() {
        _onlyWalletOrWhiteListedContract();
        _;
    }

    /**
     * @notice Check if the caller is a wallet or a whitelisted contract.
     */
    function _onlyWalletOrWhiteListedContract() internal view {
        require(
            // solhint-disable-next-line avoid-tx-origin
            msg.sender == tx.origin || isContractLocker[msg.sender],
            "NOT_CONTRACT_OR_WL"
        );
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            INFO
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    struct LockingInfo {
        uint256 tokenId;
        uint256 cvgLocked;
        uint256 lockEnd;
        uint256 ysPercentage;
        uint256 mgCvg;
    }

    /**
     *   @notice Get position information for a given tokenId, used by the CVG display of the token.
     *   @param tokenId is the token ID of the position.
     */
    function lockingInfo(uint256 tokenId) external view returns (LockingInfo memory) {
        uint256 _cvgCycle = cvgControlTower.cvgCycle();
        ILockingPositionService.LockingPosition memory _lockingPosition = lockingPositions[tokenId];
        uint256 tokenLastEndCycle = _lockingPosition.lastEndCycle;

        return
            LockingInfo({
                tokenId: tokenId,
                cvgLocked: _lockingPosition.totalCvgLocked,
                lockEnd: tokenLastEndCycle,
                ysPercentage: _lockingPosition.ysPercentage,
                mgCvg: _cvgCycle > tokenLastEndCycle ? 0 : _lockingPosition.mgCvgAmount
            });
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        PUBLIC FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Mint a locking position (ERC721) for the user.
     * @dev Lock can't be greater than the Maximum locking time / The end of the lock must finish on a TDE event cycle |  The percentage of ys determines the repartition in veCVG,mgCVG/YsCVG.
     * @param lockDuration is the duration in cycle(week) of the lock.
     * @param amount is the amount of cvg to lock in the position.
     * @param ysPercentage percentage of lock dedicated to treasury shares (ysCVG).
     * @param receiver address of the receiver of the locking position.
     * @param isAddToManagedTokens add the created token in managed tokens(voting power)  directly.
     */
    function mintPosition(
        uint24 lockDuration,
        uint128 amount,
        uint8 ysPercentage,
        address receiver,
        bool isAddToManagedTokens
    ) external onlyWalletOrWhiteListedContract {
        require(amount > 0, "LTE");
        /** @dev Percentage cannot be over 100%. */
        require(ysPercentage <= MAX_PERCENTAGE, "YS_%_OVER_100");
        /** @dev Only percentage with multiple of 10 are possible to use. */
        require(ysPercentage % RANGE_PERCENTAGE == 0, "YS_%_10_MULTIPLE");
        /** @dev Lock cannot be longer than MAX_LOCK. */
        require(lockDuration <= MAX_LOCK, "MAX_LOCK_96_CYCLES");
        /// @dev Lock duration cannot be zero
        require(lockDuration != 0, "LOCK_DURATION_ZERO");

        /** @dev Retrieve actual staking cycle. */
        uint24 actualCycle = uint24(cvgRewards.getCycleLocking(block.timestamp));
        uint24 endLockCycle = actualCycle + lockDuration;
        /** @dev End of lock must finish on TDE. */
        require(endLockCycle % TDE_DURATION == 0, "END_MUST_BE_TDE_MULTIPLE");

        /// @dev get the nextId on the LockingPosition manager
        uint256 tokenId = lockingPositionManager.mint(receiver);

        uint96 _mgCvgCreated;
        /// @dev Update checkpoints for YsCvg TotalSupply and Supply by NFT.
        if (ysPercentage != 0) {
            _ysCvgCheckpointMint(tokenId, lockDuration, amount * ysPercentage, actualCycle, endLockCycle);
        }

        /// @dev Create voting power through Curve contract, link voting power to the  token (NFT).
        if (ysPercentage != MAX_PERCENTAGE) {
            uint256 amountVote = amount * (MAX_PERCENTAGE - ysPercentage);

            /// @dev Creates the lock until the end of the ending cycle.
            /// @dev Unlocking is available at the beginning of endCycle+1
            veCvg.create_lock(
                tokenId,
                amountVote / MAX_PERCENTAGE,
                block.timestamp + (uint256(lockDuration) + 1) * 7 days
            );
            /// @dev compute the amount of mgCvg
            _mgCvgCreated = uint96((amountVote * lockDuration) / MAX_LOCK_MUL_MAX_PERCENTAGE);

            /// @dev Automatically add the veCVG and mgCVG in the balance taken from Snapshot.
            if (isAddToManagedTokens) {
                lockingPositionDelegate.addTokenAtMint(tokenId, receiver);
            }
        }

        ILockingPositionService.LockingPosition memory lockingPosition = ILockingPositionService.LockingPosition({
            startCycle: actualCycle,
            lastEndCycle: endLockCycle,
            totalCvgLocked: uint104(amount),
            mgCvgAmount: _mgCvgCreated,
            ysPercentage: ysPercentage
        });

        /// @dev Associate this Locking position on the tokenId.
        lockingPositions[tokenId] = lockingPosition;

        /// @dev Transfer CVG from user wallet to here.
        cvg.transferFrom(msg.sender, address(this), amount);

        emit MintLockingPosition(tokenId, lockingPosition);
    }

    /**
     * @notice Increase the amount of CVG token in the locking position proportionally from the actual cycle to the end of lock.
     * @dev We don't check the timelocking on the TokenId on this function, as an amount increase cannot be detrimental to a potential buyer.
     * @param tokenId is the token ID of the position to extend
     * @param amount  of cvg to add to the position
     * @param operator address of token owner (used when call from a special Locker contract)
     */
    function increaseLockAmount(
        uint256 tokenId,
        uint128 amount,
        address operator
    ) external onlyWalletOrWhiteListedContract {
        operator = isSpecialLocker[msg.sender] ? operator : msg.sender;
        lockingPositionManager.checkOwnership(tokenId, operator);

        require(amount > 0, "LTE");

        ILockingPositionService.LockingPosition memory lockingPosition = lockingPositions[tokenId];

        /// @dev Retrieve actual staking cycle. */
        uint24 actualCycle = uint24(cvgRewards.getCycleLocking(block.timestamp));

        /// @dev Impossible to increase the lock in amount after the end of the lock. */
        require(lockingPosition.lastEndCycle > actualCycle, "LOCK_OVER");

        /// @dev YsCvg TotalSupply Part, access only if some % has been given to ys on the NFT.
        if (lockingPosition.ysPercentage != 0) {
            _ysCvgCheckpointIncrease(
                tokenId,
                lockingPosition.lastEndCycle - actualCycle,
                amount * lockingPosition.ysPercentage,
                actualCycle,
                lockingPosition.lastEndCycle
            );
        }

        /** @dev Update voting power through Curve contract, link voting power to the nft tokenId. */
        if (lockingPosition.ysPercentage != MAX_PERCENTAGE) {
            uint256 amountVote = amount * (MAX_PERCENTAGE - lockingPosition.ysPercentage);
            veCvg.increase_amount(tokenId, amountVote / MAX_PERCENTAGE);

            lockingPosition.mgCvgAmount += uint96(
                (amountVote * (lockingPosition.lastEndCycle - actualCycle)) / MAX_LOCK_MUL_MAX_PERCENTAGE
            );
        }

        /** @dev Update cvgLocked balance. */
        lockingPosition.totalCvgLocked += uint104(amount);

        lockingPositions[tokenId] = lockingPosition;

        /** @dev Transfer CVG from user wallet to here. */
        cvg.transferFrom(msg.sender, address(this), amount);

        emit IncreaseLockAmount(tokenId, lockingPosition);
    }

    /**
     * @notice Increase the time of the lock
     *         Increasing the locking time will not increase the amount of ysCvg & mgCvg
     *         The amounts will be just extended on the new duration.
     * @dev The token must not be time locked  , as an increase in time can be detrimental to a potential buyer.
     * @param tokenId is the token ID of the position
     * @param durationAdd is the number of cycle to add to the position lockingTime
     */
    function increaseLockTime(uint256 tokenId, uint256 durationAdd) external onlyWalletOrWhiteListedContract {
        lockingPositionManager.checkFullCompliance(tokenId, msg.sender);
        ///  @dev Retrieve actual staking cycle.
        uint24 actualCycle = uint24(cvgRewards.getCycleLocking(block.timestamp));

        ILockingPositionService.LockingPosition memory lockingPosition = lockingPositions[tokenId];
        uint256 oldEndCycle = lockingPosition.lastEndCycle + 1;
        uint256 newEndCycle = oldEndCycle + durationAdd;

        ///  @dev Not possible extend a lock in duration after it's expiration.
        require(oldEndCycle > actualCycle, "LOCK_TIME_OVER");

        ///  @dev Not possible to have an active lock longer than the MAX_LOCK.
        require(newEndCycle - actualCycle - 1 <= MAX_LOCK, "MAX_LOCK_96_CYCLES");

        ///  @dev As the oldEnd cycle is a xTDE_DURATION. */
        ///  @dev We just need to verify that the time we add is a xTDE_DURATION to ensure new lock is ending on a xTDE_DURATION.
        require(durationAdd % TDE_DURATION == 0, "NEW_END_MUST_BE_TDE_MULTIPLE");

        /// @dev Addition of duration cannot be zero
        require(durationAdd != 0, "LOCK_DURATION_ZERO");

        /// @dev YsCvg TotalSupply Part, access only if some % has been given to ys on the NFT.
        if (lockingPosition.ysPercentage != 0) {
            /// @dev Retrieve the balance registered at the cycle where the ysBalance is supposed to drop.
            uint128 _ysToReport = uint128(balanceOfYsCvgAt(tokenId, oldEndCycle - 1));
            /** @dev Add this value to the tracking on the oldEndCycle. */
            totalSuppliesTracking[oldEndCycle].ysToAdd += _ysToReport;
            /** @dev Report this value in the newEndCycle in the Sub part. */
            totalSuppliesTracking[newEndCycle].ysToSub += _ysToReport;
        }

        /** @dev Vote part, access here only if some % has been given to ve/mg on the NFT. */
        if (lockingPosition.ysPercentage != MAX_PERCENTAGE) {
            /** @dev Increase Locking time to a new timestamp, computed with the cycle. */
            veCvg.increase_unlock_time(tokenId, block.timestamp + (uint256(newEndCycle - actualCycle) * 7 days));
        }

        /** @dev Update the new end cycle on the locking position. */
        lockingPositions[tokenId].lastEndCycle = uint24(newEndCycle - 1);

        lockingPosition.lastEndCycle = uint24(newEndCycle - 1);

        emit IncreaseLockTime(tokenId, lockingPosition, oldEndCycle - 1);
    }

    /**
     * @notice Increase first the time THEN the amount in the position proportionally from the actual cycle to the end of lock.
     * @dev The token must not be time locked, as an increase in the time can be detrimental to a potential buyer.
     * @param tokenId is the token ID of the position
     * @param durationAdd is the number of cycle to add to the position lockingTime
     * @param amount  of cvg to add to the position
     * @param operator address of token owner (used when call from a special contract)
     */
    function increaseLockTimeAndAmount(
        uint256 tokenId,
        uint24 durationAdd,
        uint128 amount,
        address operator
    ) external onlyWalletOrWhiteListedContract {
        operator = isSpecialLocker[msg.sender] ? operator : msg.sender;

        lockingPositionManager.checkFullCompliance(tokenId, operator);
        require(amount > 0, "LTE");

        /** @dev Retrieve actual staking cycle. */
        uint24 actualCycle = uint24(cvgRewards.getCycleLocking(block.timestamp));

        ILockingPositionService.LockingPosition memory lockingPosition = lockingPositions[tokenId];
        uint24 oldEndCycle = lockingPosition.lastEndCycle + 1;
        /** @dev Calculating the new end cycle. */
        uint24 newEndCycle = oldEndCycle + durationAdd;
        /** @dev Check  the new end cycle. */
        require(oldEndCycle > actualCycle, "LOCK_OVER");
        require(newEndCycle - actualCycle - 1 <= MAX_LOCK, "MAX_LOCK_96_CYCLES");
        require(durationAdd % TDE_DURATION == 0, "END_MUST_BE_TDE_MULTIPLE");
        /// @dev Addition of duration cannot be zero
        require(durationAdd != 0, "LOCK_DURATION_ZERO");

        if (lockingPosition.ysPercentage != 0) {
            /** @dev Taking in account the change of YsCvg TotalSupply update. */
            uint128 _ysToReport = uint128(balanceOfYsCvgAt(tokenId, oldEndCycle - 1));
            totalSuppliesTracking[oldEndCycle].ysToAdd += _ysToReport;
            totalSuppliesTracking[newEndCycle].ysToSub += _ysToReport;

            _ysCvgCheckpointIncrease(
                tokenId,
                newEndCycle - actualCycle - 1,
                amount * lockingPosition.ysPercentage,
                actualCycle,
                newEndCycle - 1
            );
        }

        if (lockingPosition.ysPercentage != MAX_PERCENTAGE) {
            /** @dev Update voting power through veCVG contract, link voting power to the nft tokenId. */
            uint256 amountVote = amount * (MAX_PERCENTAGE - lockingPosition.ysPercentage);
            lockingPosition.mgCvgAmount += uint96(
                (amountVote * (newEndCycle - actualCycle - 1)) / MAX_LOCK_MUL_MAX_PERCENTAGE
            );

            veCvg.increase_unlock_time_and_amount(
                tokenId,
                block.timestamp + (uint256(newEndCycle - actualCycle) * 7 days),
                amountVote / MAX_PERCENTAGE
            );
        }

        /** @dev Update the new end cycle on the locking position. */
        lockingPosition.lastEndCycle = newEndCycle - 1;
        lockingPosition.totalCvgLocked += uint104(amount);

        lockingPositions[tokenId] = lockingPosition;

        /** @dev Transfer CVG */
        cvg.transferFrom(msg.sender, address(this), amount);

        emit IncreaseLockTimeAndAmount(tokenId, lockingPosition, oldEndCycle - 1);
    }

    /**
     * @notice Unlock CVG tokens under the NFT Locking Position : Burn the NFT, Transfer back the CVG to the user.  Rewards from YsDistributor must be claimed before or they will be lost.    * @dev The locking time must be over
     * @param tokenId to burn
     */
    function burnPosition(uint256 tokenId) external {
        ILockingPositionService.LockingPosition memory lockingPosition = lockingPositions[tokenId];

        require(cvgControlTower.cvgCycle() > lockingPosition.lastEndCycle, "LOCKED");

        /** @dev  if the position contains veCvg , we must remove it from the voting escrow */
        if (lockingPosition.ysPercentage != MAX_PERCENTAGE) {
            veCvg.withdraw(tokenId);
        }

        /** @dev Burn the NFT representing the position. */
        lockingPositionManager.burn(tokenId, msg.sender);

        /** @dev Transfer CVG back to the user. */
        cvg.transfer(msg.sender, lockingPosition.totalCvgLocked);

        emit LockingPositionBurn(tokenId);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    ONLY CONTROL TOWER
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    /**
     * @notice Compute the new Ys total supply  by adding and subtracting checkpoints formerly created on mint & increaseLock by the _YsCvgCheckpoint().
     * @dev  Only callable by ControlTower ( DAO ).
     */
    function updateYsTotalSupply() external {
        require(msg.sender == address(cvgRewards), "NOT_CVG_REWARDS");
        uint256 actualCycle = cvgControlTower.cvgCycle();

        uint256 totalSupplyYsBeforeUpdate = totalSupplyYsCvgHistories[actualCycle - 1];
        /** @dev Update ysCVG  total supply with checkpoints for the actual cycle */
        totalSupplyYsCvgHistories[actualCycle] =
            totalSupplyYsBeforeUpdate +
            totalSuppliesTracking[actualCycle].ysToAdd -
            totalSuppliesTracking[actualCycle].ysToSub;

        emit UpdateTotalSupplies(totalSupplyYsBeforeUpdate, veCvg.total_supply(), actualCycle - 1);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    INTERNAL FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    function _ysCvgCheckpointMint(
        uint256 tokenId,
        uint24 lockDuration,
        uint128 cvgLockAmount,
        uint24 actualCycle,
        uint24 endLockCycle
    ) internal {
        /** @dev Compute the amount of ysCVG on this Locking Position proportionally with the ratio of lockDuration and MAX LOCK duration. */
        uint128 commonNum = lockDuration * cvgLockAmount;
        uint128 ysTotalAmount = uint128(commonNum / MAX_LOCK_MUL_MAX_PERCENTAGE);

        /// @dev realEndCycle is the cycle where we remove the ysAmount from the totalSupply.
        uint24 realEndCycle = endLockCycle + 1;
        uint24 nextTdeCycle = uint24((actualCycle / TDE_DURATION + 1) * TDE_DURATION);
        /// @dev If the lock is not made on a TDE cycle, we need to compute the partial amount of ysCVG  for the next TDE.
        if (actualCycle % TDE_DURATION != 0) {
            /// @dev Represent the amount of ysCvg to be taken into account on the next TDE of this LockingPosition.
            uint128 ysPartialAmount = uint128(
                ((nextTdeCycle - actualCycle) * commonNum) / (TDE_DURATION * MAX_LOCK_MUL_MAX_PERCENTAGE)
            );

            totalSuppliesTracking[nextTdeCycle].ysToAdd += ysPartialAmount;

            /// @dev We always push a checkpoint on the nextTDE with the partialAmount.
            checkpoints[tokenId].push(
                ILockingPositionService.Checkpoints({cycleId: nextTdeCycle, ysBalance: ysPartialAmount})
            );

            /// @dev When a lock is greater than a TDE_DURATION
            if (lockDuration > TDE_DURATION) {
                /// @dev We add in the tracking add, on next TDE + 1 TDE, the delta between full and partial, in order to get fullAmount on the TDE.
                totalSuppliesTracking[nextTdeCycle + TDE_DURATION].ysToAdd += ysTotalAmount - ysPartialAmount;
                /// @dev We add in the tracking sub on the end of the lock, the ysTotalAmount
                totalSuppliesTracking[realEndCycle].ysToSub += ysTotalAmount;

                checkpoints[tokenId].push(
                    ILockingPositionService.Checkpoints({
                        cycleId: uint24(nextTdeCycle + TDE_DURATION),
                        ysBalance: ysTotalAmount
                    })
                );
            }
            /// @dev If the lock less than TDE_DURATION.
            else {
                /// @dev We remove the amount from the supply calculation at the end of the TDE
                totalSuppliesTracking[realEndCycle].ysToSub += ysPartialAmount;
            }
        }
        /// @dev If the lock is performed on a TDE cycle, no need to compute partialAmount.
        else {
            totalSuppliesTracking[nextTdeCycle].ysToAdd += ysTotalAmount;
            totalSuppliesTracking[realEndCycle].ysToSub += ysTotalAmount;

            /// @dev We push a checkpoint on the nextTDE with the ysTotalAmount
            checkpoints[tokenId].push(
                ILockingPositionService.Checkpoints({cycleId: nextTdeCycle, ysBalance: ysTotalAmount})
            );
        }
    }

    /**
     *  @notice Compute the new Ys by adding and subtracting
     *   checkpoints formerly created on mint & increaseLock by the _YsCvgCheckpoint().
     *  @dev  Only callable by ControlTower ( DAO ).
     *  @param lockDuration is the duration in cycle(week) of the lock
     *  @param cvgLockAmount is the amount of cvg to lock in the position
     *  @param actualCycle is the actual cycle of the cvg
     *  @param endLockCycle is the end cycle of the lock
     */
    function _ysCvgCheckpointIncrease(
        uint256 tokenId,
        uint24 lockDuration,
        uint128 cvgLockAmount,
        uint24 actualCycle,
        uint24 endLockCycle
    ) internal {
        /** @dev Compute the amount of ysCVG on this Locking Position proportionally with the ratio of lockDuration and MAX LOCK duration. */
        uint128 commonNum = lockDuration * cvgLockAmount;
        uint128 ysTotalAmount = uint128(commonNum / MAX_LOCK_MUL_MAX_PERCENTAGE);
        uint24 realEndCycle = endLockCycle + 1;
        uint24 nextTdeCycle = uint24((actualCycle / TDE_DURATION + 1) * TDE_DURATION);

        uint256 checkpointsLength = checkpoints[tokenId].length;
        ILockingPositionService.Checkpoints memory lastCheckpoint = checkpoints[tokenId][checkpointsLength - 1];

        // @dev If the lock is not made on a TDE cycle, we need to compute the partial amount of ys for the next TDE.
        if (actualCycle % TDE_DURATION != 0) {
            /** @dev Represent the amount of ysCvg to be taken into account on the next TDE of this LockingPosition. */
            uint128 ysPartialAmount = uint128(
                ((nextTdeCycle - actualCycle) * commonNum) / (TDE_DURATION * MAX_LOCK_MUL_MAX_PERCENTAGE)
            );

            totalSuppliesTracking[nextTdeCycle].ysToAdd += ysPartialAmount;

            /** @dev When a lock is greater than a TDE_DURATION */
            if (lockDuration >= TDE_DURATION) {
                /** @dev we add the calculations for the next full TDE */
                totalSuppliesTracking[nextTdeCycle + TDE_DURATION].ysToAdd += ysTotalAmount - ysPartialAmount;
                totalSuppliesTracking[realEndCycle].ysToSub += ysTotalAmount;
                /// @dev If there is only one checkpoint
                if (checkpointsLength == 1) {
                    if (lastCheckpoint.cycleId == nextTdeCycle) {
                        /// @dev update last checkpoint with partial
                        checkpoints[tokenId][checkpointsLength - 1].ysBalance =
                            lastCheckpoint.ysBalance +
                            ysPartialAmount;
                    } else {
                        checkpoints[tokenId].push(
                            ILockingPositionService.Checkpoints({
                                cycleId: nextTdeCycle,
                                ysBalance: lastCheckpoint.ysBalance + ysPartialAmount
                            })
                        );
                    }

                    checkpoints[tokenId].push(
                        ILockingPositionService.Checkpoints({
                            cycleId: uint24(nextTdeCycle + TDE_DURATION),
                            ysBalance: lastCheckpoint.ysBalance + ysTotalAmount
                        })
                    );
                }
                /// @dev Else there are more than 1 checkpoint
                else {
                    uint256 _tokenId = tokenId;
                    /// @dev Both cycle in common
                    if (
                        checkpoints[_tokenId][checkpointsLength - 2].cycleId == nextTdeCycle &&
                        lastCheckpoint.cycleId == nextTdeCycle + TDE_DURATION
                    ) {
                        checkpoints[_tokenId][checkpointsLength - 2].ysBalance += ysPartialAmount;
                        checkpoints[_tokenId][checkpointsLength - 1].ysBalance += ysTotalAmount;
                    }
                    /// @dev If the last checkpoint is the nextTdeCycle but the second to last checkpoint is not the
                    else if (lastCheckpoint.cycleId == nextTdeCycle) {
                        checkpoints[_tokenId][checkpointsLength - 1].ysBalance += ysPartialAmount;
                        checkpoints[_tokenId].push(
                            ILockingPositionService.Checkpoints({
                                cycleId: uint24(nextTdeCycle + TDE_DURATION),
                                ysBalance: lastCheckpoint.ysBalance + ysTotalAmount
                            })
                        );
                    }
                    /// @dev Else no cycles in common
                    else {
                        checkpoints[_tokenId].push(
                            ILockingPositionService.Checkpoints({
                                cycleId: nextTdeCycle,
                                ysBalance: lastCheckpoint.ysBalance + ysPartialAmount
                            })
                        );

                        checkpoints[_tokenId].push(
                            ILockingPositionService.Checkpoints({
                                cycleId: uint24(nextTdeCycle + TDE_DURATION),
                                ysBalance: lastCheckpoint.ysBalance + ysTotalAmount
                            })
                        );
                    }
                }
            }
            /// @dev Else the lock remaining is smaller than a TDE
            else {
                /// @dev We need to remove the ysPartial after the nextTDE
                totalSuppliesTracking[realEndCycle].ysToSub += ysPartialAmount;

                /// @dev If the last checkpoint is not already pushed
                if (lastCheckpoint.cycleId != nextTdeCycle) {
                    checkpoints[tokenId].push(
                        ILockingPositionService.Checkpoints({
                            cycleId: nextTdeCycle,
                            ysBalance: lastCheckpoint.ysBalance + ysPartialAmount
                        })
                    );
                }
                /// @dev Else we just increment the ysBalance in the checkpoint.
                else {
                    checkpoints[tokenId][checkpointsLength - 1].ysBalance += ysPartialAmount;
                }
            }
        }
        /// @dev If the remaining or new time of locking is a TDE_DURATION multiple
        else {
            /// @dev Add amount for the ysTotal on the next cycle, no partial are needed.
            totalSuppliesTracking[nextTdeCycle].ysToAdd += ysTotalAmount;
            totalSuppliesTracking[realEndCycle].ysToSub += ysTotalAmount;

            /// @dev If nextTde older than last checkpoint.
            if (lastCheckpoint.cycleId != nextTdeCycle) {
                checkpoints[tokenId].push(
                    ILockingPositionService.Checkpoints({
                        cycleId: nextTdeCycle,
                        ysBalance: lastCheckpoint.ysBalance + ysTotalAmount
                    })
                );
            }
            /// @dev If the last checkpoint is already the nextTde, we just update it's ysAmount
            else {
                checkpoints[tokenId][checkpointsLength - 1].ysBalance += ysTotalAmount;
            }
        }
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        VIEW FUNCTIONS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *   @notice Returns the information needed to display the lock position display svg.
     *   @param _tokenId id of the token
     */
    function tokenInfos(uint256 _tokenId) external view returns (ILockingPositionService.TokenView memory) {
        ILockingPositionService.LockingPosition memory _lockingPosition = lockingPositions[_tokenId];
        uint256 _cvgCycle = cvgControlTower.cvgCycle();

        return
            ILockingPositionService.TokenView({
                tokenId: _tokenId,
                cvgLocked: _lockingPosition.totalCvgLocked,
                startCycle: _lockingPosition.startCycle,
                endCycle: _lockingPosition.lastEndCycle,
                veCvgActual: veCvg.balanceOf(_tokenId),
                ysTotal: balanceOfYsCvgAt(_tokenId, _lockingPosition.lastEndCycle),
                ysActual: balanceOfYsCvgAt(_tokenId, _cvgCycle),
                mgCvg: _cvgCycle > _lockingPosition.lastEndCycle ? 0 : _lockingPosition.mgCvgAmount,
                ysPercentage: _lockingPosition.ysPercentage
            });
    }

    /**
     * @notice Fetch the balance of veCVG (gauge voting power)  for a specified tokenId.
     * @param _tokenId id of the token
     */
    function balanceOfVeCvg(uint256 _tokenId) public view returns (uint256) {
        return veCvg.balanceOf(_tokenId);
    }

    /**
     * @notice Fetch the balance of ysCVG (treasury share)  for a specified tokenId and at a specified cycle, can be in the future.
     * @param _tokenId id of the token
     * @param _cycleId id of the cycle
     */
    function balanceOfYsCvgAt(uint256 _tokenId, uint256 _cycleId) public view returns (uint256) {
        require(_cycleId != 0, "NOT_EXISTING_CYCLE");

        ILockingPositionService.LockingPosition memory _lockingPosition = lockingPositions[_tokenId];
        uint256 checkpointsLength = checkpoints[_tokenId].length;
        uint256 ysBalance;
        /// @dev If the requested cycle is before the beginning of the lock or after the end of the lock. The balance in ysCVG is so 0.
        if (_lockingPosition.startCycle >= _cycleId || _lockingPosition.lastEndCycle < _cycleId) {
            return 0;
        }

        /// @dev We iterate from the last index of the checkpoints
        for (uint256 i = checkpointsLength; i != 0; ) {
            ILockingPositionService.Checkpoints memory cycleCheckpoint = checkpoints[_tokenId][i - 1];
            if (cycleCheckpoint.cycleId <= _cycleId) {
                ysBalance = cycleCheckpoint.ysBalance;
                break;
            }
            unchecked {
                --i;
            }
        }
        return ysBalance;
    }

    /**
     * @notice Fetch the balance of mgCVG (meta-governance voting power ) for a specified tokenId.
     * @param _tokenId id of the token
     */
    function balanceOfMgCvg(uint256 _tokenId) public view returns (uint256) {
        uint256 cycleId = cvgControlTower.cvgCycle();
        ILockingPositionService.LockingPosition memory _lockingPosition = lockingPositions[_tokenId];

        /** @dev If the requested cycle is before or after the lock , there is no balance. */
        if (_lockingPosition.startCycle > cycleId || cycleId > _lockingPosition.lastEndCycle) {
            return 0;
        }

        return _lockingPosition.mgCvgAmount;
    }

    /**
     *   @notice Fetch the voting power (in veCvg) for a specified address, used in the Cvg Governance proposal strategy.
     *   @param _user is the address that we want to fetch voting power from
     */
    function veCvgVotingPowerPerAddress(address _user) external view returns (uint256) {
        uint256 _totalVotingPower;
        ILockingPositionDelegate _lockingPositionDelegate = lockingPositionDelegate;
        ILockingPositionManager _lockingPositionManager = lockingPositionManager;

        (uint256[] memory tokenIdsOwneds, uint256[] memory tokenIdsDelegateds) = _lockingPositionDelegate
            .getTokenVeOwnedAndDelegated(_user);

        /** @dev Sum voting power from delegated tokenIds to _user. */
        for (uint256 i; i < tokenIdsDelegateds.length; ) {
            uint256 _tokenId = tokenIdsDelegateds[i];
            /** @dev Check if is really delegated, if not ve voting power for this tokenId is 0. */
            if (_user == _lockingPositionDelegate.delegatedVeCvg(_tokenId)) {
                _totalVotingPower += balanceOfVeCvg(_tokenId);
            }

            unchecked {
                ++i;
            }
        }

        /** @dev Sum voting power from _user owned tokenIds. */
        for (uint256 i; i < tokenIdsOwneds.length; ) {
            uint256 _tokenId = tokenIdsOwneds[i];
            /** @dev Check if is really owned AND not delegated to another user,if not ve voting power for this tokenId is 0. */
            if (
                _lockingPositionDelegate.delegatedVeCvg(_tokenId) == address(0) &&
                _user == _lockingPositionManager.ownerOf(_tokenId)
            ) {
                _totalVotingPower += balanceOfVeCvg(_tokenId);
            }

            unchecked {
                ++i;
            }
        }

        return _totalVotingPower;
    }

    /**
     * @notice Fetch the voting power (in mgCVG) for a specified address, used in Meta-governance  strategy
     * @param _user is the address that we want to fetch voting power from
     */
    function mgCvgVotingPowerPerAddress(address _user) public view returns (uint256) {
        uint256 _totalMetaGovernance;

        ILockingPositionDelegate _lockingPositionDelegate = lockingPositionDelegate;
        ILockingPositionManager _lockingPositionManager = lockingPositionManager;

        (uint256[] memory tokenIdsOwneds, uint256[] memory tokenIdsDelegateds) = _lockingPositionDelegate
            .getTokenMgOwnedAndDelegated(_user);

        /** @dev Sum voting power from delegated (allowed) tokenIds to _user. */
        for (uint256 i; i < tokenIdsDelegateds.length; ) {
            uint256 _tokenId = tokenIdsDelegateds[i];
            (uint256 _toPercentage, , uint256 _toIndex) = _lockingPositionDelegate.getMgDelegateeInfoPerTokenAndAddress(
                _tokenId,
                _user
            );
            /** @dev Check if is really delegated, if not mg voting power for this tokenId is 0. */
            if (_toIndex < 999) {
                uint256 _tokenBalance = balanceOfMgCvg(_tokenId);
                _totalMetaGovernance += (_tokenBalance * _toPercentage) / MAX_PERCENTAGE;
            }

            unchecked {
                ++i;
            }
        }

        /** @dev Sum voting power from _user owned (allowed) tokenIds. */
        for (uint256 i; i < tokenIdsOwneds.length; ) {
            uint256 _tokenId = tokenIdsOwneds[i];
            /** @dev Check if is really owned,if not mg voting power for this tokenId is 0. */
            if (_user == _lockingPositionManager.ownerOf(_tokenId)) {
                (, uint256 _totalPercentageDelegated, ) = _lockingPositionDelegate.getMgDelegateeInfoPerTokenAndAddress(
                    _tokenId,
                    _user
                );
                uint256 _tokenBalance = balanceOfMgCvg(_tokenId);

                _totalMetaGovernance += (_tokenBalance * (MAX_PERCENTAGE - _totalPercentageDelegated)) / MAX_PERCENTAGE;
            }

            unchecked {
                ++i;
            }
        }

        return _totalMetaGovernance;
    }

    /**
     * @notice Get the supply of YsCvg at a given cycle, can be in the future.
     * @param _at cycle requested
     */
    function totalSupplyOfYsCvgAt(uint256 _at) public view returns (uint256) {
        require(_at != 0, "NOT_EXISTING_CYCLE");

        uint256 actualCycle = cvgControlTower.cvgCycle();
        uint256 _ysCvgAt;

        if (actualCycle <= _at) {
            /** @dev If the requested cycle is in the future/actual cycle, we compute the future balance with the tracking. */
            /** @dev Start from the last known totalSupply . */
            _ysCvgAt = totalSupplyYsCvgHistories[actualCycle - 1];
            for (uint256 i = actualCycle; i <= _at; ) {
                _ysCvgAt += totalSuppliesTracking[i].ysToAdd;
                _ysCvgAt -= totalSuppliesTracking[i].ysToSub;
                ++i;
            }
        } else {
            /** @dev If the requested cycle is in the past, we can directly return the balance. */
            _ysCvgAt = totalSupplyYsCvgHistories[_at];
        }
        return _ysCvgAt;
    }

    /**
     * @notice Get the total supply of ysCVG AND the ysCVG balance of a position, for a given cycle.
     * @dev    The totalSupply cannot be fetched in the future here.
     * @param tokenId Token Id of the position to fetch the ysBalance on.
     * @param cycleId Cycle Id to fetch the ysBalance and totalSupply.
     */
    function getTotalSupplyHistoryAndBalanceOfYs(
        uint256 tokenId,
        uint256 cycleId
    ) external view returns (uint256, uint256) {
        return (totalSupplyYsCvgHistories[cycleId], balanceOfYsCvgAt(tokenId, cycleId));
    }

    /**
     * @notice Get the total supply of ysCVG AND the ysCVG balance of a position, for a given cycle.
     * @dev    The totalSupply can be fetched in the future here.
     * @param tokenId Token Id of the position to fetch the ysBalance on.
     * @param cycleId Cycle Id to fetch the ysBalance and totalSupply.
     */
    function getTotalSupplyAtAndBalanceOfYs(uint256 tokenId, uint256 cycleId) external view returns (uint256, uint256) {
        return (totalSupplyOfYsCvgAt(cycleId), balanceOfYsCvgAt(tokenId, cycleId));
    }

    /**
     * @notice  Add/remove a contract address to the whitelist. This contract will be able to perform locks on the LockingPositionService.
     * @param contractWL Address of the contract of multisig to WL.
     */
    function toggleContractLocker(address contractWL) external onlyOwner {
        isContractLocker[contractWL] = !isContractLocker[contractWL];
    }

    /**
     * @notice  Add/remove a special locker
     * @dev     Special lockers are contracts from Convergence calling locking functions here and changing the nominal behavior of the functions.
     * @param specialLocker Address of the special locker to activate/deactivate
     */
    function toggleSpecialLocker(address specialLocker) external onlyOwner {
        isSpecialLocker[specialLocker] = !isSpecialLocker[specialLocker];
        isContractLocker[specialLocker] = !isContractLocker[specialLocker];
    }

    function setCvgRewards(ICvgRewards _cvgRewards) external onlyOwner {
        cvgRewards = _cvgRewards;
    }

    function setVotingPowerEscrow(IVotingPowerEscrow _veCvg) external onlyOwner {
        veCvg = _veCvg;
    }
}
