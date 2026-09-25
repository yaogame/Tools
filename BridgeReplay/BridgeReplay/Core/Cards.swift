import Foundation

/// 座位，按顺时针顺序：北、东、南、西。
enum Seat: Int, CaseIterable, Codable, Hashable, Identifiable {
    case north = 0, east, south, west

    var id: Int { rawValue }
    var next: Seat { Seat(rawValue: (rawValue + 1) % 4)! }
    var partner: Seat { Seat(rawValue: (rawValue + 2) % 4)! }
    var previous: Seat { Seat(rawValue: (rawValue + 3) % 4)! }
    var isNorthSouth: Bool { rawValue % 2 == 0 }

    func isSameSide(as other: Seat) -> Bool { rawValue % 2 == other.rawValue % 2 }

    var name: String { ["北", "东", "南", "西"][rawValue] }
    var letter: Character { Array("NESW")[rawValue] }

    init?(letter: Character) {
        guard let index = Array("NESW").firstIndex(of: Character(letter.uppercased())) else { return nil }
        self.init(rawValue: index)
    }
}

/// 花色。rawValue 顺序与 PBN 一致：黑桃、红心、方块、梅花。
enum Suit: Int, CaseIterable, Codable, Hashable, Identifiable {
    case spades = 0, hearts, diamonds, clubs

    var id: Int { rawValue }
    var symbol: String { ["♠", "♥", "♦", "♣"][rawValue] }
    var name: String { ["黑桃", "红心", "方块", "梅花"][rawValue] }
    var letter: Character { Array("SHDC")[rawValue] }
    var isRed: Bool { self == .hearts || self == .diamonds }

    /// 手牌展示顺序，红黑相间便于辨认。
    static let displayOrder: [Suit] = [.spades, .hearts, .clubs, .diamonds]

    init?(letter: Character) {
        guard let index = Array("SHDC").firstIndex(of: Character(letter.uppercased())) else { return nil }
        self.init(rawValue: index)
    }
}

/// 一张牌。rank 0...12 对应 2...A。
struct Card: Hashable, Codable, Identifiable, Comparable, CustomStringConvertible {
    let suit: Suit
    let rank: Int

    static let rankChars = Array("23456789TJQKA")

    init(suit: Suit, rank: Int) {
        precondition((0...12).contains(rank), "rank out of range")
        self.suit = suit
        self.rank = rank
    }

    /// 解析 "SA"、"♠A"、"H10"、"DT" 这类写法。
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let suit: Suit?
        switch first {
        case "♠": suit = .spades
        case "♥", "♡": suit = .hearts
        case "♦", "♢": suit = .diamonds
        case "♣": suit = .clubs
        default: suit = Suit(letter: first)
        }
        guard let suit, let rank = Card.rank(from: String(trimmed.dropFirst())) else { return nil }
        self.init(suit: suit, rank: rank)
    }

    static func rank(from text: String) -> Int? {
        let t = text.uppercased()
        if t == "10" { return 8 }
        guard t.count == 1, let c = t.first, let index = rankChars.firstIndex(of: c) else { return nil }
        return index
    }

    var id: Int { suit.rawValue * 13 + rank }
    var rankLabel: String { rank == 8 ? "10" : String(Card.rankChars[rank]) }
    var rankChar: Character { Card.rankChars[rank] }
    var label: String { suit.symbol + rankLabel }
    var spokenName: String { suit.name + rankLabel }
    var description: String { label }
    /// 大牌点：A=4 K=3 Q=2 J=1。
    var hcp: Int { max(0, rank - 8) }

    static func < (lhs: Card, rhs: Card) -> Bool { lhs.id < rhs.id }

    static let fullDeck: [Card] = Suit.allCases.flatMap { suit in (0...12).map { Card(suit: suit, rank: $0) } }
}

extension Array where Element == Card {
    /// 按展示顺序（花色红黑相间、同花色从大到小）排序。
    func sortedForDisplay(order: [Suit] = Suit.displayOrder) -> [Card] {
        sorted { a, b in
            let ia = order.firstIndex(of: a.suit)!, ib = order.firstIndex(of: b.suit)!
            return ia != ib ? ia < ib : a.rank > b.rank
        }
    }

    func cards(in suit: Suit) -> [Card] {
        filter { $0.suit == suit }.sorted { $0.rank > $1.rank }
    }
}
