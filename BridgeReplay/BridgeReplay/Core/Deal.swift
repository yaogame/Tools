import Foundation

enum Vulnerability: String, Codable, CaseIterable, Identifiable {
    case none, northSouth, eastWest, both

    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: return "双无局"
        case .northSouth: return "南北有局"
        case .eastWest: return "东西有局"
        case .both: return "双有局"
        }
    }

    func isVulnerable(_ seat: Seat) -> Bool {
        switch self {
        case .none: return false
        case .both: return true
        case .northSouth: return seat.isNorthSouth
        case .eastWest: return !seat.isNorthSouth
        }
    }
}

/// 按副号推出发牌人和局况（标准 16 副循环）。
enum BoardNumbering {
    static func dealer(board: Int) -> Seat {
        Seat(rawValue: ((max(board, 1) - 1) % 4))!
    }

    static func vulnerability(board: Int) -> Vulnerability {
        let table: [Vulnerability] = [.none, .northSouth, .eastWest, .both,
                                      .northSouth, .eastWest, .both, .none,
                                      .eastWest, .both, .none, .northSouth,
                                      .both, .none, .northSouth, .eastWest]
        return table[(max(board, 1) - 1) % 16]
    }
}

/// 一副牌的四手。hands 按 Seat.rawValue 索引。
struct Deal: Codable, Hashable {
    var hands: [[Card]]

    init(hands: [[Card]] = [[], [], [], []]) {
        precondition(hands.count == 4)
        self.hands = hands
    }

    subscript(seat: Seat) -> [Card] {
        get { hands[seat.rawValue] }
        set { hands[seat.rawValue] = newValue }
    }

    func owner(of card: Card) -> Seat? {
        Seat.allCases.first { self[$0].contains(card) }
    }

    /// 把一张牌分给某家（从原来那家拿走）。再点同一家则收回。
    mutating func toggle(_ card: Card, for seat: Seat) {
        let current = owner(of: card)
        for s in Seat.allCases { self[s].removeAll { $0 == card } }
        if current != seat { self[seat].append(card) }
    }

    var unassigned: [Card] {
        let used = Set(hands.flatMap { $0 })
        return Card.fullDeck.filter { !used.contains($0) }
    }

    var isComplete: Bool {
        hands.allSatisfy { $0.count == 13 } && Set(hands.flatMap { $0 }).count == 52
    }

    /// 只剩一家没满且剩余的牌数正好补满时，可以按排除法补全。
    var canAutoComplete: Bool {
        let short = Seat.allCases.filter { self[$0].count < 13 }
        return short.count == 1 && unassigned.count == 13 - self[short[0]].count && !unassigned.isEmpty
    }

    mutating func autoComplete() {
        guard canAutoComplete, let seat = Seat.allCases.first(where: { self[$0].count < 13 }) else { return }
        self[seat].append(contentsOf: unassigned)
    }

    func hcp(_ seat: Seat) -> Int { self[seat].reduce(0) { $0 + $1.hcp } }

    /// 某家某花色的文字，如 "AK105"。
    func holding(_ seat: Seat, _ suit: Suit) -> String {
        let cards = self[seat].cards(in: suit)
        return cards.isEmpty ? "—" : cards.map(\.rankLabel).joined(separator: " ")
    }

    /// PBN 格式："N:A753.JT5.T94.KJ4 ..."
    func pbn(first: Seat = .north) -> String {
        var parts: [String] = []
        var seat = first
        for _ in 0..<4 {
            parts.append(Suit.allCases.map { suit in
                String(self[seat].cards(in: suit).map(\.rankChar))
            }.joined(separator: "."))
            seat = seat.next
        }
        return "\(first.letter):" + parts.joined(separator: " ")
    }
}

/// 从粘贴的文字里解析出来的牌局信息。
struct ImportedDeal {
    var deal: Deal
    var board: Int?
    var dealer: Seat?
    var vulnerability: Vulnerability?
    var contract: Contract?
}

enum DealParseError: LocalizedError {
    case notRecognized
    case invalidHand(String)
    case incomplete

    var errorDescription: String? {
        switch self {
        case .notRecognized: return "没有找到 PBN 或 LIN 格式的牌型"
        case .invalidHand(let h): return "这一手牌看不懂：\(h)"
        case .incomplete: return "四家牌加起来不是 52 张不重复的牌"
        }
    }
}

enum DealParser {
    static func parse(_ text: String) throws -> ImportedDeal {
        if text.contains("md|") { return try parseLIN(text) }
        return try parsePBN(text)
    }

