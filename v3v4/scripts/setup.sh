#!/usr/bin/env bash
# Deterministic build inputs: ensure v4-core's dependency submodules are present
# at PINNED commits (the repo ships empty lib/ dirs). Idempotent. No network if
# already populated. Records the exact commits so bytecode is reproducible.
# POSIX/bash-3.2 compatible (macOS default shell) — no associative arrays.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
V4CORE="$(cd "$HERE/contracts/lib/v4-core" && pwd)"   # resolves the symlink

# name|url|pin  (pins matched to the deployable artifacts in this repo)
DEPS="
forge-std|https://github.com/foundry-rs/forge-std|bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
solmate|https://github.com/transmissions11/solmate|89365b880c4f3c786bdd453d4b8e8fe410344a69
openzeppelin-contracts|https://github.com/OpenZeppelin/openzeppelin-contracts|a22c8862f3fd80cd2bd5fab703b4e93ef3830040
"

clone_pin() { # dir url pin
  dir="$1"; url="$2"; pin="$3"
  if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
    echo "  $dir present ($(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    return 0
  fi
  echo "  cloning $url @ $pin"
  rm -rf "$dir"; git clone --quiet "$url" "$dir"; git -C "$dir" checkout --quiet "$pin"
}

echo "v4-core deps -> $V4CORE/lib"
echo "$DEPS" | while IFS='|' read -r name url pin; do
  [ -z "$name" ] && continue
  clone_pin "$V4CORE/lib/$name" "$url" "$pin"
done
clone_pin "$V4CORE/lib/forge-std/lib/ds-test" "https://github.com/dapphub/ds-test" "e282159d5170298eb2455a6c05280ab5a73a4ef0"

echo "python deps:"
python3 - <<'PY'
import importlib
for m in ("eth_abi", "eth_account", "eth_utils"):
    try:
        importlib.import_module(m); print(f"  {m} OK")
    except ImportError:
        print(f"  {m} MISSING -> pip3 install {m}")
PY
echo "setup done. Build the PoolManager artifact once: (cd $V4CORE && forge build src/PoolManager.sol)"
