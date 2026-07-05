# v3v4 — Lux mainnet V3 → V4 LP migration (AI guide)

DEX liquidity move on C-Chain **96369**. NOT the Quasar network migration (`../CLAUDE.md`).
Read `RUNBOOK.md` first — it is the canonical, deterministic replay guide.

## Status — EXECUTED 2026-07-05 on mainnet
- V4 **PoolManager** `0x2e317c5ce2c3e3aa720a3bb7f366f5959d940d4c` (owner = treasury).
- **LiquidityDeployer** `0x9888015bd7cda1905bbebf560f800731772957fd`, **ownership → DAO Safe**
  `0x51284dc2133e8d3a8e213dca6a6fa768cfdfcce2`; residual approvals zeroed.
- Migrated 50% of 5 pools (~71M WLUX + 1.434B LZOO); LAVAX/LUSD dust-skipped.
- Re-running reconciles against live chain: every step precheck reports "already done → skip".

## One and only one way
`make snapshot` → `make plan` → `make test` → `make migrate` (dry-run) → `make migrate DRY_RUN=0` (broadcast) → `… FINALIZE=1` (hand LD to DAO).
Everything derives from **live chain**; nothing hardcoded. Idempotent; resumable via on-chain `extsload`/`NPM.positions` reads. **Suspend the `chain-heartbeat` cronjob (ns lux-mainnet) before any broadcast run** — it signs the treasury `0x9011` every 5 min and would race the nonce (RUNBOOK §1).

## Layout
- `contracts/` — foundry. `src/LiquidityDeployer.sol` (minimal owner-gated `IUnlockCallback`:
  `add`/`remove`/`initAndAdd`/`rescue`/`transferOwnership`). `test/` 16 tests incl. 256-run
  fuzz + mirror-rounding invariant. `lib/v4-core` → symlink to `~/work/lux-amm/v4-core`.
- `tools/snapshot.py` — enumerate treasury V3 positions (read-only, `kubectl exec` transport).
- `tools/investigate_all.py` — full NPM ownership map (the LETH resolution).
- `tools/v4math.py` — bit-exact TickMath + LiquidityAmounts (validated 0-wei vs on-chain).
- `tools/build_plan.py` — classify + accounting → `plan.json`; freezes `baseline.json`.
- `tools/execute.py` — staged executor (dry-run default; 5-RPC broadcast @250 gwei).
- `scripts/setup.sh` — pin v4-core deps for reproducible bytecode.

## Non-negotiables
- V4 needs EIP-1153 (TSTORE). Live on 96369 (Cancun). If a reboot changes that, STOP.
- Treasury `0x9011…` owns the live positions (NOT the DAO Safe). Migrate 50%.
- One-sided WLUX pools (LBTC, LAVAX) are honeypots at their V3 edge — init V4 at **oracle**
  price, place WLUX as a resting **bid below** oracle. Never clone the edge. Dual-control
  oracle (`price` + independent `expected_tick`); out-of-band aborts before touching V3.
- No mempool gossip: broadcast every tx to all 5 validators at ≥250 gwei; nonce drift is
  detected on the **latest** (mined) nonce, and a `nonce too low` after our own txhash
  mined is SUCCESS, not a conflict (RUNBOOK §3 — load-bearing, do not weaken).
- Contracts: solc 0.8.26, cancun, via_ir, optimizer 44444444, bytecode_hash=none (reproducible).
- No broadcast without `DRY_RUN=0` (`EXECUTE=1`) + `LUX_PRIVATE_KEY`.
