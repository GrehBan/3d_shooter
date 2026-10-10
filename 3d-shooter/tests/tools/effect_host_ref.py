# Эталонная модель для tests/golden/EffectHostGoldenTest.gd.
# Независимая реализация HandlePool + EffectHost на Python (списки вместо
# интрузивных ссылок, сортировка по ключу резолва) и тот же сценарий спавна,
# смерти и переиспользования слотов хостов, что в golden-тесте.
#
# Запуск из корня репозитория:
#   python 3d-shooter/tests/tools/effect_host_ref.py
# Печатает строку «hash <число> entries <число>»; хеш должен совпадать с
# эталоном в golden-тесте.
M = 0xFFFFFFFF
SPAN = 1 << 16
TRIGGERS = 18


def fnv(h, v):
    return ((h ^ (v & M)) * 16777619) & M


class HandlePool:
    def __init__(self, cap):
        self.cap = cap
        self.gen = [0] * cap
        self.alive = [0] * cap
        self.free = [cap - 1 - i for i in range(cap)]
        self.fc = cap

    def alloc(self):
        if self.fc == 0:
            return -1
        self.fc -= 1
        i = self.free[self.fc]
        self.alive[i] = 1
        return self.gen[i] * SPAN + i

    def idx(self, h):
        if h < 0:
            return -1
        i = h % SPAN
        if i >= self.cap or not self.alive[i] or h // SPAN != self.gen[i]:
            return -1
        return i

    def release(self, h):
        i = self.idx(h)
        if i < 0:
            return False
        self.alive[i] = 0
        self.gen[i] += 1
        self.free[self.fc] = i
        self.fc += 1
        return True


class EffectHost:
    def __init__(self, host_cap, entry_cap):
        self.host_cap = host_cap
        self.pool = HandlePool(entry_cap)
        self.slot_host = [-1] * host_cap
        self.entries = {}  # handle -> (host, trigger, phase, priority, slot_index, effect_id, state)

    def _slot(self, host):
        if host < 0:
            return -1
        s = host % SPAN
        return s if s < self.host_cap else -1

    def _clear_slot(self, s):
        # Как в EffectHost: обход списка хоста, где новые записи стоят первыми,
        # поэтому записи освобождаются в обратном порядке добавления. Порядок
        # освобождения задаёт порядок выдачи слотов записей дальше.
        removed = [h for h, e in self.entries.items() if e[0] % SPAN == s]
        removed.reverse()
        for h in removed:
            del self.entries[h]
            self.pool.release(h)
        self.slot_host[s] = -1
        return len(removed)

    def add(self, host, trig, phase, prio, slot_index, effect, state):
        s = self._slot(host)
        if s < 0:
            return -1
        if self.slot_host[s] != host:
            if self.slot_host[s] != -1:
                if host // SPAN < self.slot_host[s] // SPAN:
                    return -1  # устаревший handle не трогает живого хоста
                self._clear_slot(s)
            self.slot_host[s] = host
        h = self.pool.alloc()
        assert h != -1
        self.entries[h] = (host, trig, phase, prio, slot_index, effect, state)
        return h

    def remove(self, h):
        if h not in self.entries or self.pool.idx(h) < 0:
            return False
        host = self.entries[h][0]
        del self.entries[h]
        self.pool.release(h)
        s = host % SPAN
        if not any(e[0] % SPAN == s for e in self.entries.values()):
            self.slot_host[s] = -1
        return True

    def clear_host(self, host):
        s = self._slot(host)
        if s < 0 or self.slot_host[s] != host:
            return 0
        return self._clear_slot(s)

    def walk(self, host, trig):
        s = self._slot(host)
        if s < 0 or self.slot_host[s] != host:
            return []
        items = [(e[2], e[3], e[4], e[5], h, e) for h, e in self.entries.items() if e[0] == host and e[1] == trig]
        items.sort(key=lambda t: t[:5])
        return [(t[4], t[5]) for t in items]


eh = EffectHost(8, 256)
gens = [0] * 5
hosts = [i for i in range(5)]
stale = []
live = []
h = 2166136261
for step in range(200):
    k = (step * 37) % 101
    op = k % 10
    if op <= 5:
        e = eh.add(hosts[k % 5], k % 6, k % 3, (k * 7) % 5 - 2, (k * 3) % 4, k % 9, step)
        live.append(e)
        h = fnv(h, e)
    elif op == 6:
        if live:
            e = live.pop(k % len(live))
            h = fnv(h, 1 if eh.remove(e) else 0)
    elif op == 7:
        h = fnv(h, eh.clear_host(hosts[k % 5]))
    elif op == 8:
        i = k % 5
        stale.append(hosts[i])
        gens[i] += 1
        hosts[i] = gens[i] * SPAN + i
for host in hosts + stale[-3:]:
    for trig in range(6):
        for ent, e in eh.walk(host, trig):
            for v in (ent, e[5], e[2], e[3], e[4], e[6]):
                h = fnv(h, v)
        h = fnv(h, 0xABCD)
h = fnv(h, len(eh.entries))
print("hash", h, "entries", len(eh.entries))
