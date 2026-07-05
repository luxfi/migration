# Lux mainnet V3 → V4 liquidity migration — RUNBOOK

**Scope:** move HALF of the DAO treasury's Uniswap-V3 LP liquidity on Lux C-Chain
(chainId **96369**) into freshly-deployed Uniswap-V4-style pools. This is a **DEX
LP move only** — it has nothing to do with the Quasar network migration documented
in `../CLAUDE.md`. Everything here derives from **live chain state**; re-running is
safe and idempotent, including after a full network RLP reboot.

> NO transaction is broadcast by the tooling unless `EXECUTE=1`. The orchestrator
> runs the staged executor with the treasury key after review.

---

## 0. Headline facts (verified on-chain, block ~0x108605)

| Check | Result |
|---|---|
| **EIP-1153 TSTORE/TLOAD** (V4 hard requirement) | **SUPPORTED** — Cancun active on 96369 (probe returned `0x..01`; block carries `parentBeaconBlockRoot`/`blobGasUsed`). PUSH0 + MCOPY also supported. **No blocker.** |
| Client | luxd/coreth `v0.18.19` |
| Treasury / deployer | `0x9011E888251AB053B7bD1cdB598Db4f9DED94714` (EOA, ~2T native LUX). **This key is ACTIVELY signing** (nonce moved 748→757 during prep) — orchestrator MUST serialize against concurrent use. |
| DAO Safe | `0x51284dc2133e8d3a8e213dca6a6fa768cfdfcce2` (owns V3 factory; **owns 0 NFTs**) |
| Treasury V3 positions | **73 NFTs, but only 9 have liquidity>0.** 64 are empty. |
| WLUX | `0x4888e4a2ee0f03051c72d2bd3acf755ed3498b3e` (matches `WLUX.json`; total supply only **159M**, of which the WLUX/LZOO pool holds 131.9M = 83%) |

### LETH resolution (owner asked "get part of the LETH into V4")
The WLUX/LETH pool (`0xfafbf1…`) holds 4.8M WLUX + 0.006 LETH, but of its **29
position NFTs the only two with liquidity (id103, id104) are owned by EXTERNAL
address `0x982942216728edfc327f0b1b71ce2fafae98589b`** — NOT the treasury. **All 18
treasury WLUX/LETH NFTs are empty (liq=0). The DAO Safe owns zero NFTs. Treasury
holds 0 LETH.** ⇒ There is **no treasury-controlled path** to migrate LETH; it
cannot be moved without the external LP's key. If `0x982942…` is owner-controlled,
provide its signer and re-run `make investigate` to fold id103/104 in.

---

## 1. Migration accounting (50% of each live treasury position)

| Pool | Class | Migrate (50%) | V4 init price | Note |
|---|---|---|---|---|
| **WLUX/LZOO** | MIGRATE_SPOT | **65,941,975.39 WLUX + 1,434,223,151.30 LZOO** | V3 spot tick 30797 | deep two-sided; endogenous price → clone exactly |
| LSOL/WLUX | MIGRATE_SPOT | 0.5173 LSOL + 41,017.05 WLUX | V3 spot tick 125284 | thin two-sided (3 positions) |
| LPOL/WLUX | MIGRATE_SPOT | 1.3223 LPOL + 3,498.88 WLUX | V3 spot tick 79006 | thin two-sided |
| LBTC/WLUX | MIGRATE_ONESIDED_ORACLE | 5,000,000 WLUX (bid) | **ORACLE** = XBTUSD/12.5 | V3 edge tick 185729 = ~116M WLUX/LBTC honeypot → **do NOT clone**; resting bid below oracle |
| LAVAX/WLUX | MIGRATE_ONESIDED_ORACLE | 10,000 WLUX (bid) | **ORACLE** = AVAXUSD/12.5 | V3 at MAX tick honeypot → resting bid below oracle |
| LAVAX/LUSD | SKIP_DUST | 0.52 LUSD | — | negligible |

**Why one-sided pools are handled differently.** A pool that is ~100% WLUX sits at
a range edge where the scarce base is priced absurdly (LBTC at 116,000,000 WLUX
each; LAVAX at 1e38). Cloning that edge price into a fresh V4 pool with real WLUX =
a honeypot: anyone holding a wei of the base drains the WLUX. Instead we initialize
V4 at the **oracle** (fair) price and place the WLUX as a **resting BID ladder
BELOW oracle** — it can only be filled by someone *selling the base at ≤ fair
price*, so there is no free arbitrage.

