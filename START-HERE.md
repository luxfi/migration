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

**Canonical block-0 hashes — verified directly from the RLP bytes** (the RLP is
the source of truth; re-run the command in §4 to reproduce any of these):

| Chain | Canonical block-0 hash (the RLP demands this) | Genesis that produces it |
|---|---|---|
| Lux C mainnet (96369) | `0x3f4fa2a0b0ce089f52bf0ae9199c75ffdd76ecafc987794050cb0d286f1ec61e` | `genesis/configs/mainnet/cchain.json` — **2-alloc** (warp `0x02..05` + treasury `0x9011…`), `skipPostMergeFields:true`, ts `0x672485c2` |
| Zoo mainnet (200200) | `0x7c548af47de27560779ccc67dda32a540944accc71dac3343da3b9cd18f14933` | Zoo pristine 2-alloc form |
| Zoo testnet (200201) | `0x0652fb2fde1460544a5893e5eba5095ff566861cbc87fcb1c73be2b81d6d1979` | Zoo-test pristine 2-alloc form |

**The canonical genesis is `~/work/lux/genesis/configs/mainnet/cchain.json`**
(== `cchain.canonical.json`; both verified 2-alloc / `skipPostMergeFields:true` /
ts `0x672485c2`). That is the ONLY C-Chain genesis that produces `0x3f4fa2a0…`.

> ⚠ **Stale/wrong genesis files — DO NOT boot mainnet from these:**
> - `~/work/lux/universe/docker/genesis/mainnet/cchain.json` — has **3 allocs, no
>   `skipPostMergeFields`** → produces a DIFFERENT hash → RLP import wedges. Stale.
> - `genesis.original.json` (was in `state/pebbledb/configs/lux-*`) — **DELETED 2026-07-17.**
>   It was a 1-alloc form → `0x2f4ae11a…` (wrong), NOT `0x3f4fa2a0…`. The canonical
>   `genesis/configs/mainnet/cchain.json` is the only C-Chain genesis you need.
> - The `0x067668d0` in `migration/CLAUDE.md` Step 1 is a **phantom** — it appears in
>   no RLP decode and no genesis. Ignore it.
>
> **Pre-launch gate — source side CLOSED (2026-07-17):** `genesis/configs/mainnet/cchain.json`
> is confirmed **Candidate B** (2-alloc, ts `0x672485c2`, `skipPostMergeFields:true`) →
> boots to `0x3f4fa2a0…` (also empirically MATCH-verified against the RLP on 2026-06-02,
> see `state/CLAUDE.md`). **Remaining gate:** confirm the *deployed* k8s ConfigMap
> `cChainGenesis` (`universe/k8s/lux-mainnet/luxd-genesis.yaml`) renders byte-equal to that
> source file. Verify by booting a node and checking `eth_getBlockByNumber("0x0") == 0x3f4fa2a0…`.

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

**Reproduce the canonical block-0 hash straight from any RLP — no build, no deps**
(this is how the §2 hashes were verified; `blockN.header[0]` is the parentHash =
the prior block's hash, so `block1.header[0]` == the genesis hash the RLP demands):

```python
python3 - <<'PY'
def hdr(d,o):
    b=d[o]
    if   b>=0xf8: ll=b-0xf7; L=int.from_bytes(d[o+1:o+1+ll],'big'); s=o+1+ll
    elif b>=0xc0: L=b-0xc0; s=o+1
    elif b>=0xb8: ll=b-0xb7; L=int.from_bytes(d[o+1:o+1+ll],'big'); s=o+1+ll
    elif b>=0x80: L=b-0x80; s=o+1
    else:         L=0; s=o
    return s,L,s+L
d=open("PATH/TO/chain.rlp","rb").read(8192)
_,_,b1=hdr(d,0); b1s,_,_=hdr(d,b1); hs,_,_=hdr(d,b1s); ps,pl,_=hdr(d,hs)
print("block-0 hash = 0x"+d[ps:ps+pl].hex())
PY
```

| Tool | Purpose |
|---|---|
| `state/cmd/rlp-vs-genesis` | Verify a genesis JSON *produces* the RLP block-0 hash. ⚠ **Still won't build from cold** — the `pqcrypto` break is fixed (coreth `3687e4e25`: `pqcrypto`→`mlkem`, which wraps `luxfi/crypto/mlkem`), but coreth carries further legacy dep-skew (`warp.UnsignedMessage`, and `geth v1.16.99` in its own go.mod) that needs a separate coreth modernization. **You don't need it for launch:** the Lux-C (`0x3f4fa2a0`) and Zoo (`0x7c548af4`) genesis↔RLP matches are already empirically MATCH-verified (2026-06-02, `state/CLAUDE.md`). For a fresh check use the python snippet above (RLP side) + boot-luxd `eth_getBlockByNumber("0x0")` (genesis side, production geth v1.20.1). |
| `state/cmd/genesis-hash-empirical` | Batch-compute block-0 hash for candidate genesis JSONs (same dep caveat). |
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
