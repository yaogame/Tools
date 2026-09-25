import Foundation

struct Play: Codable, Hashable {
    let seat: Seat
    let card: Card
}

struct Trick: Hashable {
    let leader: Seat
    let plays: [Play]
    let winner: Seat
}

/// 出牌过程的状态机：只保存出过的牌，其余全部由规则推出，方便撤销和恢复到任意一墩。
struct PlayState {
    let deal: Deal
    let contract: Contract

    private(set) var hands: [[Card]]
    private(set) var plays: [Play] = []
    private(set) var completedTricks: [Trick] = []
    private(set) var currentTrick: [Play] = []
    private(set) var leader: Seat

    init(deal: Deal, contract: Contract, plays: [Play] = []) {
        self.deal = deal
        self.contract = contract
        self.hands = deal.hands
        self.leader = contract.openingLeader
        for p in plays {
            if !apply(p) { break }
        }
    }

    var trump: Suit? { contract.trump }
    var isFinished: Bool { completedTricks.count == 13 }
    var turn: Seat? {
        if isFinished { return nil }
        return currentTrick.last.map { $0.seat.next } ?? leader
    }
    var trickNumber: Int { min(completedTricks.count + 1, 13) }

    func hand(_ seat: Seat) -> [Card] { hands[seat.rawValue] }

    func legalCards(for seat: Seat) -> [Card] {
        guard seat == turn else { return [] }
        let hand = self.hand(seat)
        guard let led = currentTrick.first?.card.suit else { return hand }
        let follow = hand.filter { $0.suit == led }
        return follow.isEmpty ? hand : follow
    }

    var declarerTricks: Int {
        completedTricks.filter { $0.winner.isSameSide(as: contract.declarer) }.count
    }
    var defenderTricks: Int { completedTricks.count - declarerTricks }
    var lastTrick: Trick? { completedTricks.last }

    /// 当前这墩（或者刚结束的上一墩）目前谁的牌最大。
    var currentWinner: Play? {
        currentTrick.isEmpty ? nil : PlayState.winningPlay(currentTrick, trump: trump)
    }

    @discardableResult
    mutating func apply(_ play: Play) -> Bool {
        guard play.seat == turn, legalCards(for: play.seat).contains(play.card) else { return false }
        hands[play.seat.rawValue].removeAll { $0 == play.card }
        plays.append(play)
        currentTrick.append(play)
        if currentTrick.count == 4 {
            let winner = PlayState.winningPlay(currentTrick, trump: trump).seat
            completedTricks.append(Trick(leader: leader, plays: currentTrick, winner: winner))
            leader = winner
            currentTrick = []
        }
        return true
    }

    static func beats(_ a: Card, _ b: Card, trump: Suit?) -> Bool {
        if a.suit == b.suit { return a.rank > b.rank }
        return a.suit == trump
    }

    static func winningPlay(_ plays: [Play], trump: Suit?) -> Play {
        var best = plays[0]
        for p in plays.dropFirst() where beats(p.card, best.card, trump: trump) { best = p }
        return best
    }

    /// 第 n 墩（从 1 开始）开始前的出牌序列，用于"从第 n 墩重打"。
    static func prefix(_ plays: [Play], beforeTrick n: Int) -> [Play] {
        Array(plays.prefix(max(0, (n - 1) * 4)))
    }
}

/// 俱乐部水平的防守：首攻长套第四大（有连张先出大），第二家小，第三家大，能盖就盖。
enum HeuristicDefender {
    static func choose(for seat: Seat, in state: PlayState) -> Card {
        let legal = state.legalCards(for: seat)
        let hand = state.hand(seat)
        let trump = state.trump
        let ascending = { (cards: [Card]) -> [Card] in cards.sorted { $0.rank < $1.rank } }

        guard let led = state.currentTrick.first else {
            return leadChoice(hand: hand, trump: trump)
        }
        let follow = ascending(hand.filter { $0.suit == led.card.suit })
        let winning = state.currentWinner!
        let partnerWinning = winning.seat == seat.partner

        if !follow.isEmpty {
            if state.currentTrick.count == 1 || partnerWinning { return follow[0] }
            let winners = follow.filter { PlayState.beats($0, winning.card, trump: trump) }
            return winners.first ?? follow[0]
        }
        if let trump, !partnerWinning {
            let ruffs = ascending(hand.filter { $0.suit == trump })
                .filter { PlayState.beats($0, winning.card, trump: trump) }
            if let ruff = ruffs.first { return ruff }
        }
        // 垫牌：从非将牌里挑最小的一张。
        let pool = hand.filter { $0.suit != trump }
        return ascending(pool.isEmpty ? legal : pool)[0]
    }

    private static func leadChoice(hand: [Card], trump: Suit?) -> Card {
        let holdings = Suit.allCases.map { hand.cards(in: $0) }.filter { !$0.isEmpty }
        let sideSuits = holdings.filter { $0[0].suit != trump }
        let pool = sideSuits.isEmpty ? holdings : sideSuits
        let score = { (cards: [Card]) -> Int in cards.count * 100 + cards.reduce(0) { $0 + max(0, $1.rank - 8) } }
        let cards = pool.max { score($0) < score($1) }!
        if cards.count >= 2, cards[0].rank >= 9, cards[0].rank - cards[1].rank == 1 { return cards[0] }
        return cards.count >= 4 ? cards[3] : cards[cards.count - 1]
    }
}
