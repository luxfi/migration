#!/usr/bin/env python3
"""
Build the V3->V4 migration plan (plan.json) + human accounting table from the
on-chain snapshot. Pure computation; no network. Classification is rule-driven
and printed with rationale. Everything derives from the live snapshot — no
hardcoded reserves.

Policy (owner-directed):
  MIGRATE_SPOT            - two-sided pool at endogenous market price; clone at V3
                            spot (init V4 sqrtPrice = V3 slot0). Covers the deep
                            WLUX/LZOO and the thin two-sided LSOL/WLUX, LPOL/WLUX.
  MIGRATE_ONESIDED_ORACLE - single-sided WLUX-heavy pool at an off-market edge tick
                            (honeypot if cloned). Move 50% of the WLUX into V4 but
                            initialize at an ORACLE price and place the WLUX as a
                            resting BID ladder BELOW oracle (can only be hit by
                            someone SELLING the base at/below fair). Requires an
                            oracle price at execute time (oracle.json); skipped if
                            absent (fail-secure).
  SKIP_DUST               - economically negligible.
  SKIP_EMPTY              - NFT with zero liquidity.
"""
import json, os, time
from v4math import get_amounts_for_liquidity

HERE = os.path.dirname(__file__)
WLUX = "0x4888e4a2ee0f03051c72d2bd3acf755ed3498b3e"
OWNER = "0x9011E888251AB053B7bD1cdB598Db4f9DED94714"
DAO_SAFE = "0x51284dc2133e8d3a8e213dca6a6fa768cfdfcce2"
BASELINE = os.path.join(HERE, "baseline.json")

WLUX_ONESIDED_MIN = 1000 * 10**18   # >1000 WLUX single-sided => worth an oracle bid
DUST_WLUX_EQUIV = 100 * 10**18      # < ~100 WLUX-equiv total => dust


def load_or_create_baseline(snapshot_positions):
    """Freeze the ORIGINAL liquidity + one-shot 50% removal per position on the FIRST
    plan generation, keyed by tokenId. Never overwritten while present.

    This is the guard against a double-decrease: if a migration partially ran (V3
    liquidity already halved) and someone re-runs `make snapshot && make plan`, a
    re-snapshot reads the HALVED liquidity as the new baseline and would remove 50% of
    the REMAINDER -> 75% gone. Reading the frozen baseline instead makes plan generation
    idempotent: targets always derive from the original, and an already-migrated
    position (live <= target) is a no-op via the executor's on-chain precheck.

    Delete baseline.json ONLY to start a brand-new migration from current live liquidity.
    """
    if os.path.exists(BASELINE):
        return json.load(open(BASELINE)), False
    positions = {}
    for p in snapshot_positions:
        L = int(p["liquidity"])
        if L == 0:
            continue
        half = L // 2
        positions[str(p["tokenId"])] = {
            "originalLiquidity": str(L),
            "removeLiquidity": str(half),          # one-shot 50% decrease from original
            "targetLiquidity": str(L - half),      # liquidity to KEEP in V3
        }
    b = {"createdAt": int(time.time()), "chainId": 96369,
         "note": "FROZEN migration baseline (original liquidity + one-shot 50% removal per "
                 "tokenId), captured at first `make plan`. build_plan reads THIS, never a "
                 "re-snapshot, so a partially-migrated position is never re-halved. Delete "
                 "only to start a brand-new migration from current live liquidity.",
         "positions": positions}
    json.dump(b, open(BASELINE, "w"), indent=2)
    return b, True


def price_t1_per_t0(sqrtP, dec0, dec1):
    return (sqrtP / (1 << 96)) ** 2 * (10 ** (dec0 - dec1))


