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
import "../interfaces/IPresaleCvgWl.sol";
import "../interfaces/IboInterface.sol";
import "../interfaces/ICvgPepe.sol";

struct GalleryUserInfo {
    IBondLogo.LogoInfosFull[] bondInfos;
    ILockingLogo.LogoInfosFull[] lockingInfos;
    ISdtStakingLogo.LogoInfosFull[] sdtStakingInfos;
    PresaleInfo[] presaleInfos;
    CvgPepeInfo cvgPepeInfos;
}

error GalleryUserInfoError(GalleryUserInfo galleryUserInfo);

struct PresaleInfo {
    uint256 tokenId;
    IVestingCvg.InfoVestingTokenId presaleInfo;
    IVestingCvg.VestingType presaleType;
    BoostStruct boostStruct;
}
struct CvgPepeInfo {
    string tokenURI;
    uint256[] tokenIds;
}

struct PresaleContracts {
    IPresaleCvgSeed _presaleCvgSeed;
    IPresaleCvgWl _presaleCvgWl;
    IboInterface _presaleCvgIbo;
    IVestingCvg _vestingCvg;
    ICvgPepe _cvgPepe;
    IBoostWlIbo _boostWl;
}

struct BoostStruct {
    uint256 totalBoost;
    uint256 alreadyClaimedBoost;
    uint256 claimableBoost;
}

interface IBoostWlIbo {
    function getClaimableAmount(uint256 totalBoost, uint256 alreadyClaimed) external view returns (uint256);

    function iboAlreadyClaimed(uint256 tokenId) external view returns (uint256);

    function wlAlreadyClaimed(uint256 tokenId) external view returns (uint256);
}

