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

/*
 * @title Cvg-Finance - LockingPositionManager
 * @notice This is  an NFT contract  representing a locking position.
 * @dev This contract inherits the time lock functionality from CvgERC721TimeLockingUpgradeable
 * this contract is not callable directly, only through the LockingPositionService for Mint & Burn.
 */
contract LockingPositionManager is CvgERC721TimeLockingUpgradeable {
    /** @dev ConvergenceControlTower ControlTower. */
    ICvgControlTower public cvgControlTower;

    /// @dev LockingPosition Service.
    ILockingPositionService public lockingPositionService;

    /// @dev LockingPosition Delegate.
    ILockingPositionDelegate public lockingPositionDelegate;

    ILockingLogo public logo;

    /** @dev The ID of the next token that will be minted. Skips 0. */
    uint256 public nextId;

    string internal baseURI;

    /** @custom:oz-upgrades-unsafe-allow constructor */
    constructor() {
        _disableInitializers();
    }

    function initialize(ICvgControlTower _cvgControlTower) external initializer {
        cvgControlTower = _cvgControlTower;
        __ERC721_init("Locking Convergence", "LCK-CVG");
        _transferOwnership(msg.sender);
        nextId = 1;
        maxLockingTime = 10 days;

        ILockingPositionDelegate _lockingPositionDelegate = _cvgControlTower.lockingPositionDelegate();
        require(address(_lockingPositionDelegate) != address(0), "DELEGATION_ZERO");
        lockingPositionDelegate = _lockingPositionDelegate;
    }

    /**
     * @notice Check and Revert if the _tokenId passed in parameters is not owned by the _operator
     * @param _tokenId ID of the token.
     * @param _operator Address of the operator.
     */
    function checkOwnership(uint256 _tokenId, address _operator) external view {
        require(_operator == ownerOf(_tokenId), "TOKEN_NOT_OWNED");
    }

    /**
     * @notice Check and Revert if all _tokenIds passed in parameters are not owned by the _operator
     * @param _tokenIds ID of the tokens to iterate on.
     * @param _operator Address of the operator.
     */
    function checkOwnerships(uint256[] memory _tokenIds, address _operator) external view {
        for (uint256 i; i < _tokenIds.length; ) {
            require(_operator == ownerOf(_tokenIds[i]), "TOKEN_NOT_OWNED");
            unchecked {
                ++i;
            }
        }
    }

    /**
     *  @notice Check if the token is compliant to be manipulated.
     *   Check the token Ownership & the timelocking of the position.
     *   Time lock is a feature that protects a potential buyer of a token from a malicious front run from the seller.
     *  @param tokenId ID of the token.
     *  @param operator address of the operator.
     */
    function checkFullCompliance(uint256 tokenId, address operator) external view {
        require(operator == ownerOf(tokenId), "TOKEN_NOT_OWNED");
        require(unlockingTimestampPerToken[tokenId] < block.timestamp, "TOKEN_TIMELOCKED");
    }

    /**
     * @notice Mint a Locking position to the lock creator.
     * @dev Only callable through the mintPosition on the LockingPositionService.
     * @param account to mint the Lock Position
     */
    function mint(address account) external returns (uint256) {
        require(msg.sender == address(lockingPositionService), "NOT_LOCKING_SERVICE");
        /// @dev Increments the new last ID of the collection
        uint256 tokenId = nextId++;
        /// @dev Mint the tokenId to the receiver
        _mint(account, tokenId);
        return tokenId;
    }

    /**
     * @notice Burn a Locking position.
     * @dev Only callable through the burn on the LockingPositionService.
     * @param tokenId to burn
     */
    function burn(uint256 tokenId, address caller) external {
        require(msg.sender == address(lockingPositionService), "NOT_LOCKING_SERVICE");
        require(caller == ownerOf(tokenId), "TOKEN_NOT_OWNED");
        _burn(tokenId);
    }

    /**
     * @notice Checks for a token ID that the caller can claim it's TDE rewards
     * @param tokenId TokenId of the position to claim
     * @param caller Address to check if it's possible to claim with
     */
    function checkYsClaim(uint256 tokenId, address caller) external view {
        require(unlockingTimestampPerToken[tokenId] < block.timestamp, "TOKEN_TIMELOCKED");
        require(
            caller == ownerOf(tokenId) || caller == lockingPositionDelegate.delegatedYsCvg(tokenId),
            "NOT_OWNED_OR_DELEGATEE"
        );
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            URI & LOGO
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    /**
     * @notice Set LockingPositionService.
     * @param _lockingPositionService LockingPositionService contract to set
     */
    function setLockingPositionService(ILockingPositionService _lockingPositionService) external onlyOwner {
        lockingPositionService = _lockingPositionService;
    }

    /**
     * @notice Set the logo contract.
     * @param _logo the new logo contract
     */
    function setLogo(ILockingLogo _logo) external onlyOwner {
        logo = _logo;
    }

    /**
     * @notice Set the base URI for all token IDs.
     * @param _newBaseURI the new base url of all tokens
     */
    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    /**
     * @notice Get the url for a specific token.
     * @param tokenId id of the token
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireMinted(tokenId);

        ILockingLogo _logo = logo;
        if (address(_logo) == address(0)) {
            string memory localBaseURI = _baseURI();
            return
                bytes(localBaseURI).length > 0 ? string(abi.encodePacked(localBaseURI, Strings.toString(tokenId))) : "";
        }

        return _logo._tokenURI(logoInfo(tokenId));
    }

    /**
     * @notice Retrieve the logo details for a particular token for svg display.
     * @param tokenId id of the token
     */
    function logoInfo(uint256 tokenId) public view returns (ILockingLogo.LogoInfos memory) {
        ILockingPositionService.LockingInfo memory _lockingInfo = lockingPositionService.lockingInfo(tokenId);
        return
            ILockingLogo.LogoInfos({
                tokenId: _lockingInfo.tokenId,
                cvgLocked: _lockingInfo.cvgLocked,
                lockEnd: _lockingInfo.lockEnd,
                ysPercentage: _lockingInfo.ysPercentage,
                mgCvg: _lockingInfo.mgCvg,
                unlockingTimestamp: unlockingTimestampPerToken[tokenId]
            });
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /**
     * @notice Use before transfer hook to clean all delegatees of a token before transferring it.
     * @param from address of the sender
     * @param to address of the receiver
     * @param tokenId ID of the transferred token
     * @param batchSize size of the batch (not used in our case)
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);

        cvgControlTower.lockingPositionDelegate().cleanDelegateesOnTransfer(tokenId);
    }
}
