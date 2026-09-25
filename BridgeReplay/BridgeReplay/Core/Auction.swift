import Foundation

/// 一次叫牌：不叫、加倍、再加倍或某个定约。
enum Call: Hashable, Codable {
    case pass
    case double
    case redouble
    case bid(Int, Strain)

    var label: String {
        switch self {
        case .pass: return "不叫"
        case .double: return "X"
        case .redouble: return "XX"
        case .bid(let level, let strain): return "\(level)\(strain.symbol)"
        }
    }

    /// 在叫牌阶梯上的序号：1♣ = 0 … 7NT = 34。
    var rank: Int? {
        if case .bid(let level, let strain) = self { return (level - 1) * 5 + strain.rawValue }
        return nil
    }
}

/// 叫牌过程。
struct Auction: Hashable, Codable {
    let dealer: Seat
    private(set) var calls: [Call] = []

    init(dealer: Seat) {
        self.dealer = dealer
    }

    /// 第 i 个叫品是谁叫的。
    func seat(at index: Int) -> Seat {
        Seat(rawValue: (dealer.rawValue + index) % 4)!
    }

    var nextSeat: Seat { seat(at: calls.count) }

    var lastBid: (index: Int, level: Int, strain: Strain)? {
        for (i, call) in calls.enumerated().reversed() {
            if case .bid(let level, let strain) = call { return (i, level, strain) }
        }
        return nil
    }

    var isFinished: Bool {
        guard calls.count >= 4 else { return false }
        let lastThree = calls.suffix(3)
        guard lastThree.allSatisfy({ $0 == .pass }) else { return false }
        return lastBid != nil || calls.count >= 4
    }

    var isPassedOut: Bool { isFinished && lastBid == nil }

    func isLegal(_ call: Call) -> Bool {
        guard !isFinished else { return false }
        switch call {
        case .pass:
            return true
        case .bid:
            guard let rank = call.rank else { return false }
            guard let last = lastBid else { return true }
            return rank > Call.bid(last.level, last.strain).rank!
        case .double:
            // 只能加倍对方最后一个没被加倍的定约。
            guard let last = lastBid, !seat(at: last.index).isSameSide(as: nextSeat) else { return false }
            return calls[(last.index + 1)...].allSatisfy { $0 == .pass }
        case .redouble:
            guard let last = lastBid, seat(at: last.index).isSameSide(as: nextSeat),
                  let doubled = calls.lastIndex(of: .double), doubled > last.index else { return false }
            return calls[(doubled + 1)...].allSatisfy { $0 == .pass } && !calls[(last.index + 1)...].contains(.redouble)
        }
    }

    mutating func make(_ call: Call) {
        guard isLegal(call) else { return }
        calls.append(call)
    }

    mutating func undo(to count: Int) {
        calls = Array(calls.prefix(max(0, count)))
    }

    /// 叫牌结束后的定约：庄家是这一方第一个叫出这个花色的人。
    var finalContract: Contract? {
        guard isFinished, let last = lastBid else { return nil }
        let winner = seat(at: last.index)
        var declarer = winner
        for (i, call) in calls.enumerated() {
            if case .bid(_, let strain) = call, strain == last.strain, seat(at: i).isSameSide(as: winner) {
                declarer = seat(at: i)
                break
            }
        }
        var doubling = Doubling.undoubled
        for call in calls[(last.index + 1)...] {
            if call == .double { doubling = .doubled }
            if call == .redouble { doubling = .redoubled }
        }
        return Contract(level: last.level, strain: last.strain, doubling: doubling, declarer: declarer)
    }
}

extension Array where Element == Card {
    /// 牌型，如 "5-3-3-2"（按 ♠♥♦♣）。
    var shapeText: String {
        Suit.allCases.map { suit in String(filter { $0.suit == suit }.count) }.joined(separator: "-")
    }

    var hcp: Int { reduce(0) { $0 + $1.hcp } }
}
