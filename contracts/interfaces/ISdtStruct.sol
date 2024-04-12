// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ISdtStakingPositionService.sol";

interface ISdtStruct {
    struct CvgSdtGlobalView {
        address cvgSdt;
        address stakingAddress;
        uint256 cvgCycle;
        uint256 previousTotal;
        uint256 actualTotal;
        uint256 nextTotal;
    }

    struct SdAssetGlobalView {
        address gaugeAsset;
        address sdAsset;
        address asset;
        address stakingAddress;
        uint256 cvgCycle;
        uint256 previousTotal;
        uint256 actualTotal;
        uint256 nextTotal;
    }

    struct LpAssetGlobalView {
        address gaugeAsset;
        address lpAsset;
        address stakingAddress;
        uint256 cvgCycle;
        uint256 previousTotal;
        uint256 actualTotal;
        uint256 nextTotal;
    }

    struct TokenViewInput {
        ISdtStakingPositionService stakingContract;
        uint256 tokenId;
    }

    struct TokenViewOutput {
        ISdtStakingPositionService stakingContract;
        uint256 tokenId;
        uint256 previousToken;
        uint256 actualToken;
        uint256 nextToken;
    }
}
