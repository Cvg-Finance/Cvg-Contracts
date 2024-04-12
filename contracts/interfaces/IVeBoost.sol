// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVeBoost {
    function boost(address _to, uint256 _amount, uint256 _endtime, address _from) external;

    function approve(address _spender, uint256 _value) external returns (bool);
}
