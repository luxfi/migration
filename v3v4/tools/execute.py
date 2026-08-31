#!/usr/bin/env python3
"""
Staged, idempotent Lux V3->V4 liquidity migration executor.

DRY-RUN by default (prints the exact staged plan, simulates every independent
step, writes state.json). Broadcasts to ALL 5 validator RPCs at >= GAS_PRICE_GWEI
only when EXECUTE=1 (the mainnet mempool does not gossip, so each tx is pushed to
every validator; flat-baseFee txs never mine).

Every decision derives from LIVE chain state (nonce, code, extsload pool/position
slots, NPM positions, ERC20 balances/allowances) -> re-running after any point,
including a full network RLP reboot, resumes exactly where it left off.

NOTHING here is Lux-network-migration (Quasar) related; this is the DEX LP move.

Env (all optional; the Makefile wires the operator-tunable ones):
  EXECUTE=1            broadcast for real (default 0 = dry-run)
  LUX_PRIVATE_KEY      signer key (execute mode only; from k8s secret lux-deployer)
  GAS_PRICE_GWEI=250   legacy gasPrice; must exceed baseFee or txs never mine (preflight aborts)
  SLIPPAGE_BPS=100     min-out / max-in tolerance (1%)
  ONESIDED_BAND_TICKS=6900   width of the one-sided resting-bid ladder
  ORACLE_TICK_BAND=2000      max |oracleTick - expected_tick| for a one-sided bid (~+/-22%)
  ONESIDED_MAX_WLUX=5000000e18  hard cap on WLUX deposited into any one one-sided pool
  FINALIZE=1           opt-in: after all adds, zero LD approvals + transferOwnership LD->DAO Safe.
                       Dry-run always PREVIEWS it; execute performs it only when =1.
  KCTX,KNS             kube context / namespace
  RPC_PODS=luxd-0,..,luxd-4  the validators every tx is broadcast to (mainnet has no gossip)
  ORACLE=oracle.json   per one-sided base an OBJECT {"price":<baseUSD>,"expected_tick":<2nd-op tick>},
                       plus "LUX_USD". expected_tick is a SECOND operator's independent anchor.
"""
import os, sys, json, subprocess, time
from eth_abi import encode as abi_encode, decode as abi_decode
from eth_utils import keccak, to_checksum_address
from eth_account import Account

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from v4math import (get_sqrt_ratio_at_tick, get_tick_at_sqrt_price, sqrt_price_x96_from_price,
                    align_tick, liquidity_for_amount0, liquidity_for_amount1, get_amounts_for_liquidity)

# ---- config -----------------------------------------------------------------
CHAIN_ID = 96369
KCTX = os.environ.get("KCTX", "do-sfo3-lux-k8s")
KNS = os.environ.get("KNS", "lux-mainnet")
RPC_PODS = os.environ.get("RPC_PODS", "luxd-0,luxd-1,luxd-2,luxd-3,luxd-4").split(",")
READ_POD = RPC_PODS[1]  # reads hit one validator; every signed tx still fans out to all of RPC_PODS
GAS_PRICE_WEI = int(float(os.environ.get("GAS_PRICE_GWEI", "250")) * 1e9)
EXECUTE = os.environ.get("EXECUTE", "0") == "1"
SLIPPAGE_BPS = int(os.environ.get("SLIPPAGE_BPS", "100"))
ONESIDED_BAND_TICKS = int(os.environ.get("ONESIDED_BAND_TICKS", "6900"))
# one-sided oracle safety: reject if the oracle-derived tick strays > this many ticks
# from the operator's independently-recorded expected_tick (2000 ticks ~= +/-22% price).
ORACLE_TICK_BAND = int(os.environ.get("ORACLE_TICK_BAND", "2000"))
# hard ceiling on WLUX put into any single one-sided pool (a bug can't scale the bid).
ONESIDED_MAX_WLUX = int(float(os.environ.get("ONESIDED_MAX_WLUX", str(5_000_000 * 10**18))))
# opt-in (gated): after all adds, zero LD approvals + hand LD ownership to the DAO Safe.
FINALIZE = os.environ.get("FINALIZE", "0") == "1"
ORACLE = os.environ.get("ORACLE", os.path.join(HERE, "oracle.json"))
PLAN = os.path.join(HERE, "plan.json")
STATE = os.path.join(HERE, "state.json")
OWNER = "0x9011E888251AB053B7bD1cdB598Db4f9DED94714"
DAO_SAFE = "0x51284dc2133e8d3a8e213dca6a6fa768cfdfcce2"
NPM = "0x7a4C48B9dae0b7c396569b34042fcA604150Ee28"
# Deployable bytecode, from the canonical build locations. v4-core is reached via the
# contracts/lib/v4-core symlink, so there is no absolute ~/work path to keep in sync.
V4CORE_ART = os.path.join(HERE, "..", "contracts", "lib", "v4-core", "out",
                          "PoolManager.sol", "PoolManager.json")