**Oracle sanity is dual-controlled (2-operator confirm).** `oracle.json` carries, per
one-sided base, both a `price` (base USD, from the live Kraken mid) **and** an
`expected_tick` — the tick a **second operator** derives independently from their own
read of that mid. Before it will decrease any V3 liquidity, the executor recomputes the
tick from `price` and **ABORTS** if it deviates from `expected_tick` by more than
`ORACLE_TICK_BAND` ticks (default **±2000 ≈ ±22%**; overridable per base via
`band_ticks`). A 10× fat-finger moves the tick ~+23,000 → immediate abort. A second
**honeypot backstop** still requires the tick to sit strictly below the V3 edge, and a
hard **`ONESIDED_MAX_WLUX`** cap (default 5,000,000e18) bounds the WLUX any single
one-sided pool can ever risk. Set both `price` and `expected_tick` from
`tools/oracle.example.json`; **do not derive `expected_tick` from `price`** — the
independence is the control (see §6).

Regenerate this table anytime: `make snapshot && make plan`. The first `make plan`
freezes `tools/baseline.json` (original liquidity + one-shot 50% target per tokenId);
every later `make plan` reads that frozen baseline, so regenerating **mid-migration is
safe and idempotent** — targets never compound (see §5).

---

## 2. Contracts deployed

| Contract | Source | Creation size | Deploy gas | Constructor |
|---|---|---|---|---|
| **PoolManager** (v4-core) | `~/work/lux-amm/v4-core` | 24,194 B | ~5.29M | `(address initialOwner)` = treasury |
| **LiquidityDeployer** | `contracts/src/LiquidityDeployer.sol` | 7,303 B | ~1.4M | `(IPoolManager, address owner)` = (PoolManager, treasury) |

`LiquidityDeployer` is a minimal, owner-gated `IUnlockCallback` helper:
- holds **no idle balances** (add pulls funder→manager; remove pushes manager→recipient);
- `amount*Max` caps on add (over-pull guard), `amount*Min` floors on remove;
- ERC20-only (reverts on native);
- `initAndAdd` initializes the pool and adds liquidity **atomically** (no front-run window);
- `transferOwnership` to hand control to the DAO Safe after migration;
- `rescue` escape hatch.

Compiler (reproducible): `solc 0.8.26+commit.8a97fa7a`, `evm_version=cancun`,
`via_ir=true`, `optimizer_runs=44444444`, `bytecode_hash=none`. Deps pinned in
`scripts/setup.sh`. Tests: `make test` (16 unit + 256-run fuzz, all green).

---

## 3. How the staged executor works

`tools/execute.py` — DRY-RUN by default. Numbered steps, each with an **on-chain
idempotency precheck** so an interrupted run resumes exactly where it stopped:

```
STEP 1  deploy PoolManager            (skip if code at computed addr)
STEP 2  deploy LiquidityDeployer      (skip if code at computed addr)
per MIGRATE pool:
  decreaseLiquidity(50%) each pos     (skip if position liquidity <= target)
  collect(max) each pos -> treasury   (skip if tokensOwed == 0)
  approve token0/token1 -> LD         (skip if allowance >= need)
  initAndAdd (first) / add (rest)      (skip if V4 position liquidity >= target)
```

Idempotency reads are **direct storage reads** via `PoolManager.extsload` (pool
init + position liquidity) and `NPM.positions` — so correctness does not depend on
`state.json`. `state.json` is the machine-readable record (deployed addresses, tx
hashes, per-pool migrated amounts) for the console UI; schema is stable.

**Transport (mainnet has NO mempool gossip):** every signed tx is broadcast to
**all 5 validators** (`luxd-0..4` via `kubectl exec`) and uses legacy
`gasPrice = 250 gwei` (flat-baseFee txs never mine — they don't cover block gas
cost). Both are baked in; override with `GAS_PRICE_GWEI=…`.

**Broadcast-safety gates (execute mode).** Before STEP 1 the executor runs two
preflights and **aborts** on failure:
- **Base fee affordable** — reads the live `baseFeePerGas`; if it exceeds `gasPrice`
  the txs would never mine, so it aborts (raise `GAS_PRICE_GWEI`).
