// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

interface INPM {
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 fg0, uint256 fg1, uint128 owed0, uint128 owed1);
    function ownerOf(uint256) external view returns (address);
    function decreaseLiquidity(DecreaseParams calldata) external returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata) external returns (uint256 amount0, uint256 amount1);
    struct DecreaseParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
}
interface IERC20 { function balanceOf(address) external view returns (uint256); }

/// End-to-end against REAL mainnet liquidity (forked): the LP Safe withdraws 50%
/// of a live V3 position — the exact first leg of the V3->V4 rebalance — proving
/// it yields real tokens and leaves ~50% behind. The add-to-V4 leg is covered by
/// LiquidityDeployer.t.sol against a real PoolManager.
contract RebalanceForkTest is Test {
    INPM constant PM = INPM(0x7a4C48B9dae0b7c396569b34042fcA604150Ee28);
    address constant LP_SAFE = 0xd0ebbDcD517eAFf419eC92a258459854d610cee8;

    /// Find a live LP-Safe position that still holds liquidity. Returns 0 if the
    /// fork RPC is unreachable or every scanned position is empty.
    function _liveTokenId() internal view returns (uint256) {
        if (address(PM).code.length == 0) return 0; // not a fork run
        uint16[15] memory ids =
            [uint16(100), 143, 101, 102, 93, 94, 95, 96, 97, 98, 99, 61, 62, 63, 64];
        for (uint256 i = 0; i < ids.length; i++) {
            try PM.ownerOf(ids[i]) returns (address o) {
                if (o != LP_SAFE) continue;
                (,,,,,,, uint128 L,,,,) = PM.positions(ids[i]);
                if (L > 0) return ids[i];
            } catch {
                return 0; // RPC unavailable
            }
        }
        return 0;
    }

    function test_LPSafeWithdrawsFiftyPercentOfRealPosition() public {
        uint256 tokenId = _liveTokenId();
        if (tokenId == 0) {
            vm.skip(true);
            return;
        } // not a fork run, or no live liquidity left

        (,, address t0, address t1,,,, uint128 L,,,,) = PM.positions(tokenId);
        assertGt(L, 0, "position has liquidity");
        uint128 half = L / 2;

        uint256 b0 = IERC20(t0).balanceOf(LP_SAFE);
        uint256 b1 = IERC20(t1).balanceOf(LP_SAFE);

        vm.startPrank(LP_SAFE);
        PM.decreaseLiquidity(INPM.DecreaseParams(tokenId, half, 0, 0, block.timestamp + 1));
        (uint256 c0, uint256 c1) =
            PM.collect(INPM.CollectParams(tokenId, LP_SAFE, type(uint128).max, type(uint128).max));
        vm.stopPrank();

        (,,,,,,, uint128 Lafter,,,,) = PM.positions(tokenId);
        assertEq(Lafter, L - half, "exactly 50% liquidity remains");
        assertGt(c0 + c1, 0, "withdrawal returned real tokens");
        assertEq(IERC20(t0).balanceOf(LP_SAFE), b0 + c0, "token0 landed in the Safe");
        assertEq(IERC20(t1).balanceOf(LP_SAFE), b1 + c1, "token1 landed in the Safe");
        emit log_named_uint("withdrawn token0", c0);
        emit log_named_uint("withdrawn token1", c1);
        emit log_named_uint("liquidity before", L);
        emit log_named_uint("liquidity after ", Lafter);
    }
}
