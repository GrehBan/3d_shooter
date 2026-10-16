"""Independent M2.3b reaction oracle for tests/golden/ReactionGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/reaction_ref.py
Direct contacts and their statuses come from the status model (status_ref.py); reactions
are modelled here with plain lists: eligible candidates are filtered and sorted by full
handle, then the first N are hit. Python unbounded integers define every floor.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from status_ref import ACID, ELECTRIC, FIRE, NONE, StatusModel, digest  # noqa: E402

ARC, CONDUCTING, EXPLOSION = 'arc', 'conducting', 'explosion'
LIMITS = {ARC: 2, CONDUCTING: 4, EXPLOSION: 4}
PERCENT = {ARC: 500, CONDUCTING: 500, EXPLOSION: 750}
TEAMS = {0: 1, 10: 1, 11: 0}  # everyone else is team 2
WET = {9}

# (tick, source, element, raw, [(primary, [candidates])...], hp edits before the shot)
SHOTS = (
    (1, 0, ELECTRIC, 10003, [(1, [5, 3, 11, 10, 2, 0, 1])], {}),
    (2, 0, ACID, 1000, [(1, [])], {}),
    (3, 0, ELECTRIC, 2000, [(1, [8, 7, 6, 5, 4, 3])], {}),
    (4, 0, FIRE, 10000, [(1, [6, 7, 8, 9])], {}),
    (5, 0, FIRE, 10000, [(1, [7])], {}),
    (6, 0, ELECTRIC, 4000, [(9, [1, 2, 7, 9])], {}),
    (7, 0, ELECTRIC, 1000, [(4, [5])], {}),
    (8, 11, ELECTRIC, 3000, [(2, [3])], {}),
    (9, 0, ELECTRIC, 10000, [(8, [7, 5])], {8: 500}),
    (10, 0, ELECTRIC, 2000, [(5, [3, 7]), (5, [3, 7])], {}),
)


def team(handle):
    return TEAMS.get(handle, 2)


def plan(m, source, primary, raw, element):
    e = m.entities[primary]
    if team(source) == 0 or raw <= 0:
        return None
    if element == ELECTRIC:
        kind = CONDUCTING if e.acid > 0 or primary in WET else ARC
    elif element == FIRE and e.acid > 0:
        kind = EXPLOSION
    else:
        return None
    damage = raw * PERCENT[kind] // 1000
    return (kind, damage) if damage > 0 else None


def reference():
    m = StatusModel(12, {})
    m.entities[3].armor = 50000
    m.entities[4].shield = 2000
    m.entities[6].hp = 3000
    words = []
    hits = kills = 0
    for tick, source, element, raw, pellets, edits in SHOTS:
        m.step(tick)
        for handle, hp in edits.items():
            m.entities[handle].hp = hp
        m.source = source
        for trace, (primary, candidates) in enumerate(pellets):
            e = m.entities[primary]
            if e.hp <= 0:
                continue
            planned = plan(m, source, primary, raw, element)
            before = e.hp
            m.contact(primary, raw, element)
            damage = before - e.hp
            words.extend((100, tick, source, primary, trace, damage))
            if before > 0 and e.hp == 0:
                words.extend((101, tick, source, primary))
            if planned is None or damage <= 0:
                continue
            kind, amount = planned
            if kind == EXPLOSION:
                e.acid = e.acid_end = 0
            eligible = sorted({c for c in candidates
                               if c not in (primary, source) and team(c) != 0
                               and team(c) != team(source) and m.entities[c].hp > 0})
            for target in eligible[:LIMITS[kind]]:
                t = m.entities[target]
                if t.hp <= 0:
                    continue
                hp = t.hp
                hit = m.apply(t, amount)
                hits += 1
                words.extend((200, tick, source, target, trace, hit))
                if hp > 0 and t.hp == 0:
                    t.clear()
                    kills += 1
                    words.extend((201, tick, source, target))
        words.extend((300, tick))
        for handle in range(12):
            e = m.entities[handle]
            words.extend((e.hp, e.shield, e.acid))
    return digest(words), len(words), hits, kills


if __name__ == '__main__':
    print('reaction hash/words/secondary_hits/secondary_kills', *reference())
