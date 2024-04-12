// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICrvFactoryPlain {
    function deploy_plain_pool(
        string memory _name,
        string memory _symbol,
        address[] memory _coins,
        uint256 A,
        uint256 fee,
        uint256 _offpeg_fee_multiplier,
        uint256 _ma_exp_time,
        uint256 _implementation_idx,
        uint8[] memory _asset_types,
        bytes4[] memory _method_ids,
        address[] memory _oracles
    ) external returns (address);

    function find_pool_for_coins(address _from, address _to) external view returns (address);
}
