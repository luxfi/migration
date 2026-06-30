# Lux Production Migration — 2026 (mainnet · testnet · devnet)

PRIVATE. Operational migration state + plan. No plaintext secrets here — only
k8s-secret names + KMS paths. Complete the migration from this doc.

kube context: `do-sfo3-lux-k8s`. Zoo cluster: `do-sfo3-zoo-k8s`.

---

## 0. Current live state (verified)

| net | chainId | node image | consensus | C-Chain |
|---|---|---|---|---|
| mainnet | 96369 | `ghcr.io/luxfi/node:v1.31.4` | quorum-size=4 | live, producing (head ≥1082815) |
| testnet | 96368 | `v1.31.4` | quorum-size=4 | live, producing |
| devnet  | 96367 | `v1.31.4` | quorum-size=4 | live, producing |

- 5 validators per net (`luxd-0..4`, STS `luxd`, updateStrategy OnDelete, mainnet NO-WIPE).
- Chain set (P-Chain `platform.getBlockchains`): A B C D G K Q T X Z. **No M-Chain instantiated.**
- 0x9999 DEX precompile present + fill-proven: testnet block 347 (fresh), mainnet block 1,082,812 (real).
- Operators scaled to 0/0 (deterministic-boot-without-operator); CR image == STS image == v1.31.4.

## 1. Consensus — incident 1082814 + the durable QCv2 fix

**Incident:** finality was keyed on the OUTER proposervm envelope id (and seeded from
`vm.LastAccepted` on boot). Two envelopes (A=2U2pR3D, B=wDMUyGy) wrapped the SAME inner
EVM block (5DEgMudU / 0x098fbedb) → looked like a fork at a finalized height → fatal
EQUIVOCATION → 43h halt. Recovered by converging on A (what all 5 persisted; B was never
written to disk, only an in-memory cert) — ZERO EVM-state change (A.inner == B.inner).
Full evidence: `~/work/lux/state/incident-1082814/`.

**Durable fix (built, all-green, NOT yet rolled — gated on RED):**
- Branch `fix/qcv2-canonical-finality` (commit e8c08d3de) in `~/work/lux/consensus`.
- Part A — seed semantics: `finalizedTip` advances ONLY on a valid QC; `vm.LastAccepted`
  is a non-authoritative HINT.
- Part B — QCv2: cert binds the CANONICAL inner commitment {canonical_block_id,
  execution_state_root, payload_root}, EXCLUDES the envelope → same-inner duplicates are
  not forks. Wire: signed msg `LUX/chain/vote/v2`, QuorumCertVersion=3.
- Proof suite green: 6-row matrix (fails-on-old/passes-on-fix), inversions, go vet,
  staticcheck, `-race`, fuzz (cert codec 613k + decision 110k execs, 0 crashes), 335 tests.
- Spec: `~/work/lux/state/incident-1082814/DURABLE-DESIGN-QCv2.md`.
- ROLL when: RED verdict clean → merge consensus → tag patch → bump node go.mod → ARC build
  → gated roll devnet→testnet→mainnet (all 5 per net roll atomically; no staged QCv1→QCv2).
- Known residual (liveness-only, RED to confirm): a follower on the losing envelope that
  gets a cert for the winning envelope DEFERS (pendingBlocks keyed by outer id); recovers
  via re-request, never halts.

## 2. MPC migration — export + sweep → new shards → KMS → Safe-owned

**Current MPC (to be replaced):**
- Off-chain MPC: `lux-bridge` ns, `mpc-node-0/1/2` StatefulSet, threshold 3-of-5.
- Initiator identity: `0xC0544b64C2D56E0D3c7661B13965A3958Aa76676` (holds 0 LUX; INDEPENDENT
  of the 0x9011 master mnemonic).
- Initiator key recovered to secret `lux-bridge/mpc-identity-keys` (key `initiator.key`,
  sha256 320ca920…) — annotated `kms-backfill-todo`.

**WE CONTROL ALL MPC NODES** → we can reconstruct the threshold key + export it + sweep any
custodied funds BEFORE re-keying (so new-shards strands nothing). See
`MPC-EXPORT-SWEEP.md` for the procedure. This is its own gated task.

**Target (user directive):** rebuild MPC on FINAL-REAL `luxfi/mpc` with NEW shards (fresh
DKG), store shard/key material IN KMS (not loose k8s secrets), owner/admin = the 1/1 Safe
(0x9011). Bridge points at the new MPC; old retired after verify.

