import Foundation

/// 一个局面的双明手结果（由 DDS 计算）。
struct DDPosition: Equatable {
    /// 轮到出牌的一家。
    let mover: Seat
    /// 每张可出的牌 → 打出后庄家方整副牌最终能拿到的墩数（之后双方都最优）。
    let values: [Card: Int]
    /// 双方都最优时庄家方最终的墩数。
    let declarerTricks: Int
    /// 对出牌方来说最好的牌。
    let bestCards: Set<Card>
}

/// DDS 是单线程的全局求解器，所以用 actor 串行调用。
actor DoubleDummyEngine {
    static let shared = DoubleDummyEngine()

    private init() {
        dds_bridge_init(96)
    }

    func analyze(_ state: PlayState) -> DDPosition? {
        DoubleDummyEngine.solve(state)
    }

    /// 逐张分析一次完整（或部分）的出牌过程，用于复盘。
    func review(deal: Deal, contract: Contract, plays: [Play], progress: @escaping @Sendable (Double) -> Void) -> PlayReview {
        var items: [PlayReviewItem] = []
        var boundary: [Int: Int] = [:]
        var state = PlayState(deal: deal, contract: contract)
        for (index, play) in plays.enumerated() {
            guard let position = DoubleDummyEngine.solve(state) else { break }
            if state.currentTrick.isEmpty { boundary[state.completedTricks.count] = position.declarerTricks }
            let after = position.values[play.card] ?? position.declarerTricks
            items.append(PlayReviewItem(index: index,
                                        play: play,
                                        trickNumber: state.trickNumber,
                                        before: position.declarerTricks,
                                        after: after,
                                        bestCards: position.bestCards,
                                        byDeclarerSide: play.seat.isSameSide(as: contract.declarer)))
            state.apply(play)
            progress(Double(index + 1) / Double(max(plays.count, 1)))
        }
        if state.currentTrick.isEmpty {
            if state.isFinished {
                boundary[13] = state.declarerTricks
            } else if let position = DoubleDummyEngine.solve(state) {
                boundary[state.completedTricks.count] = position.declarerTricks
            }
        }
        return PlayReview(items: items, declarerTricksAtTrickStart: boundary)
    }

    private static func solve(_ state: PlayState) -> DDPosition? {
        guard let mover = state.turn else { return nil }

        var remain = [UInt32](repeating: 0, count: 16)
        for seat in Seat.allCases {
            for card in state.hand(seat) {
                remain[seat.rawValue * 4 + card.suit.rawValue] |= UInt32(1) << UInt32(card.rank + 2)
            }
        }
        var trickSuit = [Int32](repeating: 0, count: 3)
        var trickRank = [Int32](repeating: 0, count: 3)
        for (i, play) in state.currentTrick.enumerated() {
            trickSuit[i] = Int32(play.card.suit.rawValue)
            trickRank[i] = Int32(play.card.rank + 2)
        }
        let first = state.currentTrick.first?.seat ?? state.leader
        let trump = Int32(state.trump?.rawValue ?? 4)

        var out = DDSCardScores()
        let result = dds_bridge_solve(trump, Int32(first.rawValue), trickSuit, trickRank, remain, &out)
        guard result == 1 else { return nil }

        let suits = int32Array(out.suit)
        let ranks = int32Array(out.rank)
        let equals = int32Array(out.equals)
        let scores = int32Array(out.score)

        let remainingTricks = 13 - state.completedTricks.count
        let moverIsDeclarer = mover.isSameSide(as: state.contract.declarer)
        var values: [Card: Int] = [:]
        for i in 0..<Int(out.count) {
            guard let suit = Suit(rawValue: Int(suits[i])) else { continue }
            let score = Int(scores[i])
            let total = state.declarerTricks + (moverIsDeclarer ? score : remainingTricks - score)
            var cardRanks = [Int(ranks[i]) - 2]
            for r in 0...12 where Int(equals[i]) & (1 << (r + 2)) != 0 { cardRanks.append(r) }
            for r in cardRanks where (0...12).contains(r) {
                values[Card(suit: suit, rank: r)] = total
            }
        }
        guard !values.isEmpty else { return nil }

        let best = moverIsDeclarer ? values.values.max()! : values.values.min()!
        return DDPosition(mover: mover,
                          values: values,
                          declarerTricks: best,
                          bestCards: Set(values.filter { $0.value == best }.map(\.key)))
    }

    private static func int32Array<T>(_ tuple: T) -> [Int32] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Int32.self)) }
    }
}

/// 复盘时每一张牌的双明手评估。
struct PlayReviewItem: Identifiable, Hashable {
    let index: Int
    let play: Play
    let trickNumber: Int
    /// 出这张牌之前，庄家方最终能拿的墩数。
    let before: Int
    /// 出这张牌之后，庄家方最终能拿的墩数。
    let after: Int
    let bestCards: Set<Card>
    let byDeclarerSide: Bool

    var id: Int { index }
    /// 对庄家方的影响：负数是庄家丢墩，正数是防守送墩。
    var swing: Int { after - before }
}

struct PlayReview {
    let items: [PlayReviewItem]
    /// 第 k 墩开始前（k 从 0 起，13 表示打完）庄家方能拿的墩数。
    let declarerTricksAtTrickStart: [Int: Int]

    var mistakes: [PlayReviewItem] { items.filter { $0.swing != 0 } }
}
