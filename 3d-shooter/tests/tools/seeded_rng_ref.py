"""Independent integer model for tests/golden/SeededRngGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/seeded_rng_ref.py
All vectors and hashes are calculated. Python's arbitrary precision products,
masked to 32 bits, do not use the GDScript split multiplication implementation.
"""

MASK32 = (1 << 32) - 1
UINT32_SPAN = 1 << 32
FNV_OFFSET = 2166136261


def fnv(h: int, value: int) -> int:
    return ((h ^ (value & MASK32)) * 16777619) & MASK32


def rotate_left(word: int, bits: int) -> int:
    return ((word << bits) | (word >> (32 - bits))) & MASK32


def mix32(value: int) -> int:
    """Murmur3 fmix32, with exact products reduced modulo 2**32."""
    value &= MASK32
    value ^= value >> 16
    value = (value * 0x85EBCA6B) & MASK32
    value ^= value >> 13
    value = (value * 0xC2B2AE35) & MASK32
    return value ^ (value >> 16)


def derive_seed(parent_seed: int, stream_id: int) -> int:
    lo = mix32((parent_seed & MASK32) ^ mix32((stream_id & MASK32) ^ 0x27D4EB2F))
    hi = mix32(((parent_seed >> 32) & MASK32)
               ^ mix32(((stream_id >> 32) & MASK32) ^ 0x165667B1) ^ lo)
    return ((hi & 0x7FFFFFFF) << 32) | lo


class SeededRng:
    def __init__(self, seed: int, words: tuple[int, int, int, int] | None = None):
        self.seed = seed
        if words is None:
            lo = seed & MASK32
            hi = (seed >> 32) & MASK32
            a = mix32(lo ^ 0x9E3779B9)
            b = mix32(hi ^ 0x7F4A7C15 ^ a)
            c = mix32(a ^ mix32(b ^ 0x85EBCA77))
            d = mix32(b ^ mix32(a ^ 0xC2B2AE3D))
            words = (a, b, c, d)
        self.words = tuple(word & MASK32 for word in words)
        if not any(self.words):
            self.words = (1, 0, 0, 0)

    def next_u32(self) -> int:
        a, b, c, d = self.words
        result = (rotate_left((b * 5) & MASK32, 7) * 9) & MASK32
        # Simultaneous state transition of xoshiro128**.
        self.words = (a ^ d ^ b, b ^ c ^ a,
                      c ^ a ^ ((b << 9) & MASK32), rotate_left(d ^ b, 11))
        return result

    def substream(self, stream_id: int) -> "SeededRng":
        return SeededRng(derive_seed(self.seed, stream_id))

    def range_int(self, minimum: int, maximum: int) -> int:
        width = maximum - minimum + 1
        if not 1 <= width <= UINT32_SPAN:
            raise ValueError("range width must be between 1 and 2**32")
        threshold = UINT32_SPAN % width
        while True:
            value = self.next_u32()
            if value >= threshold:
                return minimum + value % width

    def chance_permille(self, permille: int) -> bool:
        if permille <= 0:
            return False
        if permille >= 1000:
            return True
        return self.range_int(0, 999) < permille

    def weighted_index(self, weights: list[int]) -> int:
        if any(weight < 0 for weight in weights):
            raise ValueError("weights must be nonnegative")
        total = sum(weights)
        if total == 0:
            return -1
        pick = self.range_int(0, total - 1)
        cumulative = 0
        for index, weight in enumerate(weights):
            cumulative += weight
            if pick < cumulative:
                return index
        raise AssertionError("pick must belong to a weight interval")

    def shuffle_int32(self, values: list[int]) -> None:
        for index in range(len(values) - 1, 0, -1):
            other = self.range_int(0, index)
            values[index], values[other] = values[other], values[index]


def first_values(rng: SeededRng, count: int) -> list[int]:
    return [rng.next_u32() for _ in range(count)]


def golden_values() -> dict[str, object]:
    results: dict[str, object] = {}
    results["xoshiro128ss_reference_vector"] = first_values(SeededRng(0, (1, 2, 3, 4)), 6)
    results["first_values_for_fixed_seed"] = first_values(SeededRng(0x5EED), 8)
    for seed in (0, -1, -987654321012345, (1 << 63) - 1):
        results[f"first_values_seed_{seed}"] = first_values(SeededRng(seed), 5)

    rng = SeededRng(20261009)
    h = FNV_OFFSET
    for _ in range(10000):
        h = fnv(h, rng.next_u32())
    results["hash_of_10000_values"] = h

    rng = SeededRng(7)
    h = FNV_OFFSET
    for _ in range(10000):
        h = fnv(h, rng.range_int(0, 99))
    results["hash_of_range_int"] = h

    rng = SeededRng(-123)
    weights = [5, 10, 20, 65]
    values = list(range(16))
    h = FNV_OFFSET
    for i in range(2000):
        h = fnv(h, int(rng.chance_permille(333)))
        h = fnv(h, rng.weighted_index(weights))
        h = fnv(h, rng.range_int(-50, 50))
        if i % 100 == 0:
            rng.shuffle_int32(values)
            for value in values:
                h = fnv(h, value)
    results["hash_of_mixed_api_sequence"] = h
    results["mixed_api_final_shuffle"] = values
    results["derived_seeds"] = [derive_seed(0x5EED, stream) for stream in range(3)]
    results["derived_seed_negative"] = derive_seed(-1, -1)
    results["substream_first_values"] = first_values(SeededRng(42).substream(3), 4)
    return results


def main() -> None:
    for name, result in golden_values().items():
        print(name, result)


if __name__ == "__main__":
    main()
