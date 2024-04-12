// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurveTriFactory {
    function find_pool_for_coins(address _from, address _to, uint256 i) external view returns (address);

    function deploy_pool(
        string memory _name,
        string memory _symbol,
        address[3] memory _coins,
        address weth,
        uint256 implementation_idx,
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 fee_gamma,
        uint256 allowed_extra_profit,
        uint256 adjustment_step,
        uint256 ma_exp_time,
        uint256[2] memory initial_prices
    ) external returns (address);

    // function find_pool_for_coins(address _from, address _to, uint256 i) external view returns (address);
}
