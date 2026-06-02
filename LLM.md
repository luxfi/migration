# Lux Network Migration — Quasar Edition (Dec 25 2025)

**Source of truth for the migration from the Etna-era (Dec 25 2024) Lux network to the Quasar Edition (Dec 25 2025 16:20 PST = unix `1766708400`).**

The Quasar Edition is what Lux Primary Network + C-Chain MUST be running. All historical archives import cleanly against the original genesis; Quasar Edition rules activate forward-dated via `upgrade.json`, preserving block 0 identity.

---

## Two Activation Eras (do not conflate)

| Era | Timestamp | Unix | What activates |
|---|---|---|---|
| **Etna** (already done) | Dec 25 2024 16:20 UTC | `1735143600` | C-Chain modern EVM forks (Berlin/London/Shanghai), Etna/Fortuna/Granite protocol upgrades, Warp precompile |
| **Quasar Edition** (target) | Dec 25 2025 16:20 PST (= Dec 26 00:20 UTC) | `1766708400` | Quasar consensus (Pulsar + Corona + Magnetar + Polaris), 42 PQ precompiles, ML-DSA hybrid validator identity (X-Wing pattern), BTC-style hash-of-hash NodeID, Cancun |

The Etna timestamp is baked into existing canonical genesis JSONs (look for `etnaTimestamp: 1735143600`). The Quasar timestamp is delivered via `upgrade.json` forward-dating, NEVER baked into genesis (would break block 0 identity and existing RLP archives).

---

## What "Quasar Edition" Means

### Consensus layer
- **Quasar** = composed `Pulsar` (M-LWE threshold ML-DSA) + `Corona` (R-LWE threshold) + `Magnetar` (SLH-DSA THBS-SE) + `Polaris` cert profile
- Source: `~/work/lux/consensus/protocol/quasar/`
- Round signer pattern: `RoundSigner` wraps `pulsarm.ThresholdSigner` + `prism.Cut`
- Threshold certificates carry BLS + Pulsar + ML-DSA signatures in parallel (triple mode)

### Validator identity — ML-DSA hybrid (X-Wing pattern)
- Classical: X25519 (existing keypair preserved)
- Post-quantum: ML-DSA-65 (new keypair derived from same mnemonic at canonical path)
- Composition: à la X-Wing KEM (X25519 + ML-KEM-768) — concatenate classical and PQ pubkeys; sign with both; verify both
- Old ECDSA validator keys: deprecated at Quasar activation; existing stake records re-anchored to new hybrid pubkey

### NodeID — BTC-style hash-of-hash
- Pattern: like BTC `HASH160(pubkey) = RIPEMD160(SHA256(pubkey))` — double hash, 20 bytes
- Lux PQ version: `NodeID = SHAKE256(SHAKE256(serialize(hybrid_pubkey))[:32])[:20]`
- Replaces the single-SHAKE NodeID from `~/work/lux/keys/service_identity.go` (`SHAKE256-384("NODE_ID_V1" || serviceChainID || 0x42 || pubkey)[:20]`)
- "Non-deterministic from pubkey" in the cryptographic sense (one-way), deterministic-from-pubkey computationally

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
| C-Chain | `~/work/lux/state/rlp/lux-mainnet/lux-mainnet-96369.rlp` (1.2GB) | `~/work/lux/state/pebbledb/configs/lux-mainnet-96369/genesis.original.json` (hashes to `0x595e9630575e6b596ae78bdf1c6f191fb18a1275d5939b46c26f19dff077f6a7`) | Cancun + 42 PQ precompiles forward-dated at `1766708400` |

### Step 1 — Mount `genesis.original.json` as canonical mainnet C-Chain genesis

The C-Chain RLP archive expects block 0 hash `0x595e9630...` — which is what `genesis.original.json` produces. The current `genesis.json` in the same dir (and the one in `~/work/lux/genesis/configs/mainnet/cchain.json`) added later fields and now hashes to `0x3f4fa2a0...`. That mismatch is why every recent attempt to import the RLP failed.

```bash
# luxd start args for the C-Chain (production)
luxd \
  --genesis-file=/etc/luxd/genesis.original.json \
  --chain-config-dir=/etc/luxd/chains \
  --network-id=1 \
  ...
```

K8s wiring: mount `~/work/lux/state/pebbledb/configs/lux-mainnet-96369/genesis.original.json` as a ConfigMap at `/etc/luxd/genesis.original.json`, set `--genesis-file` to that path in the StatefulSet command. Update `~/work/lux/universe/k8s/lux-mainnet/luxd-startup.yaml` accordingly.

### Step 2 — Import RLP via `admin_importChain`

Existing `~/work/lux/state/rlp/lux-mainnet/lux-mainnet-96369.rlp` carries ~1M blocks of C-Chain history. Once block 0 matches, import:

```bash
curl -s --max-time 7200 http://luxd-0:9650/ext/bc/C/rpc \
  -d '{"jsonrpc":"2.0","method":"admin_importChain","params":["/data/lux-mainnet-96369.rlp"],"id":1}'
```

Verify chain head reaches the RLP tip (`eth_blockNumber` returns multi-million hex value).

### Step 3 — Deploy `upgrade.json` activating Quasar Edition at `1766708400`

Place at `<chain-config-dir>/C/upgrade.json`:

