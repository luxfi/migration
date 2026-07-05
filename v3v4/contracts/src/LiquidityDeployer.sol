// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

/// @title LiquidityDeployer
/// @notice Minimal, owner-gated helper to add and remove concentrated liquidity in
///         Uniswap-v4 pools for a one-time treasury migration (Lux V3 -> V4).
///
/// Design goals (defensive):
///  - Holds NO idle balances. On add, tokens are pulled from `funder` straight into
///    the PoolManager (sync -> transferFrom -> settle). On remove, freed tokens are
///    pushed straight to `recipient` (take). Between calls the contract is empty.
///  - The v4 position owner is THIS contract (positions keyed by (this, tickLower,
///    tickUpper, salt)); only `owner` can add/remove/rescue. `owner` should be handed
///    to the DAO Safe after deploy via transferOwnership.
///  - amountMax guards on add cap how much can ever be pulled from the funder
///    (rounding/slippage/reentrancy bound). amountMin guards on remove floor payouts.
///  - ERC20-only. Reverts on native currency (all migration pools are WLUX/L* ERC20).
///  - No delegatecall, no upgradeability, no selfdestruct, no arbitrary external calls
///    beyond the trusted PoolManager and the pool's own tokens.
contract LiquidityDeployer is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable manager;
    address public owner;

    error NotOwner();
    error NotManager();
    error NativeUnsupported();
    error MaxInExceeded();
    error MinOutNotMet();
    error TransferFromFailed();

    event OwnerChanged(address indexed previous, address indexed next);
    event Added(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity, int128 amount0, int128 amount1);
    event Removed(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity, int128 amount0, int128 amount1);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _manager, address _owner) {
        manager = _manager;
        owner = _owner;
        emit OwnerChanged(address(0), _owner);
    }

    // ---- ownership ----------------------------------------------------------
    function transferOwnership(address next) external onlyOwner {
        emit OwnerChanged(owner, next);
        owner = next;
    }

    // ---- params -------------------------------------------------------------
    struct AddParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity; // liquidity to add
        bytes32 salt;
        address funder; // pulled from here (must approve this contract)
        uint128 amount0Max; // hard cap on token0 pulled
        uint128 amount1Max; // hard cap on token1 pulled
    }

    struct RemoveParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity; // liquidity to remove
        bytes32 salt;
        address recipient; // freed tokens sent here
        uint128 amount0Min; // floor on token0 received
        uint128 amount1Min; // floor on token1 received
    }

    uint8 private constant ACTION_ADD = 1;
    uint8 private constant ACTION_REMOVE = 2;

    // ---- entrypoints --------------------------------------------------------
    function add(AddParams calldata p) external onlyOwner returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(ACTION_ADD, abi.encode(p))), (BalanceDelta));
    }

    /// @notice Initialize the pool and add liquidity in ONE transaction, so the
    ///         price we set is the price we add at — no window for a third party
    ///         to swap the freshly-initialized pool between init and add.
    function initAndAdd(uint160 sqrtPriceX96, AddParams calldata p)
        external
        onlyOwner
        returns (BalanceDelta delta)
    {
        manager.initialize(p.key, sqrtPriceX96);
        delta = abi.decode(manager.unlock(abi.encode(ACTION_ADD, abi.encode(p))), (BalanceDelta));
    }

    function remove(RemoveParams calldata p) external onlyOwner returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(ACTION_REMOVE, abi.encode(p))), (BalanceDelta));
    }

    /// @notice Belt-and-suspenders: sweep any token that somehow ends up here.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        _rawTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ---- unlock callback ----------------------------------------------------
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (uint8 action, bytes memory inner) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_ADD) {
            return _add(abi.decode(inner, (AddParams)));
        } else {
            return _remove(abi.decode(inner, (RemoveParams)));
        }
    }

    function _add(AddParams memory p) internal returns (bytes memory) {
        (BalanceDelta delta,) = manager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams(p.tickLower, p.tickUpper, int256(uint256(p.liquidity)), p.salt),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // pay whatever we owe (cap at max); take any positive dust to funder
        _settleOrTake(p.key.currency0, a0, p.funder, p.funder, p.amount0Max, 0);
        _settleOrTake(p.key.currency1, a1, p.funder, p.funder, p.amount1Max, 0);
        emit Added(p.key.toId(), p.tickLower, p.tickUpper, p.liquidity, a0, a1);
        return abi.encode(delta);
    }

    function _remove(RemoveParams memory p) internal returns (bytes memory) {
        (BalanceDelta delta,) = manager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams(p.tickLower, p.tickUpper, -int256(uint256(p.liquidity)), p.salt),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // receive freed tokens (floor at min); if we somehow owe, maxIn=0 => revert
        _settleOrTake(p.key.currency0, a0, address(this), p.recipient, 0, p.amount0Min);
        _settleOrTake(p.key.currency1, a1, address(this), p.recipient, 0, p.amount1Min);
        emit Removed(p.key.toId(), p.tickLower, p.tickUpper, p.liquidity, a0, a1);
        return abi.encode(delta);
    }

    /// @dev The single settlement primitive. Negative delta => we owe the pool: pull
    ///      from `payer` into the manager and settle (bounded by maxIn). Positive
    ///      delta => pool owes us: take to `receiver` (floored by minOut).
    function _settleOrTake(Currency c, int128 amt, address payer, address receiver, uint128 maxIn, uint128 minOut)
        internal
    {
        if (amt < 0) {
            uint256 owed = uint256(uint128(-amt));
            if (owed > maxIn) revert MaxInExceeded();
            address token = Currency.unwrap(c);
            if (token == address(0)) revert NativeUnsupported();
            manager.sync(c);
            _pull(token, payer, address(manager), owed);
            manager.settle();
        } else if (amt > 0) {
            uint256 amount = uint256(uint128(amt));
            if (amount < minOut) revert MinOutNotMet();
            manager.take(c, receiver, amount);
        }
        // amt == 0: nothing to do
    }

    // ---- raw ERC20 helpers (tolerate non-standard bool-less tokens) ----------
    function _pull(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFromFailed();
    }

    function _rawTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFromFailed();
    }
}
