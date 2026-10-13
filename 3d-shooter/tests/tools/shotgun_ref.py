"""Independent M1 shot oracle: canonical completed headers, integer Apply, ordered events."""

MASK = (1 << 32) - 1
LARGE_SOURCE = 40000 * 65536


def reference():
    hp = {2: 10000, 3: 100000}
    shield = {2: 6000, 3: 0}
    armor = {2: 0, 3: 100000}
    shots = [
        (LARGE_SOURCE, 0, [2] * 8),
        (1, 0, [3, 2, -1, 2, 2, 2, 2, 2]),
        (1, 1, [3] * 3),
    ]
    words = []
    hits = kills = no_ops = 0
    for source, sequence, targets in sorted(shots, key=lambda s: (s[0], s[1])):
        words.extend((0, source, 0, sequence))
        for trace, target in enumerate(targets):
            if target not in hp or hp[target] <= 0:
                no_ops += 1
                continue
            before = hp[target]
            absorbed = min(shield[target], 6000)
            shield[target] -= absorbed
            damage = min(hp[target], (6000 - absorbed) * (100000 - armor[target]) // 100000)
            hp[target] -= damage
            hits += 1
            words.extend((1, source, target, trace, damage))
            if before > 0 and hp[target] == 0:
                kills += 1
                words.extend((2, source, target, trace))
        words.extend((3, source, 0, sequence))
    words.extend((hp[2], shield[2], hp[3], shield[3], hits, kills, no_ops, len(shots)))
    digest = 2166136261
    for word in words:
        for part in (word & MASK, (word >> 32) & MASK):
            digest = ((digest ^ part) * 16777619) & MASK
    return digest, hits, kills, no_ops, hp, shield


if __name__ == "__main__":
    print(reference())
