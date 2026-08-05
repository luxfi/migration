#!/usr/bin/env bash
# Rejoin stranded validators, one at a time.
#
#   ./fleet_heal.sh luxd-4              # heal named pods
#   NS=lux-testnet ./fleet_heal.sh luxd-2 luxd-3
#
# A validator that missed a gossiped block under --skip-bootstrap=true (the
# default) never re-fetches it and freezes at that height, while still logging
# "quorum: CERT assembled ... sentToPeers=4". It looks alive from every angle
# except the one that matters. startup.sh honours /data/db/.allow-bootstrap as a
# per-pod opt-in that flips --skip-bootstrap=false and self-consumes once the
# frontier is reached.
#
# ONE AT A TIME is not politeness. Quorum is 4-of-5; a fleet with one node
# already stranded has zero margin, and taking a second one down halts the chain.
set -uo pipefail
cd "$(dirname "$0")" && . ./fleet.sh

[ $# -gt 0 ] || die "usage: fleet_heal.sh <pod> [pod...]"
PORT=${BASE_PORT:-9760}

for pod in "$@"; do
  hdr "healing $pod"
  before=$(pod_read "$pod" "$PORT" tip)
  say "tip before: ${before:-unreachable}"
  heal_stranded "$pod"
  wait_healthy "$pod" "$PORT" 24 || die "$pod never came back — stop here, do NOT touch another node"
  if is_advancing "$pod" "$PORT" 45; then
    say "tip after:  $(pod_read "$pod" "$PORT" tip)  advancing"
  else
    die "$pod answers but is still frozen. Do not heal another node; investigate this one
     (check its image matches the fleet, and read its logs for the bootstrap path)."
  fi
done

hdr "done"
say "re-run fleet_verify.sh to confirm state roots agree across all $N"
