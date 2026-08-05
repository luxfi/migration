#!/usr/bin/env bash
# Stage a C-Chain StateUpgrade into the GitOps source, then verify the fleet.
#
#   ./state_upgrade.sh ../manifests/96369-packed-slot5-repair.applied.json
#   FLEET=lux-testnet ./state_upgrade.sh <manifest> --lead 1800
#   ./state_upgrade.sh <manifest> --dry-run
#
# ─────────────────────────────────────────────────────────────────────────────
# READ THIS FIRST — `kubectl patch` DOES NOT WORK HERE, and the reason is subtle.
#
# The luxd-startup ConfigMap is owned by hanzo-cd (annotation
# apps.hanzo.ai/installation-id). A hand-patched ConfigMap survives only until
# the reconciler notices. On 2026-08-05 two StateUpgrades were applied by direct
# patch; the chain executed them and all five validators agreed — and then the
# ConfigMap was reverted to the repo, leaving a chain whose state its own config
# no longer described. Running nodes were fine (the upgrades had already fired),
# but any node replaying from genesis — a re-sync, an RLP import, a new
# validator — would have computed different state and forked.
#
# The source of truth is a Helm VALUES file, not the ConfigMap:
#   luxfi/universe  deploy/<fleet>/luxd.yaml  ->  configMaps[0].data['cchain-upgrade.json']
#
# And the push target is GitHub: git.hanzo.ai/luxfi/universe is a read-only
# PULL MIRROR ("Mirror Repository luxfi/universe is read-only"), even though
# hanzo-cd reads from the git.hanzo.ai URL. Push to GitHub, wait for the mirror.
#
# ⚠️ THE DANGEROUS STEP: syncing this app RECREATES ALL FIVE PODS AT ONCE. The
# StatefulSet carries a config checksum, so any ConfigMap change rolls the whole
# fleet simultaneously — not one at a time. That is the full-fleet restart the
# runbooks warn about. It recovered cleanly on 2026-08-05 (down ~2 min, back to
# 5/5 converged), but it is a real outage window, so this script stops before it
# and makes you run the sync deliberately.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")" && . ./fleet.sh

FLEET=${FLEET:-lux-mainnet}
UNIVERSE=${UNIVERSE:-$HOME/work/lux/universe}
VALUES="$UNIVERSE/deploy/$FLEET/luxd.yaml"
CDAPP=${CDAPP:-lux-$FLEET-luxd}
CDCTX=${CDCTX:-do-sfo3-hanzo-k8s}
CDNS=${CDNS:-hanzo-cd}

MANIFEST=""; LEAD=2700; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lead) LEAD=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) MANIFEST=$1; shift ;;
  esac
