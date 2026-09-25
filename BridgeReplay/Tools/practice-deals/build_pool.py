import json, random, sys, time
from multiprocessing import Pool
import gen

LEVELS = ['beginner', 'intermediate', 'advanced', 'master']
def decl_level(traps): return 0 if traps == 0 else 1 if traps == 1 else 2 if traps <= 3 else 3
def def_level(traps): return 0 if traps == 0 else 1 if traps == 1 else 2 if traps == 2 else 3

def worker(args):
    kind, seed = args
    rng = random.Random(seed)
    fn = {'declarer': gen.declarer_candidate, 'defense': gen.defense_candidate, 'bidding': gen.bidding_candidate}[kind]
    out = []
    for _ in range(40):
        board = rng.randint(1, 16)
        try:
            r = fn(rng, board)
        except Exception as e:
            r = None
        if r: out.append(r)
    return kind, out

def main():
    want = {'declarer': 50, 'defense': 30}
    bins = {k: [[] for _ in LEVELS] for k in want}
    bidding = []
    seen = set()
    seed = 1000
    t0 = time.time()
    with Pool(4) as pool:
        while True:
            need = [k for k in want if any(len(b) < want[k] for b in bins[k])]
            if len(bidding) < 100: need.append('bidding')
            if not need: break
            jobs = []
            for k in need:
                for _ in range(4):
                    seed += 1; jobs.append((k, seed))
            for kind, rows in pool.imap_unordered(worker, jobs):
                for r in rows:
                    if r['pbn'] in seen: continue
                    if kind == 'bidding':
                        if len(bidding) < 100: bidding.append(r); seen.add(r['pbn'])
                        continue
                    lv = (decl_level if kind == 'declarer' else def_level)(r['difficulty'])
                    if len(bins[kind][lv]) < want[kind]:
                        bins[kind][lv].append(r); seen.add(r['pbn'])
            status = {k: [len(b) for b in bins[k]] for k in bins}
            print(f'{time.time()-t0:.0f}s', status, 'bidding', len(bidding), flush=True)
    out = {'version': 1, 'declarer': [], 'defense': [], 'bidding': []}
    for kind, prefix in (('declarer', 'P'), ('defense', 'F')):
        for lv, rows in enumerate(bins[kind]):
            for i, r in enumerate(rows):
                r = dict(r); r['id'] = f'{prefix}{lv+1}-{i+1:03d}'; r['level'] = lv + 1
                r['traps'] = r.pop('difficulty')
                out[kind].append(r)
    for i, r in enumerate(bidding):
        r = dict(r); r['id'] = f'B-{i+1:03d}'; out['bidding'].append(r)
    json.dump(out, open('PracticeDeals.json', 'w'), ensure_ascii=False, separators=(',', ':'))
    print('done', {k: len(v) for k, v in out.items() if isinstance(v, list)}, f'{time.time()-t0:.0f}s')

if __name__ == '__main__':
    main()
