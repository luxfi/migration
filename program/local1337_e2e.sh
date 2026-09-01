#!/usr/bin/env bash
# LOCAL 1337 END-TO-END PROOF — the FULL program from scratch (incl. deploy).
# A fresh anvil --chain-id 1337 with NO forked state: seed 0x9011 + the 8 EOAs to their live
# mainnet balances, then run deploy -> sweep -> ownership -> upgrade and prove the same money
# path + security close-out. This exercises the one phase the fork test can't: deploy.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"
STD_DIR="${STD_DIR:-/Users/z/work/lux/standard}"
PORT=8546; LRPC="http://127.0.0.1:$PORT"; CID=1337
REC="/tmp/lux-mig-1337-deployments"      # scratch records (never touch the public standard/ tree)
DAO_ALLOC=1000000000000; RESERVE=1000
hexwei() { python3 -c "print(hex(int($1)))"; }
cleanup() { kill "${ANVIL_PID:-0}" 2>/dev/null; anvil_state_sweep; }
trap cleanup EXIT
rm -rf "$REC"; mkdir -p "$REC"

# live mainnet balances to mirror (read once from a caught-up node for fidelity)
hdr "0. read live mainnet balances to mirror onto local 1337"
BEST=""; BESTH=0
for n in 0 1 2 3 4; do
  ip=$(kubectl --context do-sfo3-lux-k8s -n lux-mainnet get svc "luxd-$n" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -z "$ip" ] && continue
  h=$(cast block-number --rpc-url "http://$ip:9630/v1/bc/C/rpc" 2>/dev/null) || continue
  [ "$h" -gt "$BESTH" ] 2>/dev/null && { BESTH=$h; BEST="http://$ip:9630/v1/bc/C/rpc"; }
done
[ -n "$BEST" ] || { echo "ABORT: no reachable luxd node"; exit 1; }
EOA_ADDRS=(0xEAbCC110fAcBfebabC66Ad6f9E7B67288e720B59 0x8d5081153aE1cfb41f5c932fe0b6Beb7E159cF84 0xf7f52257a6143cE6BbD12A98eF2B0a3d0C648079 0xCA92ad0C91bd8DE640B9dAFfEB338ac908725142 0xB5B325df519eB58B7223d85aaeac8b56aB05f3d6 0xf785FA547ae9CcF3D3ca5362762A347a4c41051A 0xf4b5be7a6deA583dA4CddCDa4D9B3afd51684b6e 0x202335dd1c21C9B90277F8BcA78Db98db0bBc293)
S9_LIVE=$(cast balance "$OWNER" --rpc-url "$BEST")
declare -a EOA_LIVE
for i in "${!EOA_ADDRS[@]}"; do EOA_LIVE[$i]=$(cast balance "${EOA_ADDRS[$i]}" --rpc-url "$BEST"); done
echo "  mirror 0x9011=$(lux $S9_LIVE) LUX + ${#EOA_ADDRS[@]} EOAs"

hdr "1. start fresh anvil chainId 1337 (no fork) and seed balances"
pkill -f "anvil.*$PORT" 2>/dev/null; sleep 1
anvil_state_mark
anvil --port "$PORT" --chain-id "$CID" --silent >/tmp/local1337_anvil.log 2>&1 &
ANVIL_PID=$!
wait_ready "$LRPC"; assert_local "$LRPC"
assert_eq "local chainId" "$(cast chain-id --rpc-url $LRPC)" "1337"
cast rpc anvil_setBalance "$OWNER" "$(hexwei $S9_LIVE)" --rpc-url "$LRPC" >/dev/null
EOA_SUM=0
for i in "${!EOA_ADDRS[@]}"; do cast rpc anvil_setBalance "${EOA_ADDRS[$i]}" "$(hexwei ${EOA_LIVE[$i]})" --rpc-url "$LRPC" >/dev/null; EOA_SUM=$(python3 -c "print($EOA_SUM+${EOA_LIVE[$i]})"); done
assert_eq "0x9011 seeded" "$(cast balance $OWNER --rpc-url $LRPC)" "$S9_LIVE"

hdr "2. PHASE=deploy  — deploy both Safes from scratch (1/1 owner 0x9011, v1.5.0)"
EXPECT_CID=1337 SECRET_NS=lux-mainnet STD_DIR="$STD_DIR" REC="$REC" PHASE=deploy EXECUTE=yes \
  bash "$HERE/prepare_program.sh" "$LRPC"
DAO=$(jq -r .safe "$REC/lux-dao/1337.json"); Z=$(jq -r .safe "$REC/lux-zpriv/1337.json")
assert_eq "DAO Safe deployed (owner 0x9011)" "$(cast call $DAO 'isOwner(address)(bool)' $OWNER --rpc-url $LRPC)" "true"
assert_eq "Z Safe deployed (owner 0x9011)"   "$(cast call $Z   'isOwner(address)(bool)' $OWNER --rpc-url $LRPC)" "true"
assert_eq "DAO Safe v1.5.0" "$(cast call $DAO 'VERSION()(string)' --rpc-url $LRPC | tr -d '\"')" "1.5.0"

