// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface ICvgPepe is IERC721Enumerable {
    function getTokenIdsForWallet(address _wallet) external view returns (uint256[] memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}