LD_ART = os.path.join(HERE, "..", "contracts", "out",
                      "LiquidityDeployer.sol", "LiquidityDeployer.json")
DEADLINE = 1 << 63
U128MAX = (1 << 128) - 1

# ---- rpc via kubectl exec (works without port-forward) ----------------------
_id = [0]
def _kexec(pod, body):
    p = subprocess.run(["kubectl", "--context", KCTX, "-n", KNS, "exec", "-i", pod, "--",
                        "curl", "-s", "-X", "POST", "http://localhost:9630/v1/chain/C/rpc",
                        "-H", "content-type:application/json", "-d", "@-"],
                       input=body, capture_output=True, timeout=200)
    if p.returncode != 0:
        raise RuntimeError(f"kubectl exec {pod}: {p.stderr.decode()[:200]}")
    return json.loads(p.stdout)

def rpc(method, params, pod=None):
    _id[0] += 1
    r = _kexec(pod or READ_POD, json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode())
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]

def sel(sig):
    return keccak(text=sig)[:4]

def call_raw(to, data_hex, frm=OWNER):
    return rpc("eth_call", [{"to": to, "from": frm, "data": data_hex}, "latest"])

def estimate(to, data_hex, value=0, create=False):
    tx = {"from": OWNER, "data": data_hex, "value": hex(value)}
    if not create:
        tx["to"] = to_checksum_address(to)
    return int(rpc("eth_estimateGas", [tx]), 16)

# ---- abi encoders -----------------------------------------------------------
AP_TYPE = "((address,address,uint24,int24,address),int24,int24,uint128,bytes32,address,uint128,uint128)"

def _pk_tuple(pk):
    return (pk['currency0'], pk['currency1'], pk['fee'], pk['tickSpacing'], pk['hooks'])

def enc_decrease(tid, liq, a0min, a1min):
    return "0x" + sel("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))").hex() \
        + abi_encode(["(uint256,uint128,uint256,uint256,uint256)"], [(tid, liq, a0min, a1min, DEADLINE)]).hex()

def enc_collect(tid, recipient):
    return "0x" + sel("collect((uint256,address,uint128,uint128))").hex() \
        + abi_encode(["(uint256,address,uint128,uint128)"], [(tid, recipient, U128MAX, U128MAX)]).hex()

def enc_initialize(pk, sqrtP):
    return "0x" + sel("initialize((address,address,uint24,int24,address),uint160)").hex() \
        + abi_encode(["(address,address,uint24,int24,address)", "uint160"], [_pk_tuple(pk), sqrtP]).hex()

def enc_approve(spender, amount):
    return "0x" + sel("approve(address,uint256)").hex() + abi_encode(["address", "uint256"], [spender, amount]).hex()

def enc_transfer_ownership(next_owner):
    return "0x" + sel("transferOwnership(address)").hex() + abi_encode(["address"], [next_owner]).hex()

def ld_owner(LD):
    return "0x" + call_raw(LD, "0x" + sel("owner()").hex())[-40:]

def _ap(pk, tl, tu, liq, salt, funder, max0, max1):
    return (_pk_tuple(pk), tl, tu, liq, salt, funder, max0, max1)

def enc_add(pk, tl, tu, liq, salt, funder, max0, max1):
    return "0x" + sel("add(" + AP_TYPE + ")").hex() + abi_encode([AP_TYPE], [_ap(pk, tl, tu, liq, salt, funder, max0, max1)]).hex()

def enc_initadd(pk, sqrtP, tl, tu, liq, salt, funder, max0, max1):
    return "0x" + sel("initAndAdd(uint160," + AP_TYPE + ")").hex() \
        + abi_encode(["uint160", AP_TYPE], [sqrtP, _ap(pk, tl, tu, liq, salt, funder, max0, max1)]).hex()

# ---- reads: NPM, ERC20, extsload -------------------------------------------
PTYPES = ["uint96", "address", "address", "address", "uint24", "int24", "int24", "uint128", "uint256", "uint256", "uint128", "uint128"]

def npm_position(tid):
    raw = call_raw(NPM, "0x" + sel("positions(uint256)").hex() + abi_encode(["uint256"], [tid]).hex())
    return abi_decode(PTYPES, bytes.fromhex(raw[2:]))

def erc20_balance(token, who):
    return int(call_raw(token, "0x" + sel("balanceOf(address)").hex() + abi_encode(["address"], [who]).hex()), 16)

def erc20_allowance(token, own, spender):
    return int(call_raw(token, "0x" + sel("allowance(address,address)").hex() + abi_encode(["address", "address"], [own, spender]).hex()), 16)

def pool_id(pk):
    return keccak(abi_encode(["address", "address", "uint24", "int24", "address"], list(_pk_tuple(pk))))

def _extsload(manager, slot: bytes):
    data = "0x" + sel("extsload(bytes32)").hex() + slot.hex()
    return bytes.fromhex(call_raw(manager, data)[2:])

