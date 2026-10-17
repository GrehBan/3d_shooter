"""Independent M2.3b reaction oracle for tests/golden/ReactionGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/reaction_ref.py
Direct contacts and their statuses come from the status model (status_ref.py); reactions
are modelled here with plain lists: eligible candidates are filtered and sorted by full
handle, then the first N are hit. A reaction always fires: with no eligible candidates it
still consumes what its rule consumes (an explosion the primary's corrosion), it just hits
nobody. Python unbounded integers define every floor. A kill by a secondary hit clears the target's statuses at once, like every other
kill.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from status_ref import ACID, ELECTRIC, FIRE, StatusModel, digest  # noqa: E402

ARC, CONDUCTING, EXPLOSION = 'arc', 'conducting', 'explosion'
LIMITS = {ARC: 2, CONDUCTING: 4, EXPLOSION: 4}
PERCENT = {ARC: 500, CONDUCTING: 500, EXPLOSION: 750}
# Source 0 and ally 2 are team 1, 3 is neutral, everyone else is hostile team 2; 9 and 11
# are WET.
TEAMS = {0: 1, 2: 1, 3: 0}
WET = {9, 11}

# (tick, source, element, raw, [(primary, [candidates])...], hp edits before the shot)
SHOTS = (
    # Ally 2, neutral 3 and dead 4 sort below the eligible 5, 6, 7: the filters must drop them.
    (1, 0, ELECTRIC, 10003, [(1, [2, 3, 4, 5, 6, 7])], {4: 0}),
    (2, 0, ACID, 1000, [(1, [])], {}),
    (3, 0, ELECTRIC, 2000, [(1, [11, 10, 9, 8, 7, 6, 5, 2])], {}),
    (4, 0, FIRE, 10000, [(10, [])], {}),
    (5, 0, ACID, 1000, [(10, [])], {}),
    # 10 burns and is corroded; the explosion kills it: its statuses must go at once.
    (6, 0, FIRE, 10000, [(1, [10, 11, 9, 8])], {10: 1500}),
    (7, 0, ELECTRIC, 4000, [(9, [1, 2, 9, 11])], {}),
    (8, 0, ELECTRIC, 1000, [(7, [5])], {}),
    (9, 3, ELECTRIC, 3000, [(5, [6])], {}),
    (10, 0, ELECTRIC, 3000, [(2, [5]), (3, [5])], {}),
    (11, 0, ELECTRIC, 10000, [(9, [11, 5])], {9: 500}),
    (12, 0, ELECTRIC, 2000, [(5, [6, 11]), (5, [6, 11])], {}),
    # WET 11 is not corroded: conduction reaches the three eligible targets, arcs would hit two.
    (13, 0, ELECTRIC, 2000, [(11, [8, 7, 6, 5, 10, 2])], {}),
    (14, 0, ACID, 1000, [(11, [])], {}),
    # Only the ally and the neutral stand nearby: the explosion still fires and takes the acid.
    (15, 0, FIRE, 2000, [(11, [2, 3])], {}),
    (16, 0, FIRE, 2000, [(11, [6, 5])], {}),  # no acid left: no explosion
    (17, 0, ACID, 1000, [(11, [])], {}),
    (18, 0, FIRE, 2000, [(11, [6, 5])], {}),
)


def team(handle):
    return TEAMS.get(handle, 2)


def plan(m, source, primary, raw, element):
    e = m.entities[primary]
    if raw <= 0 or team(source) == 0 or team(primary) in (0, team(source)):
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
    m.entities[6].armor = 50000
    m.entities[7].shield = 2000
    m.entities[8].hp = 3000
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
            eligible = sorted({c for c in candidates
                               if c not in (primary, source) and team(c) != 0
                               and team(c) != team(source) and m.entities[c].hp > 0})
            if kind == EXPLOSION:
                e.acid = e.acid_end = 0
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
            words.extend((e.hp, e.shield, e.acid, e.burn['end'] if e.burn else 0))
    return digest(words), len(words), hits, kills


if __name__ == '__main__':
    print('reaction hash/words/secondary_hits/secondary_kills', *reference())