S9=$(cast balance "$OWNER" --rpc-url "$LRPC")   # post-deploy 0x9011 (deploy gas already spent)
TOTAL_BEFORE=$(python3 -c "print($S9+$EOA_SUM)")

hdr "3. PHASE=sweep  DAO_ALLOC=1T -> DAO Safe, residual+EOAs -> Z Safe"
EXPECT_CID=1337 SECRET_NS=lux-mainnet STD_DIR="$STD_DIR" REC="$REC" \
  PHASE=sweep EXECUTE=yes DAO_ALLOC=$DAO_ALLOC RESERVE=$RESERVE \
  bash "$HERE/prepare_program.sh" "$LRPC"
DAO_BAL=$(cast balance "$DAO" --rpc-url "$LRPC"); Z_BAL=$(cast balance "$Z" --rpc-url "$LRPC"); A9=$(cast balance "$OWNER" --rpc-url "$LRPC")
EOA_AFTER=0; for a in "${EOA_ADDRS[@]}"; do b=$(cast balance "$a" --rpc-url "$LRPC"); EOA_AFTER=$(python3 -c "print($EOA_AFTER+$b)"); assert_le "EOA $a swept <0.6 LUX" "$b" "$(wei 0.6)"; done
GAS=$(python3 -c "print($TOTAL_BEFORE-($DAO_BAL+$Z_BAL+$A9+$EOA_AFTER))")
RESID_PLUS=$(python3 -c "print(($S9-$(wei $DAO_ALLOC)-$(wei $RESERVE))+($EOA_SUM-$(wei 4.0)))")
echo "  DAO=$(lux $DAO_BAL)  Z=$(lux $Z_BAL)  0x9011=$(lux $A9)  gasBurned=$(lux $GAS)"
assert_eq "DAO Safe == exactly 1T LUX"      "$DAO_BAL" "$(wei $DAO_ALLOC)"
assert_ge "0x9011 ~ reserve (>=999)"        "$A9"      "$(wei 999)"
assert_le "0x9011 ~ reserve (<=1000)"       "$A9"      "$(wei 1000)"
assert_ge "Z Safe >= residual+EOAs - 1 LUX" "$Z_BAL"   "$(python3 -c "print($RESID_PLUS-$(wei 1))")"
assert_ge "conservation gasBurned >= 0"     "$GAS"     "0"
assert_le "conservation gasBurned < 5 LUX"  "$GAS"     "$(wei 5)"

hdr "4. PHASE=ownership (blocked; emits calldata; no-op) + PHASE=upgrade (rotate to fresh)"
EXPECT_CID=1337 STD_DIR="$STD_DIR" REC="$REC" PHASE=ownership bash "$HERE/prepare_program.sh" "$LRPC"
read DAO_NEW DAO_NEWK < <(cast wallet new | awk '/Address/{a=$2} /Private key/{print a,$3}')
read Z_NEW   Z_NEWK   < <(cast wallet new | awk '/Address/{a=$2} /Private key/{print a,$3}')
cast rpc anvil_setBalance "$DAO_NEW" "$(hexwei $(wei 1))" --rpc-url "$LRPC" >/dev/null
cast rpc anvil_setBalance "$Z_NEW"   "$(hexwei $(wei 1))" --rpc-url "$LRPC" >/dev/null
echo "  fresh DAO owner=$DAO_NEW  fresh Z owner=$Z_NEW"
EXPECT_CID=1337 SECRET_NS=lux-mainnet STD_DIR="$STD_DIR" REC="$REC" \
  PHASE=upgrade EXECUTE=yes DAO_FINAL_OWNER="$DAO_NEW" Z_FINAL_OWNER="$Z_NEW" \
  bash "$HERE/prepare_program.sh" "$LRPC"

hdr "5. verify rotation + fresh owner controls + exposed 0x9011 LOCKED OUT"
assert_rotated "Z Safe"   "$LRPC" "$Z"   "$Z_NEW"
assert_rotated "DAO Safe" "$LRPC" "$DAO" "$DAO_NEW"
DEST=0x000000000000000000000000000000000000bEEF
prove_control   "Z Safe"   "$LRPC" "$Z"   "$Z_NEWK"   "$DEST"
prove_control   "DAO Safe" "$LRPC" "$DAO" "$DAO_NEWK" "$DEST"
EXPOSED=$(kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n lux-mainnet -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d); case "$EXPOSED" in 0x*) ;; *) EXPOSED="0x$EXPOSED";; esac
prove_locked_out "Z Safe"   "$LRPC" "$Z"   "$EXPOSED" "$DEST"
prove_locked_out "DAO Safe" "$LRPC" "$DAO" "$EXPOSED" "$DEST"
EXPOSED=""

summary "LOCAL 1337 E2E (deploy + sweep + ownership + upgrade from scratch)"
