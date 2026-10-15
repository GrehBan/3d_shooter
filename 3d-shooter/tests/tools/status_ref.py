"""Independent M2.3 status oracle; Python unbounded products define every floor.

Run from the repository root: python 3d-shooter/tests/tools/status_ref.py
The model uses keyed entities and deadline records rather than the runtime's packed
slot records, sorted active list and quotient arithmetic. Trace words are hashed as two
unsigned little-endian 32-bit FNV-1a words.

Tick semantics: any first tick is accepted; a repeated or past tick is a no-op. After
skipped ticks each active burn executes at most one overdue pulse (due <= tick) and
schedules the next pulse from the current tick.
"""

from copy import deepcopy
from dataclasses import dataclass, field

LIMIT = (1 << 63) - 1
NONE, ELECTRIC, FIRE, ICE, ACID = range(5)
ORDINARY, PLAYER, ELITE, INERT = range(4)


def digest(words):
    result = 2166136261
    for value in words:
        for word in (value & 0xffffffff, (value >> 32) & 0xffffffff):
            result = ((result ^ word) * 16777619) & 0xffffffff
    return result


@dataclass
class Entity:
    hp: int = 1000000
    shield: int = 0
    armor: int = 0
    profile: int = ORDINARY
    shock: int = 0
    shock_ready: int = 0
    chill: int = 0
    chill_end: int = 0
    freeze: int = 0
    freeze_ready: int = 0
    acid: int = 0
    acid_end: int = 0
    generation: int = 0
    burn: dict = field(default_factory=dict)

    def clear(self):
        self.shock = self.chill = self.chill_end = self.freeze = 0
        self.acid = self.acid_end = 0
        self.burn.clear()

    def effective_armor(self):
        return max(0, min(100000, max(0, self.armor)) - 10000 * self.acid)


