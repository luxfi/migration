# Lux Network Migration — Quasar Edition (Dec 25 2025)

**Source of truth for the migration from the Etna-era (Dec 25 2024) Lux network to the Quasar Edition (Dec 25 2025 16:20 PST = unix `1766708400`).**

The Quasar Edition is what Lux Primary Network + C-Chain MUST be running. All historical archives import cleanly against the original genesis; Quasar Edition rules activate forward-dated via `upgrade.json`, preserving block 0 identity.

> ⚠️ **HASH CORRECTION (2026-07-17) — READ BEFORE ACTING.** Anywhere below that says
> "mount `genesis.original.json`" or block-0 = `0x067668d0` is **WRONG/inverted**. The
> RLP bytes demand block-0 = **`0x3f4fa2a0…`** for Lux C (verified directly from the
> archive), and the canonical genesis is **`~/work/lux/genesis/configs/mainnet/cchain.json`**
> (2-alloc, `skipPostMergeFields:true`), NOT `genesis.original.json` (1-alloc, produces
> `0x2f4ae11a…`, wedges import). Per-chain verified block-0 hashes + a build-free way to
> reproduce them: **[START-HERE.md](START-HERE.md) §2/§4**. Verify EVERY chain's genesis
> against its RLP before launch — never trust a bare hash written in a doc.

> **Not this doc:** the DEX **V3 → V4 liquidity migration** is a separate, self-contained
> toolkit in [`v3v4/`](v3v4/RUNBOOK.md) (chainId 96369). It **EXECUTED 2026-07-05** — V4
> PoolManager `0x2e317c5ce2c3e3aa720a3bb7f366f5959d940d4c`, LiquidityDeployer
> `0x9888015bd7cda1905bbebf560f800731772957fd` (owned by the DAO Safe). It is unrelated to
> the Quasar network migration below; read `v3v4/RUNBOOK.md` for it.

---

## Two Activation Eras (do not conflate)