done
[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || die "usage: state_upgrade.sh <manifest.json> [--lead SECONDS] [--dry-run]"
[ -f "$VALUES" ] || die "values file not found: $VALUES"

PORT=${BASE_PORT:-9780}

hdr "0. activation, off the CHAIN clock"
HEAD_TS=$(pod_read "$STS-0" "$PORT" ts)
[ -n "$HEAD_TS" ] || die "cannot read chain head timestamp — is the fleet up?"
HEAD_TS=$((HEAD_TS)); ACT=$((HEAD_TS + LEAD))
say "chain head ts $HEAD_TS  +${LEAD}s  ->  $ACT"
say "(the chain clock lags wall clock; the upgrade fires on BLOCK ts, not on time passing)"

hdr "1. merge into the values file"
DRY=$DRY ACT=$ACT VALUES=$VALUES MANIFEST=$MANIFEST python3 - <<'PY' || die "merge refused"
import json, os, re, sys, yaml
V, M, ACT, DRY = os.environ['VALUES'], os.environ['MANIFEST'], int(os.environ['ACT']), os.environ['DRY'] == '1'
text = open(V).read()
m = re.search(r"(?m)^(\s*)cchain-upgrade\.json: ", text)
if not m: sys.exit('cchain-upgrade.json not found in values')
indent = m.group(1)
m2 = re.search(r"(?m)^%s[\w.\-]+: " % indent, text[m.end():])
end = m.end() + (m2.start() if m2 else len(text) - m.end())
cur = json.loads(yaml.safe_load(text[m.start():end])['cchain-upgrade.json'])
new = json.load(open(M))

# Only ever APPEND. Dropping a precompile entry is indistinguishable from a
# clean apply until the validators disagree on a state root, which is too late.
if cur['precompileUpgrades'] != new['precompileUpgrades']:
    sys.exit('precompileUpgrades differ between values and manifest — refusing')
if cur['networkUpgradeOverrides'] != new['networkUpgradeOverrides']:
    sys.exit('networkUpgradeOverrides differ — refusing')
n = len(cur['stateUpgrades'])
if new['stateUpgrades'][:n] != cur['stateUpgrades']:
    sys.exit('the manifest rewrites an already-applied stateUpgrade — refusing')
if len(new['stateUpgrades']) != n + 1:
    sys.exit(f'expected exactly one new stateUpgrade, got {len(new["stateUpgrades"]) - n}')

up = new['stateUpgrades'][-1]
up['blockTimestamp'] = ACT
print(f'  appending stateUpgrade #{n+1}: ts={ACT} accounts={len(up["accounts"])}')
# A left-padded address written into a PACKED slot slides the owner one byte and
# clobbers whatever shares the word. That put 6 tokens at decimals=189 and
# ownership on a void address, and slot-readback verification passed throughout.
for a, cfg in up['accounts'].items():
    for slot, val in (cfg.get('storage') or {}).items():
        v = val.lower().replace('0x', '')
        if len(v) - len(v.lstrip('0')) == 24:
            print(f'  NOTE {a[:10]}… slot …{slot[-4:]} is a bare left-padded address.')
            print( '       If that slot is PACKED, this write is WRONG — check the source.')
if DRY:
    print('  (dry run — values file untouched)'); sys.exit(0)
cur['stateUpgrades'] = new['stateUpgrades']
blk = yaml.safe_dump({'cchain-upgrade.json': json.dumps(cur, separators=(', ', ': '))},
                     default_flow_style=False, width=100)
blk = ''.join(indent + l + '\n' for l in blk.rstrip('\n').split('\n'))
open(V, 'w').write(text[:m.start()] + blk + text[end:])
# prove the file still parses and still holds everything
d = yaml.safe_load(open(V))
c = json.loads(d['configMaps'][0]['data']['cchain-upgrade.json'])
print(f'  values now: stateUpgrades={len(c["stateUpgrades"])} precompiles={len(c["precompileUpgrades"])}')
PY

[ "$DRY" = 1 ] && { hdr "dry run complete"; exit 0; }

hdr "2. commit + push (GitHub is the write side)"
say "cd $UNIVERSE"
say "git add deploy/$FLEET/luxd.yaml && git commit && git push origin main"
say ""
say "git.hanzo.ai/luxfi/universe is a READ-ONLY MIRROR — pushing there fails with"
say "'Mirror Repository ... is read-only'. Push to GitHub; the mirror pulls it."
say "Confirm with:  git ls-remote tenant | awk '\$2==\"refs/heads/main\"{print \$1}'"

hdr "3. sync — THIS RECREATES ALL $N PODS AT ONCE"
say "hanzo-cd auto-sync is OFF for this app; nothing happens until you trigger it."
say "The StatefulSet carries a config checksum, so the ConfigMap change rolls the"
say "WHOLE fleet simultaneously. Expect ~2 min with no RPC. Do it deliberately:"
say ""
say "  kubectl --context $CDCTX -n $CDNS patch application $CDAPP --type merge -p '{"
say "    \"operation\": {\"sync\": {\"revisions\": [\"<chartVer>\", \"<gitSha>\"],"
say "      \"syncOptions\": [\"ServerSideApply=true\"]}}}'"
say ""
say "Then: ./fleet_verify.sh   (and ./fleet_heal.sh <pod> for anything stranded)"

hdr "4. activation needs a BLOCK"
say "A future-ts upgrade does not self-apply when wall clock passes it: the chain"
say "is demand-driven and builds no empty blocks. Keep traffic flowing, or send a"
say "0-value tx, until head ts >= $ACT."
say ""
say "Then verify through the CONTRACT, never the slot:"
say "  cast call <addr> 'owner()(address)'  --rpc-url <one pinned node>"
say "  cast call <addr> 'decimals()(uint8)' --rpc-url <one pinned node>"
say "with an account the upgrade did NOT touch as a control, so you can tell"
say "'my write was wrong' from 'my probe was wrong'."
