"""Novice card-play policies used to grade deals (also mirrored by the app's robots)."""
import math
from endplay.types import Player, Denom

def r0(card): return int(math.log2(card.rank.value)) - 2      # 0..12 = 2..A
def s0(card): return card.suit.value                            # 0..3 = S,H,D,C

def state(d):
    hands = {p: [(s0(c), r0(c)) for c in d[Player(p)]] for p in range(4)}
    first = d.first.value
    trick = [((first + i) % 4, s0(c), r0(c)) for i, c in enumerate(d.curtrick)]
    trump = None if d.trump == Denom.nt else d.trump.value
    return hands, trick, trump

def beats(a, b, trump):
    if a[0] == b[0]: return a[1] > b[1]
    return trump is not None and a[0] == trump

def winner(trick, trump):
    w = trick[0]
    for t in trick[1:]:
        if beats((t[1], t[2]), (w[1], w[2]), trump): w = t
    return w

def top_remaining(card, hands, trick):
    s, r = card
    for p in range(4):
        for (s2, r2) in hands[p]:
            if s2 == s and r2 > r: return False
    return True

def follow_policy(seat, hands, trick, trump):
    hand = hands[seat]
    led = trick[0][1]
    cur = winner(trick, trump)
    partner_winning = cur[0] == (seat + 2) % 4
    follow = sorted([c for c in hand if c[0] == led], key=lambda c: c[1])
    if follow:
        if partner_winning or len(trick) == 1:
            return follow[0]
        win = [c for c in follow if beats(c, (cur[1], cur[2]), trump)]
        return win[0] if win else follow[0]
    if trump is not None and not partner_winning:
        ruffs = sorted([c for c in hand if c[0] == trump and beats(c, (cur[1], cur[2]), trump)], key=lambda c: c[1])
        if ruffs: return ruffs[0]
    pool = [c for c in hand if c[0] != trump] or hand
    lengths = {s: sum(1 for c in hand if c[0] == s) for s in range(4)}
    return min(pool, key=lambda c: (-lengths[c[0]], c[1]))

def declarer_novice(seat, hands, trick, trump):
    hand = hands[seat]
    if trick:
        return follow_policy(seat, hands, trick, trump)
    defenders = [(seat + 1) % 4, (seat + 3) % 4]
    if trump is not None and any(c[0] == trump for p in defenders for c in hands[p]):
        tr = sorted([c for c in hand if c[0] == trump], key=lambda c: -c[1])
        if tr and top_remaining(tr[0], hands, trick):
            return tr[0]
    lengths = {s: sum(1 for c in hand if c[0] == s) for s in range(4)}
    tops = [c for c in hand if top_remaining(c, hands, trick)]
    if tops:
        return max(tops, key=lambda c: (lengths[c[0]], c[1]))
    pool = [c for c in hand if c[0] != trump] or hand
    return min(pool, key=lambda c: (-lengths[c[0]], c[1]))

def defender_novice(seat, hands, trick, trump):
    hand = hands[seat]
    if trick:
        return follow_policy(seat, hands, trick, trump)
    best = None
    for s in range(4):
        if s == trump: continue
        cs = sorted([c for c in hand if c[0] == s], key=lambda c: -c[1])
        if not cs: continue
        score = len(cs) * 100 + sum(max(0, c[1] - 8) for c in cs)
        if best is None or score > best[0]: best = (score, cs)
    if best is None:
        cs = sorted(hand, key=lambda c: -c[1]); return cs[-1]
    cs = best[1]
    if len(cs) >= 2 and cs[0][1] >= 9 and cs[0][1] - cs[1][1] == 1: return cs[0]
    return cs[3] if len(cs) >= 4 else cs[-1]
