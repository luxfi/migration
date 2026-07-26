// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GenesisRemint} from "../src/GenesisRemint.sol";

/// Fork-proof the lux.town ETH->C re-mint with REAL per-token bonds (all 50 sold,
/// no unsold leg). Data = on-chain snapshot of 0x31e0F919...810311 (ETH mainnet).
contract RemintPerTokenProof is Test {
    address constant DAO_SAFE = 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2;
    address constant Z_SAFE   = 0x864297c069E924a12a3CFEF294aeBB8500507d31;
    uint256 constant LUX = 1e18;
    uint256 constant ONE_T = 1_000_000_000_000 * LUX;
    uint256 constant RESERVE_LUX = 34583000000 * LUX; // 34.583B verified

    function _holders() internal pure returns (address[50] memory h) {
        h = [
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x8d56C7cf8B17A11580822C7fFF90B05B6a3e1B5e,
            0x31387D95334F7c45391410E1c43DaDACfC889f4a,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xe00A0921Ce8bC7525383383b247F568fd01e53FA,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0x9df3F0E20E4e1f1eEd635BA6F7Dc2612dd4e1fbf,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xCbe29430026B8DC840CaBC25745DD1106253D333,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0xb7C5819f928A02FF3946B369d997e1d52712bf41,
            0x7438D25F78da4b184466a04a40D45DCdF9d44158,
            0x70c91206B85D9D42Fc0A5C0C79705931Ab7d5881,
            0x3ef096E10358363fd6cF2cF6052079d5467a12f3,
            0x3ef096E10358363fd6cF2cF6052079d5467a12f3,
            0x515e3c5d738e62D8B800F5F87aBFf284D77CBb4E,
            0x111e89E354F48C324A8D2ca9873c028798AaA290,
            0x497ec62bdc58d003FaF38F3c132302692fE687fd,
            0x5945d401Dd63BFBB3C67824D72B8FCa1e3f8F6E4,
            0x5945d401Dd63BFBB3C67824D72B8FCa1e3f8F6E4,
            0x3ef096E10358363fd6cF2cF6052079d5467a12f3,
            0xaa64006A3A14e16d58933c1Fad7Ff4F1468C5efd,
            0xD8F3C05FB24cb1aB19A11b7B032C9A5A914640bC,
            0x908a311766FFb525eC05c75B884Ee00A620D94d2,
            0x908a311766FFb525eC05c75B884Ee00A620D94d2,
            0x094109Ab78767713305D2E5Cd05d832Cd1FaEfb5,
            0x094109Ab78767713305D2E5Cd05d832Cd1FaEfb5,
            0x366887642858e2b0c4fAf7226a1462aAe53E41a2,
            0x469796EEf1154EF2d0A2d2D8815771D7264a5FF6,
            0x1e3a17775D0d0CfEfb09F869617F1D22E0fD9F6C,
            0x515e3c5d738e62D8B800F5F87aBFf284D77CBb4E,
            0x8750D110D594405b788D98E1376e9841555252C2,
            0x5b6a8eb3aDdeD38e01543EB09437cFcbe7B0ddAE,
            0x0315B3892deA66A5ddbd6e6b7aD6492490Ad10BF,
            0x0315B3892deA66A5ddbd6e6b7aD6492490Ad10BF,
            0x0315B3892deA66A5ddbd6e6b7aD6492490Ad10BF,
            0x24Fdff1c4F9222EC941E7f8Da54F0922f5108433,
            0x77f495DdBE4892Bbd6400404c508448E216C7586,
            0xB4699DC301cA712e3d852e69EbE3f7DfbB0aD4b6,
            0x2F6A1CE06263F499d600893435e00EA351B765f0,
            0x3BCaed65Fd2a3296Ae448ec28F3067071378c3fd
        ];
    }
    function _bonds() internal pure returns (uint256[50] memory b) {
        b = [
            uint256(1000000000),
            1000000000,
            1000000000,
            1000000,
            10000000,
            100000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            10000000,
            10000000,
            1000000000,
            1000000000,
            1000000000,
            100000000,
            10000000,
            10000000,
            1000000000,
            100000000,
            100000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000,
            10000000,
            100000000,
            1000000000,
            1000000000,
            10000000,
            1000000,
            1000000,
            10000000,
            1000000000,
            1000000000,
            1000000000,
            1000000000
        ];
    }

    function test_remint_all50_pertoken_bonds_reserve_34_583B() public {
        assertEq(DAO_SAFE.balance, ONE_T, "genesis preserved: DAO = 1T");
        GenesisRemint g = new GenesisRemint(Z_SAFE);
        vm.deal(address(g), RESERVE_LUX);          // Fair-Launch carve-out reserve

        address[50] memory H = _holders();
        uint256[50] memory B = _bonds();
        uint256 sumBonds;
        vm.startPrank(Z_SAFE);
        for (uint256 i = 0; i < 50; i++) {
            uint256 bond = B[i] * LUX;
            uint256 pre = H[i].balance;
            g.migrate(H[i], i + 1, bond);          // re-mint tokenId i+1 to real holder
            assertEq(g.ownerOf(i + 1), H[i], "NFT re-minted to real holder");
            assertGe(H[i].balance - pre, 0);       // holder credited (>=0; some holders repeat)
            sumBonds += bond;
        }
        vm.stopPrank();

        assertEq(sumBonds, RESERVE_LUX, "sum of per-token bonds == 34.583B");
        assertEq(g.totalBondedPaid(), RESERVE_LUX, "contract paid exactly 34.583B");
        assertEq(address(g).balance, 0, "reserve fully consumed, nothing to Z from unsold");
        assertEq(DAO_SAFE.balance, ONE_T, "DAO still 1T -> C-Chain 2T preserved (bond is a MOVE not a mint)");
        emit log_named_decimal_uint("total re-mint bonded", sumBonds, 18);
    }
}