```json
{
  "precompileUpgrades": [
    {"warpConfig": {"blockTimestamp": 0, "quorumNumerator": 67, "requirePrimaryNetworkSigners": true}},
    {"feeConfigManagerConfig": {"blockTimestamp": 900000000, "...": "..."}},
    {"mldsaVerify": {"blockTimestamp": 1766708400}},
    {"slhdsaVerify": {"blockTimestamp": 1766708400}},
    {"pulsarVerify": {"blockTimestamp": 1766708400}},
    {"magnetarVerify": {"blockTimestamp": 1766708400}},
    {"p3qVerify": {"blockTimestamp": 1766708400}},
    {"coronaThreshold": {"blockTimestamp": 1766708400}},
    {"hqcEncapsulate": {"blockTimestamp": 1766708400}},
    {"cggmp21Verify": {"blockTimestamp": 1766708400}},
    {"frostVerify": {"blockTimestamp": 1766708400}},
    {"bls12381G1AddConfig": {"blockTimestamp": 1766708400}},
    {"bls12381G1MulConfig": {"blockTimestamp": 1766708400}},
    {"bls12381G1MSMConfig": {"blockTimestamp": 1766708400}},
    {"bls12381G2AddConfig": {"blockTimestamp": 1766708400}},
    {"bls12381G2MulConfig": {"blockTimestamp": 1766708400}},
    {"bls12381G2MSMConfig": {"blockTimestamp": 1766708400}},
    {"bls12381PairingConfig": {"blockTimestamp": 1766708400}},
    {"blake3Config": {"blockTimestamp": 1766708400}},
    {"curve25519Config": {"blockTimestamp": 1766708400}},
    {"x25519Config": {"blockTimestamp": 1766708400}},
    {"sr25519Verify": {"blockTimestamp": 1766708400}},
    {"babyjubjubConfig": {"blockTimestamp": 1766708400}},
    {"pedersenConfig": {"blockTimestamp": 1766708400}},
    {"poseidonConfig": {"blockTimestamp": 1766708400}},
    {"pastaConfig": {"blockTimestamp": 1766708400}},
    {"ringConfig": {"blockTimestamp": 1766708400}},
    {"hpkeConfig": {"blockTimestamp": 1766708400}},
    {"mlkemConfig": {"blockTimestamp": 1766708400}},
    {"xwingConfig": {"blockTimestamp": 1766708400}},
    {"pqcryptoConfig": {"blockTimestamp": 1766708400}},
    {"fheConfig": {"blockTimestamp": 1766708400}},
    {"zkConfig": {"blockTimestamp": 1766708400}},
    {"aiMiningConfig": {"blockTimestamp": 1766708400}},
    {"dexConfig": {"blockTimestamp": 1766708400}},
    {"computeMarketConfig": {"blockTimestamp": 1766708400}},
    {"bridgeRegistrarConfig": {"blockTimestamp": 1766708400}},
    {"routerConfig": {"blockTimestamp": 1766708400}},
    {"stableSwapConfig": {"blockTimestamp": 1766708400}},
    {"vrfConfig": {"blockTimestamp": 1766708400}},
    {"graphConfig": {"blockTimestamp": 1766708400}},
    {"attestationConfig": {"blockTimestamp": 1766708400}},
    {"anchorConfig": {"blockTimestamp": 1766708400}},
    {"fixedPointMathConfig": {"blockTimestamp": 1766708400}}
  ],
  "stateUpgrades": [],
  "networkUpgrades": {
    "evmTimestamp": 0,
    "durangoTimestamp": 0,
    "etnaTimestamp": 1735143600,
    "cancunTimestamp": 1766708400
  }
}
```

Note `eciesConfig` is EXCLUDED (44th entry; unsafe on public chain).

`upgrade.json` is a runtime config — applying it does NOT change block 0 hash. luxd activates the precompiles at the specified `blockTimestamp` as the chain crosses that timestamp. Since `1766708400` is in the past (June 2026 now), they activate immediately on next block.

### Step 4 — Roll the validator set to ML-DSA hybrid

Per task #133:
- Each validator's mnemonic stays the same.
- Derive ML-DSA-65 key at canonical path `m/44'/9000'/0'/0'/0' + PQ_BRANCH` (TBD; see `~/work/lux/keys/service_identity.go` extension).
- Stake record re-anchor: a P-Chain tx adds the new hybrid pubkey alongside the existing ECDSA pubkey, references the same staking weight. After Quasar activation timestamp, ECDSA-only certs are rejected by the network — all validators must have rolled.
- New NodeID derived from hybrid pubkey via BTC-style double-SHAKE.

This is the only step that touches P-Chain state. It cannot be RLP-imported (no archive); it executes as P-Chain transactions issued before the activation timestamp.

### Step 5 — Verification

```bash
# Block 0 hash matches RLP expectation
curl http://luxd-0:9650/ext/bc/C/rpc -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  | jq -r '.result.hash'
# Expected: 0x595e9630575e6b596ae78bdf1c6f191fb18a1275d5939b46c26f19dff077f6a7

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

- [ ] luxd boots with `--genesis-file=<genesis.original.json>` on all 5 mainnet pods
- [ ] `eth_getBlockByNumber 0x0` returns `0x595e9630575e6b596ae78bdf1c6f191fb18a1275d5939b46c26f19dff077f6a7` on all pods
- [ ] `admin_importChain` succeeds; `eth_blockNumber` > 1M
- [ ] `upgrade.json` mounted at `<chain-config-dir>/C/upgrade.json` with 42 Quasar precompiles at `blockTimestamp: 1766708400`
- [ ] Each precompile address responds (`eth_getCode` returns `0x01` sentinel)
- [ ] Cancun behavior active (test blob tx if blob support intended)
- [ ] All 5 validators present hybrid (ECDSA + ML-DSA) pubkeys via `platform.getCurrentValidators`
- [ ] NodeID derived via BTC-style double-SHAKE on each pod (`info.getNodeID` matches `SHAKE256(SHAKE256(serialize(hybrid_pubkey))[:32])[:20]`)
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
