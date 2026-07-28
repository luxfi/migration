# Lux DEX Ownership Consolidation → DAO Safe — RUNBOOK

PRIVATE. Operational runbook for making the DAO Safe the owner of the ENTIRE real Lux
mainnet (chainId 96369) DEX — every token, all DEX infra, and all LP positions.
No plaintext secrets — only k8s-secret names + KMS paths.

**GATE: do NOT execute any mainnet write until the user gives an explicit go.**
Path A is fork-proven (109/109). Path B is staged + validated read-only. kube context
`do-sfo3-lux-k8s` · namespace `lux-mainnet` · target DAO Safe
`0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2` (Safe v1.5.0, 1/1 owner 0x9011).

---

## 0. Pin ONE caught-up node (the public RPC round-robins — inconsistent reads)

```bash
kubectl --context do-sfo3-lux-k8s -n lux-mainnet port-forward --address 127.0.0.1 pod/luxd-4 19630:9630 &
export RPC=http://127.0.0.1:19630/v1/bc/C/rpc
cast chain-id --rpc-url $RPC   # must print 96369
```
If 127.0.0.1:9630 is already taken by a stale listener, use another local port (e.g. 19630).

## 1. Ownership map (read from the pinned node) — three owner classes

The live DEX ownable set splits across THREE non-Safe keys. WLUX and all V3/periphery
routers/quoters/NFT-manager/descriptors/ticklens/multicall are immutable (no owner) and
are intentionally NOT migrated — they keep functioning untouched.

| class | key | contracts | path |
|---|---|---|---|
| lost key | `0xce15D0AC…` | V3Factory `0x80bBc7C4` + V2Factory ×3 (`0xD173926A`,`0xeac0a501`,`0xaa6a41ca`) + 6 mock USDT/USDC | **A** (StateUpgrade) |
| unknown EOA (nonce 0) | `0xbe7A89F4…` | the 11 real bridge tokens: LETH `0x60E0a8`, LBTC `0x1E48D3`, LUSD `0x848Cff`, LZOO `0x5E5290`, LSOL `0x26B40f`, LBNB `0x6EdcF3`, LPOL `0x28BfC5`, LCELO `0x3078847F`, LFTM `0x8B982132`, LTON `0x3141b94b`, LAVAX `0x0e4bd0dd` | **A** (StateUpgrade) |
| unknown EOA (nonce 0) | `0x086F4aA1…` | 2 empty orphan dup tokens: LTON `0xf5a31388`, LSOL `0x1af00a25` | **A** (StateUpgrade) |
| exposed EOA (key held) | `0x9011E888…` | 74 V3 LP-position NFTs + 7 non-zero ERC-20 balances; **0 owned contracts** | **B** (direct tx) |

Regenerate/verify the ownership map + manifest deterministically:
```bash
cd ~/work/lux/migration/program
RPC=$RPC python3 gen_ownership_manifest.py       # writes manifests/96369-ownership.stateupgrade.json (23 contracts)
```

## 2. PATH A — StateUpgrade re-owns the 23 lost/unknown-key contracts → DAO Safe

Path A is the ONLY way to re-own contracts whose keys we do not control (0xce15 lost;
0xbe7A89 / 0x086F4aA1 unknown provenance). It rewrites the exact 20-byte owner window in
each contract's owner slot to the DAO Safe, preserving every co-packed byte (mock tokens
pack `decimals=0x12` in byte 31 of slot 5). luxd applies it via `stateupgrade.Configure →
state.SetState` at the activation block; identical constant at identical block on all 5
validators ⇒ identical root, no fork.

### 2a. Fork-proof (re-run any time — forks mainnet locally, NEVER writes mainnet)
```bash
cd ~/work/lux/migration/program && bash ownership_fork_e2e.sh   # → proof/ownership-fork-e2e-PASS.log
```
Proves (109/109): every one of the 23 → `owner()`/`feeToSetter()` == DAO Safe; each token's
`decimals`/`totalSupply`/`symbol` unchanged; control transferred (LUSD.mint / V2.setFeeTo by
Safe); non-manifest WLUX + V2Router byte-identical; treasury 0x9011 balance unchanged.

### 2b. Roll on mainnet (user go required)

The C-Chain upgrade.json is delivered via ConfigMap `luxd-startup` key `cchain-upgrade.json`
(ns lux-mainnet), mounted by `startup.sh` at `<chain-config-dir>/C/upgrade.json`. The LIVE
config has 49 `precompileUpgrades` and `stateUpgrades: []`. **Edit the LIVE config in place**
— inject one `stateUpgrades` entry with a FUTURE `blockTimestamp`; keep `precompileUpgrades`
+ `networkUpgradeOverrides` byte-identical (the `checkPrecompileCompatible` superset invariant).
Do NOT overwrite from the genesis source (it has fewer precompiles → would wedge the cluster).

