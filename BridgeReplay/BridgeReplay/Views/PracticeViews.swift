import SwiftUI

/// 每副练习牌的完成情况。
struct PracticeProgress {
    var played = 0
    var succeeded = 0

    static func status(of attempts: [Attempt]) -> (played: Bool, succeeded: Bool) {
        (!attempts.isEmpty, attempts.contains { $0.succeeded })
    }
}

extension BoardStore {
    /// 练习编号 → 这副牌的所有记录。
    var practiceAttempts: [String: [Attempt]] {
        var result: [String: [Attempt]] = [:]
        for board in practiceBoards {
            if let id = board.practiceID { result[id, default: []] += board.attempts }
        }
        return result
    }
}

/// 坐庄 / 防守练习首页：四个级别。
struct PracticeHomeView: View {
    let kind: PracticeKind
    @EnvironmentObject private var store: BoardStore
    @Environment(\.navigator) private var navigator

    var body: some View {
        let attempts = store.practiceAttempts
        List {
            Section {
                Text(intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("选择级别") {
                ForEach(PracticeLevel.allCases) { level in
                    let deals = PracticeLibrary.shared.deals(kind, level: level)
                    let stats = progressOf(deals, attempts: attempts)
                    NavigationLink(value: Route.practiceLevel(kind, level)) {
                        LevelRow(level: level, kind: kind, total: deals.count, progress: stats)
                    }
                }
            }
            if let next = nextUnplayed(attempts: attempts) {
                Section {
                    Button {
                        navigator.push(.practice(next.id))
                    } label: {
                        Label("继续练习：\(next.practiceLevel?.name ?? "") 第 \(next.number) 副", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle(kind.name)
    }

    private var intro: String {
        switch kind {
        case .declarer:
            return "随机生成、按双明手分析分级的牌。每副牌只要打对都能完成定约。你打庄家和明手，机器人按双明手最优防守。打的时候不提示墩数，打完在结果和复盘里看双明手分析。"
        case .defense:
            return "每副牌只要防对都能打宕一墩。你坐庄家左手首攻，同伴和庄家都由机器人按双明手打；每墩后显示防守还能拿几墩。"
        }
    }

    private func progressOf(_ deals: [PracticeDeal], attempts: [String: [Attempt]]) -> PracticeProgress {
        var p = PracticeProgress()
        for deal in deals {
            let s = PracticeProgress.status(of: attempts[deal.id] ?? [])
            if s.played { p.played += 1 }
            if s.succeeded { p.succeeded += 1 }
        }
        return p
    }

    private func nextUnplayed(attempts: [String: [Attempt]]) -> PracticeDeal? {
        for level in PracticeLevel.allCases {
            if let deal = PracticeLibrary.shared.deals(kind, level: level).first(where: { (attempts[$0.id] ?? []).isEmpty }) {
                return deal
            }
        }
        return nil
    }
}

private struct LevelRow: View {
    let level: PracticeLevel
    let kind: PracticeKind
    let total: Int
    let progress: PracticeProgress

    var body: some View {
        HStack(spacing: 14) {
            Text(level.name)
                .font(.system(.subheadline, design: .serif).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(color))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(total) 副").font(.body.weight(.semibold))
                    Spacer()
                    Text("已练 \(progress.played) · 成功 \(progress.succeeded)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(level.summary(for: kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(progress.succeeded), total: Double(max(total, 1)))
                    .tint(color)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch level {
        case .beginner: return Theme.felt
        case .intermediate: return Color(red: 0.12, green: 0.36, blue: 0.55)
        case .advanced: return Theme.brassText
        case .master: return Theme.cardBack
        }
    }
}

/// 一个级别里的所有牌。
struct PracticeLevelView: View {
    let kind: PracticeKind
    let level: PracticeLevel
    @EnvironmentObject private var store: BoardStore

    var body: some View {
        let attempts = store.practiceAttempts
        let deals = PracticeLibrary.shared.deals(kind, level: level)
        List {
            Section {
                Text(level.summary(for: kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("\(deals.count) 副") {
                ForEach(deals) { deal in
                    NavigationLink(value: Route.practice(deal.id)) {
                        PracticeDealRow(deal: deal, attempts: attempts[deal.id] ?? [])
                    }
                }
            }
        }
        .navigationTitle("\(kind.name) · \(level.name)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PracticeDealRow: View {
    let deal: PracticeDeal
    let attempts: [Attempt]

    var body: some View {
        let status = PracticeProgress.status(of: attempts)
        HStack(spacing: 12) {
            Image(systemName: status.succeeded ? "checkmark.seal.fill" : (status.played ? "xmark.seal" : "circle"))
                .font(.title3)
                .foregroundStyle(status.succeeded ? Theme.felt : (status.played ? Theme.red : Color.secondary))
                .frame(width: 28)
                .accessibilityLabel(status.succeeded ? "已成功" : (status.played ? "练过，未成功" : "未练"))
            VStack(alignment: .leading, spacing: 2) {
                Text("第 \(deal.number) 副 · \(deal.contractValue?.fullLabel ?? "")")
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let best = attempts.map(\.viewerTricks).max() {
                Text("最好 \(best) 墩")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts = ["\(deal.dealer.name)发牌", deal.vulnerability.name]
        if deal.kind == .defense, let seat = deal.userSeatValue { parts.append("你坐\(seat.name)家") }
        if !attempts.isEmpty { parts.append("练过 \(attempts.count) 次") }
        return parts.joined(separator: " · ")
    }
}

/// 打开一副练习牌：第一次时创建牌局，再进入牌桌。
struct PracticePlayContainer: View {
    let practiceID: String
    @EnvironmentObject private var store: BoardStore
    @State private var boardID: UUID?

    var body: some View {
        Group {
            if let item = PracticeLibrary.shared.deal(id: practiceID),
               let contract = item.contractValue,
               let id = boardID, let board = store.board(id) {
                PlayView(board: board, launch: launch(item, contract),
                         next: PracticeLibrary.shared.next(after: practiceID).map { Route.practice($0.id) })
            } else if PracticeLibrary.shared.deal(id: practiceID) == nil {
                ContentUnavailableView("找不到这副练习牌", systemImage: "questionmark.circle")
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if boardID == nil, let item = PracticeLibrary.shared.deal(id: practiceID) {
                boardID = store.practiceBoard(for: item)?.id
            }
        }
    }

    private func launch(_ item: PracticeDeal, _ contract: Contract) -> PlayLaunch {
        switch item.kind {
        case .declarer:
            return PlayLaunch(mode: .robotDefense, robotLevel: .expert, contract: contract, startPlays: [], practiceID: item.id)
        case .defense:
            return PlayLaunch(mode: .defense, robotLevel: .expert, contract: contract, startPlays: [],
                              viewer: item.userSeatValue, practiceID: item.id)
        }
    }
}
