# Lux Treasury Sweep + Governance Close-Out — RUNBOOK

PRIVATE. Operational runbook for the remaining treasury program on Lux mainnet
(chainId 96369). No plaintext secrets — only k8s-secret names + KMS paths.

**GATE: do NOT execute against live mainnet until the user gives an explicit go.**
The full remaining program is PROVEN end-to-end on a mainnet fork and on local 1337
(see §5). The mainnet run is then ONE clean pass using §6.

kube context: `do-sfo3-lux-k8s` · namespace: `lux-mainnet`.

---

## 1. What remains

The treasury is 100% intact: `0x9011` holds the full **1,994,739,840,345.63 LUX**;
both mainnet Safes are deployed (1/1 owner `0x9011`, v1.5.0) and hold 0. Only three
phases remain, all money/ownership, all gated:

| phase | what | gating |
|---|---|---|
| ~~deploy~~ | 2 Safes | **DONE on mainnet** (proven re-runnable on local 1337) |
| **sweep** | `0x9011` split + EOA sweeps → Safes | `EXECUTE=yes` + `DAO_ALLOC` |
| **ownership** | on-chain Ownable/admin → DAO Safe | **BLOCKED** (0xce15 key unlocated; emits calldata, no-op) |
| **upgrade** | rotate Safe owner `0x9011` → fresh owner | `EXECUTE=yes` + final owners — the security close-out |

## 2. The split (tokenomics-derived)

- `DAO_ALLOC = 1,000,000,000,000 LUX` (1T) → **DAO Safe** `0x51284dC2…`
- residual ≈ **994,739,839,345.63 LUX** → **Z Safe** `0x864297c0…`
- EOA balances (≈10,693,338.95 LUX total) → **Z Safe** (class `z`)
- `RESERVE = 1000 LUX` kept in `0x9011` for gas (becomes dust after the close-out)

Fork-proven result: DAO Safe = exactly 1T; Z Safe = **994,750,532,680.57 LUX**
(residual + EOAs); `0x9011` ≈ 999.998 LUX; total gas burned ≈ 0.017 LUX.

## 3. Addresses

| role | address |
|---|---|
| treasury / exposed key (`0x9011`) | `0x9011E888251AB053B7bD1cdB598Db4f9DEd94714` |
| DAO Safe (1/1 owner 0x9011, v1.5.0) | `0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2` |
| Z Safe (1/1 owner 0x9011, v1.5.0) | `0x864297c069E924a12a3CFEF294aeBB8500507d31` |

Funded EOA set (all class `z` → Z Safe; key derived from the mnemonic at execution):

| idx-path | address | ~LUX |
|---|---|---|
| std:1 | `0xEAbCC110fAcBfebabC66Ad6f9E7B67288e720B59` | 434.89 |
| std:2 | `0x8d5081153aE1cfb41f5c932fe0b6Beb7E159cF84` | 0.98 |
| std:6 | `0xf7f52257a6143cE6BbD12A98eF2B0a3d0C648079` | 3,235,154.32 |
| std:7 | `0xCA92ad0C91bd8DE640B9dAFfEB338ac908725142` | 2,053,894.27 |
| std:8 | `0xB5B325df519eB58B7223d85aaeac8b56aB05f3d6` | 5,397,854.67 |
| gen:0 | `0xf785FA547ae9CcF3D3ca5362762A347a4c41051A` | 1,999.84 |
| gen:1 | `0xf4b5be7a6deA583dA4CddCDa4D9B3afd51684b6e` | 1,999.99 |
| gen:2 | `0x202335dd1c21C9B90277F8BcA78Db98db0bBc293` | 1,999.99 |

`std:N` derives `m/44'/60'/0'/0/N`; `gen:N` derives `m/44'/9000'/0'/0/N`.

## 4. Program files (canonical operational home — this private repo)

`~/work/lux/migration/program/`:
- `prepare_program.sh <rpc>` — the phased program (plan/deploy/sweep/ownership/upgrade).
- `deploy_safes.sh <rpc> <label>` — deploys the 2 Safes (used only for local 1337 / re-deploy).
- `keepwarm.sh <rpc> [run|prefund]` — keep the coreth builder hot during the sweep.
- `fork_e2e.sh` / `local1337_e2e.sh` — the e2e proofs. `lib.sh` — shared assert/Safe helpers.

Safe bytecode is read from `STD_DIR/out` (default `~/work/lux/standard/out`, a foundry
build product — not duplicated here). `standard/` is a PUBLIC repo, so this private
`migration/` repo is the only place the live sweep is run from.

## 5. Proof status — PASS (gate satisfied; awaiting user go for mainnet)

Re-run any time (read-only against mainnet — forks/seeds a LOCAL anvil, never writes mainnet):

```bash
cd ~/work/lux/migration/program
bash fork_e2e.sh        # → proof/fork-e2e-PASS.log
bash local1337_e2e.sh   # → proof/local1337-e2e-PASS.log
```

- **fork_e2e** (chainId 96369, full remaining program): **31/31 PASS** — sweep money path
  exact (DAO=1T, Z=residual+EOAs, 0x9011=reserve, conservation), both owners rotated to
  fresh keys, fresh owners control both Safes, **exposed 0x9011 REVERTS GS026 on both**.
- **local1337_e2e** (deploy + sweep + ownership + upgrade from scratch): **29/29 PASS** —
  same, plus a clean Safe deploy (v1.5.0, 1/1 owner 0x9011).

Logs: `~/work/lux/migration/proof/{fork-e2e-PASS.log,local1337-e2e-PASS.log}`.

## 6. THE ONE-PASS MAINNET PROCEDURE (run only on user go)

