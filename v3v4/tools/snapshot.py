#!/usr/bin/env python3
"""
Enumerate 0x9011's V3 positions on Lux mainnet C-Chain (96369) and simulate a
50% decreaseLiquidity for each, entirely READ-ONLY (eth_call). No broadcast.

Reads via the forwarded RPC (kubectl port-forward luxd-1 9631:9630).
Outputs a structured JSON snapshot used by the accounting + staged script.
"""
import json, sys, os, urllib.request
from eth_abi import encode as abi_encode, decode as abi_decode
from eth_abi.exceptions import DecodingError

RPC = os.environ.get("RPC", "http://localhost:9631/v1/bc/C/rpc")
# Transport: "http" (port-forward) or "kubectl" (exec curl, no port-forward needed)
TRANSPORT = os.environ.get("TRANSPORT", "http")
KCTX = os.environ.get("KCTX", "do-sfo3-lux-k8s")
KNS  = os.environ.get("KNS", "lux-mainnet")
KPOD = os.environ.get("KPOD", "luxd-1")

# --- canonical addresses (verified on-chain, not trusted from files) ---
OWNER   = "0x9011E888251AB053B7bD1cdB598Db4f9DED94714"
NPM     = "0x7a4C48B9dae0b7c396569b34042fcA604150Ee28"   # NonfungiblePositionManager
FACTORY = "0x80bBc7C4C7a59C899D1B37BC14539A22D5830a84"   # UniswapV3Factory
DEADLINE = 1 << 63

_id = [0]
def _rpc(batch):
    body = json.dumps(batch).encode()
    if TRANSPORT == "kubectl":
        import subprocess
        p = subprocess.run(
            ["kubectl", "--context", KCTX, "-n", KNS, "exec", "-i", KPOD, "--",
             "curl", "-s", "-X", "POST", "http://localhost:9630/v1/bc/C/rpc",
             "-H", "content-type:application/json", "-d", "@-"],
            input=body, capture_output=True, timeout=180)
        return json.loads(p.stdout)
    req = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())

def call(to, data, frm=None):
    _id[0] += 1
    p = {"to": to, "data": data}
    if frm: p["from"] = frm
    return {"jsonrpc": "2.0", "id": _id[0], "method": "eth_call", "params": [p, "latest"]}

def sel(sig):
    from eth_utils import keccak
    return "0x" + keccak(text=sig).hex()[:8]

def enc(sig, types, args):
    return sel(sig) + abi_encode(types, args).hex()

def batch_call(calls):
    """calls: list of (key, to, data, frm). Returns {key: raw_hex_or_None}."""
    reqs, keymap = [], {}
    for key, to, data, frm in calls:
        r = call(to, data, frm); keymap[r["id"]] = key; reqs.append(r)
    out = {}
    for i in range(0, len(reqs), 50):
        for resp in _rpc(reqs[i:i+50]):
            k = keymap[resp["id"]]
            out[k] = resp.get("result") if "error" not in resp else ("ERR:"+json.dumps(resp["error"]))
    return out

def dec(types, raw):
    return abi_decode(types, bytes.fromhex(raw[2:]))

