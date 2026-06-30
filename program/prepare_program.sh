#!/usr/bin/env bash
# Lux treasury + governance program — PREPARE/EXECUTE gated. CANONICAL OPERATIONAL COPY.
# Staged in the PRIVATE ~/work/lux/migration repo (standard/ is public — no secret-reading
# operational scripts there). Proven e2e on a mainnet fork + local 1337 BEFORE any live run.
#
# Two 1/1 Safes (owner 0x9011): lux-dao (DAO funds) + lux-zpriv (team/personal + residual).
# Phases (each gated by EXECUTE=yes; mainnet money/ownership = explicit per-step go):
#   PHASE=plan      (default) print the full plan with LIVE balances + predicted addrs
#   PHASE=deploy    deploy both Safes (delegates deploy_safes.sh)
#   PHASE=sweep     0x9011 split (DAO_ALLOC -> DAO Safe, residual -> Z Safe) + EOA sweeps
#   PHASE=ownership transfer on-chain Ownable/admin handles -> DAO Safe
#   PHASE=upgrade   rotate each Safe owner 0x9011 -> final owner (KEY ROTATION CLOSE-OUT)
# Env:
#   DAO_ALLOC      LUX to DAO Safe from 0x9011 (tokenomics split: 1000000000000 = 1T)
#   RESERVE        LUX kept in 0x9011 for gas (default 1000)
#   DAO_FINAL_OWNER / Z_FINAL_OWNER   for upgrade (FRESH KMS key for Z; DAO governance for DAO)
#   EXECUTE=yes    broadcast (else plan-only)
#   EXPECT_CID     required chainId guard (default 96369 mainnet; 1337 for localnet)
#   SECRET_NS      namespace holding the lux-deployer secret (default lux-mainnet)
#   REC            deployments records dir (default <STD_DIR>/deployments)
#   STD_DIR        standard repo (Safe bytecode + records), default /Users/z/work/lux/standard
# Signing: lux-deployer secret / mnemonic (KMS-backed), NEVER printed. Keys blanked after use.
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="${1:?usage: prepare_program.sh <rpc>}"
PHASE="${PHASE:-plan}"; EXECUTE="${EXECUTE:-no}"
RESERVE="${RESERVE:-1000}"; DAO_ALLOC="${DAO_ALLOC:-}"
EXPECT_CID="${EXPECT_CID:-96369}"; SECRET_NS="${SECRET_NS:-lux-mainnet}"
STD_DIR="${STD_DIR:-/Users/z/work/lux/standard}"; REC="${REC:-$STD_DIR/deployments}"
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714
SENTINEL=0x0000000000000000000000000000000000000001
ZERO=0x0000000000000000000000000000000000000000
e18() { python3 -c "print(int($1*10**18))"; }
fromwei() { python3 -c "print($1/10**18)"; }

CID=$(cast chain-id --rpc-url "$RPC"); [ "$CID" = "$EXPECT_CID" ] || { echo "REFUSE: chainId=$CID != EXPECT_CID=$EXPECT_CID"; exit 1; }
# A fork/local is anvil (responds to anvil_nodeInfo); a real luxd node is NOT. This is a
# property of the NODE, not the URL — so a mainnet luxd reached via 127.0.0.1 port-forward is
# correctly classed live (loud warning fires), while an anvil fork is correctly classed fork.
IS_FORK=no; cast rpc anvil_nodeInfo --rpc-url "$RPC" >/dev/null 2>&1 && IS_FORK=yes
[ "$EXECUTE" = "yes" ] && [ "$IS_FORK" = "no" ] && [ "$PHASE" != "deploy" ] && {
  echo "*** LIVE EXECUTE: $PHASE on chainId $CID — REAL MONEY/OWNERSHIP, IRREVERSIBLE ***"; }

DAO_SAFE=$(jq -r .safe "$REC/lux-dao/$CID.json"   2>/dev/null)
Z_SAFE=$(jq   -r .safe "$REC/lux-zpriv/$CID.json" 2>/dev/null)

