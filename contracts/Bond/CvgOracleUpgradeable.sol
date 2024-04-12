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

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/ICrvPool.sol";
import {IOracleStructV2 as IOracleStruct, AggregatorV3Interface} from "../interfaces/IOracleStructV2.sol";

import "../libs/TickMath.sol";

/// @title Cvg-Finance - CvgOracle
/// @notice Convergence Oracle
contract CvgOracleUpgradeable is Ownable2StepUpgradeable {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant ONE_ETH = 10 ** 18;
    uint256 internal constant TEN_36 = 10 ** 36;

    /// @dev Type of pooltype for price fetching of the address
    mapping(address => IOracleStruct.PoolType) public poolTypePerErc20; // erc20 => poolType

    /// @dev Parameters of the Stablecoins in the CvgOracle
    mapping(address => IOracleStruct.StableParams) public stableParams; // erc20 => stableParams

    /// @dev Parameters of assets computed with a Curve Pool 2 assets
    mapping(address => IOracleStruct.CurveDuoParams) public curveDuoParams; // erc20 => curveDuoParams

    /// @dev Parameters of assets computed with a Curve Pool 3 assets
    mapping(address => IOracleStruct.CurveTriParams) public curveTriParams; // erc20 => curveTriParams

    /// @dev Parameters of assets computed with a UniswapV3 LP
    mapping(address => IOracleStruct.UniV3Params) public univ3Params; // erc20 => univ3Params

    /// @dev Parameters of assets computed with a UniswapV2 LP
    mapping(address => IOracleStruct.UniV2Params) public univ2Params; // erc20 => univ2Params

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external initializer {
        _transferOwnership(msg.sender);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNAL
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice - Fetch the price of 1 tokens in $ under 18 decimals
     *            OR
     *          - Revert if 1 of the conditions is not verified
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return price of the token
     */
    function getPriceVerified(address _erc20Address) public view returns (uint256) {
        (
            uint256 executionPrice,
            ,
            bool isInLimit,
            bool isEthVerified,
            bool isNotStale,
            bool isUsdRangeRespected,
            bool areStableVerified
        ) = getPriceAndValidationData(_erc20Address);

        require(isInLimit, "EXECUTION_LIMIT_DEPEG");
        require(isEthVerified, "ETH_PRICE_NOT_VERIFIED");
        require(isNotStale, "STALE_PRICE");
        require(isUsdRangeRespected, "USD_OUT_OF_RANGE");
        require(areStableVerified, "STABLE_NOT_VERIFIED");
        return executionPrice;
    }

    /**
     *  @notice - Fetch the price of 2 tokens in $ under 18 decimals
     *            OR
     *          - Revert if 1 of the conditions is not verified
     *  @param token0 address of the token we want to fetch the price of
     *  @param token1 address of the token we want to fetch the price of
     *  @return price of token 0 used for the execution of the order
     *  @return price of token 1 used for the execution of the order
     */
    function getAndVerifyTwoPrices(address token0, address token1) external view returns (uint256, uint256) {
        return (getPriceVerified(token0), getPriceVerified(token1));
    }

    /**
     *  @notice Return the execution price of an erc20. Doesn't verify any limits conditions. Used only for view purposes.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice price of token 0 used for the execution of the order
     */
    function getPriceUnverified(address _erc20Address) public view returns (uint256 executionPrice) {
        (executionPrice, , , , , , ) = getPriceAndValidationData(_erc20Address);
    }

    /**
     *  @notice Return the price and all boolean representing limits conditions.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Price used for the order execution.
     *  @return limitPrice    Price compared to execution price to verify if any liquidity is occuring.
     *  @return isInLimit     Validate if the delta between executionPrice & limitPrice is respected.
     *  @return isEthVerified Validate that the price of ETH is computed correctly, always true if no ETH is in the price computation path.
     *  @return isNotStale    Validate if a price is expired or not.
     *  @return isUsdRangeRespected Validate that the price of the asset is in the USD range predefined in the parameters.
     *  @return areStableVerified Validate that all stables used to compute the price of _erc20Address are validated.
     */
    function getPriceAndValidationData(
        address _erc20Address
    )
        public
        view
        returns (
            uint256 executionPrice,
            uint256 limitPrice,
            bool isInLimit,
            bool isEthVerified,
            bool isNotStale,
            bool isUsdRangeRespected,
            bool areStableVerified
        )
    {
        IOracleStruct.PoolType poolType = poolTypePerErc20[_erc20Address];
        /// @dev Stable coin 1$
        if (poolType == IOracleStruct.PoolType.STABLE) {
            (executionPrice, limitPrice, isInLimit, isNotStale, isUsdRangeRespected) = _getStablePriceAndValidationData(
                _erc20Address
            );
            areStableVerified = true;
            isEthVerified = true;
        }
        /// @dev CURVE 2 ASSETS
        else if (poolType == IOracleStruct.PoolType.CURVE_DUO) {
            (
                executionPrice,
                limitPrice,
                isInLimit,
                isEthVerified,
                isNotStale,
                isUsdRangeRespected,
                areStableVerified
            ) = _getCurveDuoPriceAndValidationData(_erc20Address);
        }
        /// @dev CURVE 3 ASSETS
        else if (poolType == IOracleStruct.PoolType.CURVE_TRI) {
            (
                executionPrice,
                limitPrice,
                isInLimit,
                isEthVerified,
                isNotStale,
                isUsdRangeRespected,
                areStableVerified
            ) = _getCurveTriPriceAndValidationData(_erc20Address);
        }
        /// @dev UNI V3
        else if (poolType == IOracleStruct.PoolType.UNI_V3) {
            (
                executionPrice,
                limitPrice,
                isInLimit,
                isEthVerified,
                isNotStale,
                isUsdRangeRespected,
                areStableVerified
            ) = _getUniV3PriceAndValidationData(_erc20Address);
        }
        /// @dev UNI V2
        else if (poolType == IOracleStruct.PoolType.UNI_V2) {
            (
                executionPrice,
                limitPrice,
                isInLimit,
                isEthVerified,
                isNotStale,
                isUsdRangeRespected,
                areStableVerified
            ) = _getUniV2PriceAndValidationData(_erc20Address);
        }
    }

    /**
     *  @dev Returns 1$, the Chainlink Aggregator price & all booleans validating the price of the stable.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Always return 1$ under 18 decimals.
     *  @return limitPrice     Price in $ of the stable returned by Chainlink, under 18 decimals.
     *  @return isInLimit      Validate if the delta between 1$ & the Chainlink aggregator is in range.
     *  @return isNotStale     Validate if the price returned by Chainlink is not stale.
     *  @return isUsdRangeRespected Validate that the price of the stable is in the USD range predefined in the parameters.
     */
    function _getStablePriceAndValidationData(
        address _erc20Address
    ) internal view returns (uint256, uint256, bool, bool, bool) {
        IOracleStruct.StableParams memory _stableParams = stableParams[_erc20Address];

        /// @dev Delta that has to be respected between 1$ and the Chainlink price.
        uint256 delta = (uint256(_stableParams.deltaLimitOracle) * ONE_ETH) / 10_000;
        /// @dev Get the price and the last update on the corresponding Chainlink Oracle.
        (uint256 limitPrice, uint256 lastUpdateDate) = _getAggregatorPrice(_stableParams.aggregatorOracle);

        return (
            ONE_ETH,
            limitPrice,
            ONE_ETH + delta > limitPrice && ONE_ETH - delta < limitPrice,
            lastUpdateDate + _stableParams.maxLastUpdate > block.timestamp,
            ONE_ETH > _stableParams.minPrice && ONE_ETH < _stableParams.maxPrice
        );
    }

    /**
     *  @dev Convert the raw price under 18 decimals into the price in $ of the asset under 18 decimals.
     *  @param executionPrice Raw price returned by the pool price fetching.
     *  @param isReversed     Determines if we need or not to reverse the price.
     *  @param isEthRelated   Determines if we need or not to multiply the raw price by the eth price in case of price fetching involving the ETH.
     *  @return Modified price in $ of the asset under 18 decimals.
     *  @return Validate if the price fetching of the ETH is validated or not.
     */
    function _convertToDollar(
        uint256 executionPrice,
        bool isReversed,
        bool isEthRelated
    ) internal view returns (uint256, bool) {
        bool isEthVerified = true;

        if (isReversed) {
            executionPrice = TEN_36 / executionPrice;
        }
        if (isEthRelated) {
            (
                uint256 ethPrice,
                ,
                bool isInLimits,
                ,
                bool isNotStale,
                bool isUsdRangeRespected,
                bool areStableVerified
            ) = getPriceAndValidationData(WETH);
            isEthVerified = isInLimits && isNotStale && isUsdRangeRespected && areStableVerified;
            executionPrice = (executionPrice * ethPrice) / ONE_ETH;
        }
        return (executionPrice, isEthVerified);
    }

    /**
     *  @dev Returns the executionPrice, the last_price & all booleans validating the price of the asset in a Curve Duo Pool.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Price in dollar of the erc20, under 18 decimals, computed from the price_oracle.
     *  @return limitPrice     Raw last_price returned by Curve LP.
     *  @return isInLimit      Validate if the delta between the last_price & the price_oracle is in range.
     *  @return isNotStale     Validate if the last swap timestamp in the LP is not too old.
     *  @return isUsdRangeRespected Validate that the price of the asset is in the USD range predefined in the parameters.
     */
    function _getCurveDuoPriceAndValidationData(
        address _erc20Address
    ) internal view returns (uint256, uint256, bool, bool, bool, bool, bool) {
        IOracleStruct.CurveDuoParams memory _curveDuoParams = curveDuoParams[_erc20Address];
        ICrvPool poolAddress = ICrvPool(_curveDuoParams.poolAddress);
        uint256 executionPrice = poolAddress.price_oracle();
        /// @dev limit dollar is maybe not in dollar  (is reversed or eth related), but we can keep it like this for the comparaison with price_oracle
        uint256 limitPrice = poolAddress.last_prices();

        (uint256 usdExecutionPrice, bool isEthVerified) = _convertToDollar(
            executionPrice,
            _curveDuoParams.isReversed,
            _curveDuoParams.isEthPriceRelated
        );

        uint256 delta = (_curveDuoParams.deltaLimitOracle * executionPrice) / 10_000;

        uint256 last_timestamp = _curveDuoParams.isNg
            ? poolAddress.last_timestamp() & (2 ** 128 - 1)
            : poolAddress.last_prices_timestamp();

        return (
            usdExecutionPrice,
            limitPrice,
            executionPrice + delta > limitPrice && executionPrice - delta < limitPrice,
            isEthVerified,
            last_timestamp + _curveDuoParams.maxLastUpdate > block.timestamp,
            usdExecutionPrice > _curveDuoParams.minPrice && usdExecutionPrice < _curveDuoParams.maxPrice,
            _verifyStableInPath(_curveDuoParams.stablesToCheck)
        );
    }

    /**
     *  @dev Returns the executionPrice, the last_price & all booleans validating the price of the asset in a Curve Tri Pool.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Price in dollar of the erc20, under 18 decimals, computed from the price_oracle.
     *  @return limitPrice     Raw last_price returned by Curve LP.
     *  @return isInLimit      Validate if the delta between the last_price & the price_oracle is in range.
     *  @return isNotStale     Validate if the last swap timestamp in the LP is not too old.
     *  @return isUsdRangeRespected Validate that the price of the asset is in the USD range predefined in the parameters.
     */
    function _getCurveTriPriceAndValidationData(
        address _erc20Address
    ) internal view returns (uint256, uint256, bool, bool, bool, bool, bool) {
        IOracleStruct.CurveTriParams memory _curveTriParams = curveTriParams[_erc20Address];
        ITriCrvPool poolAddress = ITriCrvPool(_curveTriParams.poolAddress);

        uint256 executionPrice = poolAddress.price_oracle(_curveTriParams.k);
        /// @dev limit dollar is maybe not in dollar (is reversed or eth related), but we can keep it like this for the comparaison with price_oracle
        uint256 limitPrice = poolAddress.last_prices(_curveTriParams.k);

        (uint256 usdExecutionPrice, bool isEthVerified) = _convertToDollar(
            executionPrice,
            _curveTriParams.isReversed,
            _curveTriParams.isEthPriceRelated
        );

        uint256 delta = (_curveTriParams.deltaLimitOracle * executionPrice) / 10_000;

        return (
            usdExecutionPrice,
            limitPrice,
            executionPrice + delta > limitPrice && executionPrice - delta < limitPrice,
            isEthVerified,
            poolAddress.last_prices_timestamp() + _curveTriParams.maxLastUpdate > block.timestamp,
            usdExecutionPrice > _curveTriParams.minPrice && usdExecutionPrice < _curveTriParams.maxPrice,
            _verifyStableInPath(_curveTriParams.stablesToCheck)
        );
    }

    /**
     *  @dev Returns the executionPrice, the Chainlink Aggregator price & all booleans validating the price of the asset in a UniswapV3 LP.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Price in dollar of the erc20, under 18 decimals.
     *  @return limitPrice     Price in dollar returned by the Chainlink Aggregator.
     *  @return isInLimit      Validate if the delta between the exectutionPrice & the limitPrice is in range.
     *  @return isNotStale     Validate if the last Chainlink update is not too old.
     *  @return isUsdRangeRespected Validate that the price of the asset is in the USD range predefined in the parameters.
     */
    function _getUniV3PriceAndValidationData(
        address _erc20Address
    ) internal view returns (uint256, uint256, bool, bool, bool, bool, bool) {
        IOracleStruct.UniV3Params memory _univ3Params = univ3Params[_erc20Address];
        IUniswapV3Pool uniswapV3Pool = IUniswapV3Pool(_univ3Params.poolAddress);

        uint256 executionPrice;

        (uint256 limitPrice, uint256 lastUpdateDate) = _getAggregatorPrice(_univ3Params.aggregatorOracle);
        if (_univ3Params.twap == 0) {
            // return the current price if twapOrK == 0
            (executionPrice, , , , , , ) = uniswapV3Pool.slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = _univ3Params.twap; // from (before)
            secondsAgos[1] = 0; // to (now)

            (int56[] memory tickCumulatives, ) = uniswapV3Pool.observe(secondsAgos);

            // tick(imprecise as it's an integer) to price
            executionPrice = TickMath.getSqrtRatioAtTick(
                int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int16(_univ3Params.twap)))
            );
        }
        uint256 usdExecutionPrice;
        bool isEthVerified;

        {
            uint256 token0Decimals = IERC20Metadata(uniswapV3Pool.token0()).decimals();
            uint256 token1Decimals = IERC20Metadata(uniswapV3Pool.token1()).decimals();

            (usdExecutionPrice, isEthVerified) = _convertToDollar(
                (((executionPrice * executionPrice) / FixedPoint96.Q96) *
                    10 **
                        (
                            token0Decimals <= token1Decimals
                                ? 18 - (token1Decimals - token0Decimals)
                                : 18 + (token0Decimals - token1Decimals)
                        )) / FixedPoint96.Q96,
                _univ3Params.isReversed,
                _univ3Params.isEthPriceRelated
            );
        }

        uint256 delta = (_univ3Params.deltaLimitOracle * limitPrice) / 10_000;
        return (
            usdExecutionPrice,
            limitPrice,
            limitPrice + delta > usdExecutionPrice && limitPrice - delta < usdExecutionPrice,
            isEthVerified,
            lastUpdateDate + _univ3Params.maxLastUpdate > block.timestamp,
            usdExecutionPrice > _univ3Params.minPrice && usdExecutionPrice < _univ3Params.maxPrice,
            _verifyStableInPath(_univ3Params.stablesToCheck)
        );
    }

    /**
     *  @dev Returns the executionPrice, the Chainlink Aggregator price & all booleans validating the price of the asset in a UniswapV2 LP.
     *  @param _erc20Address address of the token we want to fetch the price of
     *  @return executionPrice Price in dollar of the erc20, under 18 decimals.
     *  @return limitPrice     Price in dollar returned by the Chainlink Aggregator.
     *  @return isInLimit      Validate if the delta between the exectutionPrice & the limitPrice is in range.
     *  @return isNotStale     Validate if the last Chainlink update is not too old.
     *  @return isUsdRangeRespected Validate that the price of the asset is in the USD range predefined in the parameters.
     */
    function _getUniV2PriceAndValidationData(
        address _erc20Address
    ) internal view returns (uint256, uint256, bool, bool, bool, bool, bool) {
        IOracleStruct.UniV2Params memory _univ2Params = univ2Params[_erc20Address];
        (uint256 limitPrice, uint256 lastUpdateDate) = _getAggregatorPrice(_univ2Params.aggregatorOracle);
        IUniswapV2Pair uniswapPool = IUniswapV2Pair(_univ2Params.poolAddress);
        uint256 executionPrice;
        {
            (uint112 reserve0, uint112 reserve1, ) = uniswapPool.getReserves();

            executionPrice =
                (reserve0 * 10 ** (36 - IERC20Metadata(uniswapPool.token0()).decimals())) /
                (reserve1 * 10 ** (18 - IERC20Metadata(uniswapPool.token1()).decimals()));
        }
        (uint256 usdExecutionPrice, bool isEthVerified) = _convertToDollar(
            executionPrice,
            _univ2Params.isReversed,
            _univ2Params.isEthPriceRelated
        );

        uint256 delta = (_univ2Params.deltaLimitOracle * limitPrice) / 10_000;

        return (
            usdExecutionPrice,
            limitPrice,
            limitPrice + delta > usdExecutionPrice && limitPrice - delta < usdExecutionPrice,
            isEthVerified,
            lastUpdateDate + _univ2Params.maxLastUpdate > block.timestamp,
            usdExecutionPrice > _univ2Params.minPrice && usdExecutionPrice < _univ2Params.maxPrice,
            _verifyStableInPath(_univ2Params.stablesToCheck)
        );
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            ONLYOWNER
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice Set the type of OracleParams to fetch regarding the address of a Token.
     *  @param _erc20Address Address of the token to link with an oracle type.
     *  @param _poolType PoolType to link to the ERC20.
     */
    function setPoolTypeForToken(address _erc20Address, IOracleStruct.PoolType _poolType) external onlyOwner {
        poolTypePerErc20[_erc20Address] = _poolType;
    }

    /**
     *  @notice Set parameters for a stable coin.
     *  @param _erc20Address Address of the stable coin
     *  @param _stableParams stableParams used for the stable verification
     */
    function setStableParams(
        address _erc20Address,
        IOracleStruct.StableParams calldata _stableParams
    ) external onlyOwner {
        stableParams[_erc20Address] = _stableParams;
    }

    /**
     *  @notice Set the parameters of a token linked to a DUO LP tokens of Curve.
     *  @param _erc20Address Address of the erc20 in the Curve LP.
     *  @param _curveDuoParams Parameters of the curve duo pool
     */
    function setCurveDuoParams(
        address _erc20Address,
        IOracleStruct.CurveDuoParams calldata _curveDuoParams
    ) external onlyOwner {
        curveDuoParams[_erc20Address] = _curveDuoParams;
    }

    /**
     *  @notice Set the parameters of a token linked to a Tri LP tokens of Curve.
     *  @param _erc20Address Address of the erc20 in the Curve LP.
     *  @param _curveTriParams Parameters of the curve tri pool
     */
    function setCurveTriParams(
        address _erc20Address,
        IOracleStruct.CurveTriParams calldata _curveTriParams
    ) external onlyOwner {
        curveTriParams[_erc20Address] = _curveTriParams;
    }

    /**
     *  @notice Set the parameters of a token linked to a Uniswap V3 LP.
     *  @param _erc20Address Address of the token we want to fetch the price of
     *  @param _uniV3Params Params used for the price fetching on a UniV3 LP
     */
    function setUniV3Params(address _erc20Address, IOracleStruct.UniV3Params calldata _uniV3Params) external onlyOwner {
        univ3Params[_erc20Address] = _uniV3Params;
    }

    /**
     *  @notice Set the parameters of a token linked to a Uniswap V2 LP.
     *  @param _erc20Address Address of the token we want to fetch the price of
     *  @param _uniV2Params Params used for the price fetching on a UniV2 LP
     */
    function setUniV2Params(address _erc20Address, IOracleStruct.UniV2Params calldata _uniV2Params) external onlyOwner {
        univ2Params[_erc20Address] = _uniV2Params;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                        INTERNAL
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @notice Verify that stables price are valid and don't exceed allowed delta.
     *  @param stables addresses of stable tokens to verify
     *  @return state of the verification
     */
    function _verifyStableInPath(address[] memory stables) internal view returns (bool) {
        bool areStablesVerified = true;
        for (uint256 i; i < stables.length; ) {
            (, , bool isInLimit, bool isNotStale, bool isUsdRangeRespected) = _getStablePriceAndValidationData(
                stables[i]
            );
            areStablesVerified = isInLimit && isNotStale && isUsdRangeRespected;

            unchecked {
                ++i;
            }
        }
        return areStablesVerified;
    }

    // /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
    //                 FETCH LIMITS
    // =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     *  @dev Get the token price from the ChainLink aggregator in dollar and under 18 decimals
     *  @return aggregator AggregatorV3Interface
     */
    function _getAggregatorPrice(AggregatorV3Interface aggregator) internal view returns (uint256, uint256) {
        (, int256 chainlinkPrice, , uint256 lastUpdate, ) = aggregator.latestRoundData();
        return (uint256(chainlinkPrice) * 10 ** (18 - aggregator.decimals()), lastUpdate);
    }

    /**
     *  @notice View function used by the front to get the executionPrice & the validation status of 2 assets involved into a Bond.
     *  @param token0 Address of the first erc20
     *  @param token1 Address of the second erc20
     *  @return usdExecutionPrice0 Execution price in dollar and under 18 decimals of the token0
     *  @return limitPrice0        Limit price of the token0
     *  @return isToken0Verified   Validates price fetching of the token0
     *  @return usdExecutionPrice1 Execution price in dollar and under 18 decimals of the token1
     *  @return limitPrice1        Limit price of the token1
     *  @return isToken1Verified   Validates price fetching of the token1
     */
    function getTwoPricesAndIsValid(
        address token0,
        address token1
    ) external view returns (uint256, uint256, bool, uint256, uint256, bool) {
        bool isOracleValid0;
        bool isOracleValid1;
        uint256 executionPrice0;
        uint256 executionPrice1;
        uint256 limitPrice0;
        uint256 limitPrice1;

        {
            address _token0 = token0;

            (
                uint256 _executionPrice0,
                uint256 _limitPrice0,
                bool isInLimit0,
                bool isEthVerified0,
                bool isNotStale0,
                bool isUsdRangeRespected0,
                bool areStablesVerified0
            ) = getPriceAndValidationData(_token0);
            isOracleValid0 = isInLimit0 && isEthVerified0 && isNotStale0 && isUsdRangeRespected0 && areStablesVerified0;
            executionPrice0 = _executionPrice0;
            limitPrice0 = _limitPrice0;
        }

        {
            address _token1 = token1;

            (
                uint256 _executionPrice1,
                uint256 _limitPrice1,
                bool isInLimit1,
                bool isEthVerified1,
                bool isNotStale1,
                bool isUsdRangeRespected1,
                bool areStablesVerified1
            ) = getPriceAndValidationData(_token1);

            isOracleValid1 = isInLimit1 && isEthVerified1 && isNotStale1 && isUsdRangeRespected1 && areStablesVerified1;
            executionPrice1 = _executionPrice1;
            limitPrice1 = _limitPrice1;
        }

        return (executionPrice0, limitPrice0, isOracleValid0, executionPrice1, limitPrice1, isOracleValid1);
    }

    /**
     *  @notice Returns the lp address used to compute the price of an erc20 token linked
     *  @param erc20 Address of the erc20
     *  @return poolAddress
     */
    function getPoolAddressByToken(address erc20) external view returns (address) {
        IOracleStruct.PoolType poolType = poolTypePerErc20[erc20];
        address poolAddress;
        /// @dev Stable coin 1$
        if (poolType == IOracleStruct.PoolType.STABLE) {
            poolAddress = address(0);
        }
        /// @dev CURVE 2 ASSETS
        else if (poolType == IOracleStruct.PoolType.CURVE_DUO) {
            poolAddress = curveDuoParams[erc20].poolAddress;
        }
        /// @dev CURVE 3 ASSETS
        else if (poolType == IOracleStruct.PoolType.CURVE_TRI) {
            poolAddress = curveTriParams[erc20].poolAddress;
        }
        /// @dev UNI V3
        else if (poolType == IOracleStruct.PoolType.UNI_V3) {
            poolAddress = univ3Params[erc20].poolAddress;
        }
        /// @dev UNI V2
        else if (poolType == IOracleStruct.PoolType.UNI_V2) {
            poolAddress = univ2Params[erc20].poolAddress;
        }
        return poolAddress;
    }
}
