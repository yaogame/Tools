import SwiftUI
import UIKit

/// 练习方式。
enum PracticeMode: String, Codable, CaseIterable, Identifiable {
    /// 你打庄家和明手，电脑防守。
    case robotDefense
    /// 四家都由你出，适合练习和补录线下的出牌。
    case allFour

    var id: String { rawValue }
    var name: String { self == .robotDefense ? "机器人防守" : "四家都由我出" }
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

@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var boards: [PracticeBoard] = []

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("boards.json") }
    private var photoDirectory: URL { directory.appendingPathComponent("photos", isDirectory: true) }

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        load()
    }

    func board(_ id: UUID) -> PracticeBoard? {
        boards.first { $0.id == id }
    }

    func save(_ board: PracticeBoard) {
        if let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
        } else {
            boards.insert(board, at: 0)
        }
        persist()
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
        persist()
    }

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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        boards = (try? decoder.decode([PracticeBoard].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(boards) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
