"""
Exact Uniswap v3/v4 tick + liquidity math in Python big-ints (bit-for-bit with
solidity TickMath.getSqrtPriceAtTick and SqrtPriceMath.getAmount{0,1}Delta).
Used to compute V4 add requirements (roundUp=True) and validate against the
on-chain V3 decreaseLiquidity simulation (roundUp=False).
"""
Q96 = 1 << 96
MIN_TICK = -887272
MAX_TICK = 887272

def get_sqrt_ratio_at_tick(tick: int) -> int:
    assert MIN_TICK <= tick <= MAX_TICK, f"tick {tick} out of range"
    abs_tick = -tick if tick < 0 else tick
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if (abs_tick & 0x1) else (1 << 128)
    def mul(r, c):
        return (r * c) >> 128
    if abs_tick & 0x2:        ratio = mul(ratio, 0xfff97272373d413259a46990580e213a)
    if abs_tick & 0x4:        ratio = mul(ratio, 0xfff2e50f5f656932ef12357cf3c7fdcc)
    if abs_tick & 0x8:        ratio = mul(ratio, 0xffe5caca7e10e4e61c3624eaa0941cd0)
    if abs_tick & 0x10:       ratio = mul(ratio, 0xffcb9843d60f6159c9db58835c926644)
    if abs_tick & 0x20:       ratio = mul(ratio, 0xff973b41fa98c081472e6896dfb254c0)
    if abs_tick & 0x40:       ratio = mul(ratio, 0xff2ea16466c96a3843ec78b326b52861)
    if abs_tick & 0x80:       ratio = mul(ratio, 0xfe5dee046a99a2a811c461f1969c3053)
    if abs_tick & 0x100:      ratio = mul(ratio, 0xfcbe86c7900a88aedcffc83b479aa3a4)
    if abs_tick & 0x200:      ratio = mul(ratio, 0xf987a7253ac413176f2b074cf7815e54)
    if abs_tick & 0x400:      ratio = mul(ratio, 0xf3392b0822b70005940c7a398e4b70f3)
    if abs_tick & 0x800:      ratio = mul(ratio, 0xe7159475a2c29b7443b29c7fa6e889d9)
    if abs_tick & 0x1000:     ratio = mul(ratio, 0xd097f3bdfd2022b8845ad8f792aa5825)
    if abs_tick & 0x2000:     ratio = mul(ratio, 0xa9f746462d870fdf8a65dc1f90e061e5)
    if abs_tick & 0x4000:     ratio = mul(ratio, 0x70d869a156d2a1b890bb3df62baf32f7)
    if abs_tick & 0x8000:     ratio = mul(ratio, 0x31be135f97d08fd981231505542fcfa6)
    if abs_tick & 0x10000:    ratio = mul(ratio, 0x9aa508b5b7a84e1c677de54f3e99bc9)
    if abs_tick & 0x20000:    ratio = mul(ratio, 0x5d6af8dedb81196699c329225ee604)
    if abs_tick & 0x40000:    ratio = mul(ratio, 0x2216e584f5fa1ea926041bedfe98)
    if abs_tick & 0x80000:    ratio = mul(ratio, 0x48a170391f7dc42444e8fa2)
    if tick > 0:
        ratio = ((1 << 256) - 1) // ratio
    # sqrtPriceX96 = ratio >> 32, rounding up if remainder
    sp = (ratio >> 32) + (1 if (ratio % (1 << 32)) else 0)
    return sp

def _mul_div(a, b, d):
    return (a * b) // d

def _mul_div_round_up(a, b, d):
    p = a * b
    return p // d + (1 if p % d else 0)

def _div_round_up(a, d):
    return a // d + (1 if a % d else 0)

def get_amount0_delta(sqrtA: int, sqrtB: int, L: int, round_up: bool) -> int:
    if sqrtA > sqrtB:
        sqrtA, sqrtB = sqrtB, sqrtA
    num1 = L << 96
    num2 = sqrtB - sqrtA
    if round_up:
        return _div_round_up(_mul_div_round_up(num1, num2, sqrtB), sqrtA)
    return _mul_div(num1, num2, sqrtB) // sqrtA

def get_amount1_delta(sqrtA: int, sqrtB: int, L: int, round_up: bool) -> int:
    if sqrtA > sqrtB:
        sqrtA, sqrtB = sqrtB, sqrtA
    if round_up:
        return _mul_div_round_up(L, sqrtB - sqrtA, Q96)
    return _mul_div(L, sqrtB - sqrtA, Q96)

def sqrt_price_x96_from_price(price) -> int:
    """price = token1 per token0 (already decimal-adjusted). Returns floor(sqrt(price)*2^96)."""
    import decimal
    decimal.getcontext().prec = 80
    d = decimal.Decimal
    return int((d(str(price)).sqrt()) * (d(2) ** 96))

def get_tick_at_sqrt_price(sqrtP: int) -> int:
    """Largest tick t with get_sqrt_ratio_at_tick(t) <= sqrtP (matches solidity)."""
    import math
    price = (sqrtP / (1 << 96)) ** 2
    t = int(math.floor(math.log(price) / math.log(1.0001)))
    t = max(MIN_TICK, min(MAX_TICK - 1, t))
    while t > MIN_TICK and get_sqrt_ratio_at_tick(t) > sqrtP:
        t -= 1
    while t < MAX_TICK - 1 and get_sqrt_ratio_at_tick(t + 1) <= sqrtP:
        t += 1
    return t

def align_tick(tick: int, spacing: int, up: bool = False) -> int:
    q = tick // spacing
    if tick % spacing != 0 and up:
        q += 1
    return q * spacing

def liquidity_for_amount1(sqrt_lower: int, sqrt_upper: int, amount1: int) -> int:
    """L such that a 100%-token1 position over [lower,upper] holds ~amount1 (floor)."""
    if sqrt_lower > sqrt_upper:
        sqrt_lower, sqrt_upper = sqrt_upper, sqrt_lower
    return (amount1 * Q96) // (sqrt_upper - sqrt_lower)

def liquidity_for_amount0(sqrt_lower: int, sqrt_upper: int, amount0: int) -> int:
    """L such that a 100%-token0 position over [lower,upper] holds ~amount0 (floor)."""
    if sqrt_lower > sqrt_upper:
        sqrt_lower, sqrt_upper = sqrt_upper, sqrt_lower
    intermediate = (sqrt_lower * sqrt_upper) // Q96
    return (amount0 * intermediate) // (sqrt_upper - sqrt_lower)

def get_amounts_for_liquidity(sqrtP: int, tick_lower: int, tick_upper: int, L: int, round_up: bool):
    sqrtA = get_sqrt_ratio_at_tick(tick_lower)
    sqrtB = get_sqrt_ratio_at_tick(tick_upper)
    if sqrtA > sqrtB:
        sqrtA, sqrtB = sqrtB, sqrtA
    if sqrtP <= sqrtA:
        return get_amount0_delta(sqrtA, sqrtB, L, round_up), 0
    elif sqrtP < sqrtB:
        return (get_amount0_delta(sqrtP, sqrtB, L, round_up),
                get_amount1_delta(sqrtA, sqrtP, L, round_up))
    else:
        return 0, get_amount1_delta(sqrtA, sqrtB, L, round_up)