```bash
# 1) pull live config, inject stateUpgrades with a future ts (now + 2h gives rolling-restart margin)
TS=$(( $(date +%s) + 7200 ))
kubectl --context do-sfo3-lux-k8s -n lux-mainnet get cm luxd-startup \
  -o jsonpath='{.data.cchain-upgrade\.json}' > /tmp/cchain-upgrade.json
python3 - "$TS" <<'PY'
import json,sys
ts=int(sys.argv[1])
cfg=json.load(open("/tmp/cchain-upgrade.json"))
frag=json.load(open("/Users/z/work/lux/migration/manifests/96369-ownership.stateupgrade.json"))[0]
frag["blockTimestamp"]=ts                                   # bare uint64, NOT a string
assert cfg.get("stateUpgrades")==[], "live stateUpgrades not empty — review before roll"
cfg["stateUpgrades"]=[frag]
json.dump(cfg,open("/tmp/cchain-upgrade.new.json","w"))
print("injected stateUpgrades ts",ts,"contracts",len(frag["accounts"]),
      "precompiles preserved",len(cfg["precompileUpgrades"]))
PY

# 2) push back into the CM (only cchain-upgrade.json changes)
kubectl --context do-sfo3-lux-k8s -n lux-mainnet create cm luxd-startup \
  --from-file=cchain-upgrade.json=/tmp/cchain-upgrade.new.json \
  --from-literal=... --dry-run=client -o yaml   # use `kubectl patch`/kustomize in practice; keep other keys intact

# 3) rolling-restart all 5 (STS updateStrategy OnDelete) BEFORE ts passes, so every node
#    loads the new upgrade.json first, then all apply the edit at the same activation block
for n in 0 1 2 3 4; do kubectl --context do-sfo3-lux-k8s -n lux-mainnet delete pod luxd-$n; \
  kubectl --context do-sfo3-lux-k8s -n lux-mainnet wait --for=condition=ready pod/luxd-$n --timeout=300s; done
```

### 2c. Verify Path A (after `blockTimestamp` passes)
```bash
cd ~/work/lux/migration/program
for a in 0x80bBc7C4C7a59C899D1B37BC14539A22D5830a84 \
         0x848Cff46eb323f323b6Bbe1Df274E40793d7f2c2 0x5E5290f350352768bD2bfC59c2DA15DD04A7cB88; do
  echo "$a owner=$(cast call $a 'owner()(address)' --rpc-url $RPC)"; done   # all == DAO Safe
cast call 0xD173926A10A0C4eCd3A51B1422270b65Df0551c1 'feeToSetter()(address)' --rpc-url $RPC  # == DAO Safe
# spot-check a token is not bricked:
cast call 0x848Cff46eb323f323b6Bbe1Df274E40793d7f2c2 'decimals()(uint8)' --rpc-url $RPC        # 18
```

## 3. PATH B — direct transfers of everything 0x9011 CAN sign for → DAO Safe

0x9011's key is held (k8s secret `lux-deployer` / KMS `lux-infra/mainnet/deployer`), so these
move by ordinary txs. Both scripts read the key in-memory (never printed), verify the signer
== 0x9011, keep the builder hot, and verify each tx. Idempotent + resumable.

### 3a. 74 LP-position NFTs (canonical ids in `program/path_b_lp_tokenids.txt`)
```bash
cd ~/work/lux/migration/program
RPC=$RPC bash lp_transfer.sh                    # PLAN only (enumerates + verifies)
RPC=$RPC EXECUTE=yes bash lp_transfer.sh        # SEND on user go — transferFrom each id → DAO
```

### 3b. 7 non-zero ERC-20 balances (the fungible half — NOT covered by lp_transfer.sh)
LUSD, LBTC, LSOL, LPOL, **LZOO (7.638e27 ≈ 7.6B)**, LBNB, LAVAX.
```bash
RPC=$RPC bash path_b_erc20.sh                   # PLAN only (live balances)
RPC=$RPC EXECUTE=yes bash path_b_erc20.sh       # SEND on user go — transfer full balance → DAO
```
0x9011 owns **0** DEX contracts, so there is no `transferOwnership` leg in Path B.

### 3c. Verify Path B
```bash
cast call 0x7a4C48B9dae0b7c396569b34042fcA604150Ee28 'balanceOf(address)(uint256)' \
  0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2 --rpc-url $RPC     # 74  (all LP NFTs at DAO)
cast call 0x5E5290f350352768bD2bfC59c2DA15DD04A7cB88 'balanceOf(address)(uint256)' \
  0x9011E888251AB053B7bD1cdB598Db4f9DEd94714 --rpc-url $RPC     # 0   (LZOO swept)
```

## 4. Ordered execution plan (on user go)

1. Pin node (§0). Confirm chainId 96369, head caught up vs the other 4.
2. **Path B first** (cheap, reversible-ish by re-transfer, no consensus action):
   `lp_transfer.sh EXECUTE=yes` (74 NFTs) → verify NFPM.balanceOf(DAO)==74; then
   `path_b_erc20.sh EXECUTE=yes` (7 tokens) → verify 0x9011 token balances == 0.
3. **Path A roll** (§2b) — inject stateUpgrades (future ts) into live `luxd-startup`
   cchain-upgrade.json, rolling-restart all 5, wait for ts, verify (§2c) all 23 owners == DAO.
   mainnet C-Chain is healthy + immune to the fresh-net consensus bug, so the roll is safe.
4. Final map: re-run `gen_ownership_manifest.py` — it now REFUSES every target (getter !=
   recorded owner) because all owners are the Safe. That refusal is the completion proof.

## 5. Safety

- Path A never touches balances, code, or packed metadata — only the 20-byte owner window
  (fork-proven). It works regardless of whether 0xbe7A89 / 0x086F4aA1 keys are held; if the
  user later confirms holding one, those tokens could instead move via Path B (cheaper) —
  but Path A is the deterministic default that needs no key.
- Path B signs with the exposed 0x9011 key in-memory only; blanked after use; never printed.
- Every gate is `EXECUTE=yes`. Without it the scripts print the plan only. `EXPECT`/chainId
  guards refuse a wrong net. Balances/ownerOf are the source of truth; resume any phase.
