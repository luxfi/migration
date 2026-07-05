# v3v4 — Lux mainnet V3 → V4 LP migration (AI guide)

DEX liquidity move on C-Chain **96369**. NOT the Quasar network migration (`../CLAUDE.md`).
Read `RUNBOOK.md` first — it has the full accounting, findings, and run steps.

## One and only one way
- `make snapshot` → `make plan` → `make test`/`make build` → `make migrate` (dry-run) → `make migrate DRY_RUN=0` (broadcast).
- Everything derives from **live chain**; nothing hardcoded. Idempotent; resumable via on-chain `extsload` reads.

## Layout
- `contracts/` — foundry project. `src/LiquidityDeployer.sol` (minimal owner-gated
  `IUnlockCallback`; `add`/`remove`/`initAndAdd`/`rescue`/`transferOwnership`).
  `test/` 16 tests incl. 256-run fuzz + mirror-rounding invariant.
  `lib/v4-core` → symlink to `~/work/lux-amm/v4-core` (v4-core PoolManager source).
- `tools/snapshot.py` — enumerate treasury V3 positions (read-only, kubectl transport).
- `tools/investigate_all.py` — full 149-NFT ownership map (the LETH resolution).
- `tools/v4math.py` — bit-exact TickMath + LiquidityAmounts (validated 0-wei vs on-chain).
- `tools/build_plan.py` — classify + accounting → `plan.json`.
- `tools/execute.py` — staged executor (dry-run default; 5-RPC broadcast @250 gwei).
- `scripts/setup.sh` — pin v4-core deps (forge-std/solmate/oz/ds-test) for reproducible bytecode.

## Non-negotiables
- V4 needs EIP-1153 (TSTORE). Confirmed live on 96369 (Cancun). If a reboot changes that, STOP.
- Treasury `0x9011…` owns the 9 live positions (NOT the DAO Safe). Migrate 50%.
- One-sided WLUX pools (LBTC, LAVAX) are honeypots at their V3 edge price — init V4 at
  **oracle** price, place WLUX as a resting **bid below** oracle. Never clone the edge.
- Mainnet has no mempool gossip: broadcast to all 5 validators; gasPrice ≥ ~250 gwei.
- Contracts: solc 0.8.26, cancun, via_ir, optimizer 44444444, bytecode_hash=none (reproducible).
- No mainnet broadcast without `EXECUTE=1` + `LUX_PRIVATE_KEY`.