Root cause of the prior aborts: idle-chain cold builder + flaky `kubectl port-forward` +
inconsistent mempool nonce across nodes (api.lux.network round-robins stale nodes). The
fixes below make it one clean pass.

### 6.0 Pre-flight — pick ONE caught-up node, pin everything to it

The public `api.lux.network` round-robins across nodes (a lagging node → stale nonce). Use
a SINGLE caught-up node for BOTH nonce reads and broadcast. Pick the max-head node:

```bash
for n in 0 1 2 3 4; do ip=$(kubectl --context do-sfo3-lux-k8s -n lux-mainnet \
  get svc luxd-$n -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
  echo "luxd-$n $ip head=$(cast block-number --rpc-url http://$ip:9630/ext/bc/C/rpc)"; done
```

Port-forward the chosen node (most direct; the script's live-execute warning still fires —
fork detection probes `anvil_nodeInfo`, so a real luxd over 127.0.0.1 is correctly LIVE):

```bash
kubectl --context do-sfo3-lux-k8s -n lux-mainnet port-forward pod/luxd-4 9630:9630 &
export RPC=http://127.0.0.1:9630/ext/bc/C/rpc
cast chain-id --rpc-url $RPC   # must print 96369
```
If the port-forward drops mid-run, restart it and re-run the current phase — every phase is
idempotent-safe to resume (cast re-reads nonce; already-mined sends are skipped by balance).

### 6.1 Pre-warm the builder (SECOND terminal, same RPC) — leave running through 6.2

```bash
cd ~/work/lux/migration/program
bash keepwarm.sh $RPC prefund          # one tx: 1 LUX from 0x9011 → reserved key idx 777
bash keepwarm.sh $RPC run 2            # self-send every 2s; keeps the builder hot
```
The keep-warm key (mnemonic idx 777) is NOT `0x9011` and NOT a swept EOA, so it never
perturbs the sweep's nonce sequence. Leave it running until the sweep completes, then Ctrl-C.

### 6.2 Sweep — DAO_ALLOC=1T → DAO Safe, residual+EOAs → Z Safe

`cast send` blocks until the receipt is mined, so each tx is verified before the next. With
keep-warm running, no tx stalls.

```bash
cd ~/work/lux/migration/program
PHASE=sweep EXECUTE=yes DAO_ALLOC=1000000000000 RESERVE=1000 bash prepare_program.sh $RPC
```
Verify:
```bash
cast call 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2 'getBalance' >/dev/null 2>&1 # n/a
echo "DAO=$(cast to-unit $(cast balance 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2 --rpc-url $RPC) ether)"  # ~1e12
echo "Z=$(cast to-unit $(cast balance 0x864297c069E924a12a3CFEF294aeBB8500507d31 --rpc-url $RPC) ether)"    # ~9.9475e11
echo "0x9011=$(cast to-unit $(cast balance 0x9011E888251AB053B7bD1cdB598Db4f9DEd94714 --rpc-url $RPC) ether)" # ~1000
```
Stop keep-warm (Ctrl-C in terminal 2) after the sweep verifies.

### 6.3 Ownership (no-op today — emits calldata)

```bash
PHASE=ownership bash prepare_program.sh $RPC
```
The LIVE AMM handles are owned by `0xce15…` (key unlocated) → BLOCKED. The phase prints the
`setOwner`/`setFeeToSetter`/`transferOwnership` calldata to apply once that key is located or
the contracts are redeployed under `0x9011`. No state change.

### 6.4 Upgrade — the security close-out (LAST; after this `0x9011` is locked out)

Generate the Z final owner key **in KMS** (never paste a key). DAO final owner = the DAO
governance module address.

```bash
# Z_FINAL_OWNER: fresh key generated in KMS at execution (address only used here)
export Z_FINAL_OWNER=0x<fresh-kms-pubaddr>
export DAO_FINAL_OWNER=0x<dao-governance-address>
PHASE=upgrade EXECUTE=yes bash prepare_program.sh $RPC
```
Verify the close-out:
```bash
cast call 0x864297c069E924a12a3CFEF294aeBB8500507d31 'getOwners()(address[])' --rpc-url $RPC  # [Z_FINAL_OWNER]
cast call 0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2 'getOwners()(address[])' --rpc-url $RPC  # [DAO_FINAL_OWNER]
cast call 0x864297c069E924a12a3CFEF294aeBB8500507d31 'isOwner(address)(bool)' \
  0x9011E888251AB053B7bD1cdB598Db4f9DEd94714 --rpc-url $RPC   # false on both
```
After this, the exposed `0x9011` controls nothing in custody — only ~1000 LUX gas dust in
its own EOA. Sweep that dust to the Z final owner if desired and retire `0x9011`.

## 7. Security

- The Z final owner key is generated **in KMS at execution**, never pasted, never the exposed
  mnemonic. The whole point of `upgrade` is to rotate the compromised `0x9011` out.
- Signing keys are read from k8s secret `lux-deployer` (`LUX_PRIVATE_KEY` / `LUX_MNEMONIC`),
  used in-memory, blanked after use, never printed. KMS target path: `lux-infra/mainnet/deployer`.
- Until `upgrade` lands, treat `0x9011` as compromised — `sweep` then `upgrade` are the priority.

## 8. Abort / safety

- Every gate is `EXECUTE=yes`. Without it the program prints the plan only.
- `EXPECT_CID` guards the chain (96369 mainnet default; the script REFUSES a wrong chainId).
- The e2e harnesses refuse any RPC that is not a local anvil (`anvil_nodeInfo` probe).
- If anything looks wrong mid-pass, stop: balances are the source of truth; re-run the
  verify block, then resume the current phase against the same single node.
