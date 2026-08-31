#!/bin/sh
# Fork-prove the Lux tokenomics on-chain split against LIVE mainnet 96369.
# STAGING ONLY — proves mechanics on a fork; does NOT touch mainnet.
set -e
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
# 1) pin a caught-up mainnet luxd pod's C-Chain RPC to localhost:19630
kubectl -n lux-mainnet port-forward pod/luxd-0 19630:9630 >/tmp/pf-luxd.log 2>&1 &
PF=$!; sleep 4
# 2) run the proofs against the live chain state
forge test --fork-url http://localhost:19630/v1/chain/C/rpc --fork-block-number 1082900 -vv --summary
kill $PF 2>/dev/null || true
