#!/usr/bin/env python3
"""
RED repro for ATTACK #4: one-sided oracle fat-finger.

Replicates execute.py::phase_add_onesided tick/guard/ladder logic EXACTLY for the
LBTC/WLUX one-sided pool, then quantifies the WLUX an LBTC-seller can extract when
the operator mis-sets the oracle price K-times too high. Also finds the K at which
the honeypot guard (tick_o < v3edge - 1000) finally fires.

Read-only, pure math. No broadcast.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from v4math import (get_sqrt_ratio_at_tick, get_tick_at_sqrt_price, sqrt_price_x96_from_price,
                    align_tick, liquidity_for_amount1, get_amounts_for_liquidity)
# The guard under test is imported from execute.py itself (single source of truth) so this
# repro proves the LIVE code path rejects a fat-finger, not a copy of it.
from execute import onesided_band_ok, ORACLE_TICK_BAND

SPACING = 60
BAND = 6900                 # ONESIDED_BAND_TICKS default (bid ladder width)
V3_EDGE = 185729            # LBTC/WLUX v3 edge tick (plan.json)
WLUX_AMT = 4999999999999999999995806   # 50% of the LBTC bid = ~5,000,000 WLUX
LUX_USD = 12.5
FAIR_LBTC_USD = 63166.4    # oracle.json live value
# expected_tick = the operator's INDEPENDENT tick anchor, computed once from the fair mid.
EXPECTED_TICK = get_tick_at_sqrt_price(sqrt_price_x96_from_price(FAIR_LBTC_USD / LUX_USD))

def build_bid(asset_usd):
    """EXACT copy of execute.py one-sided branch for wlux_is_1 (currency1==WLUX)."""
    price = asset_usd / LUX_USD          # WLUX per LBTC (token1 per token0)
    sqrtP = sqrt_price_x96_from_price(price)
    tick_o = get_tick_at_sqrt_price(sqrtP)
    guard_ok = tick_o < V3_EDGE - 1000
    tu = align_tick(tick_o, SPACING, up=False)
    tl = align_tick(tu - BAND, SPACING, up=False)
    sL, sU = get_sqrt_ratio_at_tick(tl), get_sqrt_ratio_at_tick(tu)
    L = liquidity_for_amount1(sL, sU, WLUX_AMT)
    req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[1]
    while req > WLUX_AMT and L > 0:
        L -= 1; req = get_amounts_for_liquidity(sqrtP, tl, tu, L, True)[1]
    return dict(price=price, tick_o=tick_o, guard_ok=guard_ok, tl=tl, tu=tu, L=L, depositWLUX=req, sqrtP=sqrtP)

def wlux_out_when_true_price(bid, true_asset_usd):
    """How much WLUX an arber extracts by pushing the pool price down from tick_o to
    the tick of the TRUE price (they sell LBTC while pool WLUX/LBTC > market).
    WLUX released moving from tu down to max(tl, tick_true) = amount1 over that sub-range."""
    true_price = true_asset_usd / LUX_USD
    tick_true = get_tick_at_sqrt_price(sqrt_price_x96_from_price(true_price))
    # arb profitable only while current pool tick > tick_true (pool pays > market)
    stop = max(bid['tl'], min(bid['tu'], tick_true))
    sStop = get_sqrt_ratio_at_tick(stop); sU = get_sqrt_ratio_at_tick(bid['tu'])
    from v4math import get_amount1_delta, get_amount0_delta
    wlux_out = get_amount1_delta(sStop, sU, bid['L'], False)     # WLUX seller receives
    lbtc_in  = get_amount0_delta(sStop, sU, bid['L'], True)      # LBTC seller delivers
    lbtc_value_wlux = lbtc_in * true_price / 1e0                  # fair WLUX value of that LBTC
    return wlux_out, lbtc_in, lbtc_value_wlux

print("="*100)
print("LBTC/WLUX one-sided bid — oracle fat-finger analysis (FIX #1: tight expected_tick band)")
print("="*100)
fair = build_bid(FAIR_LBTC_USD)
fok, fwhy = onesided_band_ok(fair['tick_o'], EXPECTED_TICK)
print(f"FAIR oracle LBTC=${FAIR_LBTC_USD}: price={fair['price']:.2f} WLUX/LBTC  tick_o={fair['tick_o']}  "
      f"expected_tick={EXPECTED_TICK}  band=+/-{ORACLE_TICK_BAND}  ->  {'ACCEPT' if fok else 'REJECT'}")

print("\nFat-finger: operator types oracle K-times too high. NEW guard verdict (onesided_band_ok vs")
print("expected_tick), the OLD honeypot-only verdict, and the WLUX an arber drains at the true price:")
print(f"{'K':>7} {'oracleUSD':>12} {'tick_o':>9} {'dev':>8} {'NEWguard':>9} {'OLDhoneypot':>12} {'WLUXdrained':>15} {'lossWLUX':>15}")
rows = []
for K in [1, 1.5, 2, 3, 5, 10, 50, 100, 1000]:
    b = build_bid(FAIR_LBTC_USD * K)
    if b['L'] <= 0:
        print(f"{K:>7} L<=0"); continue
    new_ok, _ = onesided_band_ok(b['tick_o'], EXPECTED_TICK)
    dev = abs(b['tick_o'] - EXPECTED_TICK)
    wlux_out, lbtc_in, fair_val = wlux_out_when_true_price(b, FAIR_LBTC_USD)
    loss = wlux_out - fair_val
    rows.append((K, new_ok))
    print(f"{K:>7} {FAIR_LBTC_USD*K:>12,.0f} {b['tick_o']:>9} {dev:>8} "
          f"{('ACCEPT' if new_ok else 'REJECT'):>9} {('ACCEPT' if b['guard_ok'] else 'REJECT'):>12} "
          f"{wlux_out/1e18:>15,.2f} {loss/1e18:>15,.2f}")

# assert the fix: K==1 accepted, every K>=1.5 rejected by the NEW guard.
bad = [K for K, ok in rows if (K == 1 and not ok) or (K >= 1.5 and ok)]
print("\nFIX #1 verification:")
if bad:
    print(f"  FAIL — guard misbehaved at K={bad}")
    sys.exit(1)
print(f"  PASS — K=1 ACCEPT; every K>=1.5 REJECT (band +/-{ORACLE_TICK_BAND} ticks). "
      f"A 10x typo (dev~{abs(build_bid(FAIR_LBTC_USD*10)['tick_o']-EXPECTED_TICK)} ticks) aborts immediately.")
