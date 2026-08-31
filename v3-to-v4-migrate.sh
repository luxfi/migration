#!/usr/bin/env bash
#
# v3-to-v4-migrate.sh — WITHDRAW side of the Lux DAO V3->V4 LP migration.
#
# Drives the staged Safe MultiSendCallOnly batch in v3-to-v4-withdraw.json.
# The batch: for each live V3 position held by the DAO Safe, decreaseLiquidity(full)+collect(max);
# an optional cleanup batch burns all 74 emptied NFTs.
#
# SAFETY: this script NEVER sends to real mainnet. It has exactly two modes:
#   (default)        DRY RUN   — print the plan, decode the batch, compute the Safe tx hash. No sends.
#   --execute-fork   FORK ONLY — reset + execute against the local anvil fork on 127.0.0.1:8545 only.
#                                Add --with-burns to also run the burn-all cleanup batch.
#
# The real mainnet execution is performed by the Safe owner signing execTransaction in the Safe UI /
# their own signer — NOT by this script. See "MAINNET EXECUTION" printed in dry-run mode.
#
set -euo pipefail

CAST=/Users/z/.foundry/bin/cast
FORK="http://127.0.0.1:8545"          # the ONLY endpoint this script will ever send to
UPSTREAM="http://127.0.0.1:19630/v1/chain/C/rpc"
FORK_BLOCK=1082950
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$HERE/v3-to-v4-withdraw.json"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SAFE=$(python3 -c "import json;print(json.load(open('$JSON'))['meta']['safe'])")
OWNER=$(python3 -c "import json;print(json.load(open('$JSON'))['meta']['safeOwner'])")
MSCO=$(python3 -c "import json;print(json.load(open('$JSON'))['meta']['multiSendCallOnly'])")
NFPM=$(python3 -c "import json;print(json.load(open('$JSON'))['meta']['nonfungiblePositionManager'])")
Z=0x0000000000000000000000000000000000000000

jget() { python3 -c "import json;d=json.load(open('$JSON'));print(eval(\"d$1\"))"; }

live_ids() { python3 -c "import json;print(' '.join(str(p['tokenId']) for p in json.load(open('$JSON'))['positions']))"; }

liq() { $CAST call $NFPM 'positions(uint256)(uint96,address,address,address,uint24,int24,int24,uint128,uint256,uint256,uint128,uint128)' "$1" --rpc-url "$FORK" | awk 'NR==8{print $1}'; }

safe_tx_hash() {  # $1=data
  local data="$1" nonce
  nonce=$($CAST call $SAFE 'nonce()(uint256)' --rpc-url "$FORK")
  $CAST call $SAFE \
    'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)' \
    $MSCO 0 "$data" 1 0 0 0 $Z $Z "$nonce" --rpc-url "$FORK"
}

exec_batch() {  # $1=data  $2=label
  local data="$1" label="$2" txhash sig res
  txhash=$(safe_tx_hash "$data")
  echo "  [$label] safeTxHash=$txhash"
  $CAST send $SAFE 'approveHash(bytes32)' "$txhash" --from $OWNER --unlocked --rpc-url "$FORK" >/dev/null
  sig="0x000000000000000000000000${OWNER#0x}$(printf '0%.0s' {1..64})01"
  res=$($CAST send $SAFE \
    'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)' \
    $MSCO 0 "$data" 1 0 0 0 $Z $Z "$sig" --from $OWNER --unlocked --rpc-url "$FORK" --json)
  echo "  [$label] exec.status=$(echo "$res" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])') gasUsed=$(echo "$res" | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["gasUsed"],16))')"
}

