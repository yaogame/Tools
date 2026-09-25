import Foundation

/// 分级练习的难度。
enum PracticeLevel: Int, CaseIterable, Identifiable, Codable {
    case beginner = 1, intermediate, advanced, master

    var id: Int { rawValue }
    var name: String { ["初级", "中级", "高级", "大师级"][rawValue - 1] }

    func summary(for kind: PracticeKind) -> String {
        switch (kind, self) {
        case (.declarer, .beginner): return "照常规打法就能完成定约"
        case (.declarer, .intermediate): return "有 1 个关键决定，照常规打会失败"
        case (.declarer, .advanced): return "有 2–3 个关键决定"
        case (.declarer, .master): return "4 个以上关键决定，需要精确的计划"
        case (.defense, .beginner): return "照常规防守就能打宕"
        case (.defense, .intermediate): return "有 1 个关键决定"
        case (.defense, .advanced): return "有 2 个关键决定"
        case (.defense, .master): return "3 个以上关键决定"
        }
    }
}

enum PracticeKind: String, Codable, Hashable {
    case declarer, defense
    var name: String { self == .declarer ? "坐庄练习" : "防守练习" }
}

/// 练习牌库里的一副牌（打包在 App 里，由 Tools/practice-deals 生成）。
struct PracticeDeal: Codable, Identifiable, Hashable {
    let id: String
    let board: Int
    let pbn: String
    var level: Int?
    var contract: String?
    var declarer: String?
    /// 双明手下庄家能拿的墩数。
    var ddTricks: Int?
    /// 照常规打法会出错的关键决定数。
    var traps: Int?
    /// 防守练习里你坐的位置。
    var userSeat: String?
    /// 叫牌练习：双明手墩数表，按 ♠ ♥ ♦ ♣ NT，每行 北 东 南 西。
    var ddTable: [[Int]]?
    var bestScore: Int?
    var best: [String]?
    /// 叫牌专题：推荐的开叫（如 "1S"、"1NT"、"2C"）。
    var opening: String?
    /// 叫牌专题的编号，见 BiddingTopic。
    var topic: String?

    var biddingTopic: BiddingTopic { topic.flatMap { BiddingTopic(rawValue: $0) } ?? .mixed }

    /// 推荐开叫换成叫品。
    var openingCall: Call? {
        guard let opening, let contract = Contract(text: opening, declarer: .north) else { return nil }
        return .bid(contract.level, contract.strain)
    }

    var kind: PracticeKind { id.hasPrefix("F") ? .defense : .declarer }
    var deal: Deal? { try? DealParser.parsePBN(pbn).deal }
    var dealer: Seat { BoardNumbering.dealer(board: board) }
    var vulnerability: Vulnerability { BoardNumbering.vulnerability(board: board) }
    var practiceLevel: PracticeLevel? { level.flatMap { PracticeLevel(rawValue: $0) } }

    var contractValue: Contract? {
        guard let contract, let d = declarer?.first, let seat = Seat(letter: d) else { return nil }
        return Contract(text: contract, declarer: seat)
    }

    var userSeatValue: Seat? { userSeat?.first.flatMap { Seat(letter: $0) } }

    /// 叫牌练习：某家打某个花色，双明手能拿几墩。
    func ddTricks(strain: Strain, declarer: Seat) -> Int? {
        guard let table = ddTable else { return nil }
        let row: Int
        switch strain {
        case .spades: row = 0
        case .hearts: row = 1
        case .diamonds: row = 2
        case .clubs: row = 3
        case .notrump: row = 4
        }
        guard row < table.count, declarer.rawValue < table[row].count else { return nil }
        return table[row][declarer.rawValue]
    }

    /// 序号（在同一级别里从 1 开始）。
    var number: Int { Int(id.split(separator: "-").last ?? "") ?? 0 }
}

