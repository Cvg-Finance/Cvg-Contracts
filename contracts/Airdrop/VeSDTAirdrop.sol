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

contract VeSDTAirdrop is Ownable {
    enum State {
        NOT_ACTIVE,
        ACTIVE
    }
    uint256 public constant CLAIM = 1000 * 10 ** 18;
    uint256 public constant MAX_LOCK = 96;
    ICvgControlTower public immutable cvgControlTower;
    ICvg public immutable cvg;
    ILockingPositionService public immutable lockingPositionService;
    address public immutable treasuryAirdrop;

    State public state;
    bytes32 public merkleRoot;
    uint256 public cvgClaimable = 300_000 * 10 ** 18;
    mapping(address => bool) public isClaimed;

    constructor(ICvgControlTower _cvgControlTower) {
        cvgControlTower = _cvgControlTower;
        ILockingPositionService _lockingPositionService = _cvgControlTower.lockingPositionService();
        ICvg _cvg = _cvgControlTower.cvgToken();
        address _treasuryAirdrop = _cvgControlTower.treasuryAirdrop();
        address _treasuryDao = _cvgControlTower.treasuryDao();
        require(address(_lockingPositionService) != address(0), "LOCKING_ZERO");
        require(address(_cvg) != address(0), "CVG_ZERO");
        require(_treasuryAirdrop != address(0), "TREASURY_AIRDROP_ZERO");
        require(_treasuryDao != address(0), "TREASURY_DAO_ZERO");
        lockingPositionService = _lockingPositionService;
        cvg = _cvg;
        treasuryAirdrop = _treasuryAirdrop;

        cvg.approve(address(_lockingPositionService), cvgClaimable);
        _transferOwnership(_treasuryDao);
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            EXTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */

    function claim(bytes32[] calldata _merkleProof) external {
        require(state == State.ACTIVE, "CLAIM_NOT_ACTIVE");
        require(merkleVerify(_merkleProof), "INVALID_PROOF");
        require(!isClaimed[msg.sender], "ALREADY_CLAIMED");
        require(cvgClaimable >= CLAIM, "CLAIM_OVER");
        cvgClaimable -= CLAIM;
        isClaimed[msg.sender] = true;
        cvg.transferFrom(treasuryAirdrop, address(this), CLAIM);
        lockingPositionService.mintPosition(
            uint24(MAX_LOCK - cvgControlTower.cvgCycle()),
            uint96(CLAIM),
            0,
            msg.sender,
            true
        );
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            SETTERS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function startAirdrop(bytes32 _merkleRoot) external onlyOwner {
        require(cvg.allowance(treasuryAirdrop, address(this)) >= cvgClaimable, "ALLOWANCE_INSUFFICIENT");
        merkleRoot = _merkleRoot;
        state = State.ACTIVE;
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /* =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-=
                            INTERNALS
    =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=--=-=-=-= */
    function merkleVerify(bytes32[] calldata _merkleProof) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        return MerkleProof.verify(_merkleProof, merkleRoot, leaf);
    }
}