def pool_totals(pool, posById):
    ps = [posById[t] for t in pool['positions'] if posById[t]['liquidity'] > 0]
    sp = pool['sqrtPriceX96']
    tot0 = tot1 = 0
    onesided = True
    for p in ps:
        a0, a1 = get_amounts_for_liquidity(sp, p['tickLower'], p['tickUpper'], p['liquidity'] // 2, False)
        tot0 += a0
        tot1 += a1
        if a0 > 0 and a1 > 0:
            onesided = False
    return ps, tot0, tot1, onesided


def classify(pool, posById):
    ps, tot0, tot1, onesided = pool_totals(pool, posById)
    if not ps:
        return "SKIP_EMPTY", "no liquidity in any owned position", None
    wlux_is_0 = pool['token0'].lower() == WLUX
    wlux_amt = tot0 if wlux_is_0 else tot1
    other_amt = tot1 if wlux_is_0 else tot0
    if onesided and wlux_amt >= WLUX_ONESIDED_MIN and other_amt == 0:
        return ("MIGRATE_ONESIDED_ORACLE",
                f"single-sided {wlux_amt/1e18:,.0f} WLUX at edge tick {pool['tick']}; oracle-priced resting bid",
                dict(wluxCurrency=("currency0" if wlux_is_0 else "currency1"),
                     wluxAmount=str(wlux_amt),
                     baseSymbol=(pool['token1sym'] if wlux_is_0 else pool['token0sym']),
                     v3EdgeTick=pool['tick']))
    if wlux_amt < DUST_WLUX_EQUIV and other_amt < 10**18:
        return "SKIP_DUST", f"negligible (tot0={tot0/1e18:.4f} {pool['token0sym']}, tot1={tot1/1e18:.4f} {pool['token1sym']})", None
    if tot0 > 0 and tot1 > 0:
        depth = "deep" if wlux_amt >= 50_000_000 * 10**18 else "thin"
        return "MIGRATE_SPOT", f"{depth} two-sided ({wlux_amt/1e18:,.2f} WLUX); clone at V3 spot", None
    return "SKIP_DUST", "unhandled shape treated as skip", None


def main():
    s = json.load(open(os.path.join(HERE, "snapshot.json")))
    posById = {p['tokenId']: p for p in s['positions']}
    baseline, created = load_or_create_baseline(s['positions'])
    print(("created" if created else "using") + f" frozen baseline {BASELINE} "
          f"({len(baseline['positions'])} positions)")
    # Pin ALL downstream math to the FROZEN original liquidity, not live (which may be
    # already halved by a partial migration). Live is kept only to flag done positions.
    for p in s['positions']:
        b = baseline['positions'].get(str(p['tokenId']))
        if b:
            p['liveLiquidity'] = int(p['liquidity'])
            p['liquidity'] = int(b['originalLiquidity'])
            if p['liveLiquidity'] <= int(b['targetLiquidity']):
                print(f"  position {p['tokenId']}: live {p['liveLiquidity']} <= baseline target "
                      f"{b['targetLiquidity']} -> already migrated (executor skips its decrease).")
    ops = []
    print(f"{'POOL':16} {'CLASS':24} {'V3 treasury (pre)':>40}   {'50% -> migrate':>36}")
    print("-" * 132)
    for pool in sorted(s['pools'], key=lambda pl: -sum(posById[t]['liquidity'] for t in pl['positions'])):
        cls, why, strat = classify(pool, posById)
        d0, d1 = pool['dec0'], pool['dec1']
        s0, s1 = pool['token0sym'], pool['token1sym']
        sp = pool['sqrtPriceX96']
        positions = []
        pre0 = pre1 = mig0 = mig1 = 0
        for t in pool['positions']:
            p = posById[t]
            if p['liquidity'] == 0:
                continue
            # L + half come from the FROZEN baseline (p['liquidity'] was pinned to it
            # above), so removeLiquidity/target never compound across re-runs.
            L = p['liquidity']; half = int(baseline['positions'][str(t)]['removeLiquidity'])
            f0, f1 = get_amounts_for_liquidity(sp, p['tickLower'], p['tickUpper'], L, False)
            r0, r1 = get_amounts_for_liquidity(sp, p['tickLower'], p['tickUpper'], half, False)
            a0, a1 = get_amounts_for_liquidity(sp, p['tickLower'], p['tickUpper'], half, True)
            pre0 += f0; pre1 += f1; mig0 += r0; mig1 += r1
            positions.append(dict(
                tokenId=t, tickLower=p['tickLower'], tickUpper=p['tickUpper'],
                originalLiquidity=str(L), removeLiquidity=str(half),
                freed0=str(r0), freed1=str(r1),
                addRequired0=str(a0), addRequired1=str(a1),
                amount0Max=str(a0), amount1Max=str(a1),
            ))
        if cls != "SKIP_EMPTY":
            print(f"{s0+'/'+s1:16} {cls:24} {pre0/10**d0:>16,.4f} {s0:5} + {pre1/10**d1:>12,.2f} {s1:5}  "
                  f"{mig0/10**d0:>14,.4f} {s0:5} + {mig1/10**d1:>10,.2f} {s1:5}")
            print(f"{'':16} price={price_t1_per_t0(sp,d0,d1):.6g} {s1}/{s0}  tick={pool['tick']}  -> {why}")
        ops.append(dict(
            poolV3=pool['pool'], token0=pool['token0'], token1=pool['token1'],
            token0sym=s0, token1sym=s1, dec0=d0, dec1=d1, fee=pool['fee'], tickSpacing=pool['tickSpacing'],
            currentTick=pool['tick'], initSqrtPriceX96=str(sp),
            classification=cls, reason=why, oneSidedStrategy=strat,
            poolKey=dict(currency0=pool['token0'], currency1=pool['token1'], fee=pool['fee'],
                         tickSpacing=pool['tickSpacing'], hooks="0x0000000000000000000000000000000000000000"),
            positions=positions,
        ))
    plan = dict(
        chainId=96369, npm=s['npm'], factory=s['factory'], owner=OWNER, daoSafe=DAO_SAFE,
        note="V4 PoolManager + LiquidityDeployer addresses are computed at execute time from live nonce; "
             "MIGRATE_ONESIDED_ORACLE pools need oracle.json at execute time.",
        operations=ops,
    )
    out = os.path.join(HERE, "plan.json")
    json.dump(plan, open(out, "w"), indent=2)
    print("\n=== DEFAULT execution set ===")
    for o in ops:
        if o['classification'].startswith("MIGRATE"):
            t0 = sum(int(p['freed0']) for p in o['positions'])
            t1 = sum(int(p['freed1']) for p in o['positions'])
            extra = "  (needs oracle.json)" if o['classification'] == "MIGRATE_ONESIDED_ORACLE" else ""
            print(f"  [{o['classification']}] {o['token0sym']}/{o['token1sym']}: "
                  f"{t0/10**o['dec0']:,.4f} {o['token0sym']} + {t1/10**o['dec1']:,.4f} {o['token1sym']}{extra}")
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
