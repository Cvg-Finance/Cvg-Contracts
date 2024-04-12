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

import "../interfaces/ICvgControlTower.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract QuestAirdrop is Ownable {
    enum State {
        NOT_ACTIVE,
        ACTIVE
    }
    ICvgControlTower public immutable cvgControlTower;
    ICvg public immutable cvg;
    address public immutable treasuryAirdrop;

    uint256 private constant AIRDROP_AMOUNT = 1000 * 10 ** 18; //TODO: How many ?
    uint256 public constant CLIFF_PERCENT = 2000;
    uint256 public constant DENOMINATOR = 10000;

    State public state;
    bytes32 public merkleRoot;
    uint256 public startTimestamp;
    mapping(address => bool) public isClaimed;

    constructor(ICvgControlTower _cvgControlTower) {
        cvgControlTower = _cvgControlTower;
        ICvg _cvg = _cvgControlTower.cvgToken();
        address _treasuryAirdrop = _cvgControlTower.treasuryAirdrop();
        address _treasuryDao = _cvgControlTower.treasuryDao();
        require(address(_cvg) != address(0), "CVG_ZERO");
        require(_treasuryAirdrop != address(0), "TREASURY_AIRDROP_ZERO");
        require(_treasuryDao != address(0), "TREASURY_DAO_ZERO");
        cvg = _cvg;
        treasuryAirdrop = _treasuryAirdrop;
        _transferOwnership(_treasuryDao);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    function claim(uint256 maxAmount, bytes32[] calldata _merkleProof) external {
        require(state == State.ACTIVE, "CLAIM_NOT_ACTIVE");
        require(merkleVerify(maxAmount, _merkleProof), "INVALID_PROOF");
        require(!isClaimed[msg.sender], "ALREADY_CLAIMED");
        isClaimed[msg.sender] = true;
        uint256 claimableAmount = getClaimableAmount(maxAmount);
        require(claimableAmount != 0, "ZERO_CLAIMABLE");
        cvg.transferFrom(treasuryAirdrop, msg.sender, claimableAmount);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            SETTERS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function startAirdrop(bytes32 _merkleRoot) external onlyOwner {
        require(cvg.allowance(treasuryAirdrop, address(this)) >= AIRDROP_AMOUNT, "ALLOWANCE_INSUFFICIENT");
        merkleRoot = _merkleRoot;
        state = State.ACTIVE;
        startTimestamp = block.timestamp;
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            INTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function getClaimableAmount(uint256 maxAmount) internal view returns (uint256) {
        uint256 claimableAmount;
        uint256 _startVestingTimestamp = startTimestamp;
        uint256 _endVestingTimestamp = _startVestingTimestamp + 60 days;

        if (block.timestamp > _startVestingTimestamp) {
            if (block.timestamp >= _endVestingTimestamp) {
                claimableAmount = maxAmount;
            } else {
                uint256 cliffAmount = (maxAmount * CLIFF_PERCENT) / DENOMINATOR;
                uint256 ratio = ((_endVestingTimestamp - block.timestamp) * 1 ether) /
                    (_endVestingTimestamp - _startVestingTimestamp);
                claimableAmount = cliffAmount + (((1 ether - ratio) * (maxAmount - cliffAmount)) / 1 ether);
            }
        }

        return claimableAmount;
    }

    function merkleVerify(uint256 amount, bytes32[] calldata _merkleProof) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encode(msg.sender, amount));
        return MerkleProof.verify(_merkleProof, merkleRoot, leaf);
    }
}
