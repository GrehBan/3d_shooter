"""Independent entity model for tests/golden/StatBlockGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/stat_block_ref.py
Entities are records keyed by complete handles, rather than the game's SoA.
Only the allocation/stat/status contract exercised by the golden is modeled;
save-state validation is covered separately by the GDScript unit tests.
"""

from dataclasses import dataclass, field

SPAN = 1 << 16
STAT_COUNT = 7
HP, MAX_HP, SHIELD, MAX_SHIELD, ARMOR, ENERGY, MAX_ENERGY = range(STAT_COUNT)
MASK32 = (1 << 32) - 1


def fnv(h: int, value: int) -> int:
    return ((h ^ (value & MASK32)) * 16777619) & MASK32


@dataclass
class Entity:
    stats: list[int] = field(default_factory=lambda: [0] * STAT_COUNT)
    status: int = 0


class StatBlock:
    def __init__(self, capacity: int):
        if not 1 <= capacity <= SPAN:
            raise ValueError("capacity must be between 1 and 65536")
        self.capacity = capacity
        self.generations = [0] * capacity
        self.free_slots = list(reversed(range(capacity)))
        self.entities: dict[int, Entity] = {}

    def allocate(self) -> int:
        if not self.free_slots:
            return -1
        slot = self.free_slots.pop()
        handle = self.generations[slot] * SPAN + slot
        self.entities[handle] = Entity()
        return handle

    def release(self, handle: int) -> bool:
        if handle not in self.entities:
            return False
        del self.entities[handle]
        slot = handle % SPAN
        self.generations[slot] += 1
        self.free_slots.append(slot)
        return True

    def set_stat(self, handle: int, stat: int, value: int) -> bool:
        entity = self.entities.get(handle)
        if entity is None:
            return False
        if not -(1 << 31) <= value < (1 << 31):
            raise ValueError("stat value must fit Int32")
        entity.stats[stat] = value
        return True

    def get_stat(self, handle: int, stat: int) -> int:
        entity = self.entities.get(handle)
        return 0 if entity is None else entity.stats[stat]

    def add_stat_clamped(self, handle: int, stat: int, delta: int,
                         minimum: int, maximum: int) -> int:
        if handle not in self.entities:
            return 0
        value = min(maximum, max(minimum, self.get_stat(handle, stat) + delta))
        self.set_stat(handle, stat, value)
        return value

    def set_status(self, handle: int, mask: int) -> bool:
        entity = self.entities.get(handle)
        if entity is None:
            return False
        entity.status = mask
        return True

    def get_status(self, handle: int) -> int:
        entity = self.entities.get(handle)
        return 0 if entity is None else entity.status


def allocation_scenario() -> tuple[int, list[int]]:
    block = StatBlock(8)
    handles: list[int] = []
    dead: list[int] = []
    h = 2166136261
    for step in range(200):
        if (step % 5 == 4 or len(block.entities) == block.capacity) and handles:
            victim = handles.pop((step * 7) % len(handles))
            h = fnv(h, int(block.release(victim)))
            dead.append(victim)
        else:
            handle = block.allocate()
            handles.append(handle)
            h = fnv(h, handle)
            block.set_stat(handle, MAX_HP, 100_000)
            block.set_stat(handle, HP, step * 1000)
            h = fnv(h, block.add_stat_clamped(handle, HP, -step * 37, 0, 100_000))
            block.set_status(handle, (1 << 40) | step)
        for handle in dead[-3:]:
            h = fnv(h, int(block.set_stat(handle, ARMOR, 999)))
            h = fnv(h, block.get_stat(handle, HP))

    for handle in handles:
        for stat in range(STAT_COUNT):
            h = fnv(h, block.get_stat(handle, stat))
        status = block.get_status(handle)
        h = fnv(h, status)
        h = fnv(h, status >> 32)
    return h, handles


def main() -> None:
    h, handles = allocation_scenario()
    print("hash", h, "count", len(handles))
    print("first_handles", handles[:4])


if __name__ == "__main__":
    main()
