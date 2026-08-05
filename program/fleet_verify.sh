#!/usr/bin/env bash
# Is the fleet actually converged? Answers with evidence, not vibes.
#
#   ./fleet_verify.sh                      # lux mainnet
#   NS=lux-testnet ./fleet_verify.sh       # any other fleet
#   NS=zoo-mainnet STS=zood-mv CTX=do-sfo3-zoo-k8s ./fleet_verify.sh
#
# Three checks, in the order that makes a failure diagnosable:
#   1. every node answers            — a silent node is not a healthy node
#   2. every node is ADVANCING       — direction, not a single height
#   3. every node agrees on stateRoot at a COMMON height — the only real
#      "no fork" evidence. Equal tips prove nothing if the states differ.
#
# Exit 0 iff all three hold for all N.
set -uo pipefail
cd "$(dirname "$0")" && . ./fleet.sh

BASE_PORT=${BASE_PORT:-9740}
hdr "fleet $NS/$STS (N=$N, chain $CHAIN)"

declare -a TIPS=() NAMES=()
i=0; fail=0
for p in $(pods); do
  t=$(pod_read "$p" $((BASE_PORT+i)) tip)
  if [ -z "$t" ]; then say "$p  UNREACHABLE"; fail=1; else say "$p  tip=$t"; fi
  NAMES+=("$p"); TIPS+=("${t:-}")
  i=$((i+1))
done
[ "$fail" = 0 ] || die "at least one validator did not answer — fix that before reading anything else"

# 2. direction. Re-read after a settle; the fleet must have moved, and every
#    node must have moved with it. A node frozen while peers advance is the
#    stranded-validator signature.
hdr "advancing?"
sleep 30
i=0; stranded=()
for p in $(pods); do
  t2=$(pod_read "$p" $((BASE_PORT+i)) tip)
  before=${TIPS[$i]}
  if [ -n "$t2" ] && [ "$t2" -gt "$before" ]; then say "$p  $before -> $t2  moving"
  else say "$p  $before -> ${t2:-?}  FROZEN"; stranded+=("$p"); fi
  i=$((i+1))
done

# 3. same state at one common height. Use a height every node has definitely
#    accepted (min tip minus a margin) so this is not a race with block
#    production.
COMMON=$(printf '%s\n' "${TIPS[@]}" | sort -n | head -1)
COMMON=$((COMMON - 5))
hdr "stateRoot @ $COMMON"
i=0; roots=()
for p in $(pods); do
  r=$(pod_read "$p" $((BASE_PORT+i)) root "$COMMON")
  say "$p  ${r:-MISSING}"
  roots+=("${r:-MISSING}")
  i=$((i+1))
done
uniq_roots=$(printf '%s\n' "${roots[@]}" | sort -u | wc -l | tr -d ' ')

hdr "verdict"
if [ "${#stranded[@]}" -gt 0 ]; then
  say "STRANDED: ${stranded[*]}"
  say "heal with:  NS=$NS STS=$STS CTX=$CTX ./fleet_heal.sh ${stranded[*]}"
fi
[ "$uniq_roots" = 1 ] && say "state roots agree ($uniq_roots distinct)" || say "FORK: $uniq_roots distinct state roots"
if [ "${#stranded[@]}" = 0 ] && [ "$uniq_roots" = 1 ]; then
  say "CONVERGED $N/$N"; exit 0
fi
# A fleet at exactly the BFT quorum still finalizes, which is why this reads as
# healthy from the outside — and why it must be reported as a failure. One more
# node down is a halt.
exit 1
