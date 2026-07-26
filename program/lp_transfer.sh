#!/usr/bin/env bash
# Path-B ownership consolidation: transfer ALL of 0x9011's V3 LP position NFTs
# (+ optional extra tokenIds) to the DAO Safe. User-authorized ("transfer all, move all").
# Reuses the proven sweep harness: lux-deployer/LUX_PRIVATE_KEY signs (0x9011, never printed),
# keepwarm.sh (idx-777) keeps the demand-driven builder hot so txs land.
#
# Uses transferFrom (NOT safeTransferFrom) so the receive never depends on the Safe's
# onERC721Received fallback handler — the Safe custodies the NFT unconditionally, and can
# later move it via execTransaction. Enumerates ALL tokenIds FIRST (indices shift as we
# transfer), then transfers by tokenId, then verifies every ownerOf == DAO Safe.
#
# Env: RPC (required, a PINNED caught-up node), SECRET_NS (default lux-mainnet),
#      PM (V3 position manager), DAO (target owner), EXECUTE=yes to actually send.
set -uo pipefail
CTX=do-sfo3-lux-k8s
SECRET_NS="${SECRET_NS:-lux-mainnet}"
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
PM="${PM:-0x7a4C48B9dae0b7c396569b34042fcA604150Ee28}"
DAO="${DAO:-0x51284dC2133e8d3a8e213DCa6a6FA768cfDfcce2}"
: "${RPC:?set RPC to a pinned caught-up mainnet node}"

cid=$(cast chain-id --rpc-url "$RPC" 2>/dev/null)
[ "$cid" = "96369" ] || { echo "REFUSE: chainId=$cid != 96369 (wrong net / not pinned)"; exit 1; }

read_key() { kubectl --context $CTX get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d; }
MK=$(read_key); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
A=$(cast wallet address --private-key "$MK" 2>/dev/null)
[ "$(echo "$A" | tr A-Z a-z)" = "$(echo "$OWNER" | tr A-Z a-z)" ] || { echo "REFUSE: signer $A != 0x9011"; MK=; exit 1; }
echo "[lp] signer verified = 0x9011  chainId=$cid  head=$(cast block-number --rpc-url "$RPC")"

# --- enumerate ALL tokenIds FIRST (before any transfer; indices shift as balance drops) ---
n=$(cast call "$PM" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" | sed 's/ .*//')
echo "[lp] 0x9011 holds $n LP position NFTs — enumerating (with retry)..."
IDS=()
for i in $(seq 0 $((n-1))); do
  tid=""; for try in 1 2 3 4 5; do
    tid=$(cast call "$PM" 'tokenOfOwnerByIndex(address,uint256)(uint256)' "$OWNER" "$i" --rpc-url "$RPC" 2>/dev/null | sed 's/ .*//')
    [ -n "$tid" ] && break || sleep 1
  done
  [ -n "$tid" ] && IDS+=("$tid") || { echo "REFUSE: idx $i unreadable after retries"; MK=; exit 1; }
done
echo "[lp] enumerated ${#IDS[@]} tokenIds: ${IDS[*]}"
[ "${#IDS[@]}" -eq "$n" ] || { echo "REFUSE: enumerated ${#IDS[@]} != balance $n"; MK=; exit 1; }

if [ "${EXECUTE:-no}" != "yes" ]; then
  echo "[lp] PLAN ONLY (set EXECUTE=yes to send). Would transferFrom each of the ${#IDS[@]} tokenIds 0x9011 -> $DAO"
  MK=; exit 0
fi

# --- keep the builder hot (idx-777, prefunded from 0x9011) so each transfer lands fast ---
echo "[lp] pre-warming builder..."
bash "$(dirname "$0")/keepwarm.sh" "$RPC" prefund 2>&1 | grep -viE "fs_permissions|nightly|Warning" | tail -1
bash "$(dirname "$0")/keepwarm.sh" "$RPC" run 3 >/tmp/lp-keepwarm.log 2>&1 &
KW=$!
sleep 6

# --- transfer each (sequential, blocks until mined; nonce auto-increments on 0x9011) ---
ok=0; fail=0
for tid in "${IDS[@]}"; do
  if cast send "$PM" 'transferFrom(address,address,uint256)' "$OWNER" "$DAO" "$tid" \
       --private-key "$MK" --rpc-url "$RPC" --gas-limit 250000 >/tmp/lp-tx-$tid.log 2>&1; then
    now=$(cast call "$PM" 'ownerOf(uint256)(address)' "$tid" --rpc-url "$RPC" | head -c 42)
    if [ "$(echo "$now" | tr A-Z a-z)" = "$(echo "$DAO" | tr A-Z a-z)" ]; then
      ok=$((ok+1)); printf '[lp] tokenId %-8s -> DAO ✓ (%d/%d)\n' "$tid" "$ok" "${#IDS[@]}"
    else
      fail=$((fail+1)); printf '[lp] tokenId %-8s SENT but owner=%s ✗\n' "$tid" "$now"
    fi
  else
    fail=$((fail+1)); printf '[lp] tokenId %-8s SEND FAILED (see /tmp/lp-tx-%s.log)\n' "$tid" "$tid"
  fi
done
kill $KW 2>/dev/null

# --- final verify ---
rem=$(cast call "$PM" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" | sed 's/ .*//')
daon=$(cast call "$PM" 'balanceOf(address)(uint256)' "$DAO" --rpc-url "$RPC" | sed 's/ .*//')
echo "[lp] === DONE: transferred=$ok failed=$fail ; 0x9011 now holds $rem LP NFTs ; DAO Safe holds $daon ==="
MK=
[ "$fail" -eq 0 ] && [ "$rem" = "0" ]
