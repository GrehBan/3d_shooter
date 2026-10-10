# Эталонная модель для tests/golden/CombatContractsGoldenTest.gd.
# Сквозной сценарий контрактов M1a на Python: mock-дробовик → Damageable →
# HitEventQueue (канонический порядок) → AttackContext (бюджет, защита ветки,
# цепной удар) → EffectHost (ON_HIT-бонусы) → DamagePayloadBuffer → StatBlock
# (смерть и респавн в том же слоте), плюс рывок MovementAbilities.
# Порядок перемешивания попаданий в модели не нужен: очередь приводит их к
# каноническому порядку, а GDScript-тест проверяет это двумя сидами.
#
# Запуск из корня репозитория:
#   python 3d-shooter/tests/tools/combat_contracts_ref.py
# Печатает строку «hash <число>»; хеш должен совпадать с эталоном в golden-тесте.
M = 0xFFFFFFFF
SPAN = 1 << 16
SHOTS, PELLETS, ENEMIES = 12, 6, 6
ENEMY_HP = 20000
BONUS = {1: 500, 2: 100}


def fnv(h, v):
    return ((h ^ (v & M)) * 16777619) & M


class Pool:
    def __init__(self, cap):
        self.cap, self.gen, self.alive = cap, [0] * cap, [0] * cap
        self.free, self.fc = [cap - 1 - i for i in range(cap)], cap

    def alloc(self):
        self.fc -= 1
        i = self.free[self.fc]
        self.alive[i] = 1
        return self.gen[i] * SPAN + i

    def idx(self, h):
        if h < 0:
            return -1
        i = h % SPAN
        return i if i < self.cap and self.alive[i] and h // SPAN == self.gen[i] else -1

    def release(self, h):
        i = self.idx(h)
        self.alive[i] = 0
        self.gen[i] += 1
        self.free[self.fc] = i
        self.fc += 1


def prefix(t, s, k, p):
    x = t & 0xFFFF
    x = (x << 16) | (s & 0xFFFF)
    x = (x << 4) | (k & 0xF)
    return (x << 17) | (p & 0x1FFFF)


stats = Pool(16)
hp, max_hp, energy = {}, {}, {}
player = stats.alloc()
energy[player] = 3000
enemies = []
for _ in range(ENEMIES):
    e = stats.alloc()
    hp[e] = max_hp[e] = ENEMY_HP
    enemies.append(e)
dash_ready = 0
h = 2166136261
for shot in range(SHOTS):
    tick = shot * 3
    ok = tick >= dash_ready and energy[player] >= 1000
    if ok:
        energy[player] -= 1000
        dash_ready = tick + 5
    h = fnv(h, 1 if ok else 0)
    for _ in range(3):
        energy[player] = min(energy[player] + 200, 3000)
    events = []
    for p in range(PELLETS):
        t = enemies[(shot + p * p) % ENEMIES]
        events.append((t, player, 0, shot * 16 + p))
    events.sort(key=lambda e: (prefix(*e),) + e)
    # AttackContext: корень (бюджет 4) и цепной дочерний контекст
    budget = 4
    root_hits, child_hits = [], []
    payloads = []
    chain_opened = False
    for t, s, k, p in events:
        if t in root_hits or budget <= 0:
            h = fnv(h, 0)
            continue
        root_hits.append(t)
        budget -= 1
        payloads.append((t, 3000 + BONUS[1] + BONUS[2]))
        h = fnv(h, t)
        if not chain_opened:
            chain_opened = True
            ct = enemies[((t % SPAN) - 1 + 1) % ENEMIES]
            chained = ct not in root_hits and ct not in child_hits and budget > 0
            if chained:
                child_hits.append(ct)
                budget -= 1
                payloads.append((ct, 1000))
            h = fnv(h, 1 if chained else 0)
    for t, amount in payloads:
        if stats.idx(t) < 0:
            h = fnv(h, -1)
            continue
        hp[t] = min(max(hp[t] - amount, 0), max_hp[t])
        h = fnv(h, hp[t])
        if hp[t] == 0:
            i = (t % SPAN) - 1
            stats.release(t)
            n = stats.alloc()
            hp[n] = max_hp[n] = ENEMY_HP
            enemies[i] = n
    h = fnv(h, 1)  # close(root) закрывает дерево последним
for e in enemies:
    h = fnv(h, e)
    h = fnv(h, hp[e])
h = fnv(h, energy[player])
print("hash", h)
