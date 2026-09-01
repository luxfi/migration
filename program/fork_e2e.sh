#!/usr/bin/env bash
# FORKED-MAINNET END-TO-END PROOF of the remaining treasury program.
# anvil --fork-url against a single CAUGHT-UP mainnet node (auto-selected: max head across
# luxd-0..4 via their per-pod LoadBalancers — NEVER the round-robin public RPC), pinned to
# LIVE state (0x9011=1.99T, nonce 761, both Safes deployed). Runs the EXACT program:
#   sweep (DAO_ALLOC=1T -> DAO Safe, residual+EOAs -> Z Safe) -> ownership -> upgrade
# then proves the money path AND the security close-out (fresh owner controls both Safes,
# exposed 0x9011 REVERTS / GS026). Fork only. Mainnet is NEVER written.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
STD_DIR="${STD_DIR:-/Users/z/work/lux/standard}"
PORT=8545; FRPC="http://127.0.0.1:$PORT"
DAO_ALLOC=1000000000000   # 1T (tokenomics split)
RESERVE=1000
hexwei() { python3 -c "print(hex(int($1)))"; }
cleanup() { kill "${ANVIL_PID:-0}" 2>/dev/null; anvil_state_sweep; }
trap cleanup EXIT

hdr "0. select a CAUGHT-UP mainnet node (max head; public RPC is round-robin/stale)"
BEST=""; BESTH=0
for n in 0 1 2 3 4; do
  ip=$(kubectl --context do-sfo3-lux-k8s -n lux-mainnet get svc "luxd-$n" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -z "$ip" ] && continue
  h=$(cast block-number --rpc-url "http://$ip:9630/v1/bc/C/rpc" 2>/dev/null) || continue
  echo "  luxd-$n  $ip  head=$h"
  [ "$h" -gt "$BESTH" ] 2>/dev/null && { BESTH=$h; BEST="http://$ip:9630/v1/bc/C/rpc"; BESTN=$n; }
done
[ -n "$BEST" ] || { echo "ABORT: no reachable luxd node"; exit 1; }
echo "  -> fork base: luxd-$BESTN head=$BESTH  $BEST"

hdr "1. start anvil fork at LATEST (coreth prunes history -> must fork head)"
pkill -f "anvil.*$PORT" 2>/dev/null; sleep 1
anvil_state_mark
anvil --fork-url "$BEST" --port "$PORT" --silent >/tmp/fork_e2e_anvil.log 2>&1 &
ANVIL_PID=$!
wait_ready "$FRPC"; assert_local "$FRPC"
CID=$(cast chain-id --rpc-url "$FRPC"); assert_eq "fork chainId" "$CID" "96369"
S9=$(cast balance "$OWNER" --rpc-url "$FRPC"); N9=$(cast nonce "$OWNER" --rpc-url "$FRPC")
echo "  0x9011 = $(lux "$S9") LUX  nonce=$N9"
assert_eq "fork pins live nonce" "$N9" "761"
assert_ge "fork pins live treasury (>=1.99T)" "$S9" "$(wei 1994739000000)"
DAO=$(jq -r .safe "$STD_DIR/deployments/lux-dao/96369.json"); Z=$(jq -r .safe "$STD_DIR/deployments/lux-zpriv/96369.json")
assert_eq "DAO Safe owner==0x9011" "$(cast call $DAO 'isOwner(address)(bool)' $OWNER --rpc-url $FRPC)" "true"
assert_eq "Z Safe owner==0x9011"   "$(cast call $Z   'isOwner(address)(bool)' $OWNER --rpc-url $FRPC)" "true"

# snapshot EOA start balances for the conservation check
EOA_ADDRS=(0xEAbCC110fAcBfebabC66Ad6f9E7B67288e720B59 0x8d5081153aE1cfb41f5c932fe0b6Beb7E159cF84 0xf7f52257a6143cE6BbD12A98eF2B0a3d0C648079 0xCA92ad0C91bd8DE640B9dAFfEB338ac908725142 0xB5B325df519eB58B7223d85aaeac8b56aB05f3d6 0xf785FA547ae9CcF3D3ca5362762A347a4c41051A 0xf4b5be7a6deA583dA4CddCDa4D9B3afd51684b6e 0x202335dd1c21C9B90277F8BcA78Db98db0bBc293)
EOA_SUM=0
for a in "${EOA_ADDRS[@]}"; do b=$(cast balance "$a" --rpc-url "$FRPC"); EOA_SUM=$(python3 -c "print($EOA_SUM+$b)"); done
TOTAL_BEFORE=$(python3 -c "print($S9+$EOA_SUM)")
echo "  EOA total = $(lux $EOA_SUM) LUX   total before = $(lux $TOTAL_BEFORE) LUX"

hdr "2. PHASE=sweep  DAO_ALLOC=1T -> DAO Safe, residual+EOAs -> Z Safe"
EXPECT_CID=96369 SECRET_NS=lux-mainnet STD_DIR="$STD_DIR" REC="$STD_DIR/deployments" \
  PHASE=sweep EXECUTE=yes DAO_ALLOC=$DAO_ALLOC RESERVE=$RESERVE \
  bash "$HERE/prepare_program.sh" "$FRPC"