def main():
    # 1) balanceOf(owner)
    n = int(batch_call([("bal", NPM, enc("balanceOf(address)", ["address"], [OWNER]), None)])["bal"], 16)
    print(f"balanceOf(owner) = {n}", file=sys.stderr)

    # 2) tokenOfOwnerByIndex for all
    idx_calls = [(f"tok{i}", NPM, enc("tokenOfOwnerByIndex(address,uint256)", ["address","uint256"], [OWNER, i]), None)
                 for i in range(n)]
    toks_raw = batch_call(idx_calls)
    token_ids = [int(toks_raw[f"tok{i}"], 16) for i in range(n)]

    # 3) positions(tokenId)
    pos_calls = [(f"pos{t}", NPM, enc("positions(uint256)", ["uint256"], [t]), None) for t in token_ids]
    pos_raw = batch_call(pos_calls)
    ptypes = ["uint96","address","address","address","uint24","int24","int24","uint128","uint256","uint256","uint128","uint128"]

    positions = []
    for t in token_ids:
        r = pos_raw[f"pos{t}"]
        if r is None or r.startswith("ERR"):
            print(f"  position {t}: {r}", file=sys.stderr); continue
        (nonce, op, t0, t1, fee, tl, tu, liq, fg0, fg1, owed0, owed1) = dec(ptypes, r)
        positions.append(dict(tokenId=t, token0=t0.lower(), token1=t1.lower(), fee=fee,
                              tickLower=tl, tickUpper=tu, liquidity=liq,
                              tokensOwed0=owed0, tokensOwed1=owed1))

    # 4) simulate decreaseLiquidity(50%) via eth_call from OWNER -> exact (amount0, amount1)
    #    struct DecreaseLiquidityParams{tokenId,liquidity,amount0Min,amount1Min,deadline}
    dec_calls = []
    for p in positions:
        half = p["liquidity"] // 2
        p["halfLiquidity"] = half
        if half == 0:  # zero-liquidity position (fees only) -> nothing to decrease
            continue
        data = enc("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))",
                   ["(uint256,uint128,uint256,uint256,uint256)"],
                   [(p["tokenId"], half, 0, 0, DEADLINE)])
        dec_calls.append((f"dec{p['tokenId']}", NPM, data, OWNER))
    dec_raw = batch_call(dec_calls) if dec_calls else {}
    for p in positions:
        k = f"dec{p['tokenId']}"
        if k in dec_raw and dec_raw[k] and not dec_raw[k].startswith("ERR"):
            a0, a1 = dec(["uint256","uint256"], dec_raw[k])
            p["decHalf0"], p["decHalf1"] = a0, a1
        else:
            p["decHalf0"], p["decHalf1"] = 0, 0
            p["decErr"] = dec_raw.get(k)

    # 5) unique pools; read pool addr, slot0, liquidity, tickSpacing
    pools = {}
    for p in positions:
        key = (p["token0"], p["token1"], p["fee"])
        pools.setdefault(key, {"token0": p["token0"], "token1": p["token1"], "fee": p["fee"], "positions": []})
        pools[key]["positions"].append(p["tokenId"])

    pk = list(pools.keys())
    getpool = [(f"gp{i}", FACTORY, enc("getPool(address,address,uint24)", ["address","address","uint24"],
               [k[0], k[1], k[2]]), None) for i, k in enumerate(pk)]
    fts = [(f"ts{i}", FACTORY, enc("feeAmountTickSpacing(uint24)", ["uint24"], [k[2]]), None) for i, k in enumerate(pk)]
    gp_raw = batch_call(getpool + fts)
    for i, k in enumerate(pk):
        addr = "0x" + gp_raw[f"gp{i}"][-40:]
        pools[k]["pool"] = addr.lower()
        pools[k]["tickSpacing"] = int(gp_raw[f"ts{i}"], 16)

    slot_calls, liq_calls = [], []
    for i, k in enumerate(pk):
        pa = pools[k]["pool"]
        slot_calls.append((f"s{i}", pa, enc("slot0()", [], []), None))
        liq_calls.append((f"l{i}", pa, enc("liquidity()", [], []), None))
    sl_raw = batch_call(slot_calls + liq_calls)
    for i, k in enumerate(pk):
        s = sl_raw[f"s{i}"]
        # slot0: sqrtPriceX96 uint160, tick int24, obsIndex u16, obsCard u16, obsCardNext u16, feeProto u8, unlocked bool
        sp, tick, *_ = dec(["uint160","int24","uint16","uint16","uint16","uint8","bool"], s)
        pools[k]["sqrtPriceX96"] = sp
        pools[k]["tick"] = tick
        pools[k]["poolLiquidity"] = int(sl_raw[f"l{i}"], 16)

    # 6) token metadata: symbol, decimals, and pool token balances
    tokens = set()
    for k in pk:
        tokens.add(k[0]); tokens.add(k[1])
    meta_calls = []
    for tkn in tokens:
        meta_calls.append((f"sym{tkn}", tkn, enc("symbol()", [], []), None))
        meta_calls.append((f"dec{tkn}", tkn, enc("decimals()", [], []), None))
    for i, k in enumerate(pk):
        pa = pools[k]["pool"]
        meta_calls.append((f"b0_{i}", k[0], enc("balanceOf(address)", ["address"], [pa]), None))
        meta_calls.append((f"b1_{i}", k[1], enc("balanceOf(address)", ["address"], [pa]), None))
    m_raw = batch_call(meta_calls)
    tokmeta = {}
    for tkn in tokens:
        raw_sym = m_raw[f"sym{tkn}"]
        try:
            symbol = dec(["string"], raw_sym)[0]
        except (DecodingError, Exception):
            # some tokens return bytes32 symbol
            symbol = bytes.fromhex(raw_sym[2:]).rstrip(b"\x00").decode("latin1") if raw_sym else "?"
        decimals = int(m_raw[f"dec{tkn}"], 16)
        tokmeta[tkn] = {"symbol": symbol, "decimals": decimals}
    for i, k in enumerate(pk):
        pools[k]["bal0"] = int(m_raw[f"b0_{i}"], 16)
        pools[k]["bal1"] = int(m_raw[f"b1_{i}"], 16)

    snapshot = dict(
        owner=OWNER, npm=NPM, factory=FACTORY,
        blockRpc=RPC,
        positions=positions,
        pools=[{**v, "token0sym": tokmeta[v["token0"]]["symbol"], "token1sym": tokmeta[v["token1"]]["symbol"],
                "dec0": tokmeta[v["token0"]]["decimals"], "dec1": tokmeta[v["token1"]]["decimals"]}
               for v in pools.values()],
        tokens=tokmeta,
    )
    out = os.environ.get("OUT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "snapshot.json"))
    with open(out, "w") as f:
        json.dump(snapshot, f, indent=2)
    print(f"wrote {out}: {len(positions)} positions, {len(pools)} pools", file=sys.stderr)

if __name__ == "__main__":
    main()
