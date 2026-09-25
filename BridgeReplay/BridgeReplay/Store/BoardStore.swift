import SwiftUI
import UIKit

/// 练习方式。
enum PracticeMode: String, Codable, CaseIterable, Identifiable {
    /// 你打庄家和明手，电脑防守。
    case robotDefense
    /// 四家都由你出，适合练习和补录线下的出牌。
    case allFour
    /// 你防守一家，电脑打庄家、明手和你的同伴。
    case defense

    var id: String { rawValue }
    var name: String {
        switch self {
        case .robotDefense: return "机器人防守"
        case .allFour: return "四家都由我出"
        case .defense: return "防守练习"
        }
    }
}

/// 机器人防守的水平。
enum RobotLevel: String, Codable, CaseIterable, Identifiable {
    /// 常规打法：第二家小、第三家大、长套第四大首攻。
    case club
    /// 双明手最优防守。
    case expert

    var id: String { rawValue }
    var name: String { self == .club ? "常规" : "最强" }
}

/// 一次线上重打的记录。
struct Attempt: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var mode: PracticeMode
    var robotLevel: RobotLevel
    var contract: Contract
    var startPlayCount: Int
    var plays: [Play]
    var declarerTricks: Int
    /// 坐在下方的一家（坐庄是庄家，防守练习是你防守的那家）。
    var viewer: Seat?
    /// 来自分级练习牌库时的编号。
    var practiceID: String?

    var viewerSeat: Seat { viewer ?? contract.declarer }
    var viewerIsDeclarerSide: Bool { viewerSeat.isSameSide(as: contract.declarer) }
    var viewerTricks: Int { viewerIsDeclarerSide ? declarerTricks : 13 - declarerTricks }
    /// 坐庄完成定约 / 防守打宕定约。
    var succeeded: Bool { viewerIsDeclarerSide ? declarerTricks >= contract.target : declarerTricks < contract.target }
}

/// 一副需要重打的牌。
struct PracticeBoard: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var boardNumber: Int
    var dealer: Seat
    var vulnerability: Vulnerability
    var deal: Deal
    /// 定约由用户手动录入。
    var contract: Contract?
    /// 线下庄家拿到的墩数（选填）。
    var offlineTricks: Int?
    /// 恢复点：线下已经出过的牌。
    var restorePlays: [Play] = []
    var attempts: [Attempt] = []
    var photoFileName: String?
    /// 来自分级练习牌库时的编号（这类牌不显示在"我的牌局"里）。
    var practiceID: String?

    init(boardNumber: Int = 1, deal: Deal = Deal()) {
        self.boardNumber = boardNumber
        self.dealer = BoardNumbering.dealer(board: boardNumber)
        self.vulnerability = BoardNumbering.vulnerability(board: boardNumber)
        self.deal = deal
    }

    var title: String { "第 \(boardNumber) 副" }

    var declarerVulnerable: Bool {
        guard let contract else { return false }
        return vulnerability.isVulnerable(contract.declarer)
    }
}

/// 收藏的牌例：一副牌、定约，以及保存时已经出过的牌。
struct DealExample: Codable, Identifiable, Hashable {
    var id = UUID()
    var createdAt = Date()
    var title: String
    var note: String
    var boardNumber: Int
    var dealer: Seat
    var vulnerability: Vulnerability
    var deal: Deal
    var contract: Contract?
    /// 保存时已经出过的牌，练习从这里开始。
    var plays: [Play]
    /// 练习时坐在下方的一家。
    var viewer: Seat?
    /// 练习记录存在这副牌局里。
    var boardID: UUID?

    var pbn: String {
        var lines = [
            "[Event \"坐庄复盘 · 牌例\"]",
            "[Board \"\(boardNumber)\"]",
            "[Dealer \"\(dealer.letter)\"]",
            "[Vulnerable \"\(PBNText.vulnerability(vulnerability))\"]",
            "[Deal \"\(deal.pbn(first: dealer))\"]",
        ]
        if let contract {
            lines.append("[Declarer \"\(contract.declarer.letter)\"]")
            lines.append("[Contract \"\(PBNText.contract(contract))\"]")
        }
        if !note.isEmpty { lines.append("{\(note)}") }
        return lines.joined(separator: "\n")
    }
}

enum PBNText {
    static func vulnerability(_ v: Vulnerability) -> String {
        switch v {
        case .none: return "None"
        case .northSouth: return "NS"
        case .eastWest: return "EW"
        case .both: return "All"
        }
    }

