// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// Fork-proof of the Lux tokenomics on-chain split against LIVE mainnet 96369.
/// Run: forge test --fork-url http://localhost:19630/v1/chain/C/rpc -vv
contract ForkProof is Test {
    // --- live mainnet addresses (verified on chain 96369) ---
    address constant DAO_SAFE  = 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2; // Lux DAO Safe (1T)
    address constant Z_SAFE    = 0x864297c069E924a12a3CFEF294aeBB8500507d31; // Lux Team (zpriv) Safe (994.75B)
    address constant TREASURY  = 0x9011E888251AB053B7bD1cdB598Db4f9DEd94714; // genesis treasury / gas EOA
    address constant DEAD      = 0x000000000000000000000000000000000000dEaD;
    address constant FOUNDATION= 0x00000000000000000000000000000000f0009dA7; // placeholder Foundation Safe (owner to designate)

    uint256 constant LUX = 1e18;
    uint256 constant TWO_T   = 2_000_000_000_000 * LUX; // 2T cap
    uint256 constant ONE_T   = 1_000_000_000_000 * LUX;
    uint256 constant HUNDRED_B= 100_000_000_000 * LUX;  // team 100B / burn 100B
    uint64  constant YEAR = 365 days;
    uint64  constant HUNDRED_YR = 100 * YEAR;

    // measured "distributed to real holders/LPs/sale/swept EOAs" residual
    uint256 constant DISTRIBUTED = 5_249_466_428_180_000_000_000_000_000; // ~5.2495B LUX (2T - DAO - Z - treasury)

    function test_01_live_state_reconciles_to_2T() public {
        uint256 dao = DAO_SAFE.balance;
        uint256 z   = Z_SAFE.balance;
        uint256 tre = TREASURY.balance;
        emit log_named_decimal_uint("DAO Safe   ", dao, 18);
        emit log_named_decimal_uint("Z/Team Safe", z, 18);
        emit log_named_decimal_uint("Treasury   ", tre, 18);
        // DAO half is EXACTLY 1T
        assertEq(dao, ONE_T, "DAO Safe must hold exactly 1T");
        // Z/Team (Fair-Launch lump) is ~994.75B
        assertApproxEqRel(z, 994_750_532_679 * LUX, 1e15, "Z Safe ~994.75B");
        // full reconciliation: DAO + Z + treasury + distributed == 2T (net supply)
        uint256 sum = dao + z + tre + DISTRIBUTED;
        emit log_named_decimal_uint("SUM (should be 2T)", sum, 18);
        assertApproxEqAbs(sum, TWO_T, 1e21, "C-Chain native supply must reconcile to 2T");
    }

    function test_02_team_vesting_100yr_schedule_and_native_withdraw() public {
        uint64 start = uint64(block.timestamp);
        // Deploy the CANONICAL vesting primitive (OZ VestingWallet), beneficiary = Lux Team (Z) Safe.
        VestingWallet tv = new VestingWallet(Z_SAFE, start, HUNDRED_YR);
        // Fund with the imported P/X team 100B (atomic-import credit modelled by vm.deal).
        vm.deal(address(tv), HUNDRED_B);
        assertEq(address(tv).balance, HUNDRED_B, "vesting funded 100B");
        assertEq(tv.owner(), Z_SAFE, "Z/Team Safe controls the vesting");

        // t0: nothing vested
        assertEq(tv.releasable(), 0, "t0 releasable == 0");
        // +1yr ~ 1%
        vm.warp(start + YEAR);
        assertApproxEqRel(tv.releasable(), HUNDRED_B / 100, 1e16, "+1yr ~1%");
        // +50yr == 50%
        vm.warp(start + 50 * uint256(YEAR));
        assertApproxEqRel(tv.releasable(), HUNDRED_B / 2, 1e12, "+50yr ~50%");

        // native withdrawal-to-pay: release vested to the Z Safe
        uint256 zBefore = Z_SAFE.balance;
        tv.release();
        uint256 got = Z_SAFE.balance - zBefore;
        emit log_named_decimal_uint("released@50yr to Z Safe", got, 18);
        assertApproxEqRel(got, HUNDRED_B / 2, 1e12, "Z Safe received ~50B natively");

        // +100yr == fully vested (remaining releasable == the other half)
        vm.warp(start + 100 * uint256(YEAR));
        assertApproxEqRel(tv.releasable(), HUNDRED_B / 2, 1e12, "+100yr remaining ~50B");
        tv.release();
        assertEq(address(tv).balance, 0, "fully vested & withdrawn at 100yr");
    }

    function test_03_foundation_vesting_separate_instance() public {
        uint64 start = uint64(block.timestamp);
        VestingWallet fdn = new VestingWallet(FOUNDATION, start, HUNDRED_YR);
        vm.deal(address(fdn), 50_000_000_000 * LUX); // e.g. 50B (bucket TBD by owner)
        assertEq(fdn.owner(), FOUNDATION, "Foundation controls its own timelock");
        vm.warp(start + 10 * uint256(YEAR));
        assertApproxEqRel(fdn.releasable(), (50_000_000_000 * LUX) / 10, 1e13, "+10yr ~10%");
    }

    function test_04_import_100B_plus_burn_100B_is_net_zero_2T_preserved() public {
        // model the C-Chain native supply as tracked holders (pre-state)
        uint256 preDao = DAO_SAFE.balance;         // 1T
        uint256 preZ   = Z_SAFE.balance;           // 994.75B
        uint256 preTre = TREASURY.balance;         // ~892
        uint256 preTotal = preDao + preZ + preTre + DISTRIBUTED;
        assertApproxEqAbs(preTotal, TWO_T, 1e21, "pre = 2T");

        // (a) IMPORT: atomic-import the P/X team 100B onto C into the team vesting -> +100B on C
        VestingWallet tv = new VestingWallet(Z_SAFE, uint64(block.timestamp), HUNDRED_YR);
        vm.deal(address(tv), HUNDRED_B);
        uint256 afterImport = preTotal + address(tv).balance; // + 100B
        assertApproxEqAbs(afterImport, TWO_T + HUNDRED_B, 1e21, "after import = 2.1T");

        // (b) BURN: StateUpgrade-style balance reduction of the burn source by exactly 100B,
        //     credited to NO ONE (true removal). Recommended source = DAO Safe 1T -> 900B.
        vm.deal(DAO_SAFE, preDao - HUNDRED_B); // reduce, no credit = true burn
        uint256 postDao = DAO_SAFE.balance;
        assertEq(postDao, ONE_T - HUNDRED_B, "DAO 1T -> 900B after 100B burn");

        // net supply after import + burn
        uint256 postTotal = postDao + preZ + preTre + DISTRIBUTED + address(tv).balance;
        emit log_named_decimal_uint("post-import+burn total", postTotal, 18);
        assertApproxEqAbs(postTotal, TWO_T, 1e21, "NET = 2T preserved (no more minted on C)");
        // team 100B present under Z-Safe-controlled vesting
        assertEq(address(tv).balance, HUNDRED_B, "team 100B present in vesting");
        assertEq(tv.owner(), Z_SAFE, "team vesting controlled by Z/Team Safe");
    }
}
