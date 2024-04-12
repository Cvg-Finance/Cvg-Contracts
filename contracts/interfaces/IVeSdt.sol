// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVeSDT {
    function create_lock(uint256, uint256) external;

    function balanceOf(address) external view returns (uint256);

    function increase_amount(uint256) external;
}
