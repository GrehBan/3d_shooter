"""Independent list/dictionary oracle for EffectRunnerGoldenTest.gd.

Run: python 3d-shooter/tests/tools/effect_runner_ref.py
Events contain immutable tuples of complete subscription identities. The model
sorts ordinary records and uses Python unbounded arithmetic, without runtime
ring buffers, packed state, or linked-list traversal.
"""

from collections import deque

SPAN = 65536
HIGH = 40000 * SPAN
INT64_MAX = (1 << 63) - 1
METRICS = (
    "accepted_events", "processed_events", "inspected_candidates",
    "executed_actions", "condition_refusals", "cooldown_refusals",
    "stale_skips", "deferred_steps", "configuration_errors", "dropped_events",
)


class Model:
    def __init__(self, rules, quota=3):
        self.rules = tuple(tuple(rule) for rule in rules)
        self.quota = quota
        self.owners = {HIGH}
        self.entries = {}
        self.generation = [0] * 8
        self.free = list(reversed(range(8)))
        self.add_order = []
        self.words = []
        self.reset_room()

    def add(self, owner, rule, phase, priority, slot):
        for handle in tuple(reversed(self.add_order)):
            entry = self.entries[handle]
            if entry[0] % SPAN == owner % SPAN and entry[0] != owner:
                self.remove(handle)
        index = self.free.pop()
        handle = self.generation[index] * SPAN + index
        self.entries[handle] = (owner, rule, phase, priority, slot)
        self.add_order.append(handle)
        self.words.append(handle)
        return handle

    def remove(self, handle):
        del self.entries[handle]
        self.add_order.remove(handle)
        index = handle % SPAN
        self.generation[index] += 1
        self.free.append(index)

    def enqueue(self, owner, value):
        if owner not in self.owners:
            self.words.append(0)
            return
        bindings = sorted(
            (h for h, e in self.entries.items() if e[0] == owner),
            key=lambda h: (*self.entries[h][2:], self.entries[h][1], h),
        )
        self.words.append(1)
        if bindings:
            self.pending.append([owner, value, tuple(bindings), 0])
            self.metrics["accepted_events"] += 1

    def step(self, tick):
        used = 0
        if tick >= 0 and tick > self.last_tick:
            self.last_tick = tick
            while self.pending and used < self.quota:
                owner, value, bindings, cursor = self.pending[0]
                handle = bindings[cursor]
                used += 1
                self.metrics["inspected_candidates"] += 1
                if owner not in self.owners or handle not in self.entries:
                    self.metrics["stale_skips"] += 1
                else:
                    rule = self.rules[self.entries[handle][1]]
                    condition, minimum, increment, cooldown = rule
                    counter, last = self.state.get(handle, (0, -1))
                    if condition == 1 and value < minimum:
                        self.metrics["condition_refusals"] += 1
                    elif last >= 0 and tick - last < cooldown:
                        self.metrics["cooldown_refusals"] += 1
                    elif counter + increment > INT64_MAX:
                        self.metrics["configuration_errors"] += 1
                    else:
                        self.state[handle] = (counter + increment, tick)
                        self.metrics["executed_actions"] += 1
                self.pending[0][3] += 1
                if cursor + 1 == len(bindings):
                    self.pending.popleft()
                    self.metrics["processed_events"] += 1
            if self.pending:
                self.metrics["deferred_steps"] += 1
        self.words.append(used)

    def reset_room(self):
        self.pending = deque()
        self.state = {}
        self.last_tick = -1
        self.metrics = dict.fromkeys(METRICS, 0)

    def record(self, label, watches):
        self.words.append(label)
        self.words.extend(self.metrics[name] for name in METRICS)
        self.words.extend((len(self.pending), len(watches)))
        self.words.extend(self.state.get(handle, (0, -1))[0] for handle in watches)


def reference():
    # condition, minimum event value, counter increment, cooldown logic ticks.
    model = Model(((0, 0, 1, 0), (1, 5, 7, 0), (0, 0, 3, 2), (1, 6, 11, 0)))
    a = model.add(HIGH, 0, 1, 0, 2)
    b = model.add(HIGH, 1, 0, 10, 1)
    c = model.add(HIGH, 2, 1, 0, 1)
    d = model.add(HIGH, 3, 2, -4, 0)
    watches = [a, b, c, d]
    model.enqueue(HIGH, 5)
    model.enqueue(HIGH, 6)
    for label, tick in enumerate((0, 0, 1, 0, 2)):
        model.step(tick)
        model.record(label, watches)

    model.enqueue(HIGH, 6)
    model.remove(b)
    model.words.append(1)
    b2 = model.add(HIGH, 1, 0, 10, 1)
    model.step(3)
    model.record(5, [a, b2, c, d])
    model.remove(d)
    model.words.append(1)
    model.step(4)
    model.record(6, [a, b2, c])

    model.enqueue(HIGH, 6)
    model.owners.remove(HIGH)
    model.words.append(1)
    owner = HIGH + SPAN
    model.owners.add(owner)
    model.words.append(owner)
    model.enqueue(HIGH, 6)
    model.step(5)
    model.record(7, [])
    e = model.add(owner, 2, 0, 0, 0)
    # The owner has default HP=0: allocation identity, rather than HP, is valid.
    model.enqueue(owner, 0)
    model.enqueue(owner, 0)
    model.step(6)
    model.record(8, [e])
    model.enqueue(owner, 0)
    model.step(7)
    model.record(9, [e])
    model.enqueue(owner, 0)
    model.step(8)
    model.record(10, [e])
    model.enqueue(owner, 0)
    # Diagnostics are already zero; reset must preserve FIFO/state/clock/metrics.
    model.record(11, [e])
    model.step(8)
    model.record(12, [e])
    model.step(10)
    model.record(13, [e])

    model.enqueue(owner, 0)
    model.reset_room()
    model.record(14, [e])
    model.step(0)
    model.enqueue(owner, 0)
    model.step(0)
    model.record(15, [e])
    model.step(1)
    model.record(16, [e])
    for label, tick in enumerate((INT64_MAX - 2, INT64_MAX - 1, INT64_MAX), 17):
        model.enqueue(owner, 0)
        model.step(tick)
        model.record(label, [e])
    digest = 2166136261
    for word in model.words:
        for half in (word & 0xFFFFFFFF, (word >> 32) & 0xFFFFFFFF):
            digest = ((digest ^ half) * 16777619) & 0xFFFFFFFF
    return digest, model.metrics, model.state[e][0], len(model.words)


def benchmark_reference():
    """Eight hits/shot at fifteen-tick spacing; work quota splits each shot."""
    model = Model(((0, 0, 1, 0), (1, 6000, 2, 0),
                   (1, 6001, 1, 0), (0, 0, 3, 1)), quota=16)
    entries = [model.add(HIGH, rule, 1, 0, rule) for rule in range(4)]
    for tick in range(1800):
        if tick % 15 == 0:
            for _ in range(8):
                model.enqueue(HIGH, 6000)
        model.step(tick)
    return model.metrics, [model.state.get(h, (0, -1))[0] for h in entries]


if __name__ == "__main__":
    digest, metrics, counter, words = reference()
    print(f"golden hash {digest} words {words} final_counter {counter} metrics {metrics}")
    metrics, counters = benchmark_reference()
    print(f"benchmark counters {counters} metrics {metrics}")
