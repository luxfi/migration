# START HERE — Lux Regenesis (Quasar Edition) map

One page to orient. Everything below points to the authoritative source; where
two docs disagree, the **empirically-verified** one wins and the stale one is
flagged. Do not trust a hash that isn't backed by an RLP decode (this repo's
own rule — see "Gotchas").

The regenesis = **replay the preserved block history into a strict-PQ Quasar
network**. No fresh h=0 (we keep all C-Chain + Zoo history). Three EVM chains:

| Chain | ID | RLP archive (preserve all blocks) |
|---|---|---|
| Lux C-Chain mainnet | 96369 | ~1.08M blocks |
| Zoo EVM mainnet | 200200 | ~800 blocks |
| Zoo EVM testnet | 200201 | ~85 blocks |

---

## 1. Where is the block history? (the data)

The RLP archives exist in **three redundant places** — use the first that's handy:

| Location | Path | Notes |
|---|---|---|
| **Local disk (fastest)** | `~/work/lux/state/lux-mainnet-96369-full-1083873.rlp` (+ `zoo-mainnet-200200-full.rlp`, `zoo-testnet-200201-full.rlp`) | The `-full-<tip>` file is the **most complete** export. Loose top-level = working copies. |
| **s3 mirror (easy replay)** | `s3.lux.cloud` | The owner's replay mirror. *(Exact bucket/key: confirm with owner — not yet written into these docs.)* |
| **git (canonical, LFS)** | `github.com/luxfi/state` → `exports/lux-mainnet-96369/blocks-part-*` | Committed as LFS chunks in history (commit `2e3c3e1`). ⚠ Currently **behind an exceeded GitHub LFS budget** — pulling from here is blocked until the org bumps the LFS quota. Use s3/local meanwhile. |

**Ignore these — they are scratch/redundant, not the source of record:**
`rlp/` (gitignored scratch), the top-level `chunk_aa..af` (an old <100 MB split
workaround), `*.rlp.gz`, and the older `-full-1083346` export.

---

## 2. Which genesis + block-0 hash? (the wedge everyone hits)

An RLP imports **iff** the running node's block-0 hash == the RLP's block-1
parentHash. Get the genesis wrong and `admin_importChain` fails with `parent
mismatch` — the "solved 3-4 times" wedge.

**Authoritative source: [`~/work/lux/state/CLAUDE.md`](../state/CLAUDE.md)** —
section "RLP ↔ Genesis ↔ Upgrade — Canonical Migration Contract" (empirically
verified 2026-06-02 with `cmd/rlp-vs-genesis` + a real RLP decode).

| Chain | Canonical block-0 hash | Genesis that produces it |
|---|---|---|
| Lux C mainnet (96369) | **`0x3f4fa2a0…`** ✓ (RLP-decode verified) | the **2-alloc "Candidate B"** form (`genesis/configs/mainnet/cchain.json`, `skipPostMergeFields:true`, ts `0x672485c2`) |
| Zoo mainnet (200200) | **`0x7c548af4…`** ✓ | pristine 2-alloc form |

> ⚠ **CONTRADICTION — do not use:** `migration/CLAUDE.md` Step 1 says the hash is
> `0x067668d0` from `genesis.original.json`. That is **unverified and contradicted**
> by the empirical study, which shows `genesis.original.json` actually produces
> `0x2f4ae11a` (wrong). Trust `state/CLAUDE.md`'s `0x3f4fa2a0`. Re-verify yourself
> with the tool below before relying on any hash.

---

## 3. How to regenesis (the flow — no new dates, keep all blocks)

Per chain, exactly three steps + deterministic validators:

1. **Boot** with the canonical 2-alloc genesis (block-0 = `0x3f4fa2a0…` for Lux C).
2. **`admin_importChain`** the RLP (from s3/local) → re-executes every block →
   recomputes the state root → history preserved.
3. **`upgrade.json`** forward-dates the 42 PQ precompiles + RewardManager + strict-PQ
   at **`1766708400`** (Dec 25 2025 16:20 PST). That timestamp is **~200 days in the
   past**, so it activates on the next block — **no new date to pick**. NEVER bake
   these into genesis for a chain with history (drifts block-0 → breaks import).
4. **Validators** are deterministic from the one deploy mnemonic via
   `keys.DeriveHybridIdentity` (secp256k1 `m/44'/9000'/svc'/0'/0'` + ML-DSA-65
   `…/0'/1'`); NodeID = `SHAKE256-384` over the wire-form hybrid pubkey.

Full step-by-step: [`MIGRATION-2026-PRODUCTION.md`](MIGRATION-2026-PRODUCTION.md)
(§"Migration: Lux Primary Network") — but cross-check its block-0 hash against §2 here.

---

## 4. Tools

| Tool | Purpose |
|---|---|
| `state/cmd/rlp-vs-genesis` | **Verify** a genesis produces the RLP's block-0 hash. `go build` then `rlp-vs-genesis <chain.rlp> <genesis.json> [upgrade.json]`. Exit 0 = match. |
| `state/cmd/genesis-hash-empirical` | Batch-compute block-0 hash for candidate genesis JSONs. |
| `genesis/cmd/derivekey` | Derive funding/alloc keys `m/44'/9000'/0'/0/<i>` from the mnemonic. |
| `keys.DeriveHybridIdentity` / `DeriveValidatorFromMnemonic` | Derive validator staking keys (deterministic). |

---

## 5. Runbook map (which doc for what)

| Need | Doc |
|---|---|
| **This orientation** | `migration/START-HERE.md` (you are here) |
| Full production migration steps (all nets) | `migration/MIGRATION-2026-PRODUCTION.md` |
| Quasar-Edition design (precompiles, hybrid identity, activation eras) | `migration/CLAUDE.md` (⚠ Step-1 hash is stale — see §2) |
| **RLP↔genesis↔upgrade contract + verified hashes** | `state/CLAUDE.md` (authoritative for hashes) |
| Ownership / treasury sweep | `migration/OWNERSHIP-RUNBOOK.md`, `migration/SWEEP-RUNBOOK.md` |
| v1.36.14 fork runbook (RLP export→import→verify gates) | `state/V1.36.14-FORK-RUNBOOK.md` |
| Incident 1082814 (finality equivocation) + QCv2 fix | `state/incident-1082814/` |

---

## 6. Gotchas (what wasted cycles before — don't repeat)

1. **No hash assertion without an RLP decode.** Speculative hashes (`0x067668d0`,
   `0x2f4ae11a`) burned ~4 cycles. Run `cmd/rlp-vs-genesis` and read the block-1
   parentHash from the RLP itself.
2. **Never bake precompiles into genesis for a chain with RLP history** — it mutates
   the block-0 state root (`ApplyPrecompileActivations` at genesis) and breaks import.
   Forward-date in `upgrade.json`. (Fresh, no-history chains: baking at
   `blockTimestamp:0` is fine.)
3. **The RLP is NOT "gone" if `git ls-tree HEAD` shows no `exports/`** — a restructure
   moved it out of the current tree, but it's in history + s3 + local disk. Three copies.
4. **Two finality fixes must both be in the regenesis image**: the reconcile /
   SetPreference-orphan fix (consensus v1.36.9) AND the QCv2 / incident-1082814
   envelope-id fix. Verify both before cutting the image.