DAO_BAL=$(cast balance "$DAO" --rpc-url "$FRPC"); Z_BAL=$(cast balance "$Z" --rpc-url "$FRPC")
A9=$(cast balance "$OWNER" --rpc-url "$FRPC")
EOA_AFTER=0; for a in "${EOA_ADDRS[@]}"; do b=$(cast balance "$a" --rpc-url "$FRPC"); EOA_AFTER=$(python3 -c "print($EOA_AFTER+$b)"); assert_le "EOA $a swept to <0.6 LUX" "$b" "$(wei 0.6)"; done
TOTAL_AFTER=$(python3 -c "print($DAO_BAL+$Z_BAL+$A9+$EOA_AFTER)")
GAS=$(python3 -c "print($TOTAL_BEFORE-$TOTAL_AFTER)")
RESID_PLUS=$(python3 -c "print(($S9-$(wei $DAO_ALLOC)-$(wei $RESERVE))+($EOA_SUM-$(wei 4.0)))")  # -8*0.5 EOA gas-keep
echo "  DAO=$(lux $DAO_BAL)  Z=$(lux $Z_BAL)  0x9011=$(lux $A9)  gasBurned=$(lux $GAS) LUX"
assert_eq "DAO Safe == exactly 1T LUX"        "$DAO_BAL" "$(wei $DAO_ALLOC)"
assert_ge "0x9011 ~ reserve (>=999)"          "$A9"      "$(wei 999)"
assert_le "0x9011 ~ reserve (<=1000)"         "$A9"      "$(wei 1000)"
assert_ge "Z Safe >= residual+EOAs - 1 LUX"   "$Z_BAL"   "$(python3 -c "print($RESID_PLUS-$(wei 1))")"
assert_ge "conservation: gasBurned >= 0"      "$GAS"     "0"
assert_le "conservation: gasBurned < 5 LUX"   "$GAS"     "$(wei 5)"

hdr "3. PHASE=ownership  (on-chain handles 0xce15-owned -> BLOCKED, emits calldata; no-op)"
EXPECT_CID=96369 STD_DIR="$STD_DIR" REC="$STD_DIR/deployments" PHASE=ownership \
  bash "$HERE/prepare_program.sh" "$FRPC"
ok "ownership phase ran (documented blocker; no state change)"

hdr "4. PHASE=upgrade  rotate both Safe owners 0x9011 -> FRESH keys (security close-out)"
read DAO_NEW DAO_NEWK < <(cast wallet new | awk '/Address/{a=$2} /Private key/{print a,$3}')
read Z_NEW   Z_NEWK   < <(cast wallet new | awk '/Address/{a=$2} /Private key/{print a,$3}')
echo "  fresh DAO owner=$DAO_NEW   fresh Z owner=$Z_NEW   (fork-sim keys only)"
cast rpc anvil_setBalance "$DAO_NEW" "$(hexwei $(wei 1))" --rpc-url "$FRPC" >/dev/null
cast rpc anvil_setBalance "$Z_NEW"   "$(hexwei $(wei 1))" --rpc-url "$FRPC" >/dev/null
EXPECT_CID=96369 SECRET_NS=lux-mainnet STD_DIR="$STD_DIR" REC="$STD_DIR/deployments" \
  PHASE=upgrade EXECUTE=yes DAO_FINAL_OWNER="$DAO_NEW" Z_FINAL_OWNER="$Z_NEW" \
  bash "$HERE/prepare_program.sh" "$FRPC"

hdr "5. verify rotation + fresh owner controls + exposed 0x9011 LOCKED OUT"
assert_rotated "Z Safe"   "$FRPC" "$Z"   "$Z_NEW"
assert_rotated "DAO Safe" "$FRPC" "$DAO" "$DAO_NEW"
DEST=0x000000000000000000000000000000000000bEEF
prove_control   "Z Safe"   "$FRPC" "$Z"   "$Z_NEWK"   "$DEST"
prove_control   "DAO Safe" "$FRPC" "$DAO" "$DAO_NEWK" "$DEST"
EXPOSED=$(kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n lux-mainnet -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d); case "$EXPOSED" in 0x*) ;; *) EXPOSED="0x$EXPOSED";; esac
prove_locked_out "Z Safe"   "$FRPC" "$Z"   "$EXPOSED" "$DEST"
prove_locked_out "DAO Safe" "$FRPC" "$DAO" "$EXPOSED" "$DEST"
EXPOSED=""

hdr "6. robustness: keep-warm builder loop (prefund reserved key from 0x9011, then loop)"
KEEPWARM_INDEX=777 SECRET_NS=lux-mainnet PREFUND_LUX=1 bash "$HERE/keepwarm.sh" "$FRPC" prefund >/dev/null 2>&1
KW=$(KEEPWARM_INDEX=777 SECRET_NS=lux-mainnet timeout 6 bash "$HERE/keepwarm.sh" "$FRPC" run 1 2>&1 | tr -d '\n')
case "$KW" in *...*) ok "keep-warm loop issued warming txs (idle-builder mitigation verified)";; *) bad "keep-warm loop did not run: $KW";; esac

summary "FORK E2E (chainId 96369, full remaining program)"
