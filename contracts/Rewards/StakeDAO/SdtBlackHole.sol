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

/// @title Cvg-Finance - SdtBlackHole
/// @notice Receives all StakeDAO gauge tokens staked through all SdtStakingPositionServices
///         Convergence socializes the boost from veSDT holding by delegating the boost on this contract
///         Receives all Bribe rewards coming from the MultiMerkleStash and dispatches them to the corresponding buffers
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../interfaces/ISdAssets.sol";
import "../../interfaces/ICvgControlTower.sol";

interface DelegateRegistry {
    function setDelegate(bytes32 id, address delegate) external;

    function clearDelegate(bytes32 id) external;
}

contract SdtBlackHole is Ownable2StepUpgradeable {
    struct BribeToken {
        IERC20 token;
        uint96 fee;
    }
    /// @dev StakeDao delegate registry
    DelegateRegistry public constant stakeDelegateRegistry =
        DelegateRegistry(0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446);
    uint256 internal constant BASE_FEES = 100_000;

    /// @dev Convergence ecosystem address
    ICvgControlTower public cvgControlTower;

    /// @dev StakeDao token
    IERC20 public sdt;

    /// @dev allows to know if an address is a Gauge asset token
    mapping(address => bool) public isGaugeAsset;

    /// @dev allows to know if an address is an SdtBuffer
    mapping(address => bool) public isBuffer;

    //// @dev allows to know all the bribes tokens linked to a buffer if a token is already setup on a buffer
    mapping(address => BribeToken[]) public bribeTokensLinkedToBuffer;

    /// @notice event emited when the delegateSdPower function is called
    /// @param id        id of the underlying protocol
    /// @param delegatee address to delegate the power
    event DelegateSdPower(bytes32 id, address delegatee);

    /// @notice event emited when bribe rewards are updated for a buffer
    /// @param bribeTokens new bribes rewards assignated for the buffer
    /// @param buffer      address of the buffer
    event SetBribeTokens(BribeToken[] bribeTokens, address buffer);

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
        require(address(_sdt) != address(0), "SDT_ZERO");
        sdt = _sdt;
        _transferOwnership(msg.sender);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Withdraws gauge token from this contract to return it to the user, only callable by a Staking Contract.
     * @param receiver Address of gaugeAsset receiver
     * @param amount Amount of gaugeAsset to withdraw
     */
    function withdraw(address receiver, uint256 amount) external {
        require(cvgControlTower.isSdtStaking(msg.sender), "ONLY_SD_ASSET_STAKING");
        /// @dev Fetch the gaugeAsset on the associated Staking contract +  Tranfer the ERC20 token to the receiver
        ISdtStakingPositionService(msg.sender).stakingAsset().transfer(receiver, amount);
    }

    /**
     * @notice Transfer bribe tokens to the corresponding buffer, only callable by a Buffer.
     *         This process is incentivized so that the user who initiated it receives a percentage of each bribe token.
     * @param _processor Address of the processor
     * @param _processorRewardsPercentage percentage of rewards to send to the processor
     * @return array of tokens
     */
    function pullSdStakingBribes(
        address _processor,
        uint256 _processorRewardsPercentage
    ) external returns (ICommonStruct.TokenAmount[] memory) {
        /// @dev verifies that the caller is a Buffer
        require(isBuffer[msg.sender], "NOT_A_BUFFER");

        /// @dev fetches bribes token of the calling buffer
        BribeToken[] memory bribeTokens = bribeTokensLinkedToBuffer[msg.sender];
        ICommonStruct.TokenAmount[] memory _bribeTokensAmounts = new ICommonStruct.TokenAmount[](bribeTokens.length);
        ICvgControlTower _cvgControlTower = cvgControlTower;
        address sdtRewardDistributor = _cvgControlTower.sdtRewardDistributor();

        /// @dev iterates over all bribes token retrieved
        for (uint256 i; i < bribeTokens.length; ) {
            /// @dev get the balance in the bribe token
            BribeToken memory bribeToken = bribeTokens[i];
            IERC20 token = bribeToken.token;
            uint256 initialBalance = token.balanceOf(address(this));
            uint256 toDistributeInStaking = initialBalance;

            if (initialBalance != 0) {
                /// @dev send rewards to claimer
                uint256 claimerRewards = (initialBalance * _processorRewardsPercentage) / BASE_FEES;
                if (claimerRewards > 0) {
                    token.transfer(_processor, claimerRewards);
                    toDistributeInStaking -= claimerRewards;
                }

                uint256 podFees = (initialBalance * bribeToken.fee) / BASE_FEES;
                if (podFees > 0) {
                    token.transfer(_cvgControlTower.treasuryPod(), podFees);
                    toDistributeInStaking -= podFees;
                }

                /// @dev send the balance of the bribe token minus claimer rewards to the buffer
                token.transfer(sdtRewardDistributor, toDistributeInStaking);

                _bribeTokensAmounts[i] = ICommonStruct.TokenAmount({token: token, amount: toDistributeInStaking});
            }
            unchecked {
                ++i;
            }
        }

        return _bribeTokensAmounts;
    }

    /**
     * @notice Set the receiver of the Stake DAO gauge rewards for the SdtBlackHole as the corresponding buffer.
     *         Only callable by the CloneFactory during Staking contract creation
     * @param gaugeAddress stake dao gauge reward
     * @param bufferReceiver buffer contract to set as reward receiver
     */
    function setGaugeReceiver(address gaugeAddress, address bufferReceiver) external {
        require(cvgControlTower.cloneFactory() == msg.sender, "NOT_CLONE_FACTORY");
        /// @dev set the buffer as the gauge reward receiver
        ISdAssetGauge(gaugeAddress).set_rewards_receiver(bufferReceiver);
        /// @dev forbids setting a gauge asset as a bribe token
        isGaugeAsset[gaugeAddress] = true;
        /// @dev prevents sending bribes tokens elsewhere than on a buffer
        isBuffer[bufferReceiver] = true;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        OWNER
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Overrides the bribe token list linked to a buffer.
     *         It implies that all linked tokens to it's dedicated buffer will be pulled on each SDT rewards process.
     *         This function is only callable by the owner of the contract
     * @param _bribeTokens tokens bribe array to link to the buffer
     * @param buffer buffer's address to link with _bribeTokens
     */
    function setBribeTokens(BribeToken[] calldata _bribeTokens, address buffer) external onlyOwner {
        /// @dev Verify that the buffer in parameter is a real buffer
        require(isBuffer[address(buffer)], "NOT_BUFFER");

        delete bribeTokensLinkedToBuffer[buffer];

        /// @dev Iterates through the array input in the function
        for (uint256 i; i < _bribeTokens.length; ) {
            /// @dev Verify that the token is not a gauge asset
            require(!isGaugeAsset[address(_bribeTokens[i].token)], "GAUGE_ASSET");
            /// @dev Fees are maximum 15% on bribes
            require(_bribeTokens[i].fee <= 15_000, "FEE_TOO_HIGH");
            bribeTokensLinkedToBuffer[buffer].push(_bribeTokens[i]);
            unchecked {
                ++i;
            }
        }

        emit SetBribeTokens(_bribeTokens, buffer);
    }

    /**
     * @notice Delegates voting power to the stakeDelegateRegistry contract.
     * @param id bytes32, string encoded of the delegation we are applying
     * @param delegatee Address of the delegatee
     */
    function delegateSdPower(bytes32 id, address delegatee) external onlyOwner {
        /// @dev call the StakeDao contract allowing to delegate sd Asset power to an address
        stakeDelegateRegistry.setDelegate(id, delegatee);
        emit DelegateSdPower(id, delegatee);
    }

    function clearDelegate(bytes32 id) external onlyOwner {
        /// @dev call the StakeDao contract allowing to clear delegation
        stakeDelegateRegistry.clearDelegate(id);
        emit DelegateSdPower(id, address(0));
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        VIEW
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Fetches and returns an array of bribe rewards linked to a buffer.
     * @param buffer address of the buffer contract
     * @return the array of bribe token for a buffer
     */
    function getBribeTokensForBuffer(address buffer) external view returns (BribeToken[] memory) {
        return bribeTokensLinkedToBuffer[buffer];
    }
}
