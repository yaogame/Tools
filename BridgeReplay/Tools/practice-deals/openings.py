"""Opening-bid topics for bidding practice (natural system: 5-card majors, 1NT 15-17, strong 2C, weak twos)."""
import json, random, sys, time
from multiprocessing import Pool
from endplay.types import Deal
from endplay.dds import calc_dd_table
import gen

def north_info(pbn):
    north = pbn[2:].split()[0]
    suits = north.split('.')              # S H D C
    lens = [len(x) for x in suits]
    hcp = sum({'A': 4, 'K': 3, 'Q': 2, 'J': 1}.get(c, 0) for c in north)
    return hcp, lens, suits

def opening(pbn):
    hcp, (s, h, d, c), suits = north_info(pbn)
    lens = sorted([s, h, d, c], reverse=True)
    balanced = min(s, h, d, c) >= 2 and sorted([s, h, d, c]).count(2) <= 1
    if hcp >= 22: return '2C'
    if balanced and 20 <= hcp <= 21: return '2NT'
    if balanced and 15 <= hcp <= 17 and s < 5 and h < 5: return '1NT'
    if hcp >= 12 or (hcp >= 11 and hcp + lens[0] + lens[1] >= 20):
        if s >= 5 or h >= 5: return '1S' if s >= h else '1H'
        if d > c: return '1D'
        if c > d: return '1C'
        return '1C' if d == 3 else '1D'
    if 5 <= hcp <= 10:
        for L, name in ((s, 'S'), (h, 'H'), (d, 'D')):
            if L == 6: return '2' + name
        for L, name in ((s, 'S'), (h, 'H'), (d, 'D'), (c, 'C')):
            if L == 7: return '3' + name
    return None

TOPIC = {'1S': 'major', '1H': 'major', '1C': 'minor', '1D': 'minor', '1NT': 'nt', '2NT': 'strong', '2C': 'strong',
         '2D': 'preempt', '2H': 'preempt', '2S': 'preempt', '3C': 'preempt', '3D': 'preempt', '3H': 'preempt', '3S': 'preempt'}

def candidate(rng):
    board = rng.choice([1, 5, 9, 13])      # dealer North
    pbn = gen.random_pbn(rng)
    op = opening(pbn)
    if op is None: return None
    vul = gen.vul_of(board)
    table = calc_dd_table(Deal(pbn)).to_list()
    ns_vul = gen.side_vul(vul, 0)
    letters = ['S', 'H', 'D', 'C', 'NT']
    best_score, best = None, []
    for di, strain in enumerate(letters):
        for seat in (0, 2):
            t = table[di][seat]
            for level in range(1, 8):
                sc = gen.contract_score(level, strain, t, ns_vul)
                name = f"{level}{strain}{gen.SEATS[seat]}"
                if best_score is None or sc > best_score: best_score, best = sc, [name]
                elif sc == best_score: best.append(name)
    return dict(board=board, pbn=pbn, ddTable=table, bestScore=best_score, best=best[:6], opening=op, topic=TOPIC[op])

def worker(seed):
    rng = random.Random(seed)
    return [r for r in (candidate(rng) for _ in range(60)) if r]

if __name__ == '__main__':
    want = {'major': 30, 'minor': 30, 'nt': 30, 'strong': 30, 'preempt': 30}
    bins = {k: [] for k in want}
    per_open = {}
    seed = 50000
    with Pool(4) as pool:
        while any(len(bins[k]) < want[k] for k in want):
            for rows in pool.imap_unordered(worker, range(seed, seed + 8)):
                for r in rows:
                    k = r['topic']
                    # keep a mix of openings inside a topic
                    cap = {'1S': 15, '1H': 15, '1C': 15, '1D': 15, '2NT': 12, '2C': 18}.get(r['opening'], 30)
                    if len(bins[k]) < want[k] and per_open.get(r['opening'], 0) < cap:
                        bins[k].append(r); per_open[r['opening']] = per_open.get(r['opening'], 0) + 1
            seed += 8
            print({k: len(v) for k, v in bins.items()}, flush=True)
    lib = json.load(open('PracticeDeals.json'))
    lib['bidding'] = [dict(r, topic='mixed') for r in lib['bidding'] if r.get('topic') in (None, 'mixed')]
    order = ['major', 'minor', 'nt', 'strong', 'preempt']
    for k in order:
        for i, r in enumerate(bins[k]):
            r['id'] = f"BT-{k}-{i+1:03d}"
            lib['bidding'].append(r)
    json.dump(lib, open('PracticeDeals.json', 'w'), ensure_ascii=False, separators=(',', ':'))
    print('openings', per_open, 'bidding total', len(lib['bidding']))
