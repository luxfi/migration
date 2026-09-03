#!/usr/bin/env bash
# LOCAL END-TO-END ON luxd — the program against a real node, not a simulator.
#
# The anvil harnesses seed balances with anvil_setBalance and simulate the
# StateUpgrade with anvil_setStorageAt. Neither cheat exists on luxd, so what
# they prove is the money path, not the node's behaviour. This runs the same
# path on the binary that actually ships: canonical mainnet genesis, chainId
# 96369, 0x9011 funded with its real 2,000,000,000,000 LUX allocation because
# that is what the genesis says — no seeding step, and nothing to get wrong.
#
# Usage:  LUX_PRIVATE_KEY=0x… local_luxd_e2e.sh
# Env:    PORT (default 9760), KEEP=1 to leave the node running for inspection.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

PORT="${PORT:-9760}"; STAKE_PORT=$((PORT + 1))
BASE="${BASE:-$HOME/.lux/local-luxd-e2e}"
RPC="http://127.0.0.1:$PORT/v1/chain/C/rpc"
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
GENESIS="${GENESIS:-$HOME/work/lux/genesis/live/mainnet/genesis.json}"
LUXD="${LUXD:-$HOME/work/lux/node/build/luxd}"
EVM_PLUGIN="${EVM_PLUGIN:-$HOME/work/lux/evm/build/evm}"
# The EVM's own VM id. Without the binary under this exact name luxd logs
# "chain VM plugin not loaded — opting out of this chain" at info and serves
# P and X while reporting healthy — a node with no C-Chain that looks fine.
EVM_VMID=mgj786NP7uDwBCcq6YwThhaN8FLyybkCa4zBWTQbNgmK6k9A6

cleanup() { [ "${KEEP:-0}" = "1" ] && return 0; kill "${LUXD_PID:-0}" 2>/dev/null; rm -rf "$BASE"; }
trap cleanup EXIT

[ -n "${LUX_PRIVATE_KEY:-}" ] || { echo "set LUX_PRIVATE_KEY (the 0x9011 signer)"; exit 2; }
for f in "$LUXD" "$EVM_PLUGIN" "$GENESIS"; do
  [ -e "$f" ] || { echo "missing: $f"; exit 2; }
done

hdr "1. stage a local 96369 from the canonical mainnet genesis"
rm -rf "$BASE"; mkdir -p "$BASE/data/staking" "$BASE/plugins" "$BASE/data/configs/chains/C"
python3 - "$GENESIS" "$BASE/genesis.json" <<'PY'
import json,sys
g=json.load(open(sys.argv[1]))
# Isolate from the real network so this can never dial mainnet bootstrappers.
g['networkID']=96369
json.dump(g,open(sys.argv[2],'w'))
c=json.loads(g['cChainGenesis'])
alloc={k.lower():int(v['balance'],16) for k,v in c['alloc'].items() if isinstance(v.get('balance'),str)}
print(f"   cChain chainId {c['config']['chainId']}, treasury {max(alloc.values())/1e18:,.0f} LUX")
PY
# strict-PQ needs an ML-DSA staking keypair and will refuse to boot without one;
# luxd generates the TLS and signer material itself.
cp "$HOME"/.lux/devnet/staking/mldsa.* "$HOME"/.lux/devnet/staking/mlkem.* "$BASE/data/staking/" 2>/dev/null
cp "$EVM_PLUGIN" "$BASE/plugins/$EVM_VMID"; chmod +x "$BASE/plugins/$EVM_VMID"
# pruning is ON by default with state-history 32. That is right for a validator —
# quantum finality means nothing below final re-orgs — and wrong for anything
# expected to answer about the past, which is what this harness does.
cat > "$BASE/data/configs/chains/C/config.json" <<JSON
{"admin-api-enabled":true,"admin-api-dir":"$BASE/adminapi","pruning-enabled":false,
 "allow-missing-tries":true,
 "eth-apis":["eth","eth-filter","net","web3","internal-eth","internal-blockchain","internal-transaction","admin","debug"]}
JSON
mkdir -p "$BASE/adminapi"

hdr "2. start luxd and wait for the C-Chain"
"$LUXD" --genesis-file="$BASE/genesis.json" --network-id=96369 --data-dir="$BASE/data" \
  --plugin-dir="$BASE/plugins" --chain-config-dir="$BASE/data/configs/chains" \
  --http-port="$PORT" --staking-port="$STAKE_PORT" --http-host=127.0.0.1 \
  --sybil-protection-enabled=false --skip-bootstrap=true --api-admin-enabled=true \
  --log-level=info > "$BASE/node.log" 2>&1 &
LUXD_PID=$!
for _ in $(seq 1 60); do
  cid=$(cast chain-id --rpc-url "$RPC" 2>/dev/null) && [ -n "$cid" ] && break
  sleep 2
done
[ "${cid:-}" = "96369" ] && ok "C-Chain answering, chainId 96369" || bad "C-Chain never came up (see $BASE/node.log)"

hdr "3. the genesis allocation is present"
BAL=$(cast balance "$OWNER" --rpc-url "$RPC")
[ "$BAL" = "2000000000000000000000000000000" ] \
  && ok "0x9011 holds 2,000,000,000,000 LUX at genesis" \
  || bad "0x9011 holds $BAL, expected the 2e12 genesis allocation"

hdr "4. deploy the two Safes"
STD_DIR="${STD_DIR:-$HOME/work/lux/standard}" REC="${REC:-$BASE/deployments}" \
  bash "$HERE/deploy_safes.sh" "$RPC" local-luxd || bad "deploy_safes failed"
DAO=$(python3 -c "import json;print(json.load(open('$BASE/deployments/lux-dao/96369.json'))['safe'])")
Z=$(python3 -c "import json;print(json.load(open('$BASE/deployments/lux-zpriv/96369.json'))['safe'])")
ok "lux-dao $DAO"
ok "lux-zpriv $Z"

hdr "5. the Safes are 1/1 under the owner"
for s in "$DAO" "$Z"; do
  [ "$(cast call "$s" 'getThreshold()(uint256)' --rpc-url "$RPC")" = "1" ] || bad "$s threshold"
  [ "$(cast call "$s" 'isOwner(address)(bool)' "$OWNER" --rpc-url "$RPC")" = "true" ] || bad "$s owner"
done
ok "both threshold 1, owner 0x9011"

hdr "6. value moves to the DAO Safe and stays there"
# 120k gas, not the 21000 transfer floor: a Safe proxy delegatecalls its fallback
# and emits SafeReceived, so a bare transfer reverts out of gas and the balance
# silently does not move.
cast send "$DAO" --value 1000ether --gas-limit 120000 \
  --rpc-url "$RPC" --private-key "$LUX_PRIVATE_KEY" >/dev/null 2>&1
[ "$(cast balance "$DAO" --rpc-url "$RPC")" = "1000000000000000000000" ] \
  && ok "1000 LUX received and held" || bad "DAO Safe balance wrong after transfer"

hdr "7. state survives new blocks"
H0=$(cast block-number --rpc-url "$RPC")
cast send "$OWNER" --value 1ether --gas-limit 21000 --rpc-url "$RPC" --private-key "$LUX_PRIVATE_KEY" >/dev/null 2>&1
H1=$(cast block-number --rpc-url "$RPC")
[ "$H1" -gt "$H0" ] && ok "chain advanced $H0 -> $H1" || bad "no new block"
[ "$(cast balance "$DAO" --rpc-url "$RPC")" = "1000000000000000000000" ] \
  && ok "DAO Safe balance intact across new blocks" || bad "balance changed under a later block"

summary "LOCAL luxd E2E"
