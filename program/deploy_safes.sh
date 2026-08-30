#!/usr/bin/env bash
# Deploy the program's TWO canonical OSS Safes (v1.5.0 SafeL2) on a Lux C-Chain network,
# both 1/1 owned by SAFE_OWNER (0x9011 by default) so each can later be rolled to its final
# owner in a single execTransaction:
#   1. lux-dao   — DAO Safe   (receives DAO funds; final owner = DAO governance)
#   2. lux-zpriv — Z Safe      (receives team P/X + 0x9011 residual; final owner = Z KMS key)
# Shared Safe infra (SafeL2 singleton + ProxyFactory + FallbackHandler + MultiSendCallOnly)
# is deployed ONCE, then two proxies are created with distinct CREATE2 salts.
#
# Usage: deploy_safes.sh <rpc_url> <network_label>
# Env:   SAFE_OWNER (default 0x9011), SAFE_THRESHOLD (default 1),
#        SECRET_NS (namespace of lux-deployer secret, default lux-mainnet),
#        STD_DIR (Safe bytecode + records root, default /Users/z/work/lux/standard),
#        OUT (bytecode dir, default <STD_DIR>/out), REC (records dir, default <STD_DIR>/deployments)
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${1:?usage: deploy_safes.sh <rpc_url> <network_label>}"; LABELNET="${2:?usage: deploy_safes.sh <rpc_url> <network_label>}"
OWNER="${SAFE_OWNER:-0x9011E888251AB053B7bD1cdB598Db4f9DEd94714}"
THRESHOLD="${SAFE_THRESHOLD:-1}"
SECRET_NS="${SECRET_NS:-lux-mainnet}"
STD_DIR="${STD_DIR:-/Users/z/work/lux/standard}"
OUT="${OUT:-$STD_DIR/out}"; REC="${REC:-$STD_DIR/deployments}"
ZERO=0x0000000000000000000000000000000000000000

# The signer, from whichever store is actually reachable. `LUX_PRIVATE_KEY` in the
# environment wins, so this runs against a local devnet, from CI, or from a KMS
# read without editing the script. The kubectl read stays as the last resort; it
# is no longer the only path, because a cluster outage used to take the whole
# deployment with it.
if [ -n "${LUX_PRIVATE_KEY:-}" ]; then
  KEY="$LUX_PRIVATE_KEY"
elif [ -n "${KUBE_CONTEXT:-}" ] || kubectl --context "${KUBE_CONTEXT:-do-sfo3-lux-k8s}" version >/dev/null 2>&1; then
  KEY=$(kubectl --context "${KUBE_CONTEXT:-do-sfo3-lux-k8s}" get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d)
else
  echo "no signer: set LUX_PRIVATE_KEY, or make a cluster holding secret/lux-deployer reachable" >&2
  exit 2
fi
case "$KEY" in 0x*) ;; *) KEY="0x$KEY";; esac
CHAINID=$(cast chain-id --rpc-url "$RPC")
FROM=$(cast wallet address --private-key "$KEY")
[ "$(echo "$FROM" | tr 'A-Z' 'a-z')" = "$(echo "$OWNER" | tr 'A-Z' 'a-z')" ] || \
  echo "NOTE: deployer $FROM != owner $OWNER (deploying anyway, owner set in setup)"
echo "=== deploy_safes: chainId=$CHAINID deployer=$FROM owner=$OWNER threshold=$THRESHOLD ==="

bc() { jq -r '.bytecode.object' "$OUT/$1.sol/$1.json"; }
create() { local addr; addr=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$(bc "$1")" | jq -r '.contractAddress'); [ -n "$addr" ] && [ "$addr" != "null" ] || { echo "FAIL deploy $1" >&2; exit 1; }; echo "$addr"; }

# ---- shared Safe infra (once) ----
# Infra is deployed once and then reused. Supplying the four addresses makes a
# re-run resume instead of paying for a second copy — the proxies are the part
# that carries the salt, and they are cheap. A run that dies after the infra and
# before the proxies used to strand four contracts and start over.
SINGLETON="${SINGLETON:-$(create SafeL2)}";                     echo "SafeL2 singleton      : $SINGLETON"
FACTORY="${FACTORY:-$(create SafeProxyFactory)}";               echo "SafeProxyFactory      : $FACTORY"
HANDLER="${HANDLER:-$(create CompatibilityFallbackHandler)}";   echo "FallbackHandler       : $HANDLER"
MULTISEND="${MULTISEND:-$(create MultiSendCallOnly)}";          echo "MultiSendCallOnly     : $MULTISEND"

SETUP=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
  "[$OWNER]" "$THRESHOLD" "$ZERO" "0x" "$HANDLER" "$ZERO" 0 "$ZERO")

deploy_safe() { # $1=label $2=salt_string -> records <REC>/<label>/<chainid>.json
  local label="$1" saltstr="$2" salt rcpt topic safe code owners thr isown ver dir
  salt=$(cast keccak "$saltstr")
  rcpt=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json \
    "$FACTORY" "createProxyWithNonce(address,bytes,uint256)" "$SINGLETON" "$SETUP" "$salt")
  topic=$(echo "$rcpt" | jq -r --arg f "$(echo "$FACTORY" | tr 'A-Z' 'a-z')" '.logs[] | select((.address|ascii_downcase)==$f) | .topics[1]' | head -1)
  safe=$(cast to-checksum "0x${topic: -40}")
  code=$(cast codesize "$safe" --rpc-url "$RPC")
  owners=$(cast call "$safe" "getOwners()(address[])" --rpc-url "$RPC")
  thr=$(cast call "$safe" "getThreshold()(uint256)" --rpc-url "$RPC")
  isown=$(cast call "$safe" "isOwner(address)(bool)" "$OWNER" --rpc-url "$RPC")
  ver=$(cast call "$safe" "VERSION()(string)" --rpc-url "$RPC" | tr -d '"')
  echo "--- $label : $safe  code=$code owners=$owners threshold=$thr isOwner=$isown VERSION=$ver"
  [ "$code" != "0" ] || { echo "VERIFY FAIL $label: no code"; exit 1; }
  [ "$thr" = "$THRESHOLD" ] || { echo "VERIFY FAIL $label: threshold"; exit 1; }
  [ "$isown" = "true" ] || { echo "VERIFY FAIL $label: owner"; exit 1; }
  dir="$REC/$label"; mkdir -p "$dir"
  cat > "$dir/$CHAINID.json" <<JSON
{"chainId":$CHAINID,"network":"$LABELNET","label":"$label","safe":"$safe","salt":"$salt","saltString":"$saltstr","singleton":"$SINGLETON","factory":"$FACTORY","fallbackHandler":"$HANDLER","multiSendCallOnly":"$MULTISEND","owner":"$OWNER","threshold":$THRESHOLD,"version":"$ver"}
JSON
  echo "    recorded -> $dir/$CHAINID.json"
}

deploy_safe "lux-dao"   "lux.dao.safe.v1"
deploy_safe "lux-zpriv" "lux.z.private.safe.v1"
echo "=== done: 2 safes on chainId=$CHAINID ==="
KEY=""