contract GalleryInfo {
    uint256 private constant FIVE_PERCENT = 500_000;
    uint256 private constant HUNDRED_PERCENT = 10_000_000;

    constructor(
        address _wallet,
        IBondPositionManager _bondPositionManager,
        IBondLogo _bondLogo,
        ILockingPositionManager _lockingPositionManager,
        ILockingLogo _lockingLogo,
        ISdtStakingPositionManager _sdtStakingPositionManager,
        ISdtStakingLogo _sdtStakingLogo,
        PresaleContracts memory _presaleContracts
    ) {
        getGalleryInfos(
            _wallet,
            _bondPositionManager,
            _bondLogo,
            _lockingPositionManager,
            _lockingLogo,
            _sdtStakingPositionManager,
            _sdtStakingLogo,
            _presaleContracts
        );
    }

    function getPresalesInfos(
        address wallet,
        PresaleContracts memory _presaleContracts
    ) internal view returns (PresaleInfo[] memory) {
        //SEED
        uint256[] memory _Ids = _presaleContracts._presaleCvgSeed.getTokenIdsForWallet(wallet); //Id seed
        uint256[] memory _IdsWl = _presaleContracts._presaleCvgWl.getTokenIdsForWallet(wallet); //Id wl
        uint256[] memory _IdsIbo = _presaleContracts._presaleCvgIbo.getTokenIdsForWallet(wallet); //Id ibo
        PresaleInfo[] memory _presaleInfos = new PresaleInfo[](_Ids.length + _IdsWl.length + _IdsIbo.length);
        for (uint256 i; i < _Ids.length; ) {
            _presaleInfos[i] = PresaleInfo({
                tokenId: _Ids[i],
                presaleInfo: _presaleContracts._vestingCvg.getInfoVestingTokenId(_Ids[i], IVestingCvg.VestingType.SEED),
                presaleType: IVestingCvg.VestingType.SEED,
                boostStruct: BoostStruct({totalBoost: 0, alreadyClaimedBoost: 0, claimableBoost: 0})
            });
            unchecked {
                ++i;
            }
        }
        uint256 lastIndex = _Ids.length;
        for (uint256 i; i < _IdsWl.length; ) {
            uint256 totalBoost = (_presaleContracts._presaleCvgWl.presaleInfos(_IdsWl[i]).cvgAmount * FIVE_PERCENT) /
                HUNDRED_PERCENT;
            uint256 alreadyClaimedBoost = _presaleContracts._boostWl.wlAlreadyClaimed(_IdsWl[i]);
            uint256 claimableBoost = _presaleContracts._boostWl.getClaimableAmount(totalBoost, alreadyClaimedBoost);
            _presaleInfos[i + lastIndex] = PresaleInfo({
                tokenId: _IdsWl[i],
                presaleInfo: _presaleContracts._vestingCvg.getInfoVestingTokenId(_IdsWl[i], IVestingCvg.VestingType.WL),
                presaleType: IVestingCvg.VestingType.WL,
                boostStruct: BoostStruct({
                    totalBoost: totalBoost,
                    alreadyClaimedBoost: alreadyClaimedBoost,
                    claimableBoost: claimableBoost
                })
            });
            unchecked {
                ++i;
            }
        }
        lastIndex += _IdsWl.length;
        for (uint256 i; i < _IdsIbo.length; ) {
            uint256 totalBoost = (_presaleContracts._presaleCvgIbo.totalCvgPerToken(_IdsIbo[i]) * FIVE_PERCENT) /
                HUNDRED_PERCENT;
            uint256 alreadyClaimedBoost = _presaleContracts._boostWl.iboAlreadyClaimed(_IdsIbo[i]);
            uint256 claimableBoost = _presaleContracts._boostWl.getClaimableAmount(totalBoost, alreadyClaimedBoost);

            _presaleInfos[i + lastIndex] = PresaleInfo({
                tokenId: _IdsIbo[i],
                presaleInfo: _presaleContracts._vestingCvg.getInfoVestingTokenId(
                    _IdsIbo[i],
                    IVestingCvg.VestingType.IBO
                ),
                presaleType: IVestingCvg.VestingType.IBO,
                boostStruct: BoostStruct({
                    totalBoost: totalBoost,
                    alreadyClaimedBoost: alreadyClaimedBoost,
                    claimableBoost: claimableBoost
                })
            });
            unchecked {
                ++i;
            }
        }
        delete _Ids;

        return _presaleInfos;
    }

    function getGalleryInfos(
        address _wallet,
        IBondPositionManager _bondPositionManager,
        IBondLogo _bondLogo,
        ILockingPositionManager _lockingPositionManager,
        ILockingLogo _lockingLogo,
        ISdtStakingPositionManager _sdtStakingPositionManager,
        ISdtStakingLogo _sdtStakingLogo,
        PresaleContracts memory _presaleContracts
    ) internal view {
        //BOND
        uint256[] memory _Ids = _bondPositionManager.getTokenIdsForWallet(_wallet);
        IBondLogo.LogoInfosFull[] memory _bondInfos = new IBondLogo.LogoInfosFull[](_Ids.length);
        for (uint256 i; i < _Ids.length; ) {
            _bondInfos[i] = _bondLogo.getLogoInfo(_Ids[i]);
            unchecked {
                ++i;
            }
        }
        delete _Ids;

        //LOCKING
        _Ids = _lockingPositionManager.getTokenIdsForWallet(_wallet);
        ILockingLogo.LogoInfosFull[] memory _lockingInfos = new ILockingLogo.LogoInfosFull[](_Ids.length);
        for (uint256 i; i < _Ids.length; ) {
            _lockingInfos[i] = _lockingLogo.getLogoInfo(_Ids[i]);
            unchecked {
                ++i;
            }
        }
        delete _Ids;

        //SDT STAKING
        _Ids = _sdtStakingPositionManager.getTokenIdsForWallet(_wallet);
        ISdtStakingLogo.LogoInfosFull[] memory _sdtStakingInfos = new ISdtStakingLogo.LogoInfosFull[](_Ids.length);
        for (uint256 i; i < _Ids.length; ) {
            _sdtStakingInfos[i] = _sdtStakingLogo.getLogoInfo(_Ids[i]);
            unchecked {
                ++i;
            }
        }
        delete _Ids;
        address wallet_ = _wallet; //escape from stack too deeeeeeep
        //CVGPEPE
        uint256 cvgPepeBalance = _presaleContracts._cvgPepe.balanceOf(wallet_);
        uint256[] memory _cvgPepeIds = new uint256[](cvgPepeBalance);
        for (uint256 i; i < cvgPepeBalance; ) {
            _cvgPepeIds[i] = _presaleContracts._cvgPepe.tokenOfOwnerByIndex(wallet_, i);
            unchecked {
                ++i;
            }
        }
        delete cvgPepeBalance;

        //ERROR
        revert GalleryUserInfoError(
            GalleryUserInfo({
                bondInfos: _bondInfos,
                lockingInfos: _lockingInfos,
                sdtStakingInfos: _sdtStakingInfos,
                presaleInfos: getPresalesInfos(wallet_, _presaleContracts),
                cvgPepeInfos: CvgPepeInfo({tokenURI: _presaleContracts._cvgPepe.tokenURI(1), tokenIds: _cvgPepeIds})
            })
        );
    }
}
