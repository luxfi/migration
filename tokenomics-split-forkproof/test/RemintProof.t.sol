// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenesisRemint} from "../src/GenesisRemint.sol";

/// Fork-proof the lux.town ETH->C-Chain genesis-collection re-mint on live 96369.
contract RemintProof is Test {
    address constant DAO_SAFE = 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2; // must stay 1T (genesis preserved)
    address constant Z_SAFE   = 0x864297c069E924a12a3CFEF294aeBB8500507d31; // unsold route
    // real ETH-side genesis holders (from standard/docs/genesis-nft-snapshot.md)
    address constant HOLDER_A = 0xb7C5819f928A02FF3946B369d997e1d52712bf41; // 11 NFTs
    address constant HOLDER_B = 0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e; // 6 NFTs
    uint256 constant LUX = 1e18;
    uint256 constant ONE_T = 1_000_000_000_000 * LUX;
    uint256 constant GENESIS_BOND = 1_000_000_000 * LUX; // 1B per Genesis Validator NFT

    function test_remint_sold_to_holders_unsold_to_zsafe_preserving_2T() public {
        // C-Chain genesis preserved: DAO Safe still exactly 1T at fork head
        assertEq(DAO_SAFE.balance, ONE_T, "C-Chain genesis preserved (DAO=1T)");

        // deploy re-mint contract, admin = Z/Team Safe; fund from Fair-Launch reserve
        GenesisRemint g = new GenesisRemint(Z_SAFE);
        uint256 reserve = 60 * GENESIS_BOND; // sample reserve (60B) from Fair-Launch
        vm.deal(address(g), reserve);

        uint256 aBefore = HOLDER_A.balance;
        uint256 bBefore = HOLDER_B.balance;
        uint256 zBefore = Z_SAFE.balance;

        vm.startPrank(Z_SAFE);
        // SOLD: re-mint to the SAME holder address (ETH 0x == C 0x), credit bonded LUX
        g.migrate(HOLDER_A, 8,  GENESIS_BOND);
        g.migrate(HOLDER_B, 1,  GENESIS_BOND);
        // UNSOLD: route NFT + bonded LUX to Z/Team Safe
        g.migrate(Z_SAFE,   99, GENESIS_BOND);
        vm.stopPrank();

        // holders received their NFT + bonded LUX natively
        assertEq(g.ownerOf(8), HOLDER_A, "NFT 8 -> holder A");
        assertEq(g.ownerOf(1), HOLDER_B, "NFT 1 -> holder B");
        assertEq(g.ownerOf(99), Z_SAFE, "unsold NFT 99 -> Z Safe");
        assertEq(HOLDER_A.balance - aBefore, GENESIS_BOND, "holder A got 1B bonded");
        assertEq(HOLDER_B.balance - bBefore, GENESIS_BOND, "holder B got 1B bonded");
        assertEq(Z_SAFE.balance - zBefore, GENESIS_BOND, "Z Safe got unsold 1B bonded");

        // bonded LUX is a MOVE from reserve, not a mint: contract balance dropped by 3B
        assertEq(address(g).balance, reserve - 3 * GENESIS_BOND, "reserve debited, no mint");
        assertEq(g.totalBondedPaid(), 3 * GENESIS_BOND, "3B bonded paid total");

        // DAO Safe untouched -> C-Chain 2T composition preserved
        assertEq(DAO_SAFE.balance, ONE_T, "DAO still 1T after re-mint");
    }
}
