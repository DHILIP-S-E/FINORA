"""Exact money handling.

All amounts are integers in minor units (e.g. paise). Rates are Decimal.
Rounding rule (single documented place): ROUND_HALF_UP to the nearest minor unit.
"""
from decimal import Decimal, ROUND_HALF_UP

# Minor-unit exponent per currency (INR default). Extend here to add currencies.
CURRENCY_EXPONENT = {"INR": 2, "USD": 2, "EUR": 2, "GBP": 2, "JPY": 0}


def exponent(currency: str) -> int:
    try:
        return CURRENCY_EXPONENT[currency]
    except KeyError:
        raise ValueError(f"Unsupported currency: {currency}")


def to_minor(amount, currency: str = "INR") -> int:
    """Convert a major-unit decimal (str/int/Decimal) to integer minor units."""
    if isinstance(amount, float):
        raise TypeError("floats are not accepted for money; pass str or Decimal")
    q = Decimal(amount) * (Decimal(10) ** exponent(currency))
    return int(q.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def to_major_str(minor: int, currency: str = "INR") -> str:
    e = exponent(currency)
    sign = "-" if minor < 0 else ""
    if e == 0:
        return f"{sign}{abs(minor)}"
    s = str(abs(minor)).rjust(e + 1, "0")
    return f"{sign}{s[:-e]}.{s[-e:]}"


def apply_bps(minor: int, bps: int) -> int:
    """minor * bps/10000, rounded half-up, sign-symmetric."""
    q = (Decimal(abs(minor)) * Decimal(bps) / Decimal(10000)).quantize(Decimal(1), rounding=ROUND_HALF_UP)
    return int(q) if minor >= 0 else -int(q)