print_plan() {
  echo "=============================================================="
  echo " Lux DAO V3->V4 migration — WITHDRAW side"
  echo " Safe:              $SAFE (owner $OWNER, threshold 1)"
  echo " NFPM:              $NFPM"
  echo " MultiSendCallOnly: $MSCO"
  echo "--------------------------------------------------------------"
  echo " Live positions to withdraw:"
  python3 - "$JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for p in d["positions"]:
    fp=p["forkProven"]
    print(f"   id {p['tokenId']:<4} {p['pair']:<12} liq={p['liquidity']:<30} "
          f"-> {fp['withdrawn_token0']} {p['token0']['symbol']} + {fp['withdrawn_token1']} {p['token1']['symbol']}  clean={fp['clean']}")
print("   totals withdrawn:")
for s,v in d["totalsWithdrawnByToken"].items():
    print(f"     {s:<6} {v['human']}")
print(f"   empties to burn (cleanup batch): {d['meta']['emptyCount']}")
PY
  echo "--------------------------------------------------------------"
  echo " Withdraw batch: to=$MSCO operation=1(delegatecall) subCalls=$(jget "['batches']['withdraw']['subCallCount']")"
  echo " Burn-all batch: to=$MSCO operation=1(delegatecall) subCalls=$(jget "['batches']['burnAll']['subCallCount']")"
  echo "=============================================================="
}

MODE="${1:-dry}"

case "$MODE" in
  dry|--dry|--dry-run|"")
    print_plan
    echo ""
    echo "DRY RUN — no transactions sent."
    if $CAST block-number --rpc-url "$FORK" >/dev/null 2>&1; then
      DATA=$(jget "['batches']['withdraw']['execTransactionData']")
      echo "Computed Safe tx hash for the withdraw batch (against fork read-only):"
      echo "  $(safe_tx_hash "$DATA")"
    else
      echo "(fork on $FORK not running — skip live tx-hash computation; reference hash in JSON forkProof.safeTxHash_at_nonce0)"
    fi
    echo ""
    echo "MAINNET EXECUTION (performed by the Safe owner, NOT this script):"
    echo "  1. Load Safe $SAFE in the Safe UI (or your signer)."
    echo "  2. New transaction -> Contract interaction / raw:"
    echo "       to        = $MSCO   (MultiSendCallOnly)"
    echo "       value     = 0"
    echo "       operation = 1 (delegatecall)   <-- REQUIRED so inner calls run as the Safe"
    echo "       data      = batches.withdraw.execTransactionData  (in v3-to-v4-withdraw.json)"
    echo "  3. Owner $OWNER signs (threshold 1) and executes."
    echo "  4. Optionally repeat with batches.burnAll.execTransactionData to burn the 74 emptied NFTs."
    ;;

  --execute-fork)
    echo "### EXECUTE ON FORK ONLY ($FORK) ###"
    if ! $CAST block-number --rpc-url "$FORK" >/dev/null 2>&1; then
      echo "ERROR: no anvil fork on $FORK. Launch:"
      echo "  anvil --fork-url $UPSTREAM --chain-id 96369 --auto-impersonate --silent --port 8545 --fork-block-number $FORK_BLOCK --no-rate-limit"
      exit 1
    fi
    echo "resetting fork to block $FORK_BLOCK ..."
    $CAST rpc anvil_reset "{\"forking\":{\"jsonRpcUrl\":\"$UPSTREAM\",\"blockNumber\":$FORK_BLOCK}}" --rpc-url "$FORK" >/dev/null
    echo "live liquidity BEFORE:"; for t in $(live_ids); do echo "   id $t liq=$(liq $t)"; done
    exec_batch "$(jget "['batches']['withdraw']['execTransactionData']")" "withdraw"
    ALLZERO=1
    echo "live liquidity AFTER (must all be 0):"
    for t in $(live_ids); do L=$(liq $t); echo "   id $t liq=$L"; [ "$L" != "0" ] && ALLZERO=0; done
    if [ "${2:-}" = "--with-burns" ]; then
      echo "running burn-all cleanup batch ..."
      exec_batch "$(jget "['batches']['burnAll']['execTransactionData']")" "burnAll"
      echo "Safe NFPM balanceOf after burns = $($CAST call $NFPM 'balanceOf(address)(uint256)' $SAFE --rpc-url "$FORK")"
    fi
    echo ""
    echo "### ALL_LIVE_LIQUIDITY_ZERO=$ALLZERO (1 = success) ###"
    ;;

  *)
    echo "usage: $0 [dry]            # default: print plan + tx hash, no sends"
    echo "       $0 --execute-fork [--with-burns]   # execute against 127.0.0.1:8545 fork ONLY"
    exit 2
    ;;
esac
