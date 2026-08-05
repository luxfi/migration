#!/usr/bin/env bash
# path_b_erc20.sh — Path-B companion to lp_transfer.sh: sweep the ERC-20 token balances
# the exposed treasury EOA 0x9011 holds in the DEX tokens -> DAO Safe. lp_transfer.sh moves
# the 74 LP-position NFTs; THIS moves the fungible DEX-token balances (the other half of
# "move all"). Same harness: lux-deployer/LUX_PRIVATE_KEY signs (0x9011, never printed),
# keepwarm.sh keeps the builder hot, EXECUTE=yes to send, per-tx verify.
#
# Idempotent + resumable: transfers the FULL live balance of each token; a token already at
# zero (previously swept) is skipped. Balances are re-read LIVE so the set is never stale.
#
# Env: RPC (required, PINNED caught-up node), SECRET_NS (default lux-mainnet),
#      DAO (target), EXECUTE=yes to actually send.
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
CTX=do-sfo3-lux-k8s
SECRET_NS="${SECRET_NS:-lux-mainnet}"
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
DAO="${DAO:-0xF0D19cCCB8e33663e9bDEe6e40474F1E3fD1f2BD}"
: "${RPC:?set RPC to a pinned caught-up mainnet node}"
low(){ echo "$1" | tr 'A-Z' 'a-z'; }

cid=$(cast chain-id --rpc-url "$RPC" 2>/dev/null)
[ "$cid" = "96369" ] || { echo "REFUSE: chainId=$cid != 96369 (wrong net / not pinned)"; exit 1; }
# The DAO Safe must be REAL and OWNED BY A KEY WE HOLD — never sweep to a phantom.
#
# This used to hard-code 0x9011 as the required owner. That was right when the Safe
# was 1/1 0x9011, and wrong from 2026-08-05: the RLP restore to block 1,082,780
# un-deployed the old Safe (0x51284dC2, 0 bytes) and the rebuilt one is owned by the
# CLEAN deployer 0x591eE882 precisely BECAUSE 0x9011's key is compromised. Requiring
# the leaked key as owner would have been the bug, not the safeguard.
#
# The invariant that actually matters is "a key we control owns the destination", so
# assert that against SAFE_OWNER (default: the clean deployer) instead of a literal.
SAFE_OWNER="${SAFE_OWNER:-0x591eE88261B43D79692B22cBfde291f7d36853AB}"
[ "$(cast codesize $DAO --rpc-url $RPC)" -gt 0 ] || { echo "REFUSE: DAO Safe has no code"; exit 1; }
cast call $DAO 'getOwners()(address[])' --rpc-url $RPC 2>/dev/null | grep -qi "${SAFE_OWNER#0x}" \
  || { echo "REFUSE: DAO Safe $DAO owners do not include SAFE_OWNER=$SAFE_OWNER"; exit 1; }
echo "[erc20] destination Safe $DAO verified owned by $SAFE_OWNER" 

# The DEX tokens 0x9011 can hold (canonical bridge set + LAVAX). Only non-zero are swept.
TOKENS="LUSD:0x848Cff46eb323f323b6Bbe1Df274E40793d7f2c2 \
LBTC:0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e \
LETH:0x60E0a8167FC13dE89348978860466C9ceC24B9ba \
LSOL:0x26B40f650156C7EbF9e087Dd0dca181Fe87625B7 \
LPOL:0x28BfC5DD4B7E15659e41190983e5fE3df1132bB9 \
LZOO:0x5E5290f350352768bD2bfC59c2DA15DD04A7cB88 \
LBNB:0x6EdcF3645DeF09DB45050638c41157D8B9FEa1cf \
LAVAX:0x0e4bd0dd67c15DECFbBBDBbE07Fc9d51D737693D \
LCELO:0x3078847F879A33994cDa2Ec1540ca52b5E0eE2e5 \
LFTM:0x8B982132d639527E8a0eAAD385f97719af8f5e04 \
LTON:0x3141b94b89691009b950c96e97Bff48e0C543E3C"

echo "[erc20] chainId=$cid head=$(cast block-number --rpc-url "$RPC")  target DAO=$DAO"
echo "[erc20] live 0x9011 balances:"
PLAN=""
for pair in $TOKENS; do
  sym="${pair%%:*}"; addr="${pair##*:}"
  bal=$(cast call "$addr" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" 2>/dev/null); bal="${bal%% *}"
  [ -z "$bal" ] && bal=0
  if [ "$bal" != "0" ]; then echo "  $sym $addr = $bal  <-- SWEEP"; PLAN="$PLAN $sym:$addr:$bal"; \
  else echo "  $sym $addr = 0 (skip)"; fi
done
[ -z "$PLAN" ] && { echo "[erc20] nothing to sweep (all zero) — done"; exit 0; }

if [ "${EXECUTE:-no}" != "yes" ]; then
  echo "[erc20] PLAN ONLY (set EXECUTE=yes to send). Would transfer each non-zero balance 0x9011 -> DAO Safe."
  exit 0
fi

read_key(){ kubectl --context $CTX get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d; }
MK=$(read_key); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
A=$(cast wallet address --private-key "$MK" 2>/dev/null)
[ "$(low "$A")" = "$(low "$OWNER")" ] || { echo "REFUSE: signer $A != 0x9011"; MK=; exit 1; }
echo "[erc20] signer verified = 0x9011"

echo "[erc20] pre-warming builder..."
bash "$(dirname "$0")/keepwarm.sh" "$RPC" prefund 2>&1 | grep -viE "fs_permissions|nightly|Warning" | tail -1
bash "$(dirname "$0")/keepwarm.sh" "$RPC" run 3 >/tmp/erc20-keepwarm.log 2>&1 & KW=$!
sleep 6

okc=0; failc=0
for item in $PLAN; do
  sym="${item%%:*}"; rest="${item#*:}"; addr="${rest%%:*}"; bal="${rest##*:}"
  if cast send "$addr" 'transfer(address,uint256)' "$DAO" "$bal" \
       --private-key "$MK" --rpc-url "$RPC" --gas-limit 120000 >/tmp/erc20-tx-$sym.log 2>&1; then
    rem=$(cast call "$addr" 'balanceOf(address)(uint256)' "$OWNER" --rpc-url "$RPC" | sed 's/ .*//')
    if [ "$rem" = "0" ]; then okc=$((okc+1)); printf '[erc20] %-6s %s -> DAO ✓\n' "$sym" "$bal"; \
    else failc=$((failc+1)); printf '[erc20] %-6s SENT but 0x9011 still holds %s ✗\n' "$sym" "$rem"; fi
  else failc=$((failc+1)); printf '[erc20] %-6s SEND FAILED (see /tmp/erc20-tx-%s.log)\n' "$sym" "$sym"; fi
done
kill $KW 2>/dev/null; MK=
echo "[erc20] === DONE: swept=$okc failed=$failc ==="
[ "$failc" -eq 0 ]
