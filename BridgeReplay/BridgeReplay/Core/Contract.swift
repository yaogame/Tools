import Foundation

enum Strain: Int, Codable, CaseIterable, Identifiable {
    case clubs, diamonds, hearts, spades, notrump

    var id: Int { rawValue }
    var symbol: String { ["♣", "♦", "♥", "♠", "NT"][rawValue] }
    var name: String { ["梅花", "方块", "红心", "黑桃", "无将"][rawValue] }
    var isRed: Bool { self == .diamonds || self == .hearts }

    var trump: Suit? {
        switch self {
        case .clubs: return .clubs
        case .diamonds: return .diamonds
        case .hearts: return .hearts
        case .spades: return .spades
        case .notrump: return nil
        }
    }
}

enum Doubling: Int, Codable, CaseIterable, Identifiable {
    case undoubled, doubled, redoubled

    var id: Int { rawValue }
    var suffix: String { ["", "X", "XX"][rawValue] }
    var name: String { ["不加倍", "加倍 X", "再加倍 XX"][rawValue] }
}

/// 定约：阶数、花色、加倍情况和庄家。由用户手动录入。
struct Contract: Codable, Hashable {
    var level: Int
    var strain: Strain
    var doubling: Doubling
    var declarer: Seat

    init(level: Int, strain: Strain, doubling: Doubling = .undoubled, declarer: Seat) {
        self.level = min(max(level, 1), 7)
        self.strain = strain
        self.doubling = doubling
        self.declarer = declarer
    }

    /// 解析 "3NT"、"4SX"、"6HXX" 这类写法。
    init?(text: String, declarer: Seat) {
        let t = text.uppercased().replacingOccurrences(of: " ", with: "")
        guard let first = t.first, let level = first.wholeNumberValue, (1...7).contains(level) else { return nil }
        var rest = t.dropFirst()
        let strain: Strain
        if rest.hasPrefix("NT") { strain = .notrump; rest = rest.dropFirst(2) }
        else if rest.hasPrefix("N") { strain = .notrump; rest = rest.dropFirst() }
        else if let c = rest.first, let s = Contract.strainLetters[c] { strain = s; rest = rest.dropFirst() }
        else { return nil }
        let doubling: Doubling = rest.hasPrefix("XX") ? .redoubled : (rest.hasPrefix("X") ? .doubled : .undoubled)
        self.init(level: level, strain: strain, doubling: doubling, declarer: declarer)
    }

    private static let strainLetters: [Character: Strain] = ["C": .clubs, "D": .diamonds, "H": .hearts, "S": .spades]

    var trump: Suit? { strain.trump }
    var dummy: Seat { declarer.partner }
    var openingLeader: Seat { declarer.next }
    /// 完成定约所需墩数。
    var target: Int { level + 6 }
    var label: String { "\(level)\(strain.symbol)\(doubling.suffix)" }
    var fullLabel: String { "\(label) \(declarer.name)家" }

    /// 庄家方得分（负数为宕牌罚分）。
    func score(declarerTricks tricks: Int, vulnerable: Bool) -> Int {
        let multiplier = [1, 2, 4][doubling.rawValue]
        if tricks >= target {
            let perTrick = (strain == .clubs || strain == .diamonds) ? 20 : 30
            let firstTrick = strain == .notrump ? 40 : perTrick
            let trickScore = (firstTrick + perTrick * (level - 1)) * multiplier
            var score = trickScore
            score += trickScore >= 100 ? (vulnerable ? 500 : 300) : 50
            if level == 6 { score += vulnerable ? 750 : 500 }
            if level == 7 { score += vulnerable ? 1500 : 1000 }
            if doubling == .doubled { score += 50 }
            if doubling == .redoubled { score += 100 }
            let over = tricks - target
            switch doubling {
            case .undoubled: score += over * perTrick
            case .doubled: score += over * (vulnerable ? 200 : 100)
            case .redoubled: score += over * (vulnerable ? 400 : 200)
            }
            return score
        }
        let down = target - tricks
        if doubling == .undoubled { return -down * (vulnerable ? 100 : 50) }
        var penalty = 0
        for i in 1...down {
            if vulnerable { penalty += i == 1 ? 200 : 300 }
            else { penalty += i == 1 ? 100 : (i <= 3 ? 200 : 300) }
        }
        return -penalty * (doubling == .redoubled ? 2 : 1)
    }

    /// "刚好完成" / "超 1" / "宕 2"
    func resultText(declarerTricks tricks: Int) -> String {
        let diff = tricks - target
        if diff == 0 { return "刚好完成" }
        return diff > 0 ? "超 \(diff)" : "宕 \(-diff)"
    }
}