# funded EOA set: idx-path  address  class(dao|z)
read -r -d '' EOAS <<'TSV' || true
std:1	0xEAbCC110fAcBfebabC66Ad6f9E7B67288e720B59	z
std:2	0x8d5081153aE1cfb41f5c932fe0b6Beb7E159cF84	z
std:6	0xf7f52257a6143cE6BbD12A98eF2B0a3d0C648079	z
std:7	0xCA92ad0C91bd8DE640B9dAFfEB338ac908725142	z
std:8	0xB5B325df519eB58B7223d85aaeac8b56aB05f3d6	z
gen:0	0xf785FA547ae9CcF3D3ca5362762A347a4c41051A	z
gen:1	0xf4b5be7a6deA583dA4CddCDa4D9B3afd51684b6e	z
gen:2	0x202335dd1c21C9B90277F8BcA78Db98db0bBc293	z
TSV

bal()   { cast balance "$1" --rpc-url "$RPC"; }
nonceof(){ cast nonce  "$1" --rpc-url "$RPC"; }

print_plan() {
  local mbal mnonce
  mbal=$(bal "$OWNER"); mnonce=$(nonceof "$OWNER")
  cat <<H
================ LUX TREASURY + GOVERNANCE PROGRAM (chainId $CID) ================
deployer/owner : $OWNER   nonce=$mnonce
Safes          : lux-dao=$DAO_SAFE   lux-zpriv=$Z_SAFE
0x9011 balance : $mbal wei (~$(fromwei "$mbal") LUX)   reserve kept: $RESERVE LUX

PHASE deploy  — 2 Safes (SafeL2/Factory/Handler/MultiSend + 2 proxies). 1/1 owner 0x9011, v1.5.0.
PHASE sweep   — 0x9011 split: DAO_ALLOC=${DAO_ALLOC:-<UNSET — required>} LUX -> DAO Safe ;
                residual -> Z Safe ; keep $RESERVE LUX gas. Then EOA sweeps:
H
  while IFS=$'\t' read -r idx addr cls; do
    [ -z "$addr" ] && continue
    local b lux safe; b=$(bal "$addr"); lux=$(fromwei "$b")
    [ "$cls" = "dao" ] && safe="$DAO_SAFE" || safe="$Z_SAFE"
    printf "    %-6s %-44s %18s LUX -> %s Safe\n" "$idx" "$addr" "$lux" "$cls"
  done <<< "$EOAS"
  cat <<H
PHASE ownership — on-chain Ownable/admin handles -> DAO Safe (LIVE AMM owned by 0xce15, key
                  unlocated -> BLOCKED; calldata emitted for when key located / redeployed).
PHASE upgrade   — rotate each Safe owner 0x9011 -> final owner (LAST; after this 0x9011 is
                  locked out): Z Safe -> Z_FINAL_OWNER (FRESH KMS key) ; DAO Safe ->
                  DAO_FINAL_OWNER (DAO governance). Fork-proven: fresh controls, 0x9011 reverts.
=================================================================================
[plan only — set PHASE=<deploy|sweep|ownership|upgrade> EXECUTE=yes to act]
H
}

