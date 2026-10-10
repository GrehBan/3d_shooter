# Эталонная модель для tests/golden/AttackContextGoldenTest.gd.
# Независимая реализация HandlePool + AttackContextPool на Python (целые
# произвольной точности) и тот же сценарий цепной молнии, что в golden-тесте.
#
# Запуск из корня репозитория:
#   python 3d-shooter/tests/tools/acp_ref.py
# Печатает строку «hash 1200451129 n 81 opened 15 depth_ref 1 budget_ref 2»
# и список результатов. Хеш должен совпадать с эталоном в golden-тесте.
# Папка tests/tools исключена из импорта Godot файлом .gdignore.
M=0xFFFFFFFF
SPAN=1<<16
def fnv(h,v): return ((h ^ (v & M))*16777619)&M
class HP:
    def __init__(s,cap):
        s.cap=cap; s.gen=[0]*cap; s.alive=[0]*cap; s.free=[cap-1-i for i in range(cap)]; s.fc=cap
    def alloc(s):
        if s.fc==0: return -1
        s.fc-=1; i=s.free[s.fc]; s.alive[i]=1; return s.gen[i]*SPAN+i
    def idx(s,h):
        if h<0: return -1
        i=h%SPAN
        if i>=s.cap or not s.alive[i]: return -1
        if h//SPAN!=s.gen[i]: return -1
        return i
    def handle_at(s,i): return s.gen[i]*SPAN+i if s.alive[i] else -1
    def release(s,h):
        i=s.idx(h)
        if i<0: return False
        s.alive[i]=0; s.gen[i]+=1; s.free[s.fc]=i; s.fc+=1; return True
class ACP:
    MAXD=4; HITS=64
    def __init__(s,cap):
        s.h=HP(cap); n=cap
        s.root=[0]*n; s.parent=[0]*n; s.depth=[0]*n; s.budget=[0]*n; s.open=[0]*n
        s.nxt=[0]*n; s.closed=[0]*n; s.hits=[[] for _ in range(n)]
        s.depth_ref=0; s.budget_ref=0
    def _slot(s):
        c=s.h.alloc()
        if c<0: return -1
        i=s.h.idx(c); s.closed[i]=0; s.hits[i]=[]; return c
    def open_root(s,src,b):
        c=s._slot(); i=s.h.idx(c)
        s.root[i]=c; s.parent[i]=-1; s.depth[i]=0; s.budget[i]=max(b,0); s.open[i]=1; s.nxt[i]=-1
        return c
    def open_child(s,p):
        pi=s.h.idx(p)
        if pi<0: return -1
        d=s.depth[pi]+1
        if d>s.MAXD: s.depth_ref+=1; return -1
        c=s._slot()
        if c<0: return -1
        i=s.h.idx(c); r=s.root[pi]; ri=s.h.idx(r)
        s.root[i]=r; s.parent[i]=p; s.depth[i]=d; s.budget[i]=0; s.open[i]=0; s.open[ri]+=1
        s.nxt[i]=s.nxt[ri]; s.nxt[ri]=i
        return c
    def branch_has(s,i,t):
        cur=i
        while cur!=-1:
            if t in s.hits[cur]: return True
            p=s.parent[cur]; cur=-1 if p==-1 else s.h.idx(p)
        return False
    def hit(s,c,t):
        i=s.h.idx(c)
        if i<0 or s.closed[i]: return False
        if s.branch_has(i,t): return False
        ri=s.h.idx(s.root[i])
        if s.budget[ri]<=0: s.budget_ref+=1; return False
        if len(s.hits[i])>=s.HITS: return False
        s.hits[i].append(t); s.budget[ri]-=1; return True
    def close(s,c):
        i=s.h.idx(c)
        if i<0 or s.closed[i]: return False
        s.closed[i]=1; ri=s.h.idx(s.root[i]); s.open[ri]-=1
        if s.open[ri]>0: return False
        cur=ri
        while cur!=-1:
            n=s.nxt[cur]; s.h.release(s.h.handle_at(cur)); cur=n
        return True

T=[(i%3)*SPAN+(i%7) for i in range(25)]
pool=ACP(32)
res=[]
root=pool.open_root(7,23); res.append(root)
opened=[root]; queue=[(root,0)]; step=0
while queue and step<60:
    ctx,seed=queue.pop(0)
    for b in range(3):
        t=T[(seed*3+b)%25]
        ok=pool.hit(ctx,t); res.append(1 if ok else 0)
        if ok and b<2:
            ch=pool.open_child(ctx); res.append(ch)
            if ch!=-1: opened.append(ch); queue.append((ch,seed*3+b+1))
    step+=1
for c in opened: res.append(1 if pool.close(c) else 0)
res.append(1 if pool.h.idx(root)>=0 else 0)
res += [pool.depth_ref, pool.budget_ref, len(opened), pool.h.fc]
h=2166136261
for v in res: h=fnv(h,v)
print("hash",h,"n",len(res),"opened",len(opened),"depth_ref",pool.depth_ref,"budget_ref",pool.budget_ref)
print(res[:20])
