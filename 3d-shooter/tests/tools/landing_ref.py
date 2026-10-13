"""Independent integer damage/landing reference (Python arbitrary precision).
Run: python 3d-shooter/tests/tools/landing_ref.py
"""

MASK = 0xFFFFFFFF


def fold(h, value):
    return ((h ^ (value & MASK)) * 16777619) & MASK


def reference():
    h = 2166136261
    for i in range(1000):
        hp = (i * 7919) % 200001
        shield = (i * 197) % 30001
        armor = [-1000, 0, 10000, 33333, 99999, 100000, 120000][i % 7]
        mm = [7999, 8000, 8001, 12345, 100000, 922337203685485580][i % 6]
        damage = max(mm - 8000, 0) * 10
        if i % 11 == 0:
            damage = (1 << 63) - 1
        absorbed = min(shield, damage)
        shield -= absorbed
        hp_damage = (damage - absorbed) * (100000 - min(max(armor, 0), 100000)) // 100000
        actual = min(hp, hp_damage)
        hp -= actual
        for value in [actual, hp, shield, armor]:
            h = fold(h, value)
    return h


if __name__ == "__main__":
    print(reference())