    /// 解析 PBN。支持单独一行 "N:AKQ.xxx..." 或带 [Deal "..."] 等标签的完整记录。
    static func parsePBN(_ text: String) throws -> ImportedDeal {
        let normalized = text.replacingOccurrences(of: "10", with: "T")
        let pattern = #"([NESWnesw])\s*:\s*([AKQJTakqjt2-9.\-]+)\s+([AKQJTakqjt2-9.\-]+)\s+([AKQJTakqjt2-9.\-]+)\s+([AKQJTakqjt2-9.\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let firstRange = Range(match.range(at: 1), in: normalized),
              let first = Seat(letter: normalized[firstRange].first!) else {
            throw DealParseError.notRecognized
        }
        var deal = Deal()
        var seat = first
        for i in 2...5 {
            let hand = String(normalized[Range(match.range(at: i), in: normalized)!])
            deal[seat] = try parseDottedHand(hand)
            seat = seat.next
        }
        if !deal.isComplete { deal.autoComplete() }
        guard deal.isComplete else { throw DealParseError.incomplete }

        var result = ImportedDeal(deal: deal)
        if let board = tag("Board", in: text).flatMap({ Int($0) }) { result.board = board }
        if let d = tag("Dealer", in: text)?.first { result.dealer = Seat(letter: d) }
        if let v = tag("Vulnerable", in: text) {
            switch v.lowercased() {
            case "none", "love", "-": result.vulnerability = Vulnerability.none
            case "ns": result.vulnerability = .northSouth
            case "ew": result.vulnerability = .eastWest
            case "all", "both": result.vulnerability = .both
            default: break
            }
        }
        if let c = tag("Contract", in: text), let d = tag("Declarer", in: text)?.first, let declarer = Seat(letter: d) {
            result.contract = Contract(text: c, declarer: declarer)
        }
        return result
    }

    /// "A753.JT5.T94.KJ4"，花色顺序黑桃.红心.方块.梅花；"-" 表示缺门。
    static func parseDottedHand(_ text: String) throws -> [Card] {
        if text == "-" { return [] }
        let suits = text.split(separator: ".", omittingEmptySubsequences: false)
        guard suits.count == 4 else { throw DealParseError.invalidHand(text) }
        var cards: [Card] = []
        for (i, s) in suits.enumerated() where s != "-" {
            for ch in s {
                guard let rank = Card.rankChars.firstIndex(of: Character(ch.uppercased())) else {
                    throw DealParseError.invalidHand(text)
                }
                cards.append(Card(suit: Suit(rawValue: i)!, rank: rank))
            }
        }
        return cards
    }

    /// 解析 BBO 的 LIN：md|3SA753HJT5DT94CKJ4,S...,S...,|  先南、西、北、东。
    static func parseLIN(_ text: String) throws -> ImportedDeal {
        guard let md = linField("md", in: text), let dealerDigit = md.first?.wholeNumberValue else {
            throw DealParseError.notRecognized
        }
        let linSeats: [Seat] = [.south, .west, .north, .east]
        let hands = md.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        var deal = Deal()
        for (i, handText) in hands.prefix(4).enumerated() {
            var suit: Suit?
            var cards: [Card] = []
            let chars = Array(handText.uppercased())
            var index = 0
            while index < chars.count {
                let ch = chars[index]
                if let s = Suit(letter: ch), "SHDC".contains(ch) {
                    suit = s
                } else if ch == "1", index + 1 < chars.count, chars[index + 1] == "0", let suit {
                    cards.append(Card(suit: suit, rank: 8))
                    index += 1
                } else if let r = Card.rankChars.firstIndex(of: ch), let suit {
                    cards.append(Card(suit: suit, rank: r))
                } else {
                    throw DealParseError.invalidHand(String(handText))
                }
                index += 1
            }
            deal[linSeats[i]] = cards
        }
        if !deal.isComplete { deal.autoComplete() }
        guard deal.isComplete else { throw DealParseError.incomplete }

        var result = ImportedDeal(deal: deal)
        // LIN 发牌人：1 南 2 西 3 北 4 东
        let dealers: [Int: Seat] = [1: .south, 2: .west, 3: .north, 4: .east]
        result.dealer = dealers[dealerDigit]
        if let ah = linField("ah", in: text), let n = Int(ah.filter(\.isNumber)) { result.board = n }
        if let sv = linField("sv", in: text)?.lowercased().first {
            switch sv {
            case "o", "0": result.vulnerability = Vulnerability.none
            case "n": result.vulnerability = .northSouth
            case "e": result.vulnerability = .eastWest
            case "b": result.vulnerability = .both
            default: break
            }
        }
        return result
    }

    private static func tag(_ name: String, in text: String) -> String? {
        let pattern = "\\[\(name)\\s+\"([^\"]*)\"\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func linField(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)|") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "|") else { return nil }
        return String(rest[..<end])
    }
}
