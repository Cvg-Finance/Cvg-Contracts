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

import "../interfaces/IPresaleCvgWl.sol";
import "../interfaces/IboInterface.sol";
import "../interfaces/ICvg.sol";

import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract BoostWlIbo is Ownable2Step {
    enum State {
        NOT_ACTIVE,
        ACTIVE
    }
    State public state;

    mapping(uint256 => uint256) public iboAlreadyClaimed;
    mapping(uint256 => uint256) public wlAlreadyClaimed;

    address public constant treasuryDao = 0x0af815364BD9e9E60f3d2D3bAc1320B77d3E35F7;
    address public constant treasuryAirdrop = 0xCD6cfCE8c8D3b6Efad27390e87D6931d4078B36c;
    IPresaleCvgWl public constant wlPresale = IPresaleCvgWl(0xc9740aa94A8A02a3373f5F1b493D7e10d99AE811);
    IboInterface public constant iboPresale = IboInterface(0x5F02134C35449D9b6505723A56b02581356320fB);
    ICvg public constant cvg = ICvg(0x97efFB790f2fbB701D88f89DB4521348A2B77be8);
    uint256 public constant TOTAL_CVG_AMOUNT_BOOST = 165600000000000000000000;

    uint256 private constant SIXTY_DAYS = 5_184_000;
    uint256 private constant FIVE_PERCENT = 500_000;
    uint256 private constant HUNDRED_PERCENT = 10_000_000;
    uint256 private constant PRECISION_PADDING = 100_000;

    uint256 public vestingStart;
    uint256 public vestingEnd;

    constructor() {
        _transferOwnership(treasuryDao);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function getClaimableAmount(uint256 totalBoost, uint256 alreadyClaimed) public view returns (uint256) {
        if (state == State.NOT_ACTIVE) {
            return 0;
        }
        uint256 amountClaimable;
        if (block.timestamp >= vestingEnd) {
            amountClaimable = totalBoost - alreadyClaimed;
        } else {
            amountClaimable =
                ((totalBoost * (block.timestamp - vestingStart) * PRECISION_PADDING) /
                    (SIXTY_DAYS * PRECISION_PADDING)) -
                alreadyClaimed;
        }

        return amountClaimable;
    }

    function claimBoostWl(uint256 tokenId) external {
        require(state == State.ACTIVE, "CLAIM_NOT_ACTIVE");
        require(wlPresale.ownerOf(tokenId) == msg.sender, "WL_POSITION_NOT_OWNED");
        uint256 alreadyClaimed = wlAlreadyClaimed[tokenId];

        uint256 totalBoost = (wlPresale.presaleInfos(tokenId).cvgAmount * FIVE_PERCENT) / HUNDRED_PERCENT;
        uint256 amountClaimable = getClaimableAmount(totalBoost, alreadyClaimed);

        require(amountClaimable != 0, "NOTHING_CLAIMABLE");
        wlAlreadyClaimed[tokenId] = alreadyClaimed + amountClaimable;

        cvg.transferFrom(treasuryAirdrop, msg.sender, amountClaimable);
    }

    function claimBoostIbo(uint256 tokenId) external {
        require(state == State.ACTIVE, "CLAIM_NOT_ACTIVE");
        require(iboPresale.ownerOf(tokenId) == msg.sender, "IBO_POSITION_NOT_OWNED");
        uint256 alreadyClaimed = iboAlreadyClaimed[tokenId];
        uint256 totalBoost = (iboPresale.totalCvgPerToken(tokenId) * FIVE_PERCENT) / HUNDRED_PERCENT;

        uint256 amountClaimable = getClaimableAmount(totalBoost, alreadyClaimed);
        require(amountClaimable != 0, "NOTHING_CLAIMABLE");
        iboAlreadyClaimed[tokenId] = alreadyClaimed + amountClaimable;

        cvg.transferFrom(treasuryAirdrop, msg.sender, amountClaimable);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            SETTERS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function startAirdrop() external onlyOwner {
        require(cvg.allowance(treasuryAirdrop, address(this)) >= TOTAL_CVG_AMOUNT_BOOST, "INSUFFICIENT_ALLOWANCE");
        require(state == State.NOT_ACTIVE, "CLAIM_ALREADY_ACTIVE");
        state = State.ACTIVE;
        vestingStart = block.timestamp;
        vestingEnd = block.timestamp + SIXTY_DAYS;
    }
}
