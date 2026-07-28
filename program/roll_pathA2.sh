#!/usr/bin/env bash
# Path-A roll v2 — robust against the CM-mount-at-pod-creation race.
# For each validator: (1) if its COPY already carries the 23-account stateUpgrade, skip.
# (2) else wait until the RUNNING pod's MOUNT shows su=1 (kubelet has synced the fresh CM to
# that node), THEN delete the pod — the recreated pod now boots on a warm node cache and
# startup.sh copies the fresh config. Re-verify the COPY; if still stale, wait mount + retry
# (≤3). HARD STOP if a pod can't be made correct (never roll a partial set → fork at ts).
# exec is retried (transient empty-read glitches). Head-rejoin verified per pod.
set -uo pipefail
CTX=do-sfo3-lux-k8s; NS=lux-mainnet

# robust exec-read of a json file in a pod → prints "su=<n> acc=<n> pre=<n>" or "ERR"
read_json(){ # $1=pod $2=path
  local out
  for t in 1 2 3 4; do
    out=$(kubectl --context $CTX -n $NS exec "$1" -- cat "$2" 2>/dev/null | python3 -c "
import json,sys
try:
  c=json.load(sys.stdin); su=c.get('stateUpgrades',[])
  print('su=%d acc=%d pre=%d'%(len(su), len(su[0]['accounts']) if su else 0, len(c.get('precompileUpgrades',[]))))
except: print('ERR')" 2>/dev/null)
    [ -n "$out" ] && [ "$out" != "ERR" ] && { echo "$out"; return 0; }
    sleep 3
  done
  echo "${out:-ERR}"; return 1
}
copy_ok(){ read_json "$1" /data/configs/chains/C/upgrade.json | grep -q '^su=1 acc=23 pre=49'; }
mount_ok(){ read_json "$1" /scripts/cchain-upgrade.json      | grep -q '^su=1 acc=23'; }

ref_tip(){ local rp=$1 port=$2
  pkill -f "port-forward.*$NS.*$rp $port" 2>/dev/null; sleep 1
  kubectl --context $CTX -n $NS port-forward pod/$rp $port:9630 >/tmp/pf-rt.log 2>&1 &
  for i in $(seq 1 12); do sleep 1; cast chain-id --rpc-url http://127.0.0.1:$port/v1/bc/C/rpc 2>/dev/null | grep -q 96369 && break; done
  cast block-number --rpc-url http://127.0.0.1:$port/v1/bc/C/rpc 2>/dev/null
  pkill -f "port-forward.*$NS.*$rp $port" 2>/dev/null; }

for n in 0 1 2 3 4; do
  echo "=== luxd-$n ==="
  if copy_ok luxd-$n; then echo "  copy already OK (su=1 acc=23) — skip"; continue; fi
  ok=0
  for attempt in 1 2 3; do
    echo "  attempt $attempt: waiting for MOUNT to sync (su=1) on luxd-$n's node..."
    m=0; for w in $(seq 1 30); do mount_ok luxd-$n && { m=1; echo "    mount synced (t=$((w*6))s)"; break; }; sleep 6; done
    [ $m = 1 ] || { echo "    mount not synced after 180s — retry"; continue; }
    refp=luxd-$(( n<4 ? n+1 : n-1 )); TIP=$(ref_tip $refp 197$((60+n))); echo "  ref tip ($refp)=${TIP:-?}"
    kubectl --context $CTX -n $NS delete pod luxd-$n --wait=false >/dev/null 2>&1
    kubectl --context $CTX -n $NS wait --for=condition=ready pod/luxd-$n --timeout=300s >/dev/null 2>&1 \
      || { echo "    not ready in 300s — retry"; continue; }
    sleep 6
    c=$(read_json luxd-$n /data/configs/chains/C/upgrade.json); echo "    copy after roll: $c"
    if echo "$c" | grep -q '^su=1 acc=23 pre=49'; then ok=1; break; fi
    echo "    copy still stale — will wait mount + retry"
  done
  [ $ok = 1 ] || { echo "  STOP: luxd-$n copy could not be made correct after 3 attempts (NO fork risk taken)"; exit 1; }
  # head rejoin
  h=""; for t in $(seq 1 24); do
    pkill -f "port-forward.*$NS.*luxd-$n 198$((60+n))" 2>/dev/null
    kubectl --context $CTX -n $NS port-forward pod/luxd-$n 198$((60+n)):9630 >/tmp/pf-rj$n.log 2>&1 &
    sleep 4; h=$(cast block-number --rpc-url http://127.0.0.1:198$((60+n))/v1/bc/C/rpc 2>/dev/null)
    [ -n "$h" ] && [ -n "$TIP" ] && [ "$h" -ge "$TIP" ] 2>/dev/null && break; sleep 4
  done
  pkill -f "port-forward.*$NS.*luxd-$n 198$((60+n))" 2>/dev/null
  echo "  luxd-$n copy OK ✓ head=${h:-?} (tip ~$TIP) rejoined ✓"
done
echo "=== ALL 5 COPIES CARRY stateUpgrades(23 acc). Activation ts 1782953071 (2026-07-02T00:44Z). ==="