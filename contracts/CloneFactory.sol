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
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/ICvgControlTower.sol";
import "./interfaces/IOracleStruct.sol";
import "./Upgradeable/Beacon/BeaconProxy.sol";

/// @title Cvg-Finance - CloneFactory
/// @notice Convergence's factory to deploy clone of contracts
contract CloneFactory is Ownable2StepUpgradeable {
    struct WithdrawCallInfo {
        address addr;
        bytes signature;
    }

    /// @dev Convergence ecosystem address.
    ICvgControlTower public cvgControlTower;

    /// @dev Beacon contract storing the staking implementation contract.
    address public beaconSdStaking;

    /// @dev Beacon contract storing the buffer implementation contract.
    address public beaconBuffer;

    /// @dev Withdraw signature info.
    WithdrawCallInfo private withdrawCallInfo;

    event SdtStakingCreated(address stakingClone, address gaugeAsset, address bufferClone, bool isLp);

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            CONSTRUCTOR
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        _transferOwnership(msg.sender);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Create a sdtStaking contract and its associated buffer contract through the beacon proxy implementation.
     * @dev This is linking the newly created SdtBuffer to the associated SdtStakingService.
     * @dev The SdtBuffer is then set as the receiver of the rewards from the StakeDao gauge.
     * @param _sdAssetGauge - address of the sdAsset-gauge
     * @param _symbol - string ticker of the stakingAsset
     */
    function createSdtStakingAndBuffer(address _sdAssetGauge, string memory _symbol, bool isLp) external onlyOwner {
        ICvgControlTower _cvgControlTower = cvgControlTower;
        address _beaconSdStaking = beaconSdStaking;
        address _beaconBuffer = beaconBuffer;
        address beaconSdStakingProxy = address(
            new BeaconProxy(
                _beaconSdStaking,
                abi.encodeWithSignature(
                    "initialize(address,address,string,bool,(address,bytes))",
                    _cvgControlTower,
                    _sdAssetGauge,
                    _symbol,
                    true,
                    withdrawCallInfo
                )
            )
        );

        address beaconBufferProxy = address(
            new BeaconProxy(
                _beaconBuffer,
                abi.encodeWithSignature(
                    "initialize(address,address,address,address)",
                    _cvgControlTower,
                    beaconSdStakingProxy,
                    _sdAssetGauge,
                    _cvgControlTower.sdt()
                )
            )
        );

        ISdtStakingPositionService(beaconSdStakingProxy).setBuffer(beaconBufferProxy);

        /// @dev setup the receiver of the rewards on the associated buffer
        _cvgControlTower.sdtBlackHole().setGaugeReceiver(_sdAssetGauge, beaconBufferProxy);

        /// @dev register the staking contract & the buffer in the CvgControlTower
        _cvgControlTower.insertNewSdtStaking(beaconSdStakingProxy);

        emit SdtStakingCreated(beaconSdStakingProxy, _sdAssetGauge, beaconBufferProxy, isLp);
    }

    function setBeaconSdStaking(address _beaconSdStaking) external onlyOwner {
        beaconSdStaking = _beaconSdStaking;
    }

    function setBeaconBuffer(address _beaconBuffer) external onlyOwner {
        beaconBuffer = _beaconBuffer;
    }

    /// @notice set withdrawCallInfo
    function setWithdrawCallInfo(WithdrawCallInfo calldata _withdrawCallInfo) external onlyOwner {
        withdrawCallInfo = _withdrawCallInfo;
    }
}
