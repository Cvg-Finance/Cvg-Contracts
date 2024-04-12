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

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "../../libs/Base64.sol";
import "../../interfaces/ICvgControlTower.sol";
import "../../interfaces/ISdtStakingLogo.sol";
import "../../interfaces/ISdFrax3Crv.sol";
import "../../interfaces/ICrvPoolPlain.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IBalancerVault {
    function getPoolTokens(
        bytes32 poolId
    ) external view returns (IERC20[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface IBalancerPool {
    function totalSupply() external view returns (uint256);

    function getRate() external view returns (uint256);
}

contract SdtStakingLogo is Ownable2StepUpgradeable {
    //frax3Crv
    ISdFrax3Crv internal constant sdFrax3Crv = ISdFrax3Crv(0x5af15DA84A4a6EDf2d9FA6720De921E1026E37b7);
    ICrvPoolPlain internal constant frax3Crv = ICrvPoolPlain(0xd632f22692FaC7611d2AA1C0D552930D43CAEd3B);

    IBalancerVault internal constant BALANCERVAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    bytes32 internal constant _80BAL_20WETH_ID = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    IBalancerPool internal constant _80BAL_20WETH_POOL = IBalancerPool(0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56);
    IBalancerPool internal constant _SDBAL_POOL = IBalancerPool(0x2d011aDf89f0576C9B722c28269FcB5D50C2d179);
    address internal constant BAL = 0xba100000625a3754423978a60c9317c58a424e3D;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant SDBAL = 0xF24d8651578a55b0C119B9910759a351A3458895;

    ICvgControlTower internal cvgControlTower;
    ICvgOracle internal cvgOracle;
    struct SdAssetInfo {
        address asset;
        ICrvPoolPlain curvePool;
    }

    mapping(string => string) internal tokenLogo; // symbol => logo(svg)
    mapping(address => SdAssetInfo) internal sdAssetInfos; //sdAsset => sdAssetInfo

    string public constant DEFAULT_TOKEN_LOGO =
        '<path d="m116.76,172.87l1.94,15.85-12.07,2.46-9.88-2.34-14.65-24.26,4.8-45.07,17.12-22.84,23.49-2.46,21.55-11.82,28.81,14.41-6.5,7.33,47.74,9.48,25.3,17.12s2.34,24.81-5.69,33.49l9.6,56.55h-21.15l4.4-3.91-19.85-43.1-55.75,7.82-19.39,39.19h-21.55l7.08-11.42,14.87-52.88-10.37-9.97-22.32,4.4-2.46,20.62,7.63,7.42,7.3-6.06Z" fill="#fff" stroke-width="0" /><polygon points="153.24 220.77 175.93 220.77 168.81 182.94 159.46 185.55 152.16 201.13 156.66 218.74 153.24 220.77" fill="#fff" stroke-width="0" /><polygon points="195.29 220.77 199.87 214 199.87 183.8 206.86 179.24 219.02 199.99 216.8 220.77 195.29 220.77" fill="#fff" stroke-width="0" /><text transform="translate(87 260)" font-size="38" font-family="andale mono, monospace" fill="#fff">STRATEGY</text>';

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        ICvgOracle _cvgOracle = _cvgControlTower.cvgOracle();
        require(address(_cvgOracle) != address(0), "ORACLE_ZERO");
        cvgOracle = _cvgOracle;
        _transferOwnership(msg.sender);
    }

    function getLogoInfo(uint256 tokenId) external view returns (ISdtStakingLogo.LogoInfosFull memory) {
        ISdtStakingLogo.LogoInfos memory _logoInfo = cvgControlTower.sdtStakingPositionManager().logoInfo(tokenId);
        (uint256 _claimableInUsd, uint256 _hoursLock, bool _isLocked, bool _erroneousAmount) = _getLockInfos(_logoInfo);

        return
            ISdtStakingLogo.LogoInfosFull({
                tokenId: _logoInfo.tokenId,
                symbol: _logoInfo.symbol,
                pending: _logoInfo.pending,
                totalStaked: _logoInfo.totalStaked,
                cvgClaimable: _logoInfo.cvgClaimable,
                sdtClaimable: _logoInfo.sdtClaimable,
                unlockingTimestamp: _logoInfo.unlockingTimestamp,
                claimableInUsd: _claimableInUsd,
                erroneousAmount: _erroneousAmount,
                isLocked: _isLocked,
                hoursLock: _hoursLock
            });
    }

    function _getLockInfos(
        ISdtStakingLogo.LogoInfos memory logoInfos
    ) internal view returns (uint256, uint256, bool, bool) {
        ICvgOracle _cvgOracle = cvgOracle;

        bool isLocked;
        bool erroneousAmount;
        uint256 hoursLock;
        uint256 claimableInUsd = (logoInfos.cvgClaimable *
            _cvgOracle.getPriceUnverified(address(cvgControlTower.cvgToken()))) / 1 ether;

        for (uint256 i; i < logoInfos.sdtClaimable.length; ) {
            address rewardAsset = address(logoInfos.sdtClaimable[i].token);
            uint256 rewardAmount = logoInfos.sdtClaimable[i].amount;
            SdAssetInfo memory _sdAssetInfos = sdAssetInfos[rewardAsset];
            if (_cvgOracle.poolTypePerErc20(rewardAsset) != IOracleStruct.PoolType.NOT_INIT) {
                claimableInUsd +=
                    (rewardAmount * _cvgOracle.getPriceUnverified(rewardAsset)) /
                    10 ** IERC20Metadata(rewardAsset).decimals();
            } else if (rewardAsset == address(sdFrax3Crv)) {
                /// @dev Here we calculate sdFrax3CrvAmount * priceShareFrax3crv (ie: how many frax3Crv for 1 sdFrax3Crv) * priceFrax3Crv to get the actual value in Usd
                claimableInUsd +=
                    (rewardAmount * ISdFrax3Crv(rewardAsset).getPricePerFullShare() * frax3Crv.get_virtual_price()) /
                    10 ** 36;
            } else if (rewardAsset == SDBAL) {
                /// @dev get balances of BAL and WETH on 80BAL_20WETH pool
                (, uint256[] memory _balances, ) = BALANCERVAULT.getPoolTokens(_80BAL_20WETH_ID);
                /// @dev calculate total value in $ of 80BAL_20WETH pool
                uint256 _80bal_20weth_value = _balances[0] *
                    _cvgOracle.getPriceUnverified(BAL) +
                    _balances[1] *
                    _cvgOracle.getPriceUnverified(WETH);
                /// @dev get the value in $ of a unit of 80BAL_20WETH and compare it to the ratio to obtain the value in $ of sdBAL
                claimableInUsd +=
                    (((_80bal_20weth_value * 1 ether) / _80BAL_20WETH_POOL.totalSupply())) /
                    _SDBAL_POOL.getRate();
            } else if (_cvgOracle.poolTypePerErc20(_sdAssetInfos.asset) != IOracleStruct.PoolType.NOT_INIT) {
                /// @dev Here we calculate get_dy (ie: how many asset for X sdAsset) * priceAsset to get the actual value in Usd
                /// @dev asset is always coins[0] and sdAsset(or cvgSDT) always coins[1]
                claimableInUsd +=
                    (_sdAssetInfos.curvePool.get_dy(1, 0, rewardAmount) *
                        _cvgOracle.getPriceUnverified(_sdAssetInfos.asset)) /
                    1 ether;
            } else {
                erroneousAmount = true;
            }
            unchecked {
                ++i;
            }
        }

        if (logoInfos.unlockingTimestamp > block.timestamp) {
            hoursLock = (logoInfos.unlockingTimestamp - block.timestamp) / 3600;
            isLocked = true;
        }

        return (claimableInUsd, hoursLock, isLocked, erroneousAmount);
    }

    function _tokenURI(ISdtStakingLogo.LogoInfos memory logoInfos) external view returns (string memory) {
        (uint256 _claimableInUsd, uint256 _hoursLock, bool _isLocked, bool _erroneousAmount) = _getLockInfos(logoInfos);

        // BASE
        string
            memory output = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 1000"><path fill="#00f" d="M0 0h800v1000H0z"/><path stroke="#fff" stroke-miterlimit="10" stroke-width="5" d="M26 26h748v948H26z"/><path fill="none" stroke="#fff" stroke-miterlimit="10" stroke-width="5" d="M41 41.3h718V959H41z"/><path fill="#fff" fill-rule="evenodd" d="M717.9 347v43.8L701.7 406H82.1v-59h635.8zm0 203.6v43.8l-16.2 15.2H82.1v-59h635.8zm0 105.5v43.8l-16.2 15.2H82.1v-59h635.8z"/><path fill="#00f" d="m711.1 846.6-27.2 47.5-6.8-11.9 13.6-23.7h-54.3l6.8-11.9h67.9z"/><path fill="#ff0" d="m717.9 858.5-34 59.4-27.1-47.5h13.6l13.5 23.7 27.2-47.5 6.8 11.9z"/><path fill="red" d="m656.8 870.4 27.1 47.5h-13.5l-34-59.4h54.3l-6.8 11.9h-27.1z"/><path fill="none" stroke="#fff" stroke-miterlimit="11.3" stroke-width="2" d="M601 82.4h117.4l-.5 219.6M199 917.9l-116.4.3V766"/><path fill="#fff" fill-rule="evenodd" d="M717.9 448.8v43.8l-16.2 15.2H82.1v-59h635.8z"/><path fill="#fff" d="M117.2 765.9H199v116.5h-81.8z"/><text transform="translate(98.3 388.1)" font-weight="bold" font-size="35" font-family="andale mono, monospace">ID</text><text transform="translate(98.3 591.8)" font-weight="bold" font-size="35" font-family="andale mono, monospace">Balance</text><text transform="translate(98.3 697.3)" font-weight="bold" font-size="35" font-family="andale mono, monospace">Claimable</text><text transform="translate(98.3 490)" font-weight="bold" font-size="35" font-family="andale mono, monospace">Pending</text><text x="87%" y="15%" text-anchor="end" font-size="50" fill="#fff" font-family="andale mono, monospace">STAKING</text>';

        // LOGO
        if (bytes(tokenLogo[logoInfos.symbol]).length == 0) {
            output = string(abi.encodePacked(output, DEFAULT_TOKEN_LOGO));
        } else {
            output = string(abi.encodePacked(output, tokenLogo[logoInfos.symbol]));
        }

        // SYMBOL
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="22%" text-anchor="end" font-size="48" fill="#fff" font-family="andale mono, monospace">',
                logoInfos.symbol,
                "</text>"
            )
        );

        // TOKEN ID
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="39%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(logoInfos.tokenId),
                "</text>"
            )
        );

        // PENDING
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="49%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(logoInfos.pending / 10 ** 18),
                "</text>"
            )
        );

        // BALANCE
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="59%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(logoInfos.totalStaked / 10 ** 18),
                "</text>"
            )
        );

        // CLAIMABLE
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="70%" text-anchor="end" font-size="35" font-family="andale mono, monospace">$',
                _toString(_claimableInUsd / 10 ** 18),
                "</text>"
            )
        );

        // RED ICON FOR ERRONEOUS CLAIMABLE AMOUNT
        if (_erroneousAmount) {
            output = string(
                abi.encodePacked(
                    output,
                    '<path d="M15.29,19.82l.13.13v2.11l-.13.13H13.17L13,22.06V20l.13-.13ZM15.18,7.1l.13.13V17.75l-.13.13h-1.9l-.13-.13V7.23l.13-.13Z" fill="red" transform="translate(300 672)"/><path d="M14.23,28.46A14.23,14.23,0,1,1,28.46,14.23,14.25,14.25,0,0,1,14.23,28.46Zm0-26.66A12.43,12.43,0,1,0,26.66,14.23,12.44,12.44,0,0,0,14.23,1.8Z" fill="red" transform="translate(300 672)"/>'
                )
            );
        }

        // LOCK
        if (_isLocked) {
            // PADLOCK CLOSED GREEN
            output = string(
                abi.encodePacked(
                    output,
                    '<path fill="#00FF00" d="M178.26,800.21V790.12h-5V780H163.12v-5H153v5H142.94v10.09h-5v10.09h-5.05v35.32H183.3V800.21ZM163.12,820.4H160.6v5h-5v-5H153v-7.57h10.09Zm5-20.19H148V790.12h5v-5h10.09v5h5Z" />'
                )
            );
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="19.9%" y="87%" text-anchor="middle" font-size="25" font-family="andale mono, monospace">&lt;',
                    _toString(_hoursLock + 1),
                    " h</text></svg>"
                )
            );
        } else {
            // PADLOCK OPEN RED
            output = string(
                abi.encodePacked(
                    output,
                    '<path fill="#FF0000" d="M148,800.21V790.12h5v-5h10.09v5h10.09V780H163.12v-5H153v5H142.94v10.09h-5v10.09h-5.05v35.32H183.3V800.21Zm15.13,20.18H160.6v5.05h-5v-5.05H153v-7.56h10.09Z" />'
                )
            );
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="19.9%" y="87%" text-anchor="middle" font-size="25" font-family="andale mono, monospace">-</text></svg>'
                )
            );
        }

        // ATTRIBUTES
        string memory attributes = string(
            abi.encodePacked(
                '{"trait_type": "Symbol", "value": "',
                logoInfos.symbol,
                '"},{"trait_type": "Claimable", "value": "',
                (_claimableInUsd / 10 ** 18 > 0 ? "Yes" : "No"),
                '"},{"trait_type": "Locked", "value": "',
                (_isLocked ? "Yes" : "No"),
                '"}'
            )
        );

        // METADATA
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "Staking Position #',
                        _toString(logoInfos.tokenId),
                        '","description": "Convergence Staking Position Token"',
                        ',"external_url": "https://app.cvg.finance/positions/sdt-staking/',
                        _toString(logoInfos.tokenId),
                        '","image": "data:image/svg+xml;base64,',
                        Base64.encode(bytes(output)),
                        '","attributes": [',
                        attributes,
                        "]}"
                    )
                )
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", json));
    }

    function setTokensLogo(string[] calldata _symbols, string[] calldata _tokensLogo) external onlyOwner {
        uint256 length = _tokensLogo.length;
        require(_symbols.length == length, "LENGTH_MISMATCH");

        for (uint256 i; i < length; ) {
            tokenLogo[_symbols[i]] = _tokensLogo[i];
            unchecked {
                ++i;
            }
        }
    }

    struct SetSdAssetInfo {
        address sdAsset;
        address asset;
        ICrvPoolPlain curvePool;
    }

    function setSdAssetInfos(SetSdAssetInfo[] calldata _setSdAssetInfos) external onlyOwner {
        for (uint256 i; i < _setSdAssetInfos.length; ) {
            sdAssetInfos[_setSdAssetInfos[i].sdAsset] = SdAssetInfo({
                asset: _setSdAssetInfos[i].asset,
                curvePool: _setSdAssetInfos[i].curvePool
            });
            unchecked {
                ++i;
            }
        }
    }

    function setOracle(ICvgOracle _cvgOracle) external onlyOwner {
        cvgOracle = _cvgOracle;
    }

    /// @dev Inspired by OraclizeAPI's implementation - MIT license
    /// https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