    static func contract(_ c: Contract) -> String {
        let strain = ["C", "D", "H", "S", "NT"][c.strain.rawValue]
        return "\(c.level)\(strain)\(c.doubling.suffix)"
    }
}

/// 叫牌练习的一次结果。
struct BiddingResult: Codable, Hashable {
    var date = Date()
    var calls: [Call]
    var contract: Contract?
    var score: Int
    var bestScore: Int
}

@MainActor
final class BoardStore: ObservableObject {
    /// 你录入的牌局（线下复盘）。
    @Published private(set) var boards: [PracticeBoard] = []
    /// 分级练习、牌例用到的牌局（不显示在"我的牌局"里）。
    @Published private(set) var practiceBoards: [PracticeBoard] = []
    @Published private(set) var examples: [DealExample] = []
    @Published private(set) var biddingResults: [String: [BiddingResult]] = [:]

    private let directory: URL
    private var photoDirectory: URL { directory.appendingPathComponent("photos", isDirectory: true) }

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        boards = load("boards.json") ?? []
        practiceBoards = load("practice.json") ?? []
        examples = load("examples.json") ?? []
        biddingResults = load("bidding.json") ?? [:]
    }

    // MARK: - 牌局

    func board(_ id: UUID) -> PracticeBoard? {
        boards.first { $0.id == id } ?? practiceBoards.first { $0.id == id }
    }

    func save(_ board: PracticeBoard) {
        if board.practiceID != nil {
            if let index = practiceBoards.firstIndex(where: { $0.id == board.id }) {
                practiceBoards[index] = board
            } else {
                practiceBoards.append(board)
            }
            write(practiceBoards, to: "practice.json")
        } else {
            if let index = boards.firstIndex(where: { $0.id == board.id }) {
                boards[index] = board
            } else {
                boards.insert(board, at: 0)
            }
            write(boards, to: "boards.json")
        }
    }

    func update(_ id: UUID, _ change: (inout PracticeBoard) -> Void) {
        guard var board = board(id) else { return }
        change(&board)
        save(board)
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            if let name = boards[index].photoFileName {
                try? FileManager.default.removeItem(at: photoURL(name))
            }
        }
        boards.remove(atOffsets: offsets)
        write(boards, to: "boards.json")
    }

    // MARK: - 分级练习

    /// 练习牌库里这副牌对应的牌局（第一次打开时创建）。
    func practiceBoard(for item: PracticeDeal) -> PracticeBoard? {
        if let existing = practiceBoards.first(where: { $0.practiceID == item.id }) { return existing }
        guard let deal = item.deal else { return nil }
        var board = PracticeBoard(boardNumber: item.board, deal: deal)
        board.contract = item.contractValue
        board.practiceID = item.id
        save(board)
        return board
    }

    func attempts(forPractice id: String) -> [Attempt] {
        practiceBoards.first { $0.practiceID == id }?.attempts ?? []
    }

    // MARK: - 牌例

    func saveExample(_ example: DealExample) {
        if let index = examples.firstIndex(where: { $0.id == example.id }) {
            examples[index] = example
        } else {
            examples.insert(example, at: 0)
        }
        write(examples, to: "examples.json")
    }

    func deleteExamples(at offsets: IndexSet) {
        examples.remove(atOffsets: offsets)
        write(examples, to: "examples.json")
    }

    func deleteExample(_ id: UUID) {
        examples.removeAll { $0.id == id }
        write(examples, to: "examples.json")
    }

    /// 练习这个牌例用的牌局：原来的牌局还在就用它，否则新建一个。
    func boardForExample(_ id: UUID) -> PracticeBoard? {
        guard var example = examples.first(where: { $0.id == id }) else { return nil }
        if let boardID = example.boardID, let board = board(boardID) { return board }
        var board = PracticeBoard(boardNumber: example.boardNumber, deal: example.deal)
        board.dealer = example.dealer
        board.vulnerability = example.vulnerability
        board.contract = example.contract
        board.practiceID = "example:" + example.id.uuidString
        save(board)
        example.boardID = board.id
        saveExample(example)
        return board
    }

    // MARK: - 叫牌练习

    func recordBidding(_ result: BiddingResult, for id: String) {
        biddingResults[id, default: []].append(result)
        write(biddingResults, to: "bidding.json")
    }

    // MARK: - 照片

    func savePhoto(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: photoURL(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func photoURL(_ name: String) -> URL {
        photoDirectory.appendingPathComponent(name)
    }

    func photo(for board: PracticeBoard) -> UIImage? {
        guard let name = board.photoFileName else { return nil }
        return UIImage(contentsOfFile: photoURL(name).path)
    }

    // MARK: - 读写

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
