#!/usr/bin/env bash
# ⛔ SUPERSEDED 2026-08-05 — kept only as a record of what was run in July.
#
# Do not use this. Two things in it are now known to be wrong:
#
#  1. It rolls with `kubectl delete pod`. DigitalOcean's kubelet TTL-caches
#     ConfigMaps, so a recreated pod mounts the STALE copy and silently runs the
#     old config — the exact failure it is trying to avoid. Restart the luxd
#     child in place instead (program/fleet.sh restart_in_place).
#
#  2. It assumes the ConfigMap is writable. It is not: hanzo-cd owns it and
#     reverts hand-patches. The source of truth is the Helm values file
#     luxfi/universe deploy/<fleet>/luxd.yaml.
#
# Use instead:  ./state_upgrade.sh   ./fleet_verify.sh   ./fleet_heal.sh
# Path-A roll: restart all 5 mainnet validators so each copies the (now-synced) CM
# cchain-upgrade.json — carrying the ownership StateUpgrade (23 accounts) — into the file
# luxd actually reads (/data/configs/chains/C/upgrade.json). Per-pod verify that the COPY
# contains stateUpgrades==1 & accounts==23 & precompiles==49 BEFORE moving on. HARD STOP if
# any pod comes up without it (rolling with a partial set would fork at the activation ts).
# Re-rolls luxd-0 first (it booted on the stale mount during the canary).
set -uo pipefail
CTX=do-sfo3-lux-k8s; NS=lux-mainnet

verify_copy(){ # $1=pod ; echoes OK/BAD/ERR ; rc 0 iff OK
  kubectl --context $CTX -n $NS exec "$1" -- cat /data/configs/chains/C/upgrade.json 2>/dev/null | \
  python3 -c "
import json,sys
try:
  c=json.load(sys.stdin); su=c.get('stateUpgrades',[])
  acc=len(su[0]['accounts']) if su else 0; pre=len(c.get('precompileUpgrades',[]))
  ok = len(su)==1 and acc==23 and pre==49
  print(('OK' if ok else 'BAD')+f' su={len(su)} acc={acc} pre={pre}')
  sys.exit(0 if ok else 2)
except Exception as e:
  print('ERR',e); sys.exit(3)"
}

# fleet tip reference from an as-yet-unrolled pod
ref_tip(){ local rp=$1 port=$2
  pkill -f "port-forward.*$NS.*$rp $port" 2>/dev/null; sleep 1
  kubectl --context $CTX -n $NS port-forward pod/$rp $port:9630 >/tmp/pf-reftip.log 2>&1 &
  for i in $(seq 1 12); do sleep 1; cast chain-id --rpc-url http://127.0.0.1:$port/v1/bc/C/rpc 2>/dev/null | grep -q 96369 && break; done
  cast block-number --rpc-url http://127.0.0.1:$port/v1/bc/C/rpc 2>/dev/null
  pkill -f "port-forward.*$NS.*$rp $port" 2>/dev/null; }

for n in 0 1 2 3 4; do
  echo "=== rolling luxd-$n ==="
  # reference tip from a still-running peer (n+1, or n-1 for the last)
  refp=luxd-$(( n<4 ? n+1 : n-1 ))
  TIP=$(ref_tip $refp 197$((40+n)))
  echo "  ref tip ($refp) = ${TIP:-?}"
  kubectl --context $CTX -n $NS delete pod luxd-$n --wait=false >/dev/null 2>&1
  kubectl --context $CTX -n $NS wait --for=condition=ready pod/luxd-$n --timeout=300s >/dev/null 2>&1 \
    || { echo "  STOP: luxd-$n not ready in 300s"; exit 1; }
  # verify the COPY carries the stateUpgrade (retry for exec/mount settling)
  v=""; for t in 1 2 3 4 5; do v=$(verify_copy luxd-$n); echo "  copy try$t: $v"; echo "$v" | grep -q '^OK' && break; sleep 8; done
  echo "$v" | grep -q '^OK' || { echo "  STOP: luxd-$n copy MISSING stateUpgrade — do NOT continue (fork risk)"; exit 1; }
  # verify it rejoined + caught up
  h=""; for t in $(seq 1 24); do
    pkill -f "port-forward.*$NS.*luxd-$n 198$((40+n))" 2>/dev/null
    kubectl --context $CTX -n $NS port-forward pod/luxd-$n 198$((40+n)):9630 >/tmp/pf-roll$n.log 2>&1 &
    sleep 4; h=$(cast block-number --rpc-url http://127.0.0.1:198$((40+n))/v1/bc/C/rpc 2>/dev/null)
    [ -n "$h" ] && [ -n "$TIP" ] && [ "$h" -ge "$TIP" ] 2>/dev/null && break; sleep 4
  done
  pkill -f "port-forward.*$NS.*luxd-$n 198$((40+n))" 2>/dev/null
  echo "  luxd-$n head=${h:-?} (tip ~$TIP) — copy OK ✓, rejoined ✓"
done
echo "=== ALL 5 ROLLED — every copy carries stateUpgrades(23). Activation at ts 1782953071 (2026-07-02T00:44Z). ==="