- **No concurrent signer** — the treasury EOA `0x9011` is actively used (§0). It reads
  the pending nonce twice 3s apart and aborts if it moved ("another process is signing
  0x9011 — pause it"). Thereafter it **re-reads the live pending nonce before every tx**
  and aborts on drift rather than colliding. A `nonce too low/high` from any validator
  is treated as **FATAL** (abort immediately) instead of being masked as "sent" and
  stalling the 240s receipt wait; a benign `already known` counts as accepted.

**Finalize (opt-in, `FINALIZE=1`).** After all adds succeed, `make migrate DRY_RUN=0
FINALIZE=1` zeroes the treasury's residual token approvals to `LiquidityDeployer` and
`transferOwnership(LD → DAO Safe 0x51284…)`, so LD is never left owned by the hot EOA
with standing approvals. It is **gated off by default** so you can verify the pools
first; dry-run always previews the steps. It is idempotent (owner/allowance prechecks).

**V3→V4 rounding:** re-adding the removed liquidity `L` needs ≤ a few wei *more*
than the decrease freed (V3 rounds down, V4 rounds up). The treasury's standing
balances (5M WLUX, 7.6B LZOO) cover it; approvals carry a `SLIPPAGE_BPS` (1%)
buffer and the `amount*Max` guard caps the pull. Proven by the
`test_MirrorRoundingDirection` invariant (gap ≤ 2 wei).

---

## 4. Run it

```bash
make setup                 # one-time: populate pinned v4-core deps
make test                  # foundry tests must be green (16/16)
make snapshot              # refresh live position data  -> tools/snapshot.json
make plan                  # accounting table + FREEZE tools/baseline.json -> tools/plan.json
cp tools/oracle.example.json tools/oracle.json   # then set LIVE prices AND expected_tick
make migrate               # DRY-RUN: prints every staged tx + finalize preview, no broadcast

# when the orchestrator is ready (real key, real broadcast):
# EXECUTE is derived from DRY_RUN; set DRY_RUN=0 and export the key:
LUX_PRIVATE_KEY=$(kubectl --context do-sfo3-lux-k8s -n lux-mainnet \
  get secret lux-deployer -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d) \
  make migrate DRY_RUN=0

# after verifying all pools, hand LiquidityDeployer to the DAO Safe + drop approvals:
LUX_PRIVATE_KEY=$(...) make migrate DRY_RUN=0 FINALIZE=1
```

**`oracle.json` MUST be the dual-control object schema** — each one-sided base is
`{"price": <base USD>, "expected_tick": <second operator's independent tick>}` (plus
`"LUX_USD": 12.5`). A bare number is rejected. Copy `tools/oracle.example.json`, set the
LIVE `price` (operator A) and the independently-derived `expected_tick` (operator B). If
the price-derived tick strays beyond `ORACLE_TICK_BAND` (±2000) of `expected_tick`, the
executor aborts **before touching V3** (see §6).

The executor prints predicted deploy addresses (computed from the live nonce). If the
treasury key sends other txs concurrently, the execute-mode preflight detects it and
aborts with "another process is signing 0x9011 — pause it"; pause the other signer and
re-run (idempotent — completed steps skip).

---

## 5. Full re-run after a network RLP reboot (and mid-migration re-plan)

The network can be rebooted from the RLP archive (see `../CLAUDE.md`). Re-running is
safe **because the 50% target is frozen in `tools/baseline.json`, not re-derived from
live liquidity.** The trap this avoids: if a migration partially ran (V3 liquidity
already halved) and you regenerate the plan from a fresh snapshot, a naive builder reads
the **halved** liquidity as the new baseline and removes 50% of the *remainder* → 75%
gone. The frozen baseline prevents that. After the chain is live again:

1. **`make snapshot`** — re-reads all positions from the fresh chain (read-only; nothing
   hardcoded).
2. **`make plan`** — reads the **frozen `tools/baseline.json`** (created on the *first*
   ever `make plan`) and computes `removeLiquidity`/`target` from the **original**
   liquidity, never from the re-snapshot. Any position whose live liquidity is already
   ≤ its baseline target is printed as "already migrated" and the executor's on-chain
   precheck skips its decrease. Regenerating the plan mid-migration is therefore
   idempotent — it can only ever remove the original 50%, once.
3. **`make migrate`** (dry-run) — on-chain `extsload`/`NPM.positions` prechecks detect
   completed steps and skip them; if the reboot rewound state to before the migration it
   starts fresh. Either way it reconciles against what the chain currently shows.
4. `make clean` deletes only `tools/state.json` (the console record file); it does **not**
   touch `baseline.json`. **Never delete `baseline.json` mid-migration** — it is the guard
   against the double-decrease. Delete it *only* to begin a brand-new migration from
   current live liquidity (i.e. a deliberate new 50% cut of whatever remains).

---

## 6. Editing the policy / adding pools

- **Change what migrates:** edit the thresholds/classes in `tools/build_plan.py`
  (`classify()`), then `make plan`. Classes: `MIGRATE_SPOT`,
  `MIGRATE_ONESIDED_ORACLE`, `SKIP_DUST`, `SKIP_EMPTY`.
- **Migrate a different fraction:** the "50%" is frozen into `tools/baseline.json`
  (`removeLiquidity = originalLiquidity // 2`) on the first `make plan`. To change the
  fraction you must start a fresh migration: delete `tools/baseline.json`, then
  `make plan` recomputes the baseline from current live liquidity. (Do **not** hand-edit
  a live baseline — it is the double-decrease guard; see §5.)
- **Add a new pool:** it appears automatically once the treasury owns a liquid
  position in it (snapshot enumerates all owned NFTs). No code change needed.
- **One-sided bid width:** `ONESIDED_BAND_TICKS` (default 6900 ticks) — the width of the
  resting-bid ladder.
- **One-sided oracle (`tools/oracle.json`) — dual-control schema:**
  ```json
  {
    "LUX_USD": 12.5,
    "LBTC":  { "price": 63166.4, "expected_tick": 85282 },
    "LAVAX": { "price": 6.983,   "expected_tick": -5823, "band_ticks": 2000 }
  }
  ```
  - `price` — base-asset USD (Kraken XBTUSD/AVAXUSD/…), set by operator A.
  - `expected_tick` — the pool tick operator **B** derives *independently* from their own
    read of the live mid. **Never copy it from `price`** — the whole point is that a
    fat-finger in `price` (typed by A) diverges from B's `expected_tick`.
  - The executor computes the tick from `price` and **aborts** if it is more than
    `ORACLE_TICK_BAND` ticks (env, default **2000 ≈ ±22%**) from `expected_tick`.
    `band_ticks` overrides the width per base.
  - `ONESIDED_MAX_WLUX` (env, default 5,000,000e18) caps the WLUX any one one-sided pool
    can deposit — a scaling bug can never exceed it.
  - `LUX_USD` is the WLUX peg (LETH/LUX = ETHUSD/12.5 ⇒ LUX_USD = 12.5). A one-sided base
    with no oracle entry is **skipped** (fail-secure); a malformed/out-of-band/over-cap
    entry **aborts** the run before any V3 liquidity is touched.

---

## 7. Rollback (V4 → V3 reverse path)

`LiquidityDeployer.remove(RemoveParams)` is the exact inverse of `add`: it burns the
V4 position (same `key`/`ticks`/`salt`) and `take`s the tokens to a recipient
(default the treasury), with `amount*Min` floors. To reverse a migration:

1. `remove` each V4 position created (the salts are `bytes32(tokenId)` for spot
   pools, `bytes32(0)` for one-sided bids — recorded in `state.json`).
2. Re-`increaseLiquidity` on the original V3 NFTs (still owned by the treasury,
   still at the same ranges) with the returned tokens.

A reverse script is intentionally NOT auto-run; ownership of `LiquidityDeployer`
should be handed to the DAO Safe (`transferOwnership`) so any unwind is a
Safe-governed action.

---

## 8. Supersedes

The root-level `../v3-to-v4-migrate.sh` + `../v3-to-v4-withdraw.json` assume the
positions are **DAO-Safe-owned** with a **100%-withdraw + burn** flow against a
**local fork (block 1082950)**. Live chain contradicts that: the Safe owns 0 NFTs,
the treasury EOA owns all 73, and the owner now wants **50%** migrated. This
toolkit reflects live reality and should be treated as canonical.
