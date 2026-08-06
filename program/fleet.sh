#!/usr/bin/env bash
# Shared fleet operations for a luxd StatefulSet. Sourced, never run directly.
#
# One concern: talking to a running validator fleet correctly. The callers
# (state_upgrade.sh, fleet_verify.sh) decide WHAT to do; this file knows HOW to
# do it without wedging the chain.
#
# Every rule here is measured, not reasoned. See the comment on each function.
#
# Config (env, with defaults for lux mainnet):
#   CTX  kube context      NS   namespace
#   STS  pod name prefix   N    validator count
: "${CTX:=do-sfo3-lux-k8s}"
: "${NS:=lux-mainnet}"
: "${STS:=luxd}"
: "${N:=5}"
: "${CHAIN:=C}"
# Container name inside the pod. lux fleets call it "luxd"; hanzo calls it
# "hanzod". Hardcoding it made every exec silently fail on the hanzo fleet.
: "${CONTAINER:=luxd}"
: "${HTTP_PORT:=9630}"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# zsh does not word-split unquoted parameters, so `K="kubectl -n x"; $K get` runs
# a command literally named "kubectl -n x" and fails with "command not found".
# A function works under both shells. This cost 10 minutes of a mainnet window.
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

hdr()  { printf '\n=== %s ===\n' "$*"; }
say()  { printf '  %s\n' "$*"; }
die()  { printf '\nABORT: %s\n' "$*" >&2; exit 1; }

pods() { local i=0; while [ "$i" -lt "$N" ]; do echo "$STS-$i"; i=$((i+1)); done; }

# --- RPC ------------------------------------------------------------------
# The node image ships NEITHER wget NOR curl, so there is no in-pod HTTP client;
# every read has to go through a port-forward. Learning this the hard way looks
# like all 5 nodes reporting UNREACHABLE while the fleet is perfectly healthy.
#
# Reads are per-pod ON PURPOSE. A Service (or any load balancer) round-robins
# across validators at different heights, which makes consistent reads
# impossible and turns "which node is behind" into an unanswerable question.
_PF_PID=""
pf_open() { # <pod> <localport>
  pf_close
  k port-forward "pod/$1" "$2:$HTTP_PORT" >/dev/null 2>&1 &
  _PF_PID=$!
  local i; for i in $(seq 1 15); do
    cast chain-id --rpc-url "http://127.0.0.1:$2/v1/bc/$CHAIN/rpc" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
pf_close() { [ -n "$_PF_PID" ] && kill "$_PF_PID" 2>/dev/null; _PF_PID=""; }
rpc()      { echo "http://127.0.0.1:${1}/v1/bc/$CHAIN/rpc"; }

# Read one field from one pod. Echoes empty on failure — callers must
# distinguish "empty" (probe failed) from a real value, never treat empty as 0.
pod_read() { # <pod> <port> <what: tip|root|ts> [blockNumber for root]
  local pod=$1 port=$2 what=$3 blk=${4:-latest} out=""
  pf_open "$pod" "$port" || { pf_close; return 1; }
  case "$what" in
    tip)  out=$(cast block-number --rpc-url "$(rpc "$port")" 2>/dev/null) ;;
    root) out=$(cast block "$blk" --rpc-url "$(rpc "$port")" --json 2>/dev/null | jq -r '.stateRoot // empty') ;;
    ts)   out=$(cast block latest --rpc-url "$(rpc "$port")" --json 2>/dev/null | jq -r '.timestamp // empty') ;;
  esac
  pf_close
  echo "$out"
}

# --- restart --------------------------------------------------------------
# `kubectl delete pod` is the WRONG tool for anything ConfigMap-driven.
# DigitalOcean's kubelet TTL-caches ConfigMaps, so a freshly recreated pod
# mounts the STALE copy and silently runs the old config — which is how a
# "rolled" fleet ends up split at an activation timestamp.
#
# startup.sh re-copies the mount into the PVC on every boot of the luxd child,
# so killing just that process picks up the new config with no kubelet involved.
restart_in_place() { # <pod>
  k exec "$1" -c "$CONTAINER" -- sh -c \
    'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = "luxd" ] && kill ${p#/proc/}; done' \
    >/dev/null 2>&1 || true
}

# A validator that misses a gossiped block while --skip-bootstrap=true (the
# default) can never re-fetch it and sits at that height FOREVER, while still
# gossiping "CERT assembled" — consensus liveness says nothing about whether its
# EVM moved. startup.sh honours a per-pod opt-in marker that flips
# --skip-bootstrap=false, writes a state-sync config, and self-consumes once the
# frontier is reached.
heal_stranded() { # <pod>
  k exec "$1" -c "$CONTAINER" -- sh -c 'touch /data/db/.allow-bootstrap' >/dev/null 2>&1 \
    || die "could not write .allow-bootstrap on $1"
  restart_in_place "$1"
}

# --- health ---------------------------------------------------------------
# DIRECTION, not inequality. A height that merely differs from a peer is
# ambiguous (nodes are read at different instants). A height that does NOT MOVE
# across two reads, while the fleet advances, is proof the node is stranded.
is_advancing() { # <pod> <port> [settle-seconds]
  local a b
  a=$(pod_read "$1" "$2" tip); [ -n "$a" ] || return 1
  sleep "${3:-30}"
  b=$(pod_read "$1" "$2" tip); [ -n "$b" ] || return 1
  [ "$b" -gt "$a" ]
}

wait_healthy() { # <pod> <port> [tries]
  local i; for i in $(seq 1 "${3:-20}"); do
    [ -n "$(pod_read "$1" "$2" tip 2>/dev/null)" ] && return 0
    sleep 10
  done
  return 1
}
