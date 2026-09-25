"""Generate graded practice deals with DDS (via endplay).

Declarer difficulty: play the hand double-dummy (both sides best, ties -> lowest card) and, at every
declarer/dummy turn where the contract is still makeable, add the fraction of legal cards that would
let the contract fail. Defence difficulty is the same measure for the defender the user plays.
"""
import random, json, sys, time
from endplay.types import Deal, Player, Denom, Vul
from endplay.dds import calc_dd_table, par, solve_board

RANKS = '23456789TJQKA'
SEATS = 'NESW'
VUL_TABLE = ['none', 'ns', 'ew', 'both', 'ns', 'ew', 'both', 'none', 'ew', 'both', 'none', 'ns', 'both', 'none', 'ns', 'ew']
VUL_ENUM = {'none': Vul.none, 'ns': Vul.ns, 'ew': Vul.ew, 'both': Vul.both}
DENOMS = [Denom.spades, Denom.hearts, Denom.diamonds, Denom.clubs, Denom.nt]
STRAIN_LETTER = {Denom.spades: 'S', Denom.hearts: 'H', Denom.diamonds: 'D', Denom.clubs: 'C', Denom.nt: 'NT'}

def random_pbn(rng):
    cards = [(s, r) for s in range(4) for r in range(13)]
    rng.shuffle(cards)
    hands = [[[] for _ in range(4)] for _ in range(4)]
    for i, (s, r) in enumerate(cards):
        hands[i % 4][s].append(r)
    return 'N:' + ' '.join('.'.join(''.join(RANKS[r] for r in sorted(h[s], reverse=True)) for s in range(4)) for h in hands)

def hcp(pbn):
    out = []
    for hand in pbn[2:].split():
        out.append(sum({'A': 4, 'K': 3, 'Q': 2, 'J': 1}.get(c, 0) for c in hand))
    return out  # N E S W

def dealer_of(board): return (board - 1) % 4
def vul_of(board): return VUL_TABLE[(board - 1) % 16]
def side_vul(vul, seat):
    return vul == 'both' or (vul == 'ns' and seat % 2 == 0) or (vul == 'ew' and seat % 2 == 1)

def line_difficulty(pbn, denom, declarer, target, focus):
    """Traps: along the double-dummy line, decisions of the focus seats where the novice card would
    lose (declarer: contract fails; defender: contract makes). Returns (traps, critical)."""
    from novice import state, declarer_novice, defender_novice
    d = Deal(pbn)
    d.trump = denom
    d.first = Player((declarer + 1) % 4)
    decl_side = {declarer, (declarer + 2) % 4}
    won = 0
    traps = 0
    critical = 0
    for trick in range(13):
        for _ in range(4):
            pl = d.curplayer.value
            res = list(solve_board(d))
            remaining = 13 - trick
            mover_decl = pl in decl_side
            finals = {(c.suit.value, int(__import__('math').log2(c.rank.value)) - 2): (c, won + (t if mover_decl else remaining - t)) for c, t in res}
            best = max(v for _, v in finals.values()) if mover_decl else min(v for _, v in finals.values())
            if pl in focus and len(finals) > 1:
                hands, cur, trump = state(d)
                if mover_decl:
                    if best >= target and any(v < target for _, v in finals.values()):
                        critical += 1
                        nov = declarer_novice(pl, hands, cur, trump)
                        if finals[nov][1] < target: traps += 1
                else:
                    if best < target and any(v >= target for _, v in finals.values()):
                        critical += 1
                        nov = defender_novice(pl, hands, cur, trump)
                        if finals[nov][1] >= target: traps += 1
            choice = min((c for c, v in finals.values() if v == best), key=lambda c: c.rank.value)
            d.play(choice)
        if d.first.value in decl_side:
            won += 1
    return traps, critical

