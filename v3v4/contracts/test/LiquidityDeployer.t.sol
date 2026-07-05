// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LiquidityDeployer} from "../src/LiquidityDeployer.sol";

contract LiquidityDeployerTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    PoolManager manager;
    LiquidityDeployer dep;
    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency cur0;
    Currency cur1;
    PoolKey key;

    address owner = address(0xB0B);
    address funder = address(0xF00D);
    address recipient = address(0xBEEF);

    int24 constant SPACING = 60;
    uint24 constant FEE = 3000;

    function setUp() public {
        manager = new PoolManager(address(this));
        dep = new LiquidityDeployer(IPoolManager(address(manager)), owner);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        // sort
        if (address(a) < address(b)) {
            tokenA = a;
            tokenB = b;
        } else {
            tokenA = b;
            tokenB = a;
        }
        cur0 = Currency.wrap(address(tokenA));
        cur1 = Currency.wrap(address(tokenB));

        key = PoolKey({currency0: cur0, currency1: cur1, fee: FEE, tickSpacing: SPACING, hooks: IHooks(address(0))});
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0)); // price 1:1 at tick 0

        tokenA.mint(funder, 1e30);
        tokenB.mint(funder, 1e30);

        vm.startPrank(funder);
        tokenA.approve(address(dep), type(uint256).max);
        tokenB.approve(address(dep), type(uint256).max);
        vm.stopPrank();
    }

    function _fullRange() internal pure returns (int24 lo, int24 hi) {
        lo = TickMath.minUsableTick(SPACING);
        hi = TickMath.maxUsableTick(SPACING);
    }

    function _posLiquidity(int24 lo, int24 hi, bytes32 salt) internal view returns (uint128) {
        return IPoolManager(address(manager)).getPositionLiquidity(
            key.toId(), keccak256(abi.encodePacked(address(dep), lo, hi, salt))
        );
    }

    // ---- core: add then remove, exact settlement, no idle balance -----------
    function test_AddThenRemove() public {
        (int24 lo, int24 hi) = _fullRange();
        uint128 L = 1e21;

        uint256 f0 = tokenA.balanceOf(funder);
        uint256 f1 = tokenB.balanceOf(funder);

        vm.prank(owner);
        BalanceDelta d = dep.add(
            LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max)
        );

        uint256 paid0 = f0 - tokenA.balanceOf(funder);
        uint256 paid1 = f1 - tokenB.balanceOf(funder);
        assertEq(paid0, uint256(uint128(-d.amount0())), "paid0 == owed0");
        assertEq(paid1, uint256(uint128(-d.amount1())), "paid1 == owed1");
        assertGt(paid0, 0);
        assertGt(paid1, 0);
        assertEq(_posLiquidity(lo, hi, bytes32(0)), L, "position liquidity set");
        // deployer holds nothing; manager holds the tokens
        assertEq(tokenA.balanceOf(address(dep)), 0);
        assertEq(tokenB.balanceOf(address(dep)), 0);
        assertEq(tokenA.balanceOf(address(manager)), paid0);
        assertEq(tokenB.balanceOf(address(manager)), paid1);

        // remove all -> recipient
        vm.prank(owner);
        BalanceDelta rd = dep.remove(LiquidityDeployer.RemoveParams(key, lo, hi, L, bytes32(0), recipient, 0, 0));
        uint256 got0 = tokenA.balanceOf(recipient);
        uint256 got1 = tokenB.balanceOf(recipient);
        assertEq(got0, uint256(uint128(rd.amount0())));
        assertEq(got1, uint256(uint128(rd.amount1())));
        assertEq(_posLiquidity(lo, hi, bytes32(0)), 0, "position emptied");
        assertEq(tokenA.balanceOf(address(dep)), 0);
        assertEq(tokenB.balanceOf(address(dep)), 0);
    }

    // ---- V3->V4 mirror invariant: add(L) cost >= remove(L) return -----------
    // Proves re-adding the removed L needs at least what removal freed (rounding
    // goes against the depositor), so the migration must fund a tiny buffer.
    function test_MirrorRoundingDirection() public {
        (int24 lo, int24 hi) = _fullRange();
        uint128 L = 123456789e9;

        uint256 f0 = tokenA.balanceOf(funder);
        uint256 f1 = tokenB.balanceOf(funder);
        vm.prank(owner);
        dep.add(LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max));
        uint256 addCost0 = f0 - tokenA.balanceOf(funder);
        uint256 addCost1 = f1 - tokenB.balanceOf(funder);

        vm.prank(owner);
        BalanceDelta rd = dep.remove(LiquidityDeployer.RemoveParams(key, lo, hi, L, bytes32(0), recipient, 0, 0));
        uint256 back0 = uint256(uint128(rd.amount0()));
        uint256 back1 = uint256(uint128(rd.amount1()));

        assertGe(addCost0, back0, "add cost >= remove return (token0)");
        assertGe(addCost1, back1, "add cost >= remove return (token1)");
        assertLe(addCost0 - back0, 2, "rounding gap tiny (token0)");
        assertLe(addCost1 - back1, 2, "rounding gap tiny (token1)");
    }

    // ---- one-sided: range entirely above current tick pulls only token0 -----
    function test_OneSidedAbove() public {
        int24 lo = 60000;
        int24 hi = 120000; // both above current tick 0 -> position is 100% token0
        uint128 L = 1e21;

        uint256 f1 = tokenB.balanceOf(funder);
        vm.prank(owner);
        BalanceDelta d = dep.add(
            LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max)
        );
        assertLt(d.amount0(), 0, "owes token0");
        assertEq(d.amount1(), 0, "owes no token1");
        assertEq(tokenB.balanceOf(funder), f1, "token1 untouched");
    }

    // ---- atomic init+add (no front-run window) ------------------------------
    function test_InitAndAdd() public {
        // fresh, uninitialized pool key (distinct fee)
        PoolKey memory nk = PoolKey({currency0: cur0, currency1: cur1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(0))});
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint160 sp = TickMath.getSqrtPriceAtTick(1000);
        uint128 L = 1e21;
        vm.prank(owner);
        dep.initAndAdd(sp, LiquidityDeployer.AddParams(nk, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max));
        (uint160 got,,,) = IPoolManager(address(manager)).getSlot0(nk.toId());
        assertEq(got, sp, "pool initialized at our price");
        assertEq(
            IPoolManager(address(manager)).getPositionLiquidity(
                nk.toId(), keccak256(abi.encodePacked(address(dep), lo, hi, bytes32(0)))
            ),
            L
        );
    }

    function test_InitAndAddOnlyOwner() public {
        PoolKey memory nk = PoolKey({currency0: cur0, currency1: cur1, fee: 500, tickSpacing: SPACING, hooks: IHooks(address(0))});
        vm.expectRevert(LiquidityDeployer.NotOwner.selector);
        dep.initAndAdd(TickMath.getSqrtPriceAtTick(0), LiquidityDeployer.AddParams(nk, 0, 60, 1, bytes32(0), funder, 1, 1));
    }

    // ---- one-sided resting BID: range entirely below current -> only token1 --
    function test_OneSidedBelowRestingBid() public {
        // current tick 0; place range fully below -> position holds only token1 (the "quote"/WLUX side)
        int24 lo = -120000;
        int24 hi = -60000;
        uint128 L = 1e21;
        uint256 f0 = tokenA.balanceOf(funder);
        vm.prank(owner);
        BalanceDelta d = dep.add(
            LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max)
        );
        assertEq(d.amount0(), 0, "no token0 pulled");
        assertLt(d.amount1(), 0, "only token1 (quote) pulled");
        assertEq(tokenA.balanceOf(funder), f0, "token0 untouched (pure resting bid)");
    }

    // ---- guards -------------------------------------------------------------
    function test_AddMaxInGuardBinds() public {
        (int24 lo, int24 hi) = _fullRange();
        uint128 L = 1e21;
        // discover exact cost via a static call, then set max one below -> revert
        vm.prank(owner);
        uint256 snap = vm.snapshot();
        BalanceDelta d = dep.add(
            LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max)
        );
        uint128 cost0 = uint128(-d.amount0());
        vm.revertTo(snap);

        vm.prank(owner);
        vm.expectRevert(LiquidityDeployer.MaxInExceeded.selector);
        dep.add(LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, cost0 - 1, type(uint128).max));
    }

    function test_RemoveMinOutGuardBinds() public {
        (int24 lo, int24 hi) = _fullRange();
        uint128 L = 1e21;
        vm.prank(owner);
        dep.add(LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max));

        vm.prank(owner);
        vm.expectRevert(LiquidityDeployer.MinOutNotMet.selector);
        dep.remove(LiquidityDeployer.RemoveParams(key, lo, hi, L, bytes32(0), recipient, type(uint128).max, 0));
    }

    // ---- access control -----------------------------------------------------
    function test_OnlyOwnerAdd() public {
        (int24 lo, int24 hi) = _fullRange();
        vm.expectRevert(LiquidityDeployer.NotOwner.selector);
        dep.add(LiquidityDeployer.AddParams(key, lo, hi, 1e21, bytes32(0), funder, type(uint128).max, type(uint128).max));
    }

    function test_OnlyOwnerRemove() public {
        vm.expectRevert(LiquidityDeployer.NotOwner.selector);
        dep.remove(LiquidityDeployer.RemoveParams(key, 0, 60, 1, bytes32(0), recipient, 0, 0));
    }

    function test_CallbackOnlyManager() public {
        vm.expectRevert(LiquidityDeployer.NotManager.selector);
        dep.unlockCallback(hex"");
    }

    function test_TransferOwnership() public {
        vm.prank(owner);
        dep.transferOwnership(address(0xCAFE));
        assertEq(dep.owner(), address(0xCAFE));
        // old owner locked out
        vm.prank(owner);
        vm.expectRevert(LiquidityDeployer.NotOwner.selector);
        dep.transferOwnership(owner);
    }

    function test_Rescue() public {
        tokenA.mint(address(dep), 777);
        vm.prank(owner);
        dep.rescue(address(tokenA), recipient, 777);
        assertEq(tokenA.balanceOf(recipient), 777);
    }

    function test_RescueOnlyOwner() public {
        vm.expectRevert(LiquidityDeployer.NotOwner.selector);
        dep.rescue(address(tokenA), recipient, 1);
    }

    // ---- native currency rejected ------------------------------------------
    function test_NativeUnsupported() public {
        // pool with native currency0
        PoolKey memory nk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: cur1,
            fee: FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(nk, TickMath.getSqrtPriceAtTick(0));
        (int24 lo, int24 hi) = _fullRange();
        vm.prank(owner);
        vm.expectRevert(LiquidityDeployer.NativeUnsupported.selector);
        dep.add(LiquidityDeployer.AddParams(nk, lo, hi, 1e21, bytes32(0), funder, type(uint128).max, type(uint128).max));
    }

    // ---- fuzz: add/remove round-trips for arbitrary L never traps funds -----
    function testFuzz_AddRemoveNoResidual(uint96 rawL) public {
        uint128 L = uint128(bound(uint256(rawL), 1e12, 1e27));
        (int24 lo, int24 hi) = _fullRange();
        vm.prank(owner);
        dep.add(LiquidityDeployer.AddParams(key, lo, hi, L, bytes32(0), funder, type(uint128).max, type(uint128).max));
        vm.prank(owner);
        dep.remove(LiquidityDeployer.RemoveParams(key, lo, hi, L, bytes32(0), recipient, 0, 0));
        assertEq(_posLiquidity(lo, hi, bytes32(0)), 0);
        assertEq(tokenA.balanceOf(address(dep)), 0);
        assertEq(tokenB.balanceOf(address(dep)), 0);
    }
}