**HARD GATE before destroying old shards:** verify ZERO real bridged custody (initiator +
any derived deposit/vault addresses across C-Chain + Zoo). If funds exist → export+sweep
(MPC-EXPORT-SWEEP.md) first; never strand.

## 3. KMS migration — restore FINAL-REAL luxfi/kms

**Current:** KMS is DOWN — `lux-kms` + `lux-kms-go` have 0 pods AND 0 workloads (gone since
~2026-04-26). 53 `KMSSecret` (secrets.lux.network/v1alpha1) instances materialized static
k8s secrets before it died; those static secrets are the CURRENT source of truth. KMSSecret
`hostAPI` = `kms.lux-kms-go.svc` (non-resolving); `kms.hanzo.ai` 401.

**Target:** restore FINAL-REAL `luxfi/kms` (latest patch), backing store, fix hostAPI DNS.
ADDITIVE — never blank the 53 working static secrets; re-seed KMS from materialized secrets
if its store is empty; diff before/after = zero value changes. Then KMS-back the exposed
secrets (§6).

## 4. Safe / governance — 2 Safes, sweep routing, final owner-upgrade

**Architecture (user-specified):** two Safes, BOTH 1/1 owned by 0x9011 initially (roll each
to final owner in 1 tx later):
1. **Lux DAO Safe** ← DAO funds.
2. **Z private Safe** (personal) ← team P/X-chain funds + 0x9011 wallet residual.

- Safe = OSS Safe v1.5.0 (SafeL2 + ProxyFactory + CompatibilityFallbackHandler +
  MultiSendCallOnly). Harness: `~/work/lux/standard/script/{deploy_gov_safe.sh,
  mainnet_gov_batch.sh}` + DAO `~/work/lux/standard/test/foundry/GovSafeModule.t.sol` (5/5).
- DEPLOYED + verified on-chain (Safe v1.5.0, 1/1 owner 0x9011, threshold 1):
  - **mainnet** (96369, @ nonce 755): DAO `0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2` ·
    Z `0x864297c069E924a12a3CFEF294aeBB8500507d31` (singleton `0x286046f0…`, factory `0x473f010d…`).
  - **testnet** (96368): DAO `0x9b17b0269fA3b40ac244ab9662e8d4aaF2962803` · Z `0x7e50a699176A1355Ef960A17B11C9A6997218F08`.
  - **devnet** (96367): DAO `0x1FB1F272F98e913c127D9ab3B3aafaFb36EAd85c` · Z `0xA70F3d0cbf45a505E63fc56423561cAd197D55C3`.
- Ownership → 0x9011 → Safe: all prod infra contracts (lux/zoo/hanzo × 3 nets) + LP +
  bridge on-chain contracts + MPC admin. (MPC admin owner set by the §2 rebuild directly.)
- **Treasury:** 0x9011 mainnet = **~1,994,739,896,346 LUX** (~1.99T). SWEEP routing:
  DAO funds → DAO Safe; team P/X + 0x9011 residual → Z Safe. GATED — audit classifies, then
  per-step user go (real money, irreversible).
- **Final owner-upgrade:** roll each Safe owner 0x9011 → its final owner (Z's FRESH personal
  key for the Z Safe — generated securely in KMS, NOT the exposed mnemonic; DAO governance
  for the DAO Safe). THIS rotates the exposed 0x9011 key out — the security close-out.
- **STAGED + FORK-PROVEN (gate satisfied; awaiting user go for mainnet):** the remaining
  program (sweep → ownership → upgrade) is staged in `~/work/lux/migration/program/` with the
  one-pass mainnet runbook at `~/work/lux/migration/SWEEP-RUNBOOK.md`. Proven e2e:
  **fork_e2e 31/31 PASS** (mainnet fork, chainId 96369: DAO=1T exact, Z=994,750,532,680.57
  residual+EOAs, 0x9011=reserve, both owners rotated, fresh owners control, exposed 0x9011
  REVERTS GS026 on both Safes) + **local1337_e2e 29/29 PASS** (full deploy→sweep→ownership→
  upgrade from scratch). Logs in `~/work/lux/migration/proof/`. Robustness baked into the
  runbook: pre-warm the idle-chain builder (`keepwarm.sh`), pin one caught-up node (NOT the
  round-robin public RPC), verify-each-tx-mines. **Do NOT run §6 on mainnet without user go.**

## 5. Native bridge migration — B-Chain + M-Chain (retire bridge-server)