def declarer_candidate(rng, board):
    pbn = random_pbn(rng)
    vul = vul_of(board)
    deal = Deal(pbn)
    table = calc_dd_table(deal)
    p = par(table, VUL_ENUM[vul], Player(dealer_of(board)))
    contracts = list(p)
    if not contracts:
        return None
    c = contracts[0]
    if c.level == 0 or c.penalty.name != 'passed':
        return None
    declarer = c.declarer.value
    h = hcp(pbn)
    if h[declarer] + h[(declarer + 2) % 4] < 20:
        return None
    denom = c.denom
    dd = table.to_list()[DENOMS.index(denom)][declarer]
    target = c.level + 6
    diff, critical = line_difficulty(pbn, denom, declarer, target, {declarer, (declarer + 2) % 4})
    return dict(board=board, pbn=pbn, contract=f"{c.level}{STRAIN_LETTER[denom]}", declarer=SEATS[declarer],
                ddTricks=dd, difficulty=diff, critical=critical)

def defense_candidate(rng, board):
    pbn = random_pbn(rng)
    h = hcp(pbn)
    ns, ew = h[0] + h[2], h[1] + h[3]
    side = [0, 2] if ns >= ew else [1, 3]
    if max(ns, ew) < 22:
        return None
    table = calc_dd_table(Deal(pbn)).to_list()
    # best strain for the strong side (by the stronger declarer of the pair)
    best = None
    for di, denom in enumerate(DENOMS):
        for seat in side:
            t = table[di][seat]
            key = (t + (0.5 if denom in (Denom.spades, Denom.hearts, Denom.nt) else 0), -h[seat])
            if best is None or key > best[0]:
                best = (key, denom, seat, t)
    _, denom, declarer, tricks = best
    level = tricks - 6 + 1          # one level too high: goes down one with best defence
    if level < 2 or level > 6:
        return None
    target = level + 6
    user = (declarer + 1) % 4       # the user sits on declarer's left and makes the opening lead
    diff, critical = line_difficulty(pbn, denom, declarer, target, {user})
    if critical == 0:
        return None
    return dict(board=board, pbn=pbn, contract=f"{level}{STRAIN_LETTER[denom]}", declarer=SEATS[declarer],
                ddTricks=tricks, userSeat=SEATS[user], difficulty=diff, critical=critical)

def contract_score(level, strain, tricks, vul):
    target = level + 6
    if tricks < target:
        return -(100 if vul else 50) * (target - tricks)
    per = 20 if strain in ('C', 'D') else 30
    first = 40 if strain == 'NT' else per
    trick_score = first + per * (level - 1)
    s = trick_score + ((500 if vul else 300) if trick_score >= 100 else 50) + per * (tricks - target)
    if level == 6: s += 750 if vul else 500
    if level == 7: s += 1500 if vul else 1000
    return s

def bidding_candidate(rng, board):
    pbn = random_pbn(rng)
    h = hcp(pbn)
    if h[0] + h[2] < 20:
        return None
    vul = vul_of(board)
    table = calc_dd_table(Deal(pbn)).to_list()
    ns_vul = side_vul(vul, 0)
    letters = ['S', 'H', 'D', 'C', 'NT']
    best_score, best = None, []
    for di, strain in enumerate(letters):
        for seat in (0, 2):
            t = table[di][seat]
            for level in range(1, 8):
                if t < level + 6:
                    continue
                sc = contract_score(level, strain, t, ns_vul)
                name = f"{level}{strain}{SEATS[seat]}"
                if best_score is None or sc > best_score:
                    best_score, best = sc, [name]
                elif sc == best_score:
                    best.append(name)
    if best_score is None or best_score <= 0:
        return None
    return dict(board=board, pbn=pbn, ddTable=table, bestScore=best_score, best=best)

if __name__ == '__main__':
    kind = sys.argv[1]; n = int(sys.argv[2]); seed = int(sys.argv[3])
    rng = random.Random(seed)
    fn = {'declarer': declarer_candidate, 'defense': defense_candidate, 'bidding': bidding_candidate}[kind]
    out = []
    t0 = time.time()
    tries = 0
    while len(out) < n:
        tries += 1
        board = rng.randint(1, 16)
        r = fn(rng, board)
        if r:
            out.append(r)
            print(json.dumps(r), flush=True)
    print(f'# {kind}: {len(out)} deals from {tries} tries in {time.time() - t0:.0f}s', file=sys.stderr)
