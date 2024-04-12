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

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/ICvgControlTower.sol";
import "../interfaces/IYsDistributor.sol";

/**
 * @title Cvg-Finance - YsDistributor
 * @notice This contract is used to distribute rewards to locking positions (with YsCvg values).
 */
contract YsDistributor is Initializable {
    using SafeERC20 for IERC20;

    event DepositedTokens(uint256 cycleId, IYsDistributor.TokenAmount[] tokens);
    /// @dev Event for claimed tokens.
    event TokensClaim(uint256 tokenId, uint256 tde, IYsDistributor.TokenAmount[] tokens);

    /// @dev Cvg control tower.
    ICvgControlTower public cvgControlTower;

    ILockingPositionService public lockingPositionService;

    ILockingPositionManager public lockingPositionManager;

    ILockingPositionDelegate public lockingPositionDelegate;

    /// @dev Duration for one TDE => 12 Cycles.
    uint256 public constant TDE_DURATION = 12;

    /// @dev Tracking  claimed  position by TDE
    mapping(uint256 => mapping(uint256 => bool)) public rewardsClaimedForToken;

    /// @dev Tracking reward tokens address deposited by TDE
    mapping(uint256 => IYsDistributor.TokenAmount[]) public depositedTokens;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with the CvgControlTower address and the CVG token address.
     * @param _cvgControlTower address of the CvgControlTower contract
     */
    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        ILockingPositionService _lockingPositionService = _cvgControlTower.lockingPositionService();
        ILockingPositionManager _lockingPositionManager = _cvgControlTower.lockingPositionManager();
        ILockingPositionDelegate _lockingPositionDelegate = _cvgControlTower.lockingPositionDelegate();
        require(address(_lockingPositionService) != address(0), "LOCKING_SERVICE_ZERO");
        require(address(_lockingPositionManager) != address(0), "LOCKING_MANAGER_ZERO");
        require(address(_lockingPositionDelegate) != address(0), "LOCKING_DELEGATE_ZERO");
        lockingPositionService = _lockingPositionService;
        lockingPositionManager = _lockingPositionManager;
        lockingPositionDelegate = _lockingPositionDelegate;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            MODIFIERS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    modifier onlyTreasuryPdd() {
        require(msg.sender == cvgControlTower.treasuryPdd(), "NOT_TREASURY_PDD");
        _;
    }

    /* -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                    EXTERNALS ONLY TREASURY PDD
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice Deposit tokens in this contracts, these tokens will be be distributed at the next TDE.
     *  @dev Function only callable by TreasuryPdd / update and save tokens amount depending to cycles and TDE events.
     *  @param deposits Struct which contains an array of token(s) and their associated amount(s) to deposit
     */
    function depositMultipleToken(IYsDistributor.TokenAmount[] calldata deposits) external onlyTreasuryPdd {
        uint256 _actualCycle = cvgControlTower.cvgCycle();
        uint256 _actualTDE = _actualCycle % TDE_DURATION == 0
            ? _actualCycle / TDE_DURATION
            : (_actualCycle / TDE_DURATION) + 1;

        IYsDistributor.TokenAmount[] memory alreadyStored = depositedTokens[_actualTDE];
        uint256 tokensLength = alreadyStored.length;

        for (uint256 i; i < deposits.length; ) {
            IERC20 _token = deposits[i].token;
            uint96 _amount = deposits[i].amount;

            /// @dev Checks whether the token is present in depositedTokenAddressForTde, otherwise we add it.
            bool found;
            for (uint256 j; j < tokensLength; ) {
                if (_token == alreadyStored[j].token) {
                    found = true;
                    depositedTokens[_actualTDE][j].amount += _amount;
                    break;
                }
                unchecked {
                    ++j;
                }
            }

            if (!found) {
                depositedTokens[_actualTDE].push(IYsDistributor.TokenAmount({token: _token, amount: _amount}));
            }

            /// @dev Transfer tokens.
            _token.safeTransferFrom(msg.sender, address(this), _amount);

            unchecked {
                ++i;
            }
        }
        emit DepositedTokens(_actualCycle, deposits);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Claim the associated rewards to the locking position NFT.
     *  @dev  YsTotalSupply ( at the TDE ) |  Ys reward is computed by CvgRewards contract
     *  |   Bond Treasury Yield is computed and sent.
     * @param tokenId is the token ID to claim rewards of
     * @param tdeId is the TDE that will be processed
     * @param receiver is the address that will receive the rewards
     */
    function claimRewards(uint256 tokenId, uint256 tdeId, address receiver) external {
        lockingPositionManager.checkYsClaim(tokenId, msg.sender);

        uint256 cycleClaimed = tdeId * TDE_DURATION;

        /// @dev Cannot claim a TDE not available yet.
        require(cvgControlTower.cvgCycle() > cycleClaimed, "TDE_NOT_AVAILABLE");

        /// @dev Cannot claim twice rewards for a TDE.
        require(!rewardsClaimedForToken[tokenId][tdeId], "TDE_ALREADY_CLAIMED");

        /// @dev Get the totalSupply and the balance of position in ysCVG
        (uint256 totalSupply, uint256 balance) = lockingPositionService.getTotalSupplyHistoryAndBalanceOfYs(
            tokenId,
            cycleClaimed
        );

        /// @dev Cannot claim a Ys rewards if Locking position has no ys value at asked cycle.
        require(balance != 0, "NO_YS_BALANCE_ON_THIS_TDE");

        /// @dev Mark the TDE id for this token as claimed on the Storage.
        rewardsClaimedForToken[tokenId][tdeId] = true;

        /// @dev Claim according token rewards.
        IYsDistributor.TokenAmount[] memory _tokenAmounts = depositedTokens[tdeId];
        uint256 tokensLength = _tokenAmounts.length;

        for (uint256 i; i < tokensLength; ) {
            IERC20 _token = IERC20(_tokenAmounts[i].token);
            uint96 _amountUser = uint96((_tokenAmounts[i].amount * balance) / totalSupply);

            _tokenAmounts[i] = IYsDistributor.TokenAmount({token: _token, amount: _amountUser});

            _token.safeTransfer(receiver, _amountUser);

            unchecked {
                ++i;
            }
        }

        emit TokensClaim(tokenId, tdeId, _tokenAmounts);
    }

    /**
     * @notice Calculate the reward amount for a token depending the share of the user.
     * @param _tdeId desired tdeId to calculate reward amount for
     **/
    function getAllRewardsForTde(uint256 _tdeId) external view returns (IYsDistributor.TokenAmount[] memory) {
        return depositedTokens[_tdeId];
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            PUBLIC
    / =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Obtains all ERC20 reward tokens for a list of TDEs for a tokenId
     * @param _tdeIds TDE Ids to claim
     * @param _tokenId of the locking position
     */
    function getPositionRewardsForTdes(
        uint256[] calldata _tdeIds,
        uint256 actualCycle,
        uint256 _tokenId
    ) external view returns (IYsDistributor.Claim[] memory) {
        ILockingPositionService _lockingPositionService = lockingPositionService;
        if (_lockingPositionService.lockingPositions(_tokenId).ysPercentage == 0) {
            return new IYsDistributor.Claim[](0);
        }
        IYsDistributor.Claim[] memory tokenClaimDetails = new IYsDistributor.Claim[](_tdeIds.length);

        uint256 counter;

        for (uint256 i; i < _tdeIds.length; ) {
            uint256 tdeId = _tdeIds[i];
            uint256 cycleTde = _tdeIds[i] * TDE_DURATION;

            (uint256 totalSupply, uint256 balance) = _lockingPositionService.getTotalSupplyAtAndBalanceOfYs(
                _tokenId,
                cycleTde
            );

            if (balance == 0 || actualCycle <= cycleTde) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    /// @dev this reduce the length of the array to not return some useless 0 at the end
                    mstore(tokenClaimDetails, sub(mload(tokenClaimDetails), 1))
                }
            } else {
                IYsDistributor.TokenAmount[] memory totalDistributed = depositedTokens[tdeId];

                /// @dev Else, we have to return the weighted value

                for (uint256 j; j < totalDistributed.length; ) {
                    totalDistributed[j].amount = uint96((totalDistributed[j].amount * balance) / totalSupply);
                    unchecked {
                        ++j;
                    }
                }

                tokenClaimDetails[counter++] = IYsDistributor.Claim({
                    tdeCycle: tdeId,
                    isClaimed: rewardsClaimedForToken[_tokenId][tdeId],
                    tokenAmounts: totalDistributed
                });
            }

            unchecked {
                ++i;
            }
        }

        return tokenClaimDetails;
    }
}
