// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal genesis-collection re-mint used to FORK-PROVE the ETH->C mechanism.
/// The canonical production contract is luxfi/standard contracts/nft/GenesisNFTs.sol
/// (migrateTokens 1:1 from the ETH snapshot). This mirrors its migration mechanic:
/// mint the NFT to the same holder address AND credit the bonded native LUX,
/// funded from the Fair-Launch reserve held by this contract (a MOVE, not a mint).
contract GenesisRemint {
    address public owner;                       // migration admin (e.g. Z/Team Safe or DAO)
    mapping(uint256 => address) public ownerOf;  // tokenId -> holder
    mapping(uint256 => uint256) public bondedLux;// tokenId -> bonded LUX credited
    uint256 public totalBondedPaid;

    constructor(address admin) { owner = admin; }
    receive() external payable {}

    /// Re-mint one token to `to` and credit its bonded LUX natively from reserve.
    function migrate(address to, uint256 tokenId, uint256 bonded) external {
        require(msg.sender == owner, "only owner");
        require(ownerOf[tokenId] == address(0), "already migrated");
        require(address(this).balance >= bonded, "reserve underfunded");
        ownerOf[tokenId] = to;
        bondedLux[tokenId] = bonded;
        totalBondedPaid += bonded;
        (bool ok,) = to.call{value: bonded}("");
        require(ok, "bond transfer failed");
    }
}
