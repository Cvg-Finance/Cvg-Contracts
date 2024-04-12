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
import "../libs/ABDKMathQuad.sol";

/*
 * Copyright © 2019, ABDK Consulting.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. All advertising materials mentioning features or use of this software must
 *    display the following acknowledgement:
 *      This product includes software developed by ABDK Consulting.
 *
 * 4. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products derived from
 *    this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY COPYRIGHT HOLDER "AS IS" AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL COPYRIGHT HOLDER BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import "../interfaces/IBondStruct.sol";

/// @title Cvg-Finance - BondCalculator
/// @notice Various bond calculation functions

contract BondCalculator {
    using ABDKMathQuad for uint256;
    using ABDKMathQuad for bytes16;

    uint256 internal constant TEN_POWER_6 = 10 ** 6;
    uint256 internal constant TEN_POWER_18 = 10 ** 18;

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            TIME RATIO
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    /**
     * @notice Compute the time ratio representing the progression on a bonding round => t/T in bytes16.
     * @param durationFromStart time in seconds since the creation of the bond
     * @param totalDuration     expiry duration of the bond
     * @return timeRatio t/T
     */
    function _computeTimeRatio(uint256 durationFromStart, uint256 totalDuration) internal pure returns (bytes16) {
        return ABDKMathQuad.fromUInt(durationFromStart).div(ABDKMathQuad.fromUInt(totalDuration));
    }

    function computeTimeRatioUInt(uint256 durationFromStart, uint256 totalDuration) public pure returns (uint256) {
        return
            ABDKMathQuad.toUInt(
                _computeTimeRatio(durationFromStart, totalDuration).mul(
                    ABDKMathQuad.fromUInt(TEN_POWER_6) //10**6 TO GET PRECISION: 0.26 => 260000
                )
            );
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            CVG EXPECTED
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice Compute the expected CVG minted.
     *  @param durationFromStart of the computation
     *  @param totalDuration     start time of the bonding contract
     *  @param composedFunction  bonding computation type => sqrt, ², ln, linear
     *  @param totalOutToken     maxCvg that can be minted by the bonding contract
     *  @return cvgExpected is the number of CVG that are expected to be minted through the bond
     */
    function _computeCvgExpected(
        uint256 durationFromStart,
        uint256 totalDuration,
        IBondStruct.BondFunction composedFunction,
        uint256 totalOutToken
    ) internal pure returns (bytes16 cvgExpected) {
        bytes16 timeRatio = _computeTimeRatio(durationFromStart, totalDuration);

        if (composedFunction == IBondStruct.BondFunction.SQRT) {
            cvgExpected = ABDKMathQuad.sqrt(timeRatio);
        } else if (composedFunction == IBondStruct.BondFunction.LN) {
            cvgExpected = ABDKMathQuad
                .ln(timeRatio)
                .div(ABDKMathQuad.ln(ABDKMathQuad.fromUInt(totalOutToken).div(ABDKMathQuad.fromUInt(TEN_POWER_18))))
                .add(ABDKMathQuad.fromUInt(1));
        } else if (composedFunction == IBondStruct.BondFunction.POWER_2) {
            cvgExpected = timeRatio.mul(timeRatio);
        } else {
            cvgExpected = timeRatio;
        }
        bytes16 expectedToCheck = cvgExpected.mul(ABDKMathQuad.fromUInt(totalOutToken));
        cvgExpected = ABDKMathQuad.toInt(expectedToCheck) <= 0 ? ABDKMathQuad.fromUInt(0) : expectedToCheck;
        //10**6 TO GET PRECISION: 0.26 => 260000
    }

    /**
     *  @notice Compute the expected CVG minted.
     *  @param durationFromStart time in seconds since the creation of the bond
     *  @param totalDuration total duration in seconds of the bond
     *  @param composedFunction bonding computation type => sqrt, ², ln, linear
     *  @param maxCvgToMint maximum amount of CVG to mint
     *  @return ntrNtcRatio uint256
     */
    function computeCvgExpected(
        uint256 durationFromStart,
        uint256 totalDuration,
        IBondStruct.BondFunction composedFunction,
        uint256 maxCvgToMint
    ) public pure returns (uint256) {
        return
            ABDKMathQuad.toUInt(_computeCvgExpected(durationFromStart, totalDuration, composedFunction, maxCvgToMint));
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        RATIO REAL EXPECTED
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Compute the time ratio representing the progression on a bonding round => t/T in bytes16.
     * @param durationFromStart time in seconds since the creation of the bond
     * @param totalDuration     total duration in seconds of the bond
     * @param composedFunction  bonding computation type => sqrt, ², ln, linear
     * @param totalOutToken     maxCvg that will be minted by the bonding contract
     * @param soldTokenOut      cvg amount already sold since the beginning of the bond
     * @return ntrNtcRatio uint256
     */
    function computeNtrDivNtc(
        uint256 durationFromStart,
        uint256 totalDuration,
        IBondStruct.BondFunction composedFunction,
        uint256 totalOutToken,
        uint256 soldTokenOut
    ) public pure returns (uint256) {
        bytes16 cvgExpectedOnActualRound = _computeCvgExpected(
            durationFromStart,
            totalDuration,
            composedFunction,
            totalOutToken
        );
        return
            ABDKMathQuad.toInt(cvgExpectedOnActualRound) == 0
                ? 0
                : ABDKMathQuad.toUInt(ABDKMathQuad.fromUInt(soldTokenOut * TEN_POWER_6).div(cvgExpectedOnActualRound));
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        ROI COMPUTATION
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Compute the ROI of a bond with the values provided as function's arguments.
     * @param durationFromStart time in seconds since the creation of the bond
     * @param totalDuration     total duration in seconds of the bond
     * @param composedFunction  bonding computation type => sqrt, ², ln, linear
     * @param totalOutToken     maxCvg that will be minted by the bonding contract
     * @param amountTokenSold   cvg amount already sold since the beginning of the bond
     * @param gamma             variable dividing the NTR/NTB.
     * @param scale             % that is removed on the ROI each time the intRange increases
     * @param minRoi            minimum ROI that the bond allows
     * @param maxRoi            maximum ROI that the bond allows
     * @return roi uint256
     */
    function computeRoi(
        uint256 durationFromStart,
        uint256 totalDuration,
        IBondStruct.BondFunction composedFunction,
        uint256 totalOutToken,
        uint256 amountTokenSold,
        uint256 gamma,
        uint256 scale,
        uint256 minRoi,
        uint256 maxRoi
    ) external pure returns (uint256) {
        uint256 percentageReduction = (computeNtrDivNtc(
            durationFromStart,
            totalDuration,
            composedFunction,
            totalOutToken,
            amountTokenSold
        ) / gamma) * scale; // euclidean division here, we keep only the full number 4.8888 => 4

        if (percentageReduction >= (maxRoi - minRoi)) {
            return minRoi;
        } else {
            return maxRoi - percentageReduction;
        }
    }
}