struct PracticeLibrary: Codable {
    let version: Int
    let declarer: [PracticeDeal]
    let defense: [PracticeDeal]
    let bidding: [PracticeDeal]

    /// 牌库直接编在代码里（PracticeDealsData.swift），不依赖资源文件打包。
    static let shared: PracticeLibrary = {
        guard let raw = try? JSONDecoder().decode(RawLibrary.self, from: Data(practiceDealsJSON.utf8)) else {
            return PracticeLibrary(version: 0, declarer: [], defense: [], bidding: [])
        }
        return PracticeLibrary(version: raw.version,
                               declarer: raw.declarer.compactMap(\.value),
                               defense: raw.defense.compactMap(\.value),
                               bidding: raw.bidding.compactMap(\.value))
    }()

    /// 逐条解码，个别条目出错只跳过那一条。
    private struct RawLibrary: Decodable {
        let version: Int
        let declarer: [Lossy]
        let defense: [Lossy]
        let bidding: [Lossy]
    }

    private struct Lossy: Decodable {
        let value: PracticeDeal?
        init(from decoder: Decoder) throws {
            value = try? PracticeDeal(from: decoder)
        }
    }

    func deals(_ kind: PracticeKind, level: PracticeLevel) -> [PracticeDeal] {
        (kind == .declarer ? declarer : defense).filter { $0.level == level.rawValue }
    }

    func deal(id: String) -> PracticeDeal? {
        if id.hasPrefix("B") { return bidding.first { $0.id == id } }
        return (id.hasPrefix("F") ? defense : declarer).first { $0.id == id }
    }

    func bidding(_ topic: BiddingTopic) -> [PracticeDeal] {
        bidding.filter { $0.biddingTopic == topic }
    }

    /// 同一级别（叫牌是同一专题）里的下一副。
    func next(after id: String) -> PracticeDeal? {
        guard let current = deal(id: id) else { return nil }
        let list: [PracticeDeal]
        if id.hasPrefix("B") {
            list = bidding(current.biddingTopic)
        } else if let level = current.practiceLevel {
            list = deals(current.kind, level: level)
        } else {
            return nil
        }
        guard let index = list.firstIndex(where: { $0.id == id }), index + 1 < list.count else { return nil }
        return list[index + 1]
    }
}

/// 叫牌练习的专题。按自然制：五张高花、1NT 15–17 点、强 2♣、弱二。
enum BiddingTopic: String, CaseIterable, Identifiable, Codable {
    case major, minor, nt, strong, preempt, mixed

    var id: String { rawValue }

    var name: String {
        switch self {
        case .major: return "1 阶高花开叫"
        case .minor: return "1 阶低花开叫"
        case .nt: return "1NT 开叫"
        case .strong: return "强开叫（2♣ / 2NT）"
        case .preempt: return "阻击开叫（弱二 / 三阶）"
        case .mixed: return "综合练习"
        }
    }

    var rule: String {
        switch self {
        case .major: return "12–21 点，5 张以上高花；两门 5 张先叫 ♠。"
        case .minor: return "12–21 点，没有 5 张高花、不适合 1NT：方块长叫 1♦，梅花长叫 1♣；3-3 叫 1♣，4-4 叫 1♦。"
        case .nt: return "15–17 点平均牌型，没有 5 张高花。"
        case .strong: return "22 点以上开叫 2♣；20–21 点平均牌型开叫 2NT。"
        case .preempt: return "5–10 点：6 张好套开叫 2♦ / 2♥ / 2♠，7 张套开叫三阶。"
        case .mixed: return "南北合计 20 点以上的随机牌，叫到得分最高的定约。"
        }
    }

    var systemImage: String {
        switch self {
        case .major: return "suit.spade.fill"
        case .minor: return "suit.club.fill"
        case .nt: return "circle.grid.2x2"
        case .strong: return "bolt.fill"
        case .preempt: return "hand.raised.fill"
        case .mixed: return "shuffle"
        }
    }
}
