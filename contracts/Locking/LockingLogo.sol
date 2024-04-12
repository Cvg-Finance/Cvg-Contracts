// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "../libs/Base64.sol";
import "../interfaces/ICvgControlTower.sol";

contract LockingLogo is Ownable2StepUpgradeable {
    /// @dev cvg control tower address
    ICvgControlTower internal cvgControlTower;

    ILockingPositionManager internal lockingPositionManager;

    ILockingPositionService internal lockingPositionService;

    ICvg internal cvg;

    uint256 internal startTdePriceFetching;

    /// @dev constants to define gauge data in SVG
    uint256 internal constant GAUGE_X_REFERENCE = 260;
    uint256 internal constant GAUGE_WIDTH = 449;

    uint256 internal constant TDE_DURATION = 12;

    uint256 internal constant NOT_FOUND_INDEX = 999;

    /// @dev gauge ysPercentage => GaugePosition
    mapping(uint256 => ILockingLogo.GaugePosition) internal gaugePositions;

    struct ClaimableData {
        IERC20Metadata token;
        uint256 tokenPrice;
        uint256 decimals;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;

        startTdePriceFetching = 1;

        /// @dev define gauge positions according to token's ysPercentage
        gaugePositions[10] = ILockingLogo.GaugePosition({ysWidth: 45, veWidth: 404});
        gaugePositions[20] = ILockingLogo.GaugePosition({ysWidth: 90, veWidth: 359});
        gaugePositions[30] = ILockingLogo.GaugePosition({ysWidth: 135, veWidth: 314});
        gaugePositions[40] = ILockingLogo.GaugePosition({ysWidth: 180, veWidth: 269});
        gaugePositions[50] = ILockingLogo.GaugePosition({ysWidth: 225, veWidth: 224});
        gaugePositions[60] = ILockingLogo.GaugePosition({ysWidth: 270, veWidth: 179});
        gaugePositions[70] = ILockingLogo.GaugePosition({ysWidth: 315, veWidth: 134});
        gaugePositions[80] = ILockingLogo.GaugePosition({ysWidth: 359, veWidth: 90});
        gaugePositions[90] = ILockingLogo.GaugePosition({ysWidth: 404, veWidth: 45});

        ILockingPositionService _lockingPositionService = _cvgControlTower.lockingPositionService();
        require(address(_lockingPositionService) != address(0), "LOCKING_SERVICE_ZERO");
        lockingPositionService = _lockingPositionService;

        ILockingPositionManager _lockingPositionManager = _cvgControlTower.lockingPositionManager();
        require(address(_lockingPositionManager) != address(0), "LOCKING_MANAGER_ZERO");
        lockingPositionManager = _lockingPositionManager;

        ICvg _cvg = _cvgControlTower.cvgToken();
        require(address(_cvg) != address(0), "CVG_TOKEN_ZERO");
        cvg = _cvg;

        address _treasuryDao = cvgControlTower.treasuryDao();
        require(_treasuryDao != address(0), "TREASURY_DAO_ZERO");
        _transferOwnership(_treasuryDao);
    }

    function setStartTdePriceFetching(uint256 tdeStart) external onlyOwner {
        startTdePriceFetching = tdeStart;
    }

    /// @dev Inspired by OraclizeAPI's implementation - MIT license
    ///      https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol
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

    /**
     *  @notice Finds the index of the _token in the _claimableData array
     *  @param _token address of the token to look up in the array
     *  @param _claimableData array containing token address and current price
     *  @param _arrayLength actual length of the _claimableData array
     */
    function _findIndex(
        IERC20Metadata _token,
        ClaimableData[] memory _claimableData,
        uint256 _arrayLength
    ) internal pure returns (uint256) {
        for (uint256 i; i < _arrayLength; ) {
            if (_claimableData[i].token == _token) {
                return i;
            }

            unchecked {
                ++i;
            }
        }

        return NOT_FOUND_INDEX;
    }

    /**
     *  @notice Calculates the claimable amount in USD for a specified token
     *  @param _tokenId token id
     *  @param _cvgCycle actual cvgCycle
     */
    function _getClaimableAmountInUsd(uint256 _tokenId, uint256 _cvgCycle) internal view returns (uint256) {
        uint256 claimableUsdAmount;
        ICvgControlTower _cvgControlTower = cvgControlTower;
        ICvgOracle _cvgOracle = _cvgControlTower.cvgOracle();

        uint256 _startTde = startTdePriceFetching;
        uint256 lastTde = (_cvgCycle - 1) / TDE_DURATION;

        uint256[] memory tdeCycles = new uint256[](lastTde + 1 - _startTde);

        for (uint256 i; _startTde <= lastTde; ) {
            tdeCycles[i] = _startTde;
            unchecked {
                ++i;
                ++_startTde;
            }
        }
        /// @dev Retrieve datas on the TDE we need to iterate on
        IYsDistributor.Claim[] memory tdeRecords = _cvgControlTower.ysDistributor().getPositionRewardsForTdes(
            tdeCycles,
            _cvgCycle,
            _tokenId
        );

        uint256 claimableDataLength;
        /// @dev We put an arbitrary value of 15. It means that if there are more than 15 tokens distributed over several TDE ( months ), the function will fail.
        /// To prevent this, we can increase the startTdePriceFetching value.
        ClaimableData[] memory claimableData = new ClaimableData[](15);

        /// @dev We iterate through all TDE
        for (uint256 i; i < tdeRecords.length; ) {
            /// @dev We only take into account TDE that are not claimed
            if (!tdeRecords[i].isClaimed) {
                /// @dev iteration through token & amounts deposited on the iterated TDE
                for (uint256 j; j < tdeRecords[i].tokenAmounts.length; ) {
                    IERC20Metadata token = IERC20Metadata(address(tdeRecords[i].tokenAmounts[j].token));
                    uint256 tokenIndex = _findIndex(token, claimableData, claimableDataLength);
                    /// @dev If the token price has not already been fetched
                    if (tokenIndex == NOT_FOUND_INDEX) {
                        claimableData[claimableDataLength] = ClaimableData({
                            token: token,
                            decimals: token.decimals(),
                            tokenPrice: _cvgOracle.getPriceUnverified(address(token))
                        });
                        claimableUsdAmount +=
                            (tdeRecords[i].tokenAmounts[j].amount * claimableData[claimableDataLength].tokenPrice) /
                            10 ** claimableData[claimableDataLength].decimals;

                        unchecked {
                            ++claimableDataLength;
                        }
                    }
                    /// @dev Else we don't have to fetch the price of the token
                    else {
                        claimableUsdAmount +=
                            (tdeRecords[i].tokenAmounts[j].amount * claimableData[tokenIndex].tokenPrice) /
                            10 ** claimableData[tokenIndex].decimals;
                    }
                    unchecked {
                        ++j;
                    }
                }
            }

            unchecked {
                ++i;
            }
        }
        return claimableUsdAmount;
    }

    function _getLockInfo(
        ILockingLogo.LogoInfos memory _logoInfos
    )
        internal
        view
        returns (
            uint256 cvgLockedInUsd,
            uint256 ysCvgActual,
            uint256 ysCvgNext,
            uint256 veCvg,
            ILockingLogo.GaugePosition memory gaugePosition,
            uint256 claimableInUsd,
            bool isLocked,
            uint256 hoursLock
        )
    {
        ICvgControlTower _cvgControlTower = cvgControlTower;
        uint256 actualTde;
        {
            uint256 actualCvgCycle = _cvgControlTower.cvgCycle();
            actualTde = (((actualCvgCycle - 1) / TDE_DURATION) + 1) * TDE_DURATION;
            claimableInUsd = _getClaimableAmountInUsd(_logoInfos.tokenId, actualCvgCycle);
        }

        cvgLockedInUsd =
            (_logoInfos.cvgLocked * _cvgControlTower.cvgOracle().getPriceUnverified(address(cvg))) /
            10 ** 18;

        if (_logoInfos.unlockingTimestamp > block.timestamp) {
            hoursLock = (_logoInfos.unlockingTimestamp - block.timestamp) / 3600;
            isLocked = true;
        }
        (ysCvgActual, ysCvgNext, veCvg) = (
            lockingPositionService.balanceOfYsCvgAt(_logoInfos.tokenId, actualTde),
            lockingPositionService.balanceOfYsCvgAt(_logoInfos.tokenId, actualTde + TDE_DURATION),
            cvgControlTower.votingPowerEscrow().balanceOf(_logoInfos.tokenId)
        );

        gaugePosition = gaugePositions[_logoInfos.ysPercentage];
    }

    function getLogoInfo(uint256 tokenId) external view returns (ILockingLogo.LogoInfosFull memory) {
        ILockingLogo.LogoInfos memory _logoInfo = lockingPositionManager.logoInfo(tokenId);
        (
            uint256 cvgLockedInUsd,
            uint256 ysCvgActual,
            uint256 ysCvgNext,
            uint256 veCvg,
            ILockingLogo.GaugePosition memory gaugePosition,
            uint256 claimableInUsd,
            bool isLocked,
            uint256 hoursLock
        ) = _getLockInfo(_logoInfo);

        return (
            ILockingLogo.LogoInfosFull({
                tokenId: _logoInfo.tokenId,
                cvgLocked: _logoInfo.cvgLocked,
                lockEnd: _logoInfo.lockEnd,
                ysPercentage: _logoInfo.ysPercentage,
                mgCvg: _logoInfo.mgCvg,
                unlockingTimestamp: _logoInfo.unlockingTimestamp,
                cvgLockedInUsd: cvgLockedInUsd,
                ysCvgActual: ysCvgActual,
                ysCvgNext: ysCvgNext,
                veCvg: veCvg,
                gaugePosition: gaugePosition,
                claimableInUsd: claimableInUsd,
                isLocked: isLocked,
                hoursLock: hoursLock
            })
        );
    }

    function _tokenURI(ILockingLogo.LogoInfos calldata _logoInfos) external view returns (string memory output) {
        (
            uint256 cvgLockedInUsd,
            uint256 ysCvgActual,
            uint256 ysCvgNext,
            uint256 veCvg,
            ILockingLogo.GaugePosition memory gaugePosition,
            uint256 claimableInUsd,
            bool isLocked,
            uint256 hoursLock
        ) = _getLockInfo(_logoInfos);

        output = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 1404.99"><path fill="#00f" d="M0 0h800v1404.99H0z"/><path stroke="#fff" stroke-miterlimit="10" stroke-width="5" d="M26 26.01h748v1352.98H26z"/><path fill="none" stroke="#fff" stroke-miterlimit="10" stroke-width="5" d="M41 41.33h718v1322.66H41z"/><path fill="#00f" d="m711.1 1251.57-27.17 47.54-6.79-11.88 13.58-23.78h-54.33l6.79-11.88h67.92z"/><path fill="#ff0" d="m717.89 1263.45-33.96 59.43-27.17-47.54h13.59l13.58 23.77 27.17-47.54 6.79 11.88z"/><path fill="red" d="m656.76 1275.34 27.17 47.54h-13.58l-33.96-59.43h54.33l-6.79 11.89h-27.17z"/><path fill="none" stroke="#fff" stroke-miterlimit="11.34" stroke-width="2" d="M601 78.99h117.39l-.5 219.56M199 1322.85l-116.89.38V1175.7"/><path fill="#fff" d="M116.96 1175.7h81.85v116.45h-81.85z"/><path fill="#00f" d="m269.35 111.99-66.59 116.54-16.65-29.14 33.3-58.27H86.22l16.65-29.13h166.48z"/><path fill="#ff0" d="M286 141.12 202.76 286.8l-66.59-116.54h33.29l33.3 58.27 66.59-116.54L286 141.12z"/><path fill="red" d="m136.17 170.26 66.59 116.54h-33.3L86.22 141.12h133.19l-16.65 29.14h-66.59z"/><path fill="#fff" fill-rule="evenodd" d="M717.89 536.4v43.8l-16.22 15.2H82.11v-59h635.78zm0 414.64v43.8l-16.22 15.2H82.11v-59h635.78zm0 105.5v43.8l-16.22 15.2H82.11v-59h635.78zm0-207.32v43.8l-16.22 15.2H82.11v-59h635.78zm0-414.64v43.8l-16.22 15.2H82.11v-59h635.78zm0 203.64v43.8l-16.22 15.2H82.11v-59h635.78zm0 105.5v43.8l-16.22 15.2H82.11v-59h635.78z"/><path d="M716.89 336.18v49H253.8v-49h463.09m5-5H248.8v59h473.09v-59Z" fill="#fff"/><path fill="#fff" fill-rule="evenodd" d="M227 331.19v43.8l-16.22 15.2H82.11v-59H227z"/><text transform="translate(408.56 212.43)" font-size="60" fill="#fff" font-family="andale mono, monospace" font-weight="bold">Lock</text><text transform="translate(103.48 370.47)" font-size="35" font-family="andale mono, monospace" font-weight="bold">ys/ve</text><text transform="translate(98.36 475.73)" font-size="35" font-family="andale mono, monospace" font-weight="bold">ID</text><text transform="translate(98.36 577.55)" font-size="35" font-family="andale mono, monospace" font-weight="bold">CVG Locked</text><text transform="translate(98.36 679.37)" font-size="35" font-family="andale mono, monospace" font-weight="bold">Lock end</text><text transform="translate(98.36 784.87)" font-size="35" font-family="andale mono, monospace" font-weight="bold">ysCVG</text><text transform="translate(98.36 890.37)" font-size="35" font-family="andale mono, monospace" font-weight="bold">veCVG</text><text transform="translate(98.36 992.18)" font-size="35" font-family="andale mono, monospace" font-weight="bold">mgCVG</text><text transform="translate(98.36 1097.68)" font-size="35" font-family="andale mono, monospace" font-weight="bold">Claimable</text>';

        if (_logoInfos.ysPercentage == 0) {
            output = string(
                abi.encodePacked(
                    output,
                    '<rect x="',
                    _toString(GAUGE_X_REFERENCE),
                    '" y="341.99" width="',
                    _toString(GAUGE_WIDTH),
                    '" height="37.33" fill="blue"/>'
                )
            );

            output = string(
                abi.encodePacked(
                    output,
                    '<text x="484.5" y="26.3%" text-anchor="middle" font-size="22" fill="#fff" font-family="andale mono, monospace">100%</text>'
                )
            );
        } else if (_logoInfos.ysPercentage == 100) {
            output = string(
                abi.encodePacked(
                    output,
                    '<rect x="',
                    _toString(GAUGE_X_REFERENCE),
                    '" y="341.99" width="',
                    _toString(GAUGE_WIDTH),
                    '" height="37.33" fill="#ff0"/>'
                )
            );

            output = string(
                abi.encodePacked(
                    output,
                    '<text x="484.5" y="26.3%" text-anchor="middle" font-size="22" fill="#1d1d1b" font-family="andale mono, monospace">100%</text>'
                )
            );
        } else {
            output = string(
                abi.encodePacked(
                    output,
                    '<rect x="',
                    _toString(GAUGE_X_REFERENCE),
                    '" y="341.99" width="',
                    _toString(gaugePosition.ysWidth),
                    '" height="37.33" fill="#ff0"/><rect x="',
                    _toString(GAUGE_X_REFERENCE + gaugePosition.ysWidth),
                    '" y="341.99" width="',
                    _toString(gaugePosition.veWidth),
                    '" height="37.33" fill="blue"/>'
                )
            );

            output = string(
                abi.encodePacked(
                    output,
                    '<text x="',
                    _toString(GAUGE_X_REFERENCE + (gaugePosition.ysWidth / 2)),
                    '" y="26.3%" text-anchor="middle" font-size="22" fill="#1d1d1b" font-family="andale mono, monospace">',
                    _toString(_logoInfos.ysPercentage),
                    '%</text><text x="',
                    _toString(GAUGE_X_REFERENCE + gaugePosition.ysWidth + (gaugePosition.veWidth / 2)),
                    '" y="26.3%" text-anchor="middle" font-size="22" fill="#fff" font-family="andale mono, monospace">',
                    _toString(100 - _logoInfos.ysPercentage),
                    "%</text>"
                )
            );
        }

        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="34%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(_logoInfos.tokenId),
                "</text>"
            )
        );
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="41.3%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(_logoInfos.cvgLocked / 10 ** 18),
                " ($",
                _toString(cvgLockedInUsd / 10 ** 18),
                ")</text>"
            )
        );
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="48.4%" text-anchor="end" font-size="35" font-family="andale mono, monospace">cvgCycle ',
                _toString(_logoInfos.lockEnd),
                "</text>"
            )
        );
        if (ysCvgActual == ysCvgNext || ysCvgNext == 0) {
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="87%" y="56%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                    _toString(ysCvgActual / 10 ** 18),
                    "</text>"
                )
            );
        } else {
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="87%" y="56%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                    _toString(ysCvgActual / 10 ** 18),
                    " / ",
                    _toString(ysCvgNext / 10 ** 18),
                    "</text>"
                )
            );
        }

        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="63.4%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(veCvg / 10 ** 18),
                "</text>"
            )
        );
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="70.8%" text-anchor="end" font-size="35" font-family="andale mono, monospace">',
                _toString(_logoInfos.mgCvg / 10 ** 18),
                "</text>"
            )
        );
        output = string(
            abi.encodePacked(
                output,
                '<text x="87%" y="78.2%" text-anchor="end" font-size="35" font-family="andale mono, monospace">$',
                _toString(claimableInUsd / 10 ** 18),
                "</text>"
            )
        );
        //LOCK
        if (isLocked) {
            //PADLOCK CLOSED GREEN
            output = string(
                abi.encodePacked(
                    output,
                    '<path fill="#00FF00" d="M178.07 1209.99v-10.1h-5v-10.09h-10.14v-5h-10.09v5h-10.09v10.09h-5v10.1h-5.05v35.31h50.45v-35.31Zm-15.14 20.18h-2.52v5h-5v-5h-2.53v-7.57h10.09Zm5-20.18H147.8v-10.1h5v-5h10.09v5h5Z" />'
                )
            );
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="19.9%" y="91%" text-anchor="middle" font-size="23" font-family="andale mono, monospace">&lt;',
                    _toString(hoursLock + 1),
                    " h</text></svg>"
                )
            );
        } else {
            //PADLOCK OPEN RED
            output = string(
                abi.encodePacked(
                    output,
                    '<path fill="#FF0000" d="M147.8,1212v-10.09h5v-5h10.09v5H173v-10.09H162.93v-5H152.84v5H142.75v10.09h-5V1212h-5.05v35.32h50.45V1212Zm15.13,20.18h-2.52v5h-5v-5h-2.52v-7.56h10.09Z" />'
                )
            );
            output = string(
                abi.encodePacked(
                    output,
                    '<text x="19.9%" y="91%" text-anchor="middle" font-size="25" font-family="andale mono, monospace">-</text></svg>'
                )
            );
        }

        // ATTRIBUTES
        string memory attributes = string(
            abi.encodePacked(
                '{"trait_type": "End Cycle", "value": "',
                _toString(_logoInfos.lockEnd),
                '"},{"trait_type": "Ys Percentage", "value": "',
                _toString(_logoInfos.ysPercentage),
                '"},{"trait_type": "Ve Percentage", "value": "',
                _toString(100 - _logoInfos.ysPercentage),
                '"},{"trait_type": "Claimable", "value": "',
                (claimableInUsd / 10 ** 18 > 0 ? "Yes" : "No"),
                '"},{"trait_type": "Locked", "value": "',
                (isLocked ? "Yes" : "No"),
                '"}'
            )
        );

        // METADATA
        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "Locking Position #',
                        _toString(_logoInfos.tokenId),
                        '","description": "Convergence Locking Position Token",',
                        '"external_url": "https://app.cvg.finance/positions/lock/',
                        _toString(_logoInfos.tokenId),
                        '","image": "data:image/svg+xml;base64,',
                        Base64.encode(bytes(output)),
                        '","attributes": [',
                        attributes,
                        "]}"
                    )
                )
            )
        );

        output = string(abi.encodePacked("data:application/json;base64,", json));
    }
}
