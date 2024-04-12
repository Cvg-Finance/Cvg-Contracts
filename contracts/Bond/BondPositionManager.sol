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

import "../Token/CvgERC721TimeLockingUpgradeable.sol";
import "../interfaces/ICvgControlTower.sol";

/// @title Cvg-Finance - BondPositionManager
/// @notice Manages bond positions
contract BondPositionManager is CvgERC721TimeLockingUpgradeable {
    /// @dev convergence ecosystem address
    ICvgControlTower public cvgControlTower;

    /// @dev BondDepository
    IBondDepository public bondDepository;

    /// @dev bong logo contract address
    IBondLogo internal logo;

    /// @dev base URI for the tokens
    string internal baseURI;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextId;

    /// @dev Bond ID per tokenId
    mapping(uint256 => uint256) public bondPerTokenId;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     *  @notice Initialize function of the bond position manager, can only be called once (by the clone factory).
     *  @param _cvgControlTower address of the control tower
     */
    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        __ERC721_init("Bond Positions", "BOND-CVG");
        _transferOwnership(msg.sender);
        nextId = 1;
        maxLockingTime = 10 days;
    }

    /**
     * @dev Function called on a deposit in the BondDepository.
     *      If, it's called with tokenId = 0, mint a new NFT and associate this NFT to the bondID
     *      Else, it's a position update, so we check the ownership of the token & its timelocking.
     *  @param bondId It's the bondId to associate on with the positionId
     *  @param tokenId It's the tokenId of the position to update or if 0, mint a new position.
     *  @param receiver Receiver address of the operation
     */
    function mintOrCheck(uint256 bondId, uint256 tokenId, address receiver) external returns (uint256) {
        require(address(bondDepository) == msg.sender, "NOT_BOND_DEPOSITORY");

        /// @dev If it's a token minting, we get & increment the nextId.
        if (tokenId == 0) {
            /// @dev Increments the new last ID of the collection
            tokenId = nextId++;
            /// @dev Associate the bondId with the tokenId
            bondPerTokenId[tokenId] = bondId;
            /// @dev Mint the tokenId to the receiver
            _mint(receiver, tokenId);
            return tokenId;
        }
        /// @dev Else, we verify that token is owned, not timelocked & that the token ID is linked to the proper bondID
        else {
            /// @dev Verify that receiver is always the NFT owner
            require(receiver == ownerOf(tokenId), "TOKEN_NOT_OWNED");
            /// @dev We verify that the tokenId is not timelocked
            require(unlockingTimestampPerToken[tokenId] < block.timestamp, "TOKEN_TIMELOCKED");

            /// @dev If the bond position is not linked to the bondId where it has been created
            if (bondId != bondPerTokenId[tokenId]) {
                /// @dev Only if the token has been fully claimable.
                require(bondDepository.positionInfos(tokenId).leftClaimable == 0, "NO_UPT_BOND_ID_ON_OPEN_POSITION");
                /// @dev link the new bondId to the tokenId
                bondPerTokenId[tokenId] = bondId;
            }
            return tokenId;
        }
    }

    /**
     * @dev Verifies the full compliance of a token. Checked during withdraw & claim.
     *      Checks that every positions are owned by the account.
     *      Checks that every positions are not timelocked.
     *  @param tokenIds of the bond positions.
     * @param caller Caller of the Redeem.
     */
    function checkTokenRedeem(uint256[] calldata tokenIds, address caller) external view {
        for (uint256 i; i < tokenIds.length; ) {
            /// @dev Verify that the caller is always the NFT owner
            require(caller == ownerOf(tokenIds[i]), "TOKEN_NOT_OWNED");
            /// @dev We verify that the tokenId is not timelocked
            require(unlockingTimestampPerToken[tokenIds[i]] < block.timestamp, "TOKEN_TIMELOCKED");
            unchecked {
                ++i;
            }
        }
    }

    /**
     *  @notice Burn a token if the position is fully claimed.
     *  @param tokenId to burn
     */
    function burn(uint256 tokenId) external onlyNftOwner(tokenId) {
        require(bondDepository.positionInfos(tokenId).leftClaimable == 0, "POSITION_STILL_OPEN");
        _burn(tokenId);
    }

    /**
     *  @notice Get the bond contracts associated to provided tokens.
     *  @param tokenIds IDs of the tokens
     *  @return array of bond contract
     */
    function getBondIdsOfTokens(uint256[] calldata tokenIds) external view returns (uint256[] memory) {
        uint256[] memory bondIds = new uint256[](tokenIds.length);
        for (uint256 index; index < tokenIds.length; ) {
            bondIds[index] = bondPerTokenId[tokenIds[index]];
            unchecked {
                ++index;
            }
        }
        return bondIds;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            URI & LOGO
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    function setBaseURI(string memory baseURI_) external onlyOwner {
        baseURI = baseURI_;
    }

    /**
     * @notice Set the logo contract.
     * @param _logo the new logo contract
     */
    function setLogo(IBondLogo _logo) external onlyOwner {
        logo = _logo;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /**
     *  @notice Get the URI of the token.
     *  @param tokenId ID of the token
     *  @return token URI
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        IBondLogo _logo = logo;
        if (address(_logo) == address(0)) {
            string memory localBaseURI = _baseURI();
            return
                bytes(localBaseURI).length > 0 ? string(abi.encodePacked(localBaseURI, Strings.toString(tokenId))) : "";
        }

        return _logo._tokenURI(logoInfo(tokenId));
    }

    /**
     *  @notice Get the logo information for the provided token ID.
     *  @param tokenId ID of the token
     *  @return logo information of the token
     */
    function logoInfo(uint256 tokenId) public view returns (IBondLogo.LogoInfos memory) {
        _requireMinted(tokenId);

        IBondStruct.TokenVestingInfo memory infos = bondDepository.getTokenVestingInfo(tokenId);
        return
            IBondLogo.LogoInfos({
                tokenId: tokenId,
                termTimestamp: infos.term,
                pending: infos.pending,
                cvgClaimable: infos.claimable,
                unlockingTimestamp: unlockingTimestampPerToken[tokenId]
            });
    }

    function setBondDepository(IBondDepository _bondDepository) external onlyOwner {
        bondDepository = _bondDepository;
    }
}
