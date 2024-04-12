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

interface IVe {
    function balanceOf(address) external view returns (uint256);
}

struct BalanceVeSDTInfo {
    address holder;
    uint256 balance;
}

error BalanceVeSDTInfosError(BalanceVeSDTInfo[] balanceInfos);

contract BalanceVeSDT {
    IVe constant VESDT = IVe(0x0C30476f66034E11782938DF8e4384970B6c9e8a);

    constructor(address[] memory holders) {
        getBalanceInfos(holders);
    }

    function getBalanceInfos(address[] memory holders) internal view {
        IVe _veSDT = VESDT;
        BalanceVeSDTInfo[] memory _balanceInfos = new BalanceVeSDTInfo[](holders.length);

        for (uint256 i; i < holders.length; i++) {
            _balanceInfos[i] = BalanceVeSDTInfo({holder: holders[i], balance: _veSDT.balanceOf(holders[i])});
        }

        revert BalanceVeSDTInfosError(_balanceInfos);
    }
}
