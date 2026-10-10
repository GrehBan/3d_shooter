# Эталонная модель для tests/golden/MovementAbilitiesGoldenTest.gd.
# Независимая реализация на Python: выдача слотов StatBlock (handle по
# поколениям), энергия ENERGY/MAX_ENERGY и MovementAbilities (кулдауны в
# логических тиках, плата энергией, регенерация). Тот же сценарий из 300
# логических тиков, что в golden-тесте.
#
# Запуск из корня репозитория:
#   python 3d-shooter/tests/tools/movement_ref.py
# Печатает строку «hash <число> activations <число>»; хеш должен совпадать с
# эталоном в golden-тесте.
M = 0xFFFFFFFF
SPAN = 1 << 16
KINDS = 6
DASH, DOUBLE_JUMP, SLIDE, WALL_RUN, GRAPPLE, TRIPLE_JUMP = range(6)
GROUND, AIR = 1, 2


def fnv(h, v):
    return ((h ^ (v & M)) * 16777619) & M


class Stats:
    def __init__(self, cap):
        self.cap = cap
        self.gen = [0] * cap
        self.alive = [0] * cap
        self.free = [cap - 1 - i for i in range(cap)]
        self.fc = cap
        self.energy = [0] * cap
        self.max_energy = [0] * cap

    def allocate(self):
        self.fc -= 1
        i = self.free[self.fc]
        self.alive[i] = 1
        self.energy[i] = 0
        self.max_energy[i] = 0
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
        self.alive[i] = 0
        self.gen[i] += 1
        self.free[self.fc] = i
        self.fc += 1

    def add_energy(self, h, d):
        i = self.idx(h)
        self.energy[i] = min(max(self.energy[i] + d, 0), self.max_energy[i])


class Abilities:
    def __init__(self, cap, regen):
        self.cap = cap
        self.regen = regen
        self.slot_host = [-1] * cap
        self.granted = {}  # (slot, kind) -> [cost, cooldown, flags, ready]
        self.active = []   # порядок как у плотного массива со swap-remove

    def _clear(self, s):
        n = 0
        for k in range(KINDS):
            if (s, k) in self.granted:
                del self.granted[(s, k)]
                n += 1
        self._deactivate(s)
        self.slot_host[s] = -1
        return n

    def _deactivate(self, s):
        for pos, e in enumerate(self.active):
            if e % SPAN == s:
                last = self.active.pop()
                if pos < len(self.active):
                    self.active[pos] = last
                return

    def grant(self, e, k, cost, cd, ground, air):
        s = e % SPAN
        if self.slot_host[s] != e:
            if self.slot_host[s] != -1:
                if e // SPAN < self.slot_host[s] // SPAN:
                    return False  # устаревший handle не трогает живую сущность
                self._clear(s)
            self.slot_host[s] = e
        flags = (GROUND if ground else 0) | (AIR if air else 0)
        if (s, k) not in self.granted:
            had = any((s, kk) in self.granted for kk in range(KINDS))
            self.granted[(s, k)] = [cost, cd, flags, 0]
            if not had:
                self.active.append(e)
        else:
            g = self.granted[(s, k)]
            g[0], g[1], g[2] = cost, cd, flags

    def revoke(self, e, k):
        s = e % SPAN
        if self.slot_host[s] != e or (s, k) not in self.granted:
            return False
        del self.granted[(s, k)]
        if not any((s, kk) in self.granted for kk in range(KINDS)):
            self._deactivate(s)
        return True

    def clear_entity(self, e):
        s = e % SPAN
        if self.slot_host[s] != e:
            return 0
        return self._clear(s)

    def try_activate(self, e, k, now, in_air, st):
        s = e % SPAN
        if self.slot_host[s] != e or (s, k) not in self.granted:
            return False
        g = self.granted[(s, k)]
        if now < g[3]:
            return False
        if not (g[2] & (AIR if in_air else GROUND)):
            return False
        i = st.idx(e)
        if i < 0 or st.energy[i] < g[0]:
            return False
        if g[0] > 0:
            st.add_energy(e, -g[0])
        g[3] = now + g[1]
        return True

    def regen_energy(self, st):
        for e in self.active:
            if st.idx(e) >= 0:
                st.add_energy(e, self.regen)


st = Stats(8)
ab = Abilities(8, 50)
ents = []
for _ in range(3):
    e = st.allocate()
    i = st.idx(e)
    st.max_energy[i] = 3000
    st.energy[i] = 3000
    ents.append(e)
ab.grant(ents[0], DASH, 1000, 6, True, True)
ab.grant(ents[0], DOUBLE_JUMP, 0, 10, False, True)
ab.grant(ents[1], DASH, 1000, 3, True, True)
ab.grant(ents[1], SLIDE, 500, 0, True, False)
ab.grant(ents[2], GRAPPLE, 1500, 20, True, True)
h = 2166136261
activations = 0
for t in range(300):
    if t == 100:
        h = fnv(h, ab.clear_entity(ents[1]))
        st.release(ents[1])
        e = st.allocate()
        i = st.idx(e)
        st.max_energy[i] = 2000
        st.energy[i] = 500
        ents[1] = e
        ab.grant(e, DASH, 700, 4, True, True)
    if t == 150:
        ab.grant(ents[0], DASH, 800, 6, True, True)
    if t == 200:
        h = fnv(h, 1 if ab.revoke(ents[0], DOUBLE_JUMP) else 0)
    for n, e in enumerate(ents):
        k = (t * 7 + n * 3) % 11
        if k < KINDS:
            in_air = (t // 5 + n) % 2 == 1
            ok = ab.try_activate(e, k, t, in_air, st)
            activations += 1 if ok else 0
            h = fnv(h, 1 if ok else 0)
    ab.regen_energy(st)
    for e in ents:
        h = fnv(h, st.energy[st.idx(e)])
for e in ents:
    for k in range(KINDS):
        s = e % SPAN
        g = ab.granted.get((s, k)) if ab.slot_host[s] == e else None
        h = fnv(h, g[3] if g else -1)
h = fnv(h, len(ab.active))
print("hash", h, "activations", activations)