| Era | Timestamp | Unix | What activates |
|---|---|---|---|
| **Etna** (already done) | Dec 25 2024 16:20 UTC | `1735143600` | C-Chain modern EVM forks (Berlin/London/Shanghai), Etna/Fortuna/Granite protocol upgrades, Warp precompile |
| **Quasar Edition** (target) | Dec 25 2025 16:20 PST (= Dec 26 00:20 UTC) | `1766708400` | Quasar consensus (Pulsar + Corona + Magnetar + Polaris), 42 PQ precompiles, ML-DSA hybrid validator identity (X-Wing pattern), single SHAKE256-384 NodeID (sponge ROM one-way; XOFs aren't length-extendable so no BTC-style double-hash is needed; see Validator identity section L43, L151), Cancun |

The Etna timestamp is baked into existing canonical genesis JSONs (look for `etnaTimestamp: 1735143600`). The Quasar timestamp is delivered via `upgrade.json` forward-dating, NEVER baked into genesis (would break block 0 identity and existing RLP archives).

---

## What "Quasar Edition" Means

### Consensus layer
- **Quasar** = composed `Pulsar` (M-LWE threshold ML-DSA) + `Corona` (R-LWE threshold) + `Magnetar` (SLH-DSA THBS-SE) + `Polaris` cert profile
- Source: `~/work/lux/consensus/protocol/quasar/`
- Round signer pattern: `RoundSigner` wraps `pulsarm.ThresholdSigner` + `prism.Cut`
- Threshold certificates carry BLS + Pulsar + ML-DSA signatures in parallel (triple mode)

### Validator identity — Bindel-Brendel-Fischlin (BBF21 + CDFFJ23) stronger-binding hybrid
- Classical: **secp256k1 ECDSA** (existing P/X validator keypair preserved; the ECDSA scalar IS the classical sub-key)
- Post-quantum: ML-DSA-65 (FIPS 204) — new keypair derived from same mnemonic at a sibling BIP-44 leaf
- Construction (BBF21 N-Sig with CDFFJ23 joint-pubkey binding — NOT raw concat):
  - `m_bound = SHAKE256-384("lux-hybrid-sig-v1" || left_encode(8·|pk_c|) || pk_c || left_encode(8·|pk_pq|) || pk_pq || left_encode(8·|msg|) || msg)`
  - `sig_c   = secp256k1.SignHash(sk_c, m_bound[:32])`
  - `sig_pq  = mldsa65.SignCtx(sk_pq, m_bound, ctx="lux-hybrid-sig-v1")`
  - `Verify  = AND( secp256k1.VerifyHash(pk_c, m_bound[:32], sig_c), mldsa65.VerifyCtx(pk_pq, m_bound, sig_pq, ctx="lux-hybrid-sig-v1") )`
- Why BBF, not raw concat: raw concat reduces to MIN security under non-honest-key adversary (CDFFJ23 §4). BBF binds BOTH pubkeys into m_bound so substituting either component invalidates the binding; security ≥ max(EUF-CMA_secp, sEUF-CMA_mldsa).
- Reference: `~/work/lux/keys/hybrid.go` (implementation), `~/work/lux/keys/proofs/easycrypt/Hybrid_BBF_Binding.ec` (formal theory, 0 admits).
- Old ECDSA-only validator certs: rejected after Quasar activation timestamp; stake records re-anchored to hybrid pubkey via a P-Chain re-anchor tx that includes BOTH the new hybrid pubkey AND a signed transcript proving control over both keys (joint hybrid signature over the re-anchor envelope).

### NodeID — single SHAKE256-384 over wire-form hybrid pubkey
- `NodeID = SHAKE256-384("NODE_ID_V1" || serviceChainID || 0x42 || wireFormHybridPubkey)[:20]`
- `wireFormHybridPubkey = left_encode(8·|pk_c|) || pk_c || left_encode(8·|pk_pq|) || pk_pq`
- Per cryptographer review: single-SHAKE is sound; BTC-style double-hash buys nothing here because SHAKE256-384 is one-way under the standard sponge ROM assumption. The 0x42 scheme byte is preserved — a hybrid identity inherits the existing ML-DSA-65 NodeID scheme.
- See `~/work/lux/keys/service_identity.go` `DeriveHybridIdentity` for the concrete derivation.

### EVM Cancun + 42 PQ precompiles on C-Chain
- `cancunTimestamp`: `1766708400` (was `null`)
- `precompileUpgrades[]` adds 42 PQ precompiles at `blockTimestamp: 1766708400`. The full set:
  - PQ signature/KEM verifiers: `mldsaVerify`, `slhdsaVerify`, `hqcEncapsulate`, `pulsarVerify`, `magnetarVerify`, `p3qVerify`, `coronaThreshold`
  - Threshold ECDSA: `cggmp21Verify`, `frostVerify`
  - BLS12-381: `bls12381G1AddConfig`, `bls12381G1MulConfig`, `bls12381G1MSMConfig`, `bls12381G2AddConfig`, `bls12381G2MulConfig`, `bls12381G2MSMConfig`, `bls12381PairingConfig`
  - Hashes/curves: `blake3Config`, `curve25519Config`, `x25519Config`, `sr25519Verify`, `babyjubjubConfig`, `pedersenConfig`, `poseidonConfig`, `pastaConfig`, `ringConfig`
  - Encryption: `hpkeConfig`, `mlkemConfig`, `xwingConfig`, `pqcryptoConfig`
  - FHE/ZK: `fheConfig`, `zkConfig`
  - App primitives: `aiMiningConfig`, `dexConfig`, `computeMarketConfig`, `bridgeRegistrarConfig`, `routerConfig`, `stableSwapConfig`, `vrfConfig`, `graphConfig`, `attestationConfig`, `anchorConfig`, `fixedPointMathConfig`
- **EXCLUDED:** `eciesConfig` (unsafe on public chain per task #99)
- The 43rd from the brand L1 list (`hanzo-mainnet/genesis.json -> config.precompileUpgrades`) is `eciesConfig`. We activate 42 on Lux primary C-Chain.

---

## Migration: Lux Primary Network (P + X + C-Chain)

### State of play

| Chain | Has RLP archive? | Original genesis available? | Quasar Edition target |
|---|---|---|---|
| P-Chain | No (DB-only, sybil-protected) | n/a | New ML-DSA hybrid validator certs + BTC-style NodeID after Quasar timestamp |
| X-Chain | No (DB-only) | n/a | UTXO format unchanged; address derivation paths unchanged |
| C-Chain | `~/work/lux/state/rlp/lux-mainnet/lux-mainnet-96369.rlp` (1.2GB) | `~/work/lux/genesis/configs/mainnet/cchain.json` (2-alloc, `skipPostMergeFields:true`, ts `0x672485c2` → block-0 **`0x3f4fa2a0`**, RLP-verified) | Cancun + 42 PQ precompiles forward-dated at `1766708400` |

### Step 1 — Mount the canonical 2-alloc `cchain.json` as mainnet C-Chain genesis

> **CORRECTED 2026-07-17 — this step was INVERTED and would have wedged the import.**

The C-Chain RLP archive demands block-0 hash
**`0x3f4fa2a0b0ce089f52bf0ae9199c75ffdd76ecafc987794050cb0d286f1ec61e`** — verified
directly from the RLP's block-1 `parentHash` (`block1.header[0]`; reproduce with the
build-free snippet in [START-HERE.md §4](START-HERE.md)). The **2-alloc
`~/work/lux/genesis/configs/mainnet/cchain.json`** (warp `0x02..05` + treasury,
`skipPostMergeFields:true`, ts `0x672485c2`) is the ONLY genesis that produces that
hash — empirically confirmed in [`state/CLAUDE.md`](../state/CLAUDE.md). Do **NOT**
mount `genesis.original.json`: it is a 1-alloc form that produces `0x2f4ae11a…` (wrong)
and wedges the import. The prior `0x067668d0` in this doc was a **phantom** (in no RLP
decode and no genesis) — ignore it.

```bash
# luxd start args for the C-Chain (production)
luxd \
  --genesis-file=/etc/luxd/cchain.json \
  --chain-config-dir=/etc/luxd/chains \
  --network-id=1 \
  ...
```

K8s wiring: mount the canonical `~/work/lux/genesis/configs/mainnet/cchain.json`
(2-alloc → block-0 `0x3f4fa2a0`) as a ConfigMap at `/etc/luxd/cchain.json`, set
`--genesis-file` to that path in the StatefulSet command. Update
`~/work/lux/universe/k8s/lux-mainnet/luxd-startup.yaml` accordingly. Do NOT mount
`genesis.original.json` (produces `0x2f4ae11a`, wedges import).

### Step 2 — Import RLP via `admin_importChain`

Existing `~/work/lux/state/rlp/lux-mainnet/lux-mainnet-96369.rlp` carries ~1M blocks of C-Chain history. Once block 0 matches, import:

```bash
curl -s --max-time 7200 http://luxd-0:9650/ext/bc/C/rpc \
  -d '{"jsonrpc":"2.0","method":"admin_importChain","params":["/data/lux-mainnet-96369.rlp"],"id":1}'
```

Verify chain head reaches the RLP tip (`eth_blockNumber` returns multi-million hex value).

### Step 3 — Deploy `upgrade.json` activating Quasar Edition at `1766708400`

The canonical `upgrade.json` lives in `~/work/lux/genesis/configs/mainnet/upgrade.json` and is mounted at `<chain-config-dir>/C/upgrade.json` on every luxd pod. The schema has THREE invariants luxd enforces at boot. Violate any and the cluster wedges:

**Invariant 1 — Superset of live activations.** `params/extras.ChainConfig.checkPrecompileCompatible` (evm/params/extras/precompile_upgrade.go:217) walks every already-activated precompile in the running config and requires the new config to keep it at the *same blockTimestamp*. The live `lux-mainnet` StatefulSet inlines 18 precompiles at `blockTimestamp:0` (universe/k8s/lux-mainnet/luxd-startup.yaml line 182), so those 18 entries MUST stay at `blockTimestamp:0` in the canonical upgrade.json:

```
aiMiningConfig, blake3Config, cggmp21Verify,
deadZeroConfig, deadConfig, deadFullConfig,
dexConfig, routerConfig,
fheConfig, frostVerify, graphConfig, hpkeConfig,
mldsaVerify, mlkemConfig, pqcryptoConfig,
ringConfig, slhdsaVerify, zkConfig
```

Rescheduling any of these to `1766708400` (or omitting them) → boot fails with `mismatching PrecompileUpgrade` / `missing PrecompileUpgrade`. Regression test: `evm/params/extras/precompile_upgrade_rollout_test.go::TestMainnetUpgradeJSON_IsForwardCompatibleWithLiveActivations`.

**Invariant 2 — Strict-PQ profile.** Two complementary surfaces switch on the same posture:

1. `networkUpgradeOverrides.strictPQTimestamp = 1766708400` in `upgrade.json`. This pins `NetworkUpgrades.StrictPQTimestamp` and exposes the `StrictPQReporter` interface to `contract.RefuseUnderStrictPQ`, which classical Lux stateful precompiles call at the top of their `Run()`:
   - bls12-381 G1/G2 add/mul/MSM/pairing
   - sr25519, x25519, curve25519, ed25519
   - babyjubjub, pedersen, pasta, poseidon, ring, hpke
   - frostVerify, cggmp21Verify (ECDSA threshold — refused under strict-PQ; hybrid validators MUST migrate to PQ-only certs before activation per Step 4)
   - kzg4844Config, zk (classical SNARK wrappers — refused)
2. `pq: true` in `~/work/lux/state/chain-configs/lux-mainnet/config.json` (the EVM plugin config mounted at `<chain-config-dir>/<CID>/config.json`). This:
   - sets `vm.chainConfig.PQ = gethvm.AllForbidden()` covering the 0x01–0x09 standard precompiles (ecrecover, sha256/ripemd/blake2F, alt_bn128 add/mul/pairing, blake2F, KZG point eval)
   - and forces `StrictPQTimestamp = &0` on the extras config so the Lux precompile gate fires from genesis on freshly-rebuilt nodes too

Both surfaces are required. The upgrade.json side activates the gate on the running mainnet at the Quasar timestamp; the chain-config side pins the same posture for nodes that rebuild state from scratch. Regression tests: `TestMainnetUpgradeJSON_HasStrictPQActivation`, `TestMainnetChainConfig_HasStrictPQTrue`.

**Invariant 3 — Warp policy.** `warpConfig.requirePrimaryNetworkSigners = true` MUST be set so every cross-chain warp message is signed by primary-network validators (not a subnet quorum). The live config sets it; the canonical upgrade.json keeps it. Regression: `TestMainnetUpgradeJSON_WarpRequiresPrimaryNetworkSigners`.

**Cancun is genesis-time, not upgrade-time.** Cancun activates from genesis automatically — `vm.parseGenesis` (evm/plugin/evm/vm.go:709-712) forces `ShanghaiTime` and `CancunTime` to 0 if not set. The earlier `cancunTimestamp` field inside `networkUpgrades` (sic) was unrecognized and silently dropped. Do not add it back.

**Field name is `networkUpgradeOverrides`, NOT `networkUpgrades`.** `UpgradeConfig` (evm/params/extras/config.go:141) reads the override block from `networkUpgradeOverrides`. Earlier drafts wrote `networkUpgrades`, which JSON-unmarshalled to nothing — the override was silently ignored.

**Field name is `feeManagerConfig`, NOT `feeConfigManagerConfig`.** The registered module key is `feeManagerConfig` (evm/precompile/contracts/feemanager/module.go:19); earlier drafts wrote the longer string, which `UpgradeConfig.UnmarshalJSON` rejected with "unknown precompile config".

`upgrade.json` is a runtime config — applying it does NOT change block 0 hash. luxd activates the precompiles at the specified `blockTimestamp` as the chain crosses that timestamp. Since `1766708400` is in the past (June 2026 now), they activate immediately on the next block.

### Step 4 — Roll the validator set to BBF-bound hybrid identity

Per task #133, with the BBF21+CDFFJ23 binding (NOT raw concat — see Validator identity section above):

- Each validator's mnemonic stays the same.
- Derive joint hybrid key via `keys.DeriveHybridIdentity(mnemonic, "lux/validator/<index>")`:
  - classical (secp256k1): `m/44'/9000'/serviceIndex'/0'/0'`, KDF-mixed with domain `"lux-hybrid-classical-secp256k1-v1"`
  - PQ (ML-DSA-65): `m/44'/9000'/serviceIndex'/0'/1'`, KDF-mixed with domain `"lux-hybrid-pq-mldsa65-v1"`
  - The two leaves share the same hardened branches up to the role node; only the leaf index distinguishes them (0 vs 1). Both leaves are hardened.
- **Stake record re-anchor** (the actual P-Chain tx):
  - Carries BOTH the new wire-form hybrid pubkey (`HybridPublicKeyBytes`) AND the existing ECDSA pubkey, referencing the same staking weight.
  - Includes a **proof-of-control transcript** = a hybrid signature (`keys.HybridSign`) over `"lux-reanchor-v1" || existing_ecdsa_pubkey || new_hybrid_pubkey || stake_weight || activation_timestamp`. This signature proves the validator controls BOTH the legacy and the new joint key — the BBF binding makes this single signature unforgeable under either component's break.
  - After Quasar activation timestamp (`1766708400`), classical-only certs are refused by the staking gate; all validators must have re-anchored before this point or be unstaked.
- New NodeID: derived from hybrid pubkey via single SHAKE256-384 over `wire-form hybrid pubkey` (no BTC-style double-hash; see Validator identity / NodeID section above).

This is the only step that touches P-Chain state. It cannot be RLP-imported (no archive); it executes as P-Chain transactions issued before the activation timestamp. The implementation is at `~/work/lux/keys/hybrid.go` + `~/work/lux/keys/service_identity.go::DeriveHybridIdentity`; the formal theory is at `~/work/lux/keys/proofs/easycrypt/Hybrid_BBF_Binding.ec`.

### Step 5 — Coordinated luxd image swap (closure-swarm, 2026-06-02)

The closure-swarm pushed a clean v1.28.15 with the latest semver everywhere
(consensus v1.25.13, threshold v1.9.7, magnetar v1.2.0, pulsar v1.1.2,
keys v1.1.0, accel v1.1.8). NO weird hybrid tag — earlier
`v1.28.7-corona-v0.7.6` and `v1.25.5-corona-v0.7.6` compat tags were
deleted from both origin and local. There is no env-var dual-mode codec.
Main is strict v0.7.6 wire.

Because every closure-swarm tag commits to a single wire shape, this is
a **coordinated full-network restart**, not a rolling upgrade. Brief
outage, clean upgrade. Pre-flight: confirm GHCR has
`ghcr.io/luxfi/node:v1.28.15` for `linux/amd64` (arm64 paused per
memory:multiarch_builds — DOKS has no arm64 droplets):

```bash
docker manifest inspect ghcr.io/luxfi/node:v1.28.15 | head -10
```

Procedure (mainnet — same shape for devnet/testnet):

```bash
# Cluster: DOKS lux-k8s, namespace lux-mainnet
NS=lux-mainnet
SS=luxd

# 1. Snapshot validator IDs (for re-anchor verification at step 4 if needed)
kubectl -n "$NS" exec sts/${SS}-0 -- curl -s http://localhost:9650/ext/bc/P \
  -d '{"jsonrpc":"2.0","method":"platform.getCurrentValidators","params":{},"id":1}' \
  > /tmp/validators-pre-v1.28.15.json

# 2. STOP all 5 luxd pods simultaneously (sybil-protection requires the
#    set goes down together — staggered downs can wedge the P-chain at
#    h<n while peers still expect a quorum).
kubectl -n "$NS" scale sts/${SS} --replicas=0
kubectl -n "$NS" wait pod -l app.kubernetes.io/name=luxd \
  --for=delete --timeout=120s

# 3. Apply the v1.28.15 manifest (the LuxNetwork CR's spec.image.tag is
#    already pinned via the universe/k8s/lux-mainnet/network.yaml on
#    branch bump/luxd-v1.28.15-closure-swarm — merge or use kustomize).
kubectl -n "$NS" kustomize . | kubectl -n "$NS" apply -f -

# 4. START all 5 pods simultaneously.
kubectl -n "$NS" scale sts/${SS} --replicas=5

# 5. Watch consensus quorum form. Expected: ~30-60s to reach quorum
#    once 4 of 5 pods are Ready; full sync once 5/5.
kubectl -n "$NS" rollout status sts/${SS} --timeout=600s
kubectl -n "$NS" logs sts/${SS}-0 --tail=50 | grep -E "quorum|consensus|started"

# 6. Health probe (must succeed within 2min of restart)
for i in 0 1 2 3 4; do
  echo "=== luxd-$i ==="
  kubectl -n "$NS" exec sts/${SS}-$i -- curl -s http://localhost:9650/ext/health \
    | jq '.healthy'
done
```

Per global rule "NEVER wipe luxd /data/db" (memory:luxd_db_wipe_lesson) —
the StatefulSet must NOT have its PVCs touched. The bump is image-only.

Pre-flight gates before STOP:
1. All 5 pods Ready + healthy
2. No active C-Chain import (`admin_isImporting` returns false)
3. Validator set count = 5 (no in-flight stake-record re-anchors)
4. KMS reachable (`kubectl -n hanzo logs sts/kms-0 --tail=5` is steady)
5. Universe manifest PR merged into main, or you're applying from the
   `bump/luxd-v1.28.15-closure-swarm` branch directly

Rollback: revert to v1.28.7 (the last known-good production image
before the closure-swarm series) — same procedure, swap the image tag
in the LuxNetwork CR.

### Step 6 — Verification (post-restart)

```bash
# Block 0 hash matches RLP expectation
curl http://luxd-0:9650/ext/bc/C/rpc -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  | jq -r '.result.hash'
# Expected: 0x3f4fa2a0 (RLP-verified; NOT 0x067668d0 — that was a phantom)

# Chain tip > 1M
curl http://luxd-0:9650/ext/bc/C/rpc -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Precompile active (e.g. mldsaVerify at slot 0x0...0100 — verify actual slot from genesis builder)
curl http://luxd-0:9650/ext/bc/C/rpc -d '{"jsonrpc":"2.0","method":"eth_getCode","params":["0x0000000000000000000000000000000000000100","latest"],"id":1}'
# Expected: 0x01 (precompile sentinel)

# Validator set has hybrid pubkeys
curl http://luxd-0:9650/ext/bc/P -d '{"jsonrpc":"2.0","method":"platform.getCurrentValidators","params":{},"id":1}' \
  | jq '.result.validators[0].pq_pubkey'
# Expected: ML-DSA-65 pubkey hex
```

---

## Migration: L1/L2 EVM Chains (Hanzo / Zoo / Pars / SPC)

### Per-brand status

| Brand | Layer | Mainnet RLP available? | Quasar Edition target |
|---|---|---|---|
| Hanzo L2 | L2 (shares Lux validators) | No archival RLP — fresh-chain | Genesis already has 43 precompiles baked at `blockTimestamp: 0`; drop eciesConfig to 42 via in-place genesis edit (acceptable — no historical state) |
| Zoo L2 | L2 (shares Lux validators) | `rlp/zoo-mainnet/zoo-mainnet-200200.rlp` (1.3MB, 799 blocks) | Use `genesis.original.json` for archive, upgrade.json for Quasar precompiles |
| Pars L1 | L1 (sovereign) | No archival RLP (fresh) | Baked into genesis at `blockTimestamp: 0` (acceptable for fresh chain) |
| SPC L2 | L2 (shares Lux validators) | `rlp/spc-mainnet/spc-mainnet-36911.rlp` (7.8KB, 11 blocks) | Use `genesis.original.json` for archive, upgrade.json for Quasar precompiles |

### Per-chain flow

For chains WITH archival RLP (zoo-mainnet, spc-mainnet):
1. Verify `genesis.original.json` exists in `~/work/lux/state/pebbledb/configs/<chain>-<env>/`. If not, create it from the genesis that matches the RLP's block 1 parent.
2. Mount `genesis.original.json` via the chain's `CreateChainTx` `Genesis []byte` parameter.
3. `admin_importChain` against the RLP.
4. Deploy `upgrade.json` activating Quasar Edition rules forward-dated. Same shape as Lux primary C-Chain except chain-specific chainId.

For chains WITHOUT archival history (hanzo-mainnet, pars-mainnet, all testnet/devnet fresh):
1. Bake the Quasar Edition precompile set into the genesis at `blockTimestamp: 0` (forward-dated unnecessary; no history to preserve).
2. `CreateChainTx` with that genesis. Chain starts at h=0 with Quasar rules active.
3. Drop `eciesConfig` from brand L1 genesis if present (was the 43rd precompile per hanzo-mainnet schema; unsafe).

---

## Anti-patterns (we've done these — STOP)

1. **Baking Quasar activation timestamps INTO genesis JSON for chains with archival history.** Every attempt drifts the genesis hash and breaks RLP import. Forward-date via `upgrade.json` instead.
2. **Wiping chain DB to "fix" the wedge.** The wedge isn't a corruption — it's a hash mismatch between the canonical-shipped genesis and the RLP's expected genesis. Wiping just loses history. The real fix is mounting the right genesis.
3. **Manufacturing genesis to make the hash match.** The hash-matching genesis ALREADY exists at `pebbledb/configs/<chain>-<env>/genesis.original.json`. Use it.
4. **Sentinel-version bumping in startup scripts** (`.cchain_rlp_imported_v1`, v2, v3, v4 …). That's manual cache invalidation by string mutation. Replaced with operator-driven content-hash addressed `tenantImports[]` per luxfi/operator@v0.7.0.
5. **Bumping luxd image (or any image) above its current major in hopes of fixing the wedge.** Never crosses majors per CLAUDE.md. The bug isn't a luxd version bug; it's a genesis-selection bug.

---

## Cross-repo references

| What | Where |
|---|---|
| RLP ↔ genesis ↔ upgrade contract | `~/work/lux/state/LLM.md` |
| Canonical genesis configs (Lux primary only) | `~/work/lux/genesis/configs/{mainnet,testnet,devnet,dev,localnet}/` |
| Original genesis matching RLP | `~/work/lux/state/pebbledb/configs/<chain>-<env>/genesis.original.json` |
| Quasar consensus | `~/work/lux/consensus/protocol/quasar/` |
| Pulsar (M-LWE threshold ML-DSA) | `~/work/lux/pulsar/` |
| Corona (R-LWE threshold) | `~/work/lux/corona/` |
| Magnetar (SLH-DSA THBS-SE) | `~/work/lux/magnetar/` |
| ML-DSA hybrid identity design | `~/work/lux/keys/service_identity.go` + task #133 |
| Operator-driven `tenantImports[]` | `~/work/lux/operator/go/internal/manifests/luxnetwork_plugin.go` (v0.7.0) |

---

## Verification Checklist (Quasar Edition production readiness)

- [ ] luxd boots with `--genesis-file=<genesis/configs/mainnet/cchain.json>` (2-alloc) on all 5 mainnet pods
- [ ] `eth_getBlockByNumber 0x0` returns `0x3f4fa2a0…` on all pods (NOT `0x067668d0`)
- [ ] `admin_importChain` succeeds; `eth_blockNumber` > 1M
- [ ] `upgrade.json` mounted at `<chain-config-dir>/C/upgrade.json` with 42 Quasar precompiles at `blockTimestamp: 1766708400`
- [ ] Each precompile address responds (`eth_getCode` returns `0x01` sentinel)
- [ ] Cancun behavior active (test blob tx if blob support intended)
- [ ] All 5 validators present hybrid (ECDSA + ML-DSA) pubkeys via `platform.getCurrentValidators`
- [ ] NodeID derived via single SHAKE256-384 on each pod (`info.getNodeID` matches `SHAKE256-384("NODE_ID_V1" || serviceChainID || 0x42 || serialize(hybrid_pubkey))[:20]` per `keys/service_identity.go:549-553`; single-pass is sound under sponge ROM, XOFs aren't length-extendable, so no BTC-style double-hash is needed)
- [ ] Bridge round-trip: send tokens C-Chain → Zoo L2 → C-Chain via Warp + sBridge contract
- [ ] DEX swap: AMM router + WLUX/sLUX/sZOO swap works
- [ ] Vault: deposit + withdraw works against latest `~/work/lux/standard` contracts

---

## Why this doc exists

We've solved variants of this migration 3-4 times without persistent institutional memory. Each round the same rediscovery happens (genesis hash mismatch → "missing last accepted block" / "triedb parent missing" → wipe → fresh h=0 → realize we lost history → start over).

This doc is the canonical reference so the next person (or AI agent) reads ONE place and understands:
1. Which genesis hashes which RLP
2. How upgrade activation is forward-dated WITHOUT changing block 0
3. What Quasar Edition adds and at what timestamp
4. Per-chain whether you import-then-upgrade (archival) or bake-at-genesis (fresh)

Read this BEFORE attempting any C-Chain bring-up work. Do not invent new patterns. The pattern is documented; follow it.

---

*Created 2026-06-01. Repo: `~/work/lux/migration/` (this file).*
