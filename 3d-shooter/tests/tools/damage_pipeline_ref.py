"""Independent physical DamagePipeline oracle for DamagePipelineGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/damage_pipeline_ref.py
Entities are records keyed by complete handles; the queue is a Python deque.
Python's unbounded product and floor division specify mitigation directly,
independently of the runtime's overflow-safe int64 implementation.
Malformed records and diagnostics are covered by the separate unit suite.
"""

from collections import deque
from dataclasses import dataclass

MASK32 = (1 << 32) - 1
INT64_MAX = (1 << 63) - 1
INT32_MAX = (1 << 31) - 1
HIGH = 40000 * 65536
REPLACEMENT = 65536 + 2
BASE, POST_HIT = 0, 7
HP, MAX_HP, SHIELD, MAX_SHIELD, ARMOR, ENERGY, MAX_ENERGY = range(7)

# target, initial HP, initial shield, armor, raw amount
CASES = (
    (HIGH, 100000, 0, 0, 12345),
    (HIGH, 100000, 20000, 33333, 12345),
    (HIGH, 100000, 12345, 99999, 12345),
    (HIGH, 100000, 12344, 33333, 12346),
    (HIGH, 100000, 0, 33333, 100001),
    (HIGH, 100000, 0, 1, 100001),
    (HIGH, 100000, 0, 99999, 99999),
    (HIGH, 100000, 0, 99999, 100000),
    (HIGH, 100000, 0, -123, 100001),
    (HIGH, 100000, 2500, 100000, INT64_MAX),
    (HIGH, 100000, 2500, 100001, INT64_MAX - 1),
    (HIGH, INT32_MAX, INT32_MAX, 99999, INT64_MAX),
    (HIGH, INT32_MAX, 0, 0, INT64_MAX),
    (HIGH, INT32_MAX, 0, 33333, INT64_MAX - 65535),
    (HIGH, 1, 0, 99999, 100000),
    (HIGH, 1, 0, 99999, 99999),
    (HIGH, 12345, -17, 33333, 12346),
    (HIGH, 12345, -17, 33333, 0),
    (HIGH, 0, -17, 33333, INT64_MAX),
    (HIGH, -7, 3456, 33333, INT64_MAX),
    (1, 100000, 0, 0, INT64_MAX),
    (2, 100000, 4321, 33333, INT64_MAX),
    (REPLACEMENT, 100000, 4321, 33333, 5432),
    (-1, 100000, 4321, 33333, INT64_MAX),
    (HIGH + 1, 100000, 4321, 33333, INT64_MAX),
    (HIGH, INT32_MAX, INT32_MAX, 0, INT32_MAX),
    (HIGH, INT32_MAX, INT32_MAX, 0, INT32_MAX + 1),
    (HIGH, INT32_MAX, 1, 99999, 200001),
)


@dataclass
class Payload:
    source: int
    target: int
    amount: int
    tags: int
    context: int
    element: int = 0
    flags: int = 0
    phase: int = BASE


def payload(index: int) -> Payload:
    target, _, _, _, amount = CASES[index]
    source = -1 if index % 3 == 0 else (1 << 50) + index * 65536 + 7
    context = INT64_MAX - index * 65536 if index % 2 == 0 else -1
    tags = (1 << 60) + index if index % 2 == 0 else -(1 << 60) + index
    return Payload(source, target, amount, tags, context)


def resolve(record: Payload, entities: dict[int, list[int]]) -> int:
    target = entities.get(record.target)
    applied = 0
    if target is not None and target[HP] > 0 and record.amount > 0:
        available_shield = max(target[SHIELD], 0)
        absorbed = min(available_shield, record.amount)
        target[SHIELD] = available_shield - absorbed
        armor = min(100000, max(0, target[ARMOR]))
        mitigation = (record.amount - absorbed) * (100000 - armor) // 100000
        applied = min(target[HP], mitigation)
        target[HP] -= applied
    record.phase = POST_HIT
    return applied


def reference() -> tuple[int, int, int]:
    entities = {
        HIGH: [0, INT32_MAX, 0, INT32_MAX, 0, 4321, 9876],
        1: [0, 100000, 3456, 10000, 22222, 765, 1234],
        REPLACEMENT: [0, INT32_MAX, 0, INT32_MAX, 0, 4321, 9876],
    }
    pending = deque(payload(i) for i in range(3))
    next_index = 3
    head = 0
    words = [-1]  # Empty resolve before the first enqueue is an ordinary refusal.
    positive = 0
    for index, (_, hp, shield, armor, _) in enumerate(CASES):
        for handle in (HIGH, REPLACEMENT):
            entities[handle][HP] = hp
            entities[handle][SHIELD] = shield
            entities[handle][ARMOR] = armor
        record = pending[0]
        count = len(pending)
        applied = resolve(record, entities)
        positive += int(applied > 0)
        words.extend((index, head, count, applied, head, len(pending)))
        words.extend((record.source, record.target, record.context, record.amount,
                      record.tags, record.element, record.flags, record.phase))
        for handle in (HIGH, 1, REPLACEMENT):
            words.extend(entities[handle])
        pending.popleft()
        head = (head + 1) % 3
        if next_index < len(CASES):
            pending.append(payload(next_index))
            next_index += 1
    words.extend((-1, len(pending), 0, 0))  # Empty result, count, drops, errors.
    digest = 2166136261
    for word in words:
        for part in (word & MASK32, (word >> 32) & MASK32):
            digest = ((digest ^ part) * 16777619) & MASK32
    return digest, len(CASES), positive


if __name__ == "__main__":
    digest, resolved, positive = reference()
    print(f"hash {digest} resolved {resolved} positive_hp_results {positive}")
