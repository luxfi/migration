"""Reference tests for v4math — the bit-exact tick + liquidity math the V3->V4
migration relies on. Constants are the audited Uniswap v3 TickMath values, so
these assert CORRECTNESS, not just regression. Run: `python3 test_v4math.py`
(also pytest-discoverable)."""
import v4math as m

Q96 = 1 << 96

def test_tickmath_canonical_constants():
    # audited Uniswap v3 TickMath reference values — bit-exact
    assert m.get_sqrt_ratio_at_tick(0) == Q96
    assert m.get_sqrt_ratio_at_tick(m.MIN_TICK) == 4295128739
    assert m.get_sqrt_ratio_at_tick(m.MAX_TICK) == 1461446703485210103287273052203988822378723970342
    assert m.get_sqrt_ratio_at_tick(1) == 79232123823359799118286999568
    assert m.get_sqrt_ratio_at_tick(-1) == 79224201403219477170569942574

def test_tickmath_monotonic():
    prev = 0
    for t in range(-500000, 500001, 50000):
        v = m.get_sqrt_ratio_at_tick(t)
        assert v > prev, f"not monotonic at {t}"
        prev = v

def test_tick_sqrt_roundtrip():
    for t in (-887272, -100000, -1000, -1, 0, 1, 1000, 100000, 887271):
        assert m.get_tick_at_sqrt_price(m.get_sqrt_ratio_at_tick(t)) == t

def test_get_tick_at_sqrt_price_is_floor():
    # largest tick whose ratio <= sqrtP (matches solidity)
    for t in (-1234, 0, 777, 202020):
        sp = m.get_sqrt_ratio_at_tick(t)
        assert m.get_sqrt_ratio_at_tick(m.get_tick_at_sqrt_price(sp)) <= sp
        assert m.get_sqrt_ratio_at_tick(m.get_tick_at_sqrt_price(sp) + 1) > sp

def test_amount_deltas_canonical_vector():
    # Uniswap SqrtPriceMath vector: price 1 -> 1.21 (sqrt 1.1), L=1e18
    sqrtA = Q96
    sqrtB = 87150978765690771352898345369  # sqrt(1.21)*Q96
    assert m.get_amount0_delta(sqrtA, sqrtB, 10**18, True)  == 90909090909090910
    assert m.get_amount0_delta(sqrtA, sqrtB, 10**18, False) == 90909090909090909
    assert m.get_amount1_delta(sqrtA, sqrtB, 10**18, True)  == 100000000000000000
    assert m.get_amount1_delta(sqrtA, sqrtB, 10**18, False) == 99999999999999999

def test_amount_delta_invariants():
    sqrtA, sqrtB = Q96, m.get_sqrt_ratio_at_tick(6931)  # ~price 2
    for fn in (m.get_amount0_delta, m.get_amount1_delta):
        assert fn(sqrtA, sqrtB, 0, True) == 0                       # L=0 -> 0
        assert fn(sqrtA, sqrtB, 10**18, True) >= fn(sqrtA, sqrtB, 10**18, False)  # ceil >= floor
        assert fn(sqrtA, sqrtB, 10**18, True) == fn(sqrtB, sqrtA, 10**18, True)   # order-independent

def test_sqrt_price_from_price():
    assert abs(m.sqrt_price_x96_from_price(1) - Q96) < 2
    assert m.sqrt_price_x96_from_price(4) == 2 * Q96  # sqrt(4)=2

if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for f in fns:
        f(); print("PASS", f.__name__)
    print(f"\n{len(fns)} v4math tests passed")