# canonical 1/1 ECDSA Safe exec (signerKey signs safeTxHash, senderKey broadcasts)
exec_safe() { local safe="$1" to="$2" val="$3" data="$4" sk="$5" tk="$6" n h sig
  n=$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$RPC")
  h=$(cast call "$safe" "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" "$to" "$val" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$n" --rpc-url "$RPC")
  sig=$(cast wallet sign --private-key "$sk" --no-hash "$h")
  cast send --rpc-url "$RPC" --private-key "$tk" "$safe" \
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
    "$to" "$val" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$sig"
}

read_key()      { kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d; }
read_mnemonic() { kubectl --context do-sfo3-lux-k8s get secret lux-deployer -n "$SECRET_NS" -o jsonpath='{.data.LUX_MNEMONIC}'    | base64 -d; }

case "$PHASE" in
  plan) print_plan ;;
  deploy)
    [ "$EXECUTE" = "yes" ] || { echo "deploy is gated: set EXECUTE=yes"; exit 0; }
    SECRET_NS="$SECRET_NS" REC="$REC" STD_DIR="$STD_DIR" \
      bash "$(dirname "$0")/deploy_safes.sh" "$RPC" "lux-$CID" ;;
  sweep)
    [ "$EXECUTE" = "yes" ] || { print_plan; exit 0; }
    [ -n "$DAO_ALLOC" ] || { echo "REFUSE: set DAO_ALLOC=<LUX to DAO Safe>"; exit 1; }
    [ "$(cast codesize "$DAO_SAFE" --rpc-url "$RPC")" != "0" ] || { echo "REFUSE: DAO Safe not deployed"; exit 1; }
    MK=$(read_key); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
    M=$(read_mnemonic)
    echo ">>> sweep DAO_ALLOC=$DAO_ALLOC LUX -> DAO Safe"
    cast send --rpc-url "$RPC" --private-key "$MK" "$DAO_SAFE" --value "$(e18 "$DAO_ALLOC")"
    MBAL=$(bal "$OWNER"); RESIDUAL=$(python3 -c "print($MBAL-$(e18 "$RESERVE"))")
    echo ">>> sweep residual $(fromwei "$RESIDUAL") LUX -> Z Safe (keep $RESERVE LUX gas)"
    cast send --rpc-url "$RPC" --private-key "$MK" "$Z_SAFE" --value "$RESIDUAL"
    while IFS=$'\t' read -r idx addr cls; do
      [ -z "$addr" ] && continue
      i=${idx#*:}; path=${idx%%:*}
      if [ "$path" = "std" ]; then k=$(cast wallet private-key --mnemonic "$M" --mnemonic-index "$i" 2>/dev/null); else k=$(cast wallet private-key --mnemonic "$M" --mnemonic-derivation-path "m/44'/9000'/0'/0/$i" 2>/dev/null); fi
      case "$k" in 0x*) ;; *) k="0x$k";; esac
      b=$(bal "$addr"); mv=$(python3 -c "v=$b-$(e18 0.5); print(v if v>0 else '')")   # keep 0.5 LUX gas
      [ -n "$mv" ] || { echo "skip $idx (dust)"; continue; }
      safe="$Z_SAFE"; [ "$cls" = "dao" ] && safe="$DAO_SAFE"
      echo ">>> sweep $idx $(fromwei "$mv") LUX -> $cls Safe"
      cast send --rpc-url "$RPC" --private-key "$k" "$safe" --value "$mv"; k=""
    done <<< "$EOAS"
    M=""; MK=""
    echo "DAO Safe=$(fromwei $(bal $DAO_SAFE)) LUX   Z Safe=$(fromwei $(bal $Z_SAFE)) LUX   0x9011=$(fromwei $(bal $OWNER)) LUX" ;;
  ownership)
    echo "PHASE ownership: on-chain handles are 0xce15-owned (key unlocated) -> BLOCKED."
    echo "calldata ready (apply once 0xce15 key located or contracts redeployed under 0x9011):"
    echo "  V3Factory.setOwner:        $(cast calldata 'setOwner(address)' $DAO_SAFE)"
    echo "  V2Factory.setFeeToSetter:  $(cast calldata 'setFeeToSetter(address)' $DAO_SAFE)"
    echo "  Token.transferOwnership:   $(cast calldata 'transferOwnership(address)' $DAO_SAFE)" ;;
  upgrade)
    [ "$EXECUTE" = "yes" ] || { echo "upgrade gated: set EXECUTE=yes + DAO_FINAL_OWNER + Z_FINAL_OWNER"; exit 0; }
    : "${Z_FINAL_OWNER:?set Z_FINAL_OWNER (FRESH KMS key)}"; : "${DAO_FINAL_OWNER:?set DAO_FINAL_OWNER (DAO governance)}"
    MK=$(read_key); case "$MK" in 0x*) ;; *) MK="0x$MK";; esac
    echo ">>> rotate Z Safe owner 0x9011 -> $Z_FINAL_OWNER"
    exec_safe "$Z_SAFE"  "$Z_SAFE"  0 "$(cast calldata 'swapOwner(address,address,address)' $SENTINEL $OWNER $Z_FINAL_OWNER)" "$MK" "$MK"
    echo ">>> rotate DAO Safe owner 0x9011 -> $DAO_FINAL_OWNER"
    exec_safe "$DAO_SAFE" "$DAO_SAFE" 0 "$(cast calldata 'swapOwner(address,address,address)' $SENTINEL $OWNER $DAO_FINAL_OWNER)" "$MK" "$MK"
    MK=""
    echo "Z Safe owners=$(cast call $Z_SAFE 'getOwners()(address[])' --rpc-url $RPC)  DAO Safe owners=$(cast call $DAO_SAFE 'getOwners()(address[])' --rpc-url $RPC)" ;;
  *) echo "unknown PHASE=$PHASE"; exit 1 ;;
esac
