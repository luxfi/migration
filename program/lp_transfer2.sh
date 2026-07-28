#!/usr/bin/env bash
# Path-B v2 — robust to kubectl port-forward drops (which die after ~50 sequential calls).
# Self-manages its OWN auto-restarting port-forward; iterates the KNOWN fixed 74-tokenId list
# (no fragile long enumeration); idempotent — skips tokenIds already at the DAO Safe, so it can
# be re-run any number of times until 0x9011 holds 0. Signs with lux-deployer/LUX_PRIVATE_KEY
# (0x9011, never printed). Builder kept hot via keepwarm.sh idx-777 (no 0x9011 nonce contention).
set -uo pipefail
CTX=do-sfo3-lux-k8s
NINE=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
PM=0x7a4C48B9dae0b7c396569b34042fcA604150Ee28
DAO=0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2
PORT="${PORT:-19710}"
RPC=http://127.0.0.1:$PORT/v1/bc/C/rpc
# The full, known set of 0x9011's V3 LP position tokenIds (captured from the first clean plan).
IDS="7 8 9 10 11 18 19 20 21 23 24 25 26 27 28 29 30 32 36 37 41 42 43 44 45 46 47 48 49 50 61 62 63 64 65 66 67 68 72 73 74 75 76 78 80 81 82 84 85 86 93 94 95 96 97 98 99 100 101 102 130 131 133 134 135 136 137 138 139 140 141 142 143 150"
lc(){ echo "$1" | tr 'A-Z' 'a-z'; }

pf_start(){ pkill -f "port-forward.*lux-mainnet.*luxd-4 $PORT" 2>/dev/null; sleep 1
  kubectl --context $CTX -n lux-mainnet port-forward pod/luxd-4 $PORT:9630 >/tmp/pf-lp2.log 2>&1 &
  for i in $(seq 1 20); do sleep 1; cast chain-id --rpc-url $RPC 2>/dev/null | grep -q 96369 && return 0; done; return 1; }
pf_ensure(){ cast chain-id --rpc-url $RPC 2>/dev/null | grep -q 96369 || pf_start; }

pf_start || { echo "REFUSE: cannot start port-forward"; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = "96369" ] || { echo "REFUSE: wrong chain"; exit 1; }

MK=$(kubectl --context $CTX get secret lux-deployer -n lux-mainnet -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
[ "$(lc "$(cast wallet address --private-key "$MK")")" = "$(lc "$NINE")" ] || { echo "REFUSE: signer != 0x9011"; MK=; exit 1; }
echo "[lp2] signer=0x9011 verified  head=$(cast block-number --rpc-url $RPC)"

# keep the builder hot (idx-777; one prefund tx from 0x9011 BEFORE the loop to avoid nonce race)
bash "$(dirname "$0")/keepwarm.sh" $RPC prefund 2>&1 | grep -viE "fs_permissions|nightly|Warning" | tail -1
bash "$(dirname "$0")/keepwarm.sh" $RPC run 3 >/tmp/lp2-keepwarm.log 2>&1 &
KW=$!; sleep 5

seen=0; moved=0; skip=0; fail=0
for tid in $IDS; do
  seen=$((seen+1)); pf_ensure
  ow=$(cast call $PM 'ownerOf(uint256)(address)' $tid --rpc-url $RPC 2>/dev/null | head -c 42)
  if [ "$(lc "$ow")" = "$(lc "$DAO")" ]; then skip=$((skip+1)); continue; fi
  if [ "$(lc "$ow")" != "$(lc "$NINE")" ]; then echo "[lp2] tid $tid owner=$ow (neither 0x9011 nor DAO) — skip"; continue; fi
  ok=0
  for try in 1 2 3; do
    pf_ensure
    cast send $PM 'transferFrom(address,address,uint256)' $NINE $DAO $tid --private-key "$MK" --rpc-url $RPC --gas-limit 250000 >/tmp/lp2-tx-$tid.log 2>&1 && { ok=1; break; } || sleep 2
  done
  if [ $ok = 1 ]; then
    pf_ensure; now=$(cast call $PM 'ownerOf(uint256)(address)' $tid --rpc-url $RPC 2>/dev/null | head -c 42)
    if [ "$(lc "$now")" = "$(lc "$DAO")" ]; then moved=$((moved+1)); printf '[lp2] tid %-6s -> DAO ✓  (moved=%d skip=%d seen=%d/74)\n' "$tid" "$moved" "$skip" "$seen"
    else fail=$((fail+1)); echo "[lp2] tid $tid SENT but owner=$now ✗"; fi
  else fail=$((fail+1)); echo "[lp2] tid $tid SEND FAILED (see /tmp/lp2-tx-$tid.log)"; fi
done
kill $KW 2>/dev/null
pf_ensure
rem=$(cast call $PM 'balanceOf(address)(uint256)' $NINE --rpc-url $RPC 2>/dev/null | sed 's/ .*//')
dao=$(cast call $PM 'balanceOf(address)(uint256)' $DAO --rpc-url $RPC 2>/dev/null | sed 's/ .*//')
echo "[lp2] === DONE moved=$moved skip=$skip fail=$fail ; 0x9011 now holds $rem ; DAO Safe holds $dao ==="
pkill -f "port-forward.*lux-mainnet.*luxd-4 $PORT" 2>/dev/null
MK=
[ "$rem" = "0" ]
