// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISdFrax3Crv {
    function getPricePerFullShare() external view returns (uint256);

    function token() external view returns (address);
}