class StatusModel:
    def __init__(self, count, profiles):
        self.entities = {i: Entity(profile=profiles.get(i, ORDINARY)) for i in range(count)}
        self.tick = 0
        self.source = 0
        self.handles = list(range(count))
        self.words = []
        self.pulses = 0
        self.kills = 0
        self.contacts = 0

    @staticmethod
    def provenance(source, tick, target):
        return (source, (1 << 50) + source, 7, tick * 100 + target,
                target, (1 << 40) + target)

    def apply(self, target, amount):
        if target is None or target.hp <= 0 or amount <= 0:
            return 0
        shield = max(0, target.shield)
        absorbed = min(shield, amount)
        target.shield = shield - absorbed
        damage = min(target.hp, (amount - absorbed) *
                     (100000 - target.effective_armor()) // 100000)
        target.hp -= damage
        return damage

    def contact(self, handle, raw, element):
        self.contacts += 1
        target = self.entities.get(handle)
        frozen = bool(target and target.freeze)
        applied = self.apply(target, min(LIMIT, raw * (2 if frozen else 1)))
        if target and applied > 0:
            if frozen:
                target.freeze = target.chill = target.chill_end = 0
            if target.hp == 0:
                target.clear()
            elif target.profile != INERT:
                t = self.tick
                if element == FIRE and raw // 5 > 0:
                    provenance = self.provenance(self.source, t, handle)
                    if not target.burn:
                        target.generation += 1
                        target.burn = dict(end=t + 90, due=t + 15,
                                           amount=raw // 5, ordinal=0,
                                           provenance=provenance)
                    else:
                        target.burn['end'] = t + 90
                        if raw // 5 > target.burn['amount']:
                            target.burn.update(amount=raw // 5, provenance=provenance)
                if element == ACID:
                    target.acid = min(3, target.acid + 1)
                    target.acid_end = t + 90
                if element == ELECTRIC and target.profile == ORDINARY and t >= target.shock_ready:
                    target.shock, target.shock_ready = t + 3, t + 15
                if element == ICE and not frozen:
                    target.chill = min(3 if target.profile == ORDINARY and t >= target.freeze_ready
                                       else 2, target.chill + 1)
                    target.chill_end = t + 60
                    if target.chill == 3:
                        target.chill = target.chill_end = 0
                        target.freeze, target.freeze_ready = t + 30, t + 60
        self.words.extend((100, self.tick, self.source, handle, raw, element, applied))

    def step(self, tick):
        if tick <= self.tick:
            return
        self.tick = tick
        for handle in sorted(self.entities, key=lambda h: h % 65536):
            e = self.entities[handle]
            if e.hp <= 0:
                e.clear()
                continue
            if tick >= e.shock:
                e.shock = 0
            if tick >= e.chill_end:
                e.chill = e.chill_end = 0
            if tick >= e.freeze:
                e.freeze = 0
            if tick >= e.acid_end:
                e.acid = e.acid_end = 0
            b = e.burn
            if b and b['due'] <= tick:
                source, credit, epoch, sequence, trace, tags = b['provenance']
                ordinal = b['ordinal'] + 1
                amount = self.apply(e, b['amount'])
                values = (source, handle, credit, e.generation, ordinal,
                          amount, epoch, sequence, trace, tags)
                self.words.extend((201, *values))
                if e.hp == 0:
                    self.words.extend((202, *values))
                    self.kills += 1
                self.words.extend((203, *values))
                self.pulses += 1
                if e.hp == 0 or tick + 15 > b['end']:
                    e.burn = {}
                    if e.hp == 0:
                        e.clear()
                else:
                    b['due'] = tick + 15
                    b['ordinal'] = ordinal

    def record(self):
        self.words.extend((300, self.tick))
        for handle in self.handles[1:]:
            e = self.entities[handle]
            mask = int(bool(e.shock)) + 2 * int(bool(e.burn)) + 4 * int(bool(e.chill))
            mask += 8 * int(bool(e.freeze)) + 16 * int(bool(e.acid))
            self.words.extend((handle, e.hp, e.shield, mask,
                               0 if e.freeze or e.shock else 1000 - 200 * e.chill,
                               int(bool(e.freeze or e.shock)), e.effective_armor(), e.acid))


def status_reference():
    """Consecutive ticks 1..125 with releases, reuse and a cold restore at tick 45."""
    m = StatusModel(8, {2: PLAYER, 3: ELITE, 4: INERT})
    m.entities[1].armor = 50000
    m.entities[5].armor = 100000
    m.entities[7].shield = 10000
    for tick in range(1, 126):
        m.step(tick)
        if tick == 1:
            for args in ((1, 10001, FIRE), (1, 1000, ACID), (2, 1000, FIRE),
                         (2, 1000, ICE), (2, 1000, ICE), (2, 1000, ICE),
                         (2, 1000, ELECTRIC), (3, 1000, FIRE), (3, 1000, ICE),
                         (3, 1000, ICE), (3, 1000, ICE), (3, 1000, ELECTRIC),
                         (4, 1000, FIRE), (4, 1000, ACID), (4, 1000, ICE),
                         (4, 1000, ELECTRIC), (5, 1000, ACID), (7, 10000, FIRE),
                         (6, 5000, FIRE)):
                m.contact(*args)
        actions = {2: ((1, 1001, ACID), (1, 1000, ICE), (6, 1000, ICE)),
                   3: ((1, 1000, ICE), (1, 1000, ELECTRIC), (7, 10001, FIRE)),
                   4: ((1, 1000, ICE),), 5: ((1, 1001, NONE), (1, 1000, ELECTRIC)),
                   10: ((1, 5000, FIRE),), 16: ((1, 20001, FIRE),),
                   18: ((65542, 1000, ICE),), 19: ((65542, 1000, ICE),),
                   20: ((65542, 1000, ICE), (1, 5, FIRE)),
                   21: ((65542, 10000, NONE),), 22: ((65542, 10001, NONE),),
                   30: ((1, 1000, ELECTRIC),), 31: ((1, 1000, ACID),),
                   64: ((1, 1000, ICE),), 65: ((1, 1000, ICE),),
                   66: ((1, 1000, ICE),), 67: ((1, 9999, FIRE),)}
        if tick == 15:
            del m.entities[0]
            m.source = 65536
            m.entities[m.source] = Entity()
        if tick == 17:
            del m.entities[6]
            m.entities[65542] = Entity()
            m.handles[6] = 65542
            m.contact(6, 10000, FIRE)
        if tick == 21:
            m.entities[65542].shield = 40000
        if tick == 80:
            m.entities[3].hp = 100
        for args in actions.get(tick, ()):
            m.contact(*args)
        if tick == 45:
            # Standalone cold status restore preserves external stat values.
            before = [(e.hp, e.shield, e.armor) for e in m.entities.values()]
            m.entities = deepcopy(m.entities)
            assert before == [(e.hp, e.shield, e.armor) for e in m.entities.values()]
            m.words.extend((400, tick))
        m.record()
    return digest(m.words), len(m.words), m.contacts, m.pulses, m.kills


# (requested tick, contacts after the step). Repeated and past ticks are no-ops.
SKIP_TIMELINE = (
    (500, ((1, 10000, FIRE), (2, 1000, ICE), (2, 1000, ICE), (2, 1000, ICE),
           (3, 1000, ACID), (4, 1000, ELECTRIC), (5, 5000, FIRE), (6, 1000, ICE),
           (6, 1000, ICE), (6, 1000, ICE))),
    (501, ((5, 20000, FIRE), (3, 1000, ACID))),
    (509, ((2, 3000, ICE), (4, 1000, ELECTRIC))),
    (530, ((4, 1000, ELECTRIC),)),
    (530, ()),
    (520, ()),
    (531, ((1, 10000, FIRE),)),
    (600, ()),
    (620, ()),
    (5000, ()),
)


def skip_reference():
    """Room starting at logic tick 500 with skipped, repeated and past ticks."""
    m = StatusModel(7, {6: PLAYER})
    m.entities[3].armor = 50000
    for tick, contacts in SKIP_TIMELINE:
        m.step(tick)
        for args in contacts:
            m.contact(*args)
        m.words.append(tick)
        m.record()
    return digest(m.words), len(m.words), m.contacts, m.pulses, m.kills


if __name__ == '__main__':
    print('status hash/words/contacts/pulses/kills', *status_reference())
    print('skip hash/words/contacts/pulses/kills', *skip_reference())
