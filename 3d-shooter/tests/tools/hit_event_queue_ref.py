"""Independent sort model for tests/golden/HitEventQueueGoldenTest.gd.

Run from the repository root: python 3d-shooter/tests/tools/hit_event_queue_ref.py
Events are sorted directly by (prefix, complete fields), without packed record
indices, a preallocated key buffer, or the GDScript tie insertion algorithm.
"""

SPAN = 1 << 16
MASK32 = (1 << 32) - 1
Event = tuple[int, int, int, int]  # target, source, kind, payload


def fnv(h: int, value: int) -> int:
    return ((h ^ (value & MASK32)) * 16777619) & MASK32


def canonical_key(event: Event) -> tuple[tuple[int, int, int, int], Event]:
    target, source, kind, payload = event
    prefix = (target & (SPAN - 1), source & (SPAN - 1),
              kind & 15, payload & ((1 << 17) - 1))
    return prefix, event


def sorted_sequence() -> list[Event]:
    events = []
    for i in range(299, -1, -1):
        target = (i * 37) % 23 + ((i * 7) % 3) * SPAN
        source = -1 if i % 11 == 0 else (i * 13) % 17 + ((i * 5) % 2) * SPAN
        kind = (i * 3) % 4
        payload = (i * 104729) % (1 << 20) - (1 << 19)
        events.append((target, source, kind, payload))
    return sorted(events, key=canonical_key)


def main() -> None:
    events = sorted_sequence()
    h = 2166136261
    for event in events:
        for value in event:
            h = fnv(h, value)
    print("hash", h, "count", len(events))
    print("first_event", events[0])


if __name__ == "__main__":
    main()
