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

struct BondTokenInfo {
    uint256 tokenId;
    uint256 bondId;
    IBondStruct.BondTokenView bondTokenInfo;
}

error BondTokenInfosError(BondTokenInfo[] bondInfos);

contract BondInfo {
    constructor(address _wallet, IBondPositionManager _bondPositionManager) {
        getBondInfos(_wallet, _bondPositionManager);
    }

    function getBondInfos(address _wallet, IBondPositionManager _bondPositionManager) internal view {
        IBondDepository _bondDepository = _bondPositionManager.bondDepository();
        uint256[] memory tokenIds = _bondPositionManager.getTokenIdsForWallet(_wallet);
        BondTokenInfo[] memory _bondInfos = new BondTokenInfo[](tokenIds.length);

        for (uint256 i; i < tokenIds.length; i++) {
            IBondStruct.BondPending memory bondPending = _bondDepository.positionInfos(tokenIds[i]);
            _bondInfos[i] = BondTokenInfo({
                tokenId: tokenIds[i],
                bondId: _bondPositionManager.bondPerTokenId(tokenIds[i]),
                bondTokenInfo: IBondStruct.BondTokenView({
                    claimableCvg: _bondDepository.pendingPayoutFor(tokenIds[i]),
                    leftClaimable: bondPending.leftClaimable,
                    lastTimestamp: bondPending.lastTimestamp,
                    vestingEnd: bondPending.lastTimestamp + bondPending.vestingTimeLeft
                })
            });
        }

        revert BondTokenInfosError(_bondInfos);
    }
}
