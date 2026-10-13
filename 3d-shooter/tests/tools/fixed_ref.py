"""Independent integer model for tests/golden/FixedGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/fixed_ref.py
Python integers keep intermediate products exact; no float division is used.
The output is calculated from the golden scenario, not stored reference values.
"""

SCALE = 1000
MASK32 = (1 << 32) - 1


def trunc_div(numerator: int, denominator: int) -> int:
    """Integer division with truncation toward zero, including negative operands."""
    if denominator == 0:
        raise ZeroDivisionError("trunc_div denominator is zero")
    magnitude = abs(numerator) // abs(denominator)
    return -magnitude if (numerator < 0) != (denominator < 0) else magnitude


def mul(a: int, b: int) -> int:
    return trunc_div(a * b, SCALE)


def div(a: int, b: int) -> int:
    return 0 if b == 0 else trunc_div(a * SCALE, b)


def fnv(h: int, value: int) -> int:
    return ((h ^ (value & MASK32)) * 16777619) & MASK32


def sweep() -> tuple[int, int]:
    h = 2166136261
    count = 0
    for i in range(-500, 500):
        a = i * 7919 - 13
        b = ((i + 500) * 104729) % 50000 - 25000
        h = fnv(h, mul(a, b))
        count += 1
        if b != 0:
            h = fnv(h, div(a, b))
            count += 1
    return h, count


def main() -> None:
    h, count = sweep()
    print("hash", h, "count", count)


if __name__ == "__main__":
    main()
