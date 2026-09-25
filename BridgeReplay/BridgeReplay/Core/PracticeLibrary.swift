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

    static let shared: PracticeLibrary = {
        guard let url = Bundle.main.url(forResource: "PracticeDeals", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(PracticeLibrary.self, from: data) else {
            return PracticeLibrary(version: 0, declarer: [], defense: [], bidding: [])
        }
        return library
    }()

    func deals(_ kind: PracticeKind, level: PracticeLevel) -> [PracticeDeal] {
        (kind == .declarer ? declarer : defense).filter { $0.level == level.rawValue }
    }

    func deal(id: String) -> PracticeDeal? {
        if id.hasPrefix("B") { return bidding.first { $0.id == id } }
        return (id.hasPrefix("F") ? defense : declarer).first { $0.id == id }
    }

    /// 同一级别里的下一副。
    func next(after id: String) -> PracticeDeal? {
        guard let current = deal(id: id) else { return nil }
        let list: [PracticeDeal]
        if id.hasPrefix("B") {
            list = bidding
        } else if let level = current.practiceLevel {
            list = deals(current.kind, level: level)
        } else {
            return nil
        }
        guard let index = list.firstIndex(where: { $0.id == id }), index + 1 < list.count else { return nil }
        return list[index + 1]
    }
}