def pool_sqrtprice(manager, pk):
    ss = keccak(pool_id(pk) + (6).to_bytes(32, "big"))
    return int.from_bytes(_extsload(manager, ss), "big") & ((1 << 160) - 1)

def pos_liquidity(manager, pk, own, tl, tu, salt: bytes):
    ss = keccak(pool_id(pk) + (6).to_bytes(32, "big"))
    pmap = (int.from_bytes(ss, "big") + 6).to_bytes(32, "big")
    pid = keccak(bytes.fromhex(own[2:]) + (tl & 0xFFFFFF).to_bytes(3, "big") + (tu & 0xFFFFFF).to_bytes(3, "big") + salt)
    slot = keccak(pid + pmap)
    return int.from_bytes(_extsload(manager, slot), "big") & ((1 << 128) - 1)

# ---- create-address (rlp[sender,nonce]) ------------------------------------
def create_address(sender, nonce):
    s = bytes.fromhex(sender[2:])
    def eb(b):
        if len(b) == 1 and b[0] < 0x80:
            return b
        return bytes([0x80 + len(b)]) + b
    def ei(n):
        return b"\x80" if n == 0 else eb(n.to_bytes((n.bit_length() + 7) // 8, "big"))
    payload = eb(s) + ei(nonce)
    out = bytes([0xc0 + len(payload)]) + payload
    return "0x" + keccak(out)[12:].hex()

# ---- signing + 5-RPC broadcast ---------------------------------------------
# The treasury EOA 0x9011 is known to be actively signed by other processes (RUNBOOK 0:
# nonce moved 748->757 during prep). Two signers racing the same nonce => one tx is
# silently dropped. So: (a) re-derive the live pending nonce before EVERY tx and refuse
# on drift; (b) never mask a nonce error as "sent" — that stalled the 240s receipt wait
# on a tx no validator actually holds.
NONCE = [None]  # expected nonce for the next tx; seeded at preflight, +1 per broadcast
BENIGN_SEND = ("already known", "alreadyknown", "already imported", "already exists",
               "known transaction", "replacement transaction underpriced")
FATAL_NONCE = ("nonce too low", "nonce too high", "invalid nonce", "nonce is too")

def _read_nonce(block="pending"):
    return int(rpc("eth_getTransactionCount", [OWNER, block]), 16)

def _nonce():
    if NONCE[0] is None:
        NONCE[0] = _read_nonce("pending")
    if not EXECUTE:
        return NONCE[0]  # dry-run: never signs; used only for CREATE-address prediction
    expected = NONCE[0]
    # Concurrent-signer detection via the LATEST (mined) nonce, NOT pending. On a no-gossip
    # chain our just-broadcast tx may sit in ONE node's mempool while READ_POD's pending nonce
    # still reads lower — so a pending==expected equality check false-aborts against our OWN
    # in-flight txs. The real hazard is a tx WE DID NOT SEND mining at/above our next nonce:
    # that only happens if another process signs 0x9011. latest > expected catches exactly that.
    latest = _read_nonce("latest")
    if latest > expected:
        raise RuntimeError(
            f"NONCE DRIFT: {OWNER} latest MINED nonce {latest} > our next {expected}. A "
            f"concurrent signer took our nonce — PAUSE it (suspend chain-heartbeat) and re-run "
            f"(idempotent; completed steps skip).")
    return expected

def _our_tx_mined(txhash, tries=6, delay=2):
    """Poll every validator for OUR tx's receipt (no-gossip: it may be on any one node).
    Returns True if it mined with status 1. Short poll — the tx either already mined
    (that is why a peer said nonce-low) or it did not."""
    for _ in range(tries):
        for pod in RPC_PODS:
            try:
                r = rpc("eth_getTransactionReceipt", [txhash], pod=pod)
                if r:
                    if int(r["status"], 16) != 1:
                        raise RuntimeError(f"tx {txhash} REVERTED (status 0)")
                    return True
            except RuntimeError as e:
                if "REVERTED" in str(e):
                    raise
        time.sleep(delay)
    return False

def sign_and_broadcast(to, data_hex, gas, value=0, create=False):
    key = os.environ["LUX_PRIVATE_KEY"]
    nonce = _nonce()
    tx = {"nonce": nonce, "gasPrice": GAS_PRICE_WEI, "gas": gas, "value": value,
          "data": data_hex, "chainId": CHAIN_ID}
    if not create:
        tx["to"] = to_checksum_address(to)
    signed = Account.sign_transaction(tx, key)
    raw = "0x" + signed.raw_transaction.hex()
    txhash = "0x" + keccak(signed.raw_transaction).hex()
    sent = 0
    for pod in RPC_PODS:
        try:
            rpc("eth_sendRawTransaction", [raw], pod=pod)
            sent += 1
        except RuntimeError as e:
            msg = str(e).lower()
            if any(k in msg for k in FATAL_NONCE):
                # NO-GOSSIP RECONCILE: on a chain whose mempool does not gossip we broadcast to
                # ALL validators; a tx can MINE via one node and then a LATER node reports "nonce
                # too low" for the SAME (now-consumed) nonce — that is SUCCESS, not a conflict.
                # Distinguish: (a) OUR txhash already mined -> success; (b) a DIFFERENT tx took our
                # nonce (our txhash absent AND latest nonce > ours) -> real concurrent signer, abort.
                if _our_tx_mined(txhash):
                    print(f"      {pod} reports nonce-low but our tx {txhash} MINED — success")
                    NONCE[0] = nonce + 1
                    return txhash
                live_latest = _read_nonce("latest")
                if live_latest > nonce and sent == 0:
                    raise RuntimeError(
                        f"FATAL nonce conflict on tx {txhash} (nonce={nonce}): a DIFFERENT tx took "
                        f"this nonce (latest={live_latest}, our tx not mined). Concurrent signer on "
                        f"0x9011 — pause it and re-run (idempotent).")
                # else: this pod is just lagging (our tx is in flight elsewhere) — skip it.
                print(f"      broadcast {pod}: nonce-low but tx in flight elsewhere — skipping pod")
                continue
            if any(k in msg for k in BENIGN_SEND):
                sent += 1  # already in this validator's pool == accepted
            else:
                print(f"      broadcast {pod}: {str(e)[:120]}")
    if sent == 0:
        # last check: did it mine anyway (accepted+mined between our sends)?
        if _our_tx_mined(txhash):
            NONCE[0] = nonce + 1
            return txhash
        raise RuntimeError(
            f"tx {txhash} (nonce={nonce}) accepted by 0/{len(RPC_PODS)} validators; not "
            f"waiting on a tx no validator holds. Check nonce / gasPrice vs baseFee.")
    NONCE[0] = nonce + 1
    print(f"      broadcast {sent}/{len(RPC_PODS)} validators tx={txhash} nonce={nonce}")
    return txhash

# ---- broadcast-safety preflights (EXECUTE only) -----------------------------
def preflight_gas():
    """Abort if the live base fee already exceeds our legacy gasPrice — such txs never
    mine and would only stall the receipt wait."""
    blk = rpc("eth_getBlockByNumber", ["latest", False])
    base_fee = int(blk.get("baseFeePerGas", "0x0"), 16)
    if base_fee > GAS_PRICE_WEI:
        print(f"FATAL: baseFee {base_fee/1e9:.2f} gwei > gasPrice {GAS_PRICE_WEI/1e9:.2f} "
              f"gwei; txs would never mine. Raise GAS_PRICE_GWEI. Aborting.")
        sys.exit(5)
    print(f"preflight: baseFee {base_fee/1e9:.2f} gwei <= gasPrice {GAS_PRICE_WEI/1e9:.2f} gwei  OK")
    return base_fee

def preflight_nonce_stability():
    """Detect a concurrent signer on 0x9011 before we start: read the pending nonce twice
    3s apart; abort if it moved. Returns the stable nonce to seed the counter."""
    a = _read_nonce("pending")
    time.sleep(3)
    b = _read_nonce("pending")
    if a != b:
        print(f"FATAL: treasury {OWNER} pending nonce moved {a} -> {b} in 3s. Another process "
              f"is signing 0x9011 — PAUSE it, then re-run (idempotent).")
        sys.exit(4)
    print(f"preflight: treasury nonce stable at {b} (no concurrent signer)  OK")
    return b

def wait_receipt(txhash, timeout=240):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for pod in RPC_PODS:
            try:
                r = rpc("eth_getTransactionReceipt", [txhash], pod=pod)
                if r:
                    if int(r["status"], 16) != 1:
                        raise RuntimeError(f"tx {txhash} REVERTED")
                    return r
            except RuntimeError as e:
                if "REVERTED" in str(e):
                    raise
        time.sleep(4)
    raise TimeoutError(f"receipt {txhash} not mined in {timeout}s")

# ---- state.json (stable schema for the console UI) --------------------------
def load_state():
    if os.path.exists(STATE):
        st = json.load(open(STATE))
        # normalize: one record per pool (older runs appended a fresh copy each run).
        seen = {}
        for p in st.get("pools", []):
            seen[p.get("v4PoolId")] = p
        st["pools"] = list(seen.values())
        return st
    return {"chainId": CHAIN_ID, "mode": None, "contracts": {}, "txs": [], "pools": []}

def save_state(st):
    st["updatedAt"] = int(time.time())
    st["mode"] = "execute" if EXECUTE else "dry-run"
    st["gasPriceGwei"] = GAS_PRICE_WEI // 10**9
    json.dump(st, open(STATE, "w"), indent=2)

ST = load_state()
def record_tx(label, txhash, to):
    ST["txs"].append({"label": label, "hash": txhash, "to": to, "ts": int(time.time())})
    save_state(ST)

def record_pool(entry):
    """Upsert a pool record by v4PoolId (idempotent — re-runs replace, never append)."""
    pools = ST.setdefault("pools", [])
    for i, p in enumerate(pools):
        if p.get("v4PoolId") == entry["v4PoolId"]:
            pools[i] = entry
            save_state(ST)
            return
    pools.append(entry)
    save_state(ST)

# ---- step engine ------------------------------------------------------------
def do_step(tag, label, to, data_hex, done_fn, value=0):
    print(f"  [{tag}] {label}")
    try:
        if done_fn():
            print("       already done -> skip")
            return None
    except Exception as e:
        print(f"       precheck read failed: {str(e)[:120]} (continuing)")
    # simulate/estimate
    gas = None
    try:
        gas = int(estimate(to, data_hex, value=value) * 1.3)
    except RuntimeError as e:
        if not EXECUTE:
            print(f"       [dry-run] PLANNED (unsimulated: {str(e)[:80]})  to={to} data={data_hex[:26]}..")
            return None
        raise
    if not EXECUTE:
        print(f"       [dry-run] to={to} gas~{gas} gasPrice={GAS_PRICE_WEI//10**9}gwei data={data_hex[:26]}..")
        return None
    txhash = sign_and_broadcast(to, data_hex, gas, value)
    wait_receipt(txhash)
    if not done_fn():
        raise RuntimeError(f"{label}: post-state check FALSE after mining {txhash}")
    record_tx(label, txhash, to)
    print(f"       confirmed {txhash}")
    return txhash

def do_create(tag, label, key, bytecode, ctor_hex, code_addr_state_key):
    print(f"  [{tag}] {label}")
    addr = ST["contracts"].get(code_addr_state_key)
    if addr and rpc("eth_getCode", [addr, "latest"]) not in ("0x", "0x0"):
        print(f"       already deployed at {addr} -> skip")
        return addr
    data = "0x" + bytecode.replace("0x", "") + ctor_hex.replace("0x", "")
    gas = int(estimate(None, data, create=True) * 1.3)
    predicted = create_address(OWNER, _nonce())
    if not EXECUTE:
        print(f"       [dry-run] CREATE gas~{gas} predicted={predicted}")
        return predicted
    txhash = sign_and_broadcast(None, data, gas, create=True)
    wait_receipt(txhash)
    if rpc("eth_getCode", [predicted, "latest"]) in ("0x", "0x0"):
        raise RuntimeError(f"{label}: no code at {predicted}")
    ST["contracts"][code_addr_state_key] = predicted
    record_tx(label, txhash, predicted)
    print(f"       deployed at {predicted}")
    return predicted

def assert_pool_price(PM, pk, expected_sqrtP, label):
    """If a pool is already initialized (possibly by a third party), refuse to add
    unless its price matches ours within tolerance — defends against front-run-init
    griefing that would make us deposit at an attacker-chosen price."""
    try:
        actual = pool_sqrtprice(PM, pk)
    except Exception:
        return  # PM not deployed yet (dry-run) -> nothing to check
    if actual == 0:
        return  # not initialized; we will initialize it
    if abs(actual - expected_sqrtP) * 10000 > expected_sqrtP * SLIPPAGE_BPS:
        raise RuntimeError(
            f"{label}: pool already initialized at sqrtP={actual} != expected {expected_sqrtP} "
            f"(>{SLIPPAGE_BPS}bps). Refusing to add at a foreign price. Investigate before proceeding.")

def bps_down(x):
    return x * (10000 - SLIPPAGE_BPS) // 10000

def bps_up(x):
    return x * (10000 + SLIPPAGE_BPS) // 10000

# ---- phases -----------------------------------------------------------------
def phase_withdraw(op, tag):
    """decrease 50% + collect each position -> OWNER. Idempotent."""
    for pos in op["positions"]:
        tid = pos["tokenId"]
        orig = int(pos["originalLiquidity"]); half = int(pos["removeLiquidity"])
        target = orig - half
        f0, f1 = int(pos["freed0"]), int(pos["freed1"])
        do_step(f"{tag}.dec.{tid}", f"V3 decreaseLiquidity 50% tokenId={tid} (~{f0/1e18:.4f}/{f1/1e18:.4f})",
                NPM, enc_decrease(tid, half, bps_down(f0), bps_down(f1)),
                lambda tid=tid, target=target: npm_position(tid)[7] <= target)
    for pos in op["positions"]:
        tid = pos["tokenId"]
        do_step(f"{tag}.col.{tid}", f"V3 collect tokenId={tid} -> {OWNER}",
                NPM, enc_collect(tid, OWNER),
                lambda tid=tid: (lambda p: p[10] == 0 and p[11] == 0)(npm_position(tid)))

def phase_add_spot(op, tag, PM, LD):
    pk = op["poolKey"]; sqrtP = int(op["initSqrtPriceX96"])
    need0 = bps_up(sum(int(p["addRequired0"]) for p in op["positions"]))
    need1 = bps_up(sum(int(p["addRequired1"]) for p in op["positions"]))
    if need0 > 0:
        do_step(f"{tag}.appr0", f"approve {op['token0sym']} -> LD ({need0/1e18:.4f})",
                pk["currency0"], enc_approve(LD, need0),
                lambda: erc20_allowance(pk["currency0"], OWNER, LD) >= need0)
    if need1 > 0:
        do_step(f"{tag}.appr1", f"approve {op['token1sym']} -> LD ({need1/1e18:.4f})",
                pk["currency1"], enc_approve(LD, need1),
                lambda: erc20_allowance(pk["currency1"], OWNER, LD) >= need1)
    assert_pool_price(PM, pk, sqrtP, f"{op['token0sym']}/{op['token1sym']}")
    try:
        inited = pool_sqrtprice(PM, pk) != 0
    except Exception:
        inited = False
    for i, pos in enumerate(op["positions"]):
        tl, tu = pos["tickLower"], pos["tickUpper"]; L = int(pos["removeLiquidity"])
        salt = pos["tokenId"].to_bytes(32, "big")
        max0 = bps_up(int(pos["addRequired0"])); max1 = bps_up(int(pos["addRequired1"]))
        done = lambda tl=tl, tu=tu, L=L, salt=salt: pos_liquidity(PM, pk, LD, tl, tu, salt) >= L
        if not inited:
            do_step(f"{tag}.initadd.{pos['tokenId']}",
                    f"V4 initAndAdd @tick{op['currentTick']} L={L} [{tl},{tu}]",
                    LD, enc_initadd(pk, sqrtP, tl, tu, L, salt, OWNER, max0, max1), done)
            inited = True
        else:
            do_step(f"{tag}.add.{pos['tokenId']}", f"V4 add L={L} [{tl},{tu}]",
                    LD, enc_add(pk, tl, tu, L, salt, OWNER, max0, max1), done)
    record_pool({"pair": f"{op['token0sym']}/{op['token1sym']}", "classification": op["classification"],
                 "v4PoolId": "0x" + pool_id(pk).hex(), "initSqrtPriceX96": str(sqrtP),
                 "migrated": {op["token0sym"]: str(sum(int(p['freed0']) for p in op['positions'])),
                              op["token1sym"]: str(sum(int(p['freed1']) for p in op['positions']))}})

def onesided_band_ok(tick_o, expected_tick, band=None):
    """Fail-secure sanity band for a one-sided oracle bid. The oracle-derived tick must
    sit within +/- band ticks of the operator's INDEPENDENTLY-recorded expected_tick
    (2-operator confirm; see RUNBOOK 6). A price fat-finger (e.g. 10x) jumps tick_o by
    ~23000 ticks -> immediate reject. Returns (ok, reason)."""
    if band is None:
        band = ORACLE_TICK_BAND
    dev = abs(tick_o - expected_tick)
    if dev > band:
        pct = (1.0001 ** dev - 1.0) * 100.0
        return False, (f"tick {tick_o} deviates {dev} ticks (~{pct:,.0f}% price) from "
                       f"expected_tick {expected_tick} (band +/-{band})")
    return True, f"tick {tick_o} within +/-{band} of expected_tick {expected_tick}"

def compute_onesided_bid(op, oracle, tag):
    """Parse+validate the oracle for a one-sided pool and compute the resting-bid params
    (sqrtP, ticks, L, req). Returns None if there is no oracle entry (fail-secure skip).
    ABORTS (exit 3) on a malformed entry, an out-of-band tick (price fat-finger), a
    honeypot-edge tick, or a WLUX deposit over ONESIDED_MAX_WLUX. Pure/read-only, so
    main() calls it BEFORE phase_withdraw -> a bad oracle never even decreases V3."""
    strat = op["oneSidedStrategy"]; base = strat["baseSymbol"]
    pair = f"{op['token0sym']}/{op['token1sym']}"
    entry = oracle.get(base)
    if entry is None:
        print(f"  [{tag}] MIGRATE_ONESIDED_ORACLE {pair}: no oracle entry for {base} "
              f"-> SKIP (fail-secure). Provide {ORACLE}.")
        return None
    if not isinstance(entry, dict) or "price" not in entry or "expected_tick" not in entry:
        print(f"  [{tag}] ABORT: oracle[{base}] must be an object with 'price' AND "
              f"'expected_tick' (2-operator confirm; see RUNBOOK 6); got {entry!r}.")
        save_state(ST); sys.exit(3)
    pk = op["poolKey"]; spacing = op["tickSpacing"]
    lux_usd = float(oracle.get("LUX_USD", 12.5)); asset_usd = float(entry["price"])
    expected_tick = int(entry["expected_tick"])
    tick_band = int(entry.get("band_ticks", ORACLE_TICK_BAND))
    wlux_is_1 = strat["wluxCurrency"] == "currency1"
    # price = token1 per token0
    price = (asset_usd / lux_usd) if wlux_is_1 else (lux_usd / asset_usd)
    sqrtP = sqrt_price_x96_from_price(price)
    tick_o = get_tick_at_sqrt_price(sqrtP)
    v3edge = strat["v3EdgeTick"]
    # PRIMARY GUARD: tight, independently-anchored band -> a price fat-finger aborts.
    ok, why = onesided_band_ok(tick_o, expected_tick, tick_band)
    if not ok:
        print(f"  [{tag}] ABORT: oracle sanity failed for {base}: {why}. Suspected fat-finger/"
              f"oracle error — refusing (fail-secure). Fix oracle.json price, re-confirm "
              f"expected_tick with a SECOND operator, then re-run.")
        save_state(ST); sys.exit(3)
    # BACKSTOP: the bid must rest strictly below the v3 honeypot edge, never clone it.
    if wlux_is_1 and not (tick_o < v3edge - 1000):
        print(f"  [{tag}] ABORT: oracle tick {tick_o} not below v3 honeypot edge {v3edge}-1000; "
              f"would clone the honeypot. Refusing.")
        save_state(ST); sys.exit(3)
    wlux_amt = int(strat["wluxAmount"])
    if wlux_is_1:
        tu = align_tick(tick_o, spacing, up=False)
        tl = align_tick(tu - ONESIDED_BAND_TICKS, spacing, up=False)
        sL, sU = get_sqrt_ratio_at_tick(tl), get_sqrt_ratio_at_tick(tu)
        L = liquidity_for_amount1(sL, sU, wlux_amt)
        # ensure required(roundUp) <= wlux_amt
        req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[1]
        while req > wlux_amt and L > 0:
            L -= 1; req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[1]
        wlux_token = pk["currency1"]; sym = op["token1sym"]
    else:
        tl = align_tick(tick_o, spacing, up=True)
        tu = align_tick(tl + ONESIDED_BAND_TICKS, spacing, up=True)
        sL, sU = get_sqrt_ratio_at_tick(tl), get_sqrt_ratio_at_tick(tu)
        L = liquidity_for_amount0(sL, sU, wlux_amt)
        req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[0]
        while req > wlux_amt and L > 0:
            L -= 1; req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[0]
        wlux_token = pk["currency0"]; sym = op["token0sym"]
    # HARD CAP: a scaling bug / bad wluxAmount can never risk more than ONESIDED_MAX_WLUX.
    if req > ONESIDED_MAX_WLUX:
        print(f"  [{tag}] ABORT: one-sided WLUX deposit {req/1e18:,.2f} exceeds cap "
              f"ONESIDED_MAX_WLUX={ONESIDED_MAX_WLUX/1e18:,.2f}. Refusing (fail-secure).")
        save_state(ST); sys.exit(3)
    return dict(pk=pk, sqrtP=sqrtP, tick_o=tick_o, expected_tick=expected_tick, v3edge=v3edge,
                tl=tl, tu=tu, L=L, req=req, wlux_amt=wlux_amt, wlux_token=wlux_token, sym=sym,
                wlux_is_1=wlux_is_1, price=price)

def phase_add_onesided(op, tag, PM, LD, oracle, bid=None):
    if bid is None:
        bid = compute_onesided_bid(op, oracle, tag)
    if bid is None:
        return  # no oracle entry -> fail-secure skip
    pk, sqrtP, tick_o, tl, tu = bid["pk"], bid["sqrtP"], bid["tick_o"], bid["tl"], bid["tu"]
    L, req, wlux_amt, wlux_token, sym, wlux_is_1 = (bid["L"], bid["req"], bid["wlux_amt"],
                                                    bid["wlux_token"], bid["sym"], bid["wlux_is_1"])
    print(f"  [{tag}] one-sided bid: price={bid['price']:.6g} {op['token1sym']}/{op['token0sym']} "
          f"oracleTick={tick_o} bidRange=[{tl},{tu}] L={L} depositWLUX={req/1e18:.4f} (v3edge={bid['v3edge']})")
    do_step(f"{tag}.appr", f"approve {sym} -> LD ({req/1e18:.4f} WLUX resting bid)",
            wlux_token, enc_approve(LD, wlux_amt),
            lambda: erc20_allowance(wlux_token, OWNER, LD) >= req)
    salt = (0).to_bytes(32, "big")
    max0 = req if not wlux_is_1 else 0
    max1 = req if wlux_is_1 else 0
    assert_pool_price(PM, pk, sqrtP, f"{op['token0sym']}/{op['token1sym']}")
    try:
        inited = pool_sqrtprice(PM, pk) != 0
    except Exception:
        inited = False
    done = lambda: pos_liquidity(PM, pk, LD, tl, tu, salt) >= L
    if not inited:
        do_step(f"{tag}.initadd", f"V4 initAndAdd @oracleTick{tick_o} (resting bid) L={L}",
                LD, enc_initadd(pk, sqrtP, tl, tu, L, salt, OWNER, max0, max1), done)
    else:
        do_step(f"{tag}.add", f"V4 add resting bid L={L}", LD, enc_add(pk, tl, tu, L, salt, OWNER, max0, max1), done)
    record_pool({"pair": f"{op['token0sym']}/{op['token1sym']}", "classification": op["classification"],
                 "v4PoolId": "0x" + pool_id(pk).hex(), "initSqrtPriceX96": str(sqrtP),
                 "oracleTick": tick_o, "expectedTick": bid["expected_tick"], "bidRange": [tl, tu],
                 "migratedWLUX": str(req)})

def phase_finalize(ops, PM, LD):
    """End state: no standing token approvals from the hot treasury EOA to LD, and LD
    owned by the DAO Safe (not the hot EOA). Idempotent; each step prechecks on-chain."""
    tokens = []
    for op in ops:
        for c in (op["poolKey"]["currency0"], op["poolKey"]["currency1"]):
            if c.lower() not in tokens:
                tokens.append(c.lower())
    for i, tok in enumerate(tokens):
        do_step(f"FIN.zero.{i}", f"zero treasury approval {tok} -> LD",
                tok, enc_approve(LD, 0),
                lambda tok=tok: erc20_allowance(tok, OWNER, LD) == 0)
    do_step("FIN.owner", f"transferOwnership LD -> DAO Safe {DAO_SAFE}",
            LD, enc_transfer_ownership(DAO_SAFE),
            lambda: ld_owner(LD).lower() == DAO_SAFE.lower())
    ST["ownership"] = {"liquidityDeployer": LD, "owner": DAO_SAFE}
    save_state(ST)

# ---- main -------------------------------------------------------------------
def main():
    plan = json.load(open(PLAN))
    oracle = json.load(open(ORACLE)) if os.path.exists(ORACLE) else {}
    pmbc = json.load(open(V4CORE_ART))["bytecode"]["object"]
    ldbc = json.load(open(LD_ART))["bytecode"]["object"]

    mode = "EXECUTE (BROADCAST TO MAINNET)" if EXECUTE else "DRY-RUN (no broadcast)"
    print("=" * 78)
    print(f"Lux V3->V4 migration executor  chainId={CHAIN_ID}  mode={mode}")
    print(f"gasPrice={GAS_PRICE_WEI//10**9} gwei  broadcast_pods={RPC_PODS}  slippage={SLIPPAGE_BPS}bps")
    if EXECUTE and "LUX_PRIVATE_KEY" not in os.environ:
        print("FATAL: EXECUTE=1 but LUX_PRIVATE_KEY not set."); sys.exit(2)
    print("=" * 78)

    # broadcast-safety preflights (execute only): base fee affordable + no concurrent signer.
    if EXECUTE:
        preflight_gas()
        NONCE[0] = preflight_nonce_stability()

    # STEP 1/2 — deploy V4 PoolManager + LiquidityDeployer
    print("\n[STEP 1] Deploy V4 PoolManager(initialOwner=OWNER)")
    pm_ctor = abi_encode(["address"], [OWNER]).hex()
    PM = do_create("1", "deploy PoolManager", "poolManager", pmbc, pm_ctor, "poolManager")
    print("\n[STEP 2] Deploy LiquidityDeployer(manager=PM, owner=OWNER)")
    ld_ctor = abi_encode(["address", "address"], [PM, OWNER]).hex()
    LD = do_create("2", "deploy LiquidityDeployer", "liquidityDeployer", ldbc, ld_ctor, "liquidityDeployer")
    save_state(ST)

    ops = [o for o in plan["operations"] if o["classification"].startswith("MIGRATE")]
    n = 3
    for op in ops:
        pair = f"{op['token0sym']}/{op['token1sym']}"
        print(f"\n[STEP {n}] {op['classification']} {pair}  ({op['reason']})")
        tag = f"{n}"
        if op["classification"] == "MIGRATE_SPOT":
            phase_withdraw(op, tag)
            phase_add_spot(op, tag, PM, LD)
        else:
            # validate the oracle (abort on fat-finger) BEFORE decreasing any V3 liquidity.
            bid = compute_onesided_bid(op, oracle, tag)
            phase_withdraw(op, tag)
            phase_add_onesided(op, tag, PM, LD, oracle, bid=bid)
        n += 1

    # FINALIZE — hand LD to the DAO Safe + drop residual approvals (gated in execute mode).
    if EXECUTE and not FINALIZE:
        print("\n[FINALIZE] skipped (set FINALIZE=1 to zero LD approvals + hand LD ownership "
              "to the DAO Safe once pools are verified).")
    else:
        print("\n[FINALIZE] zero residual LD approvals + transferOwnership LD -> DAO Safe"
              + ("" if EXECUTE else "  [dry-run preview]"))
        phase_finalize(ops, PM, LD)

    save_state(ST)
    print("\n" + "=" * 78)
    print(f"{'DRY-RUN complete — no transactions broadcast.' if not EXECUTE else 'EXECUTE complete.'}")
    print(f"state -> {STATE}")
    if not EXECUTE:
        print("Review the plan above, then re-run with EXECUTE=1 LUX_PRIVATE_KEY=$(...) to broadcast.")

if __name__ == "__main__":
    main()
