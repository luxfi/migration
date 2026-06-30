#!/usr/bin/env bash
# ROBUSTNESS: keep the coreth builder hot during a sweep.
# The live mainnet C-Chain is idle — the block builder goes cold, so the FIRST tx after
# idle stalls (the failure that kept aborting the real sweep). This loop issues continuous
# tiny self-sends from a DEDICATED key (reserved mnemonic index, NOT 0x9011, NOT any swept
# EOA) so the builder stays in active block-production mode and the sweep's 0x9011 txs land
# immediately. Run this against the SAME single caught-up node the sweep uses, in parallel
# with the sweep; stop it after.
#
#   subcommand prefund : send gas to the keep-warm key from 0x9011 (one tx), then exit
#   subcommand run     : loop self-sends (default)
#
# Usage: keepwarm.sh <rpc> [run|prefund] [interval_sec]
# Env:   KEEPWARM_INDEX (reserved std mnemonic index, default 777),
#        PREFUND_LUX (gas to seed on prefund, default 1), SECRET_NS (default lux-mainnet)
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${1:?usage: keepwarm.sh <rpc> [run|prefund] [interval_sec]}"
SUB="${2:-run}"; IV="${3:-2}"
SECRET_NS="${SECRET_NS:-lux-mainnet}"
IDX="${KEEPWARM_INDEX:-777}"; PREFUND_LUX="${PREFUND_LUX:-1}"
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714

M=$(kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_MNEMONIC}' | base64 -d)
K=$(cast wallet private-key --mnemonic "$M" --mnemonic-index "$IDX"); case "$K" in 0x*) ;; *) K="0x$K";; esac
A=$(cast wallet address --private-key "$K")

case "$SUB" in
  prefund)
    MK=$(kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
    echo "prefund keep-warm key idx=$IDX addr=$A with $PREFUND_LUX LUX from 0x9011"
    cast send --rpc-url "$RPC" --private-key "$MK" "$A" --value "$(python3 -c "print(int($PREFUND_LUX*10**18))")"
    M=""; MK=""; K=""
    echo "keep-warm bal=$(cast to-unit $(cast balance $A --rpc-url $RPC) ether) LUX" ;;
  run)
    M=""
    echo "keep-warm idx=$IDX addr=$A bal=$(cast to-unit $(cast balance $A --rpc-url $RPC) ether) LUX — self-send every ${IV}s (Ctrl-C to stop)"
    trap 'echo; echo "keep-warm stopped"; K=""; exit 0' INT TERM
    while true; do
      cast send "$A" --value 1 --private-key "$K" --rpc-url "$RPC" >/dev/null 2>&1 && printf '.' || printf 'x'
      sleep "$IV"
    done ;;
  *) echo "unknown subcommand: $SUB (run|prefund)"; exit 1 ;;
esac