**The gap you flagged:** the bridge is NOT native. The live bridge is the OFF-CHAIN
`bridge-server` (`ghcr.io/luxfi/bridge-server`, repo `~/work/lux/bridge`) + the MPC nodes —
NOT luxd-native. The native pieces exist in source but are not the live path:
- `node/vms/bridgevm` — native bridge VM, but only `state/bridgevmroot/` (~939 LOC) — PARTIAL,
  not a complete block.ChainVM.
- `node/vms/chainadapter` — carries **M-Chain** (`mChain`/`MChain`) + external-chain adapters
  (bitcoin/eth/solana/cosmos/polkadot/zk-rollup/btc-fork/dag/parachain/generic-evm).
- B-Chain exists + bootstrapped (mainnet id `2gS5fcDaq6q72V7fhtEe5BpQU9weNKWidcbE8b1WQdfSktWm2c`)
  but runs the placeholder VM, not the full native bridge.

**Intended design** (mirrors how the DEX went native via D-Chain/dexvm): the bridge runs
NATIVELY in luxd — **B-Chain** (bridgevm: settlement/custody state) + **M-Chain**
(chainadapter: the multi-chain message/relay layer for external chains), with the MPC for
threshold signing. Retire the off-chain `bridge-server`.

**Work to complete:** finish `bridgevm` into a full native VM (matcher/relay-at-Verify on
versiondb, like dexvm); instantiate M-Chain via P-Chain CreateChainTx; wire the chainadapter
external-chain adapters; point the MPC at the native B/M chains; cut over off bridge-server;
prove a native cross-chain transfer e2e. SIZE: substantial (a D-Chain-scale native-VM build).
Decide: do now vs as a scoped follow-up.

## 6. Secrets exposure — the exposed treasury key

The master mnemonic controlling 0x9011 (mainnet treasury ~1.99T) was pasted in plaintext in
a session transcript (2026-06-30). It derives 0x9011 via STANDARD eth path m/44'/60'/0'/0/0,
and the genesis deployer 0xf785FA / taker 0x202335dd via m/44'/9000' (genesis path). Stored
in k8s secret `lux-deployer` (keys LUX_MNEMONIC/LUX_PRIVATE_KEY/LUX_ADDRESS).

**Mitigation = the migration itself:** funds → Safes → final owner-upgrade rotates 0x9011
out. Until then, treat 0x9011 as compromised — prioritize the Safe sweep + final upgrade.
Do NOT reuse this mnemonic for the final Safe owners; generate FRESH keys in KMS.

## 7. Key reference

- RPCs: mainnet `https://api.lux.network/ext/bc/C/rpc` (port 9630); testnet
  `https://api.lux-test.network/...` (9630); devnet (9650).
- Addresses: treasury `0x9011E888251AB053B7bD1cdB598Db4f9DEd94714`; genesis deployer
  `0xf785FA547ae9CcF3D3ca5362762A347a4c41051A`; MPC initiator `0xC054…`; predicted Safe
  `0x676Da41B…`.
- Secret/KMS locations (names only): `lux-deployer` (treasury mnemonic);
  `lux-bridge/mpc-identity-keys` (MPC initiator); KMS target paths `lux-infra/mainnet/{deployer,bridge}`.
- RLP backups (chain history): `~/work/lux/standard/rlp/{lux-mainnet-96369,lux-testnet-96368}.rlp`
  + MANIFEST.md (admin_importChain restore).
- S3 (object store): SeaweedFS `ghcr.io/hanzoai/s3:4.34.6` serves the `s3` Service
  (s3.lux.network / s3.lux.cloud). MinIO decommissioned (scaled 0, PVC retained).
- Validator alerting: hanzo o11y (vmalert/alertmanager), rules in
  `~/work/hanzo/universe/infra/k8s/monitoring/` + `~/work/lux/monitoring/`.

## 8. Completion checklist

DONE: Lux 3 nets live v1.31.4 · QCv2 fix built+green · C-Chain DEX proven · bridge-server
2/2 (interim) · SeaweedFS cutover · validator alerting · RLP preserved.

GATED on user go (real-money/irreversible): treasury sweep + fund moves · ownership
transfers → Safe · QCv2 roll (after RED) · mainnet Hanzo/Zoo CreateChainTx · final
owner-upgrade.

IN FLIGHT: KMS restore (final-real) · MPC rebuild (new shards/KMS/Safe-owned) · Safe deploy
all nets · Hanzo/Zoo brand EVMs · RED review of QCv2.

PENDING (decide): native bridge (B-Chain + M-Chain, retire bridge-server) — §5.
