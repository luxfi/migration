#!/usr/bin/env bash
# Shared helpers for the Lux treasury/governance e2e harnesses (fork + local 1337).
# Sourced by fork_e2e.sh and local1337_e2e.sh. No mainnet writes ever happen here —
# every function takes an explicit RPC and the harnesses only ever pass a local anvil.
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
OWNER=0x9011E888251AB053B7bD1cdB598Db4f9DEd94714      # exposed treasury key (0x9011)
SENTINEL=0x0000000000000000000000000000000000000001     # Safe owner-linked-list head
ZERO=0x0000000000000000000000000000000000000000

PASS=0; FAILED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
hdr()  { printf '\n=== %s ===\n' "$*"; }
lux()  { python3 -c "print($1/10**18)"; }          # wei -> LUX float
wei()  { python3 -c "print(int($1*10**18))"; }      # LUX -> wei int

# assert helpers (record pass/fail, never exit — harness decides at the end)
assert_eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
assert_true(){ [ "$2" = "true" ] && ok "$1" || bad "$1: not true ($2)"; }
# numeric (python int compare to dodge bash 64-bit overflow on wei)
assert_ge()  { python3 -c "import sys; sys.exit(0 if $2>=$3 else 1)" && ok "$1" || bad "$1: $2 < $3"; }
assert_le()  { python3 -c "import sys; sys.exit(0 if $2<=$3 else 1)" && ok "$1" || bad "$1: $2 > $3"; }

# Refuse to operate against anything but a local anvil (belt-and-suspenders: the
# harnesses must only ever drive a fork/local node, never a real validator).
assert_local() {
  case "$1" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "ABORT: RPC '$1' is not a local anvil"; exit 1;; esac
  cast rpc anvil_nodeInfo --rpc-url "$1" >/dev/null 2>&1 || { echo "ABORT: RPC '$1' is not anvil (no anvil_nodeInfo)"; exit 1; }
}

wait_ready() { # <rpc>
  local i; for i in $(seq 1 60); do cast chain-id --rpc-url "$1" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "ABORT: anvil at $1 never became ready"; exit 1
}

# canonical 1/1 Safe ECDSA exec: signer signs the safeTxHash, sender broadcasts.
exec_safe() { # <rpc> <safe> <to> <val> <data> <signerKey> <senderKey>  -> rc of cast send
  local rpc="$1" safe="$2" to="$3" val="$4" data="$5" sk="$6" tk="$7" n h sig
  n=$(cast call "$safe" 'nonce()(uint256)' --rpc-url "$rpc")
  h=$(cast call "$safe" "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
        "$to" "$val" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$n" --rpc-url "$rpc")
  sig=$(cast wallet sign --private-key "$sk" --no-hash "$h")
  cast send --rpc-url "$rpc" --private-key "$tk" "$safe" \
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
    "$to" "$val" "$data" 0 0 0 0 "$ZERO" "$ZERO" "$sig" >/dev/null 2>&1
}

# After an owner rotation: owners==[newOwner], 0x9011 no longer an owner.
assert_rotated() { # <label> <rpc> <safe> <newOwner>
  local owners isnew is9011
  owners=$(cast call "$3" 'getOwners()(address[])' --rpc-url "$2")
  isnew=$(cast call "$3" 'isOwner(address)(bool)' "$4" --rpc-url "$2")
  is9011=$(cast call "$3" 'isOwner(address)(bool)' "$OWNER" --rpc-url "$2")
  assert_eq "$1 owners==[fresh]" "$owners" "[$4]"
  assert_true "$1 isOwner(fresh)" "$isnew"
  assert_eq "$1 isOwner(0x9011)==false" "$is9011" "false"
}

# Fresh owner CAN move funds out (recoverability) — proves control post-rotation.
prove_control() { # <label> <rpc> <safe> <ownerKey> <dest>
  local before after moved
  before=$(cast balance "$5" --rpc-url "$2")
  exec_safe "$2" "$3" "$5" 1000000000000000000 "0x" "$4" "$4"   # move 1 LUX out
  after=$(cast balance "$5" --rpc-url "$2")
  moved=$(python3 -c "print($after-$before)")
  assert_eq "$1 fresh owner moved 1 LUX out" "$moved" "1000000000000000000"
}

# Exposed 0x9011 CANNOT move funds (the security close-out): a 0x9011-signed
# execTransaction must REVERT (Safe GS026: invalid owner / signature).
prove_locked_out() { # <label> <rpc> <safe> <exposedKey> <dest>
  exec_safe "$2" "$3" "$5" 1000000000000000000 "0x" "$4" "$4"
  [ $? -ne 0 ] && ok "$1 exposed 0x9011 execTransaction REVERTED (GS026 — locked out)" \
                || bad "$1 exposed 0x9011 STILL moved funds — lockout failed"
}

summary() { # <name>
  hdr "$1 RESULT"
  printf 'asserts: %d passed, %d failed\n' "$PASS" "$FAILED"
  [ "$FAILED" -eq 0 ] && { printf '\033[32m*** %s: PASS ***\033[0m\n' "$1"; return 0; } \
                       || { printf '\033[31m*** %s: FAIL ***\033[0m\n' "$1"; return 1; }
}
