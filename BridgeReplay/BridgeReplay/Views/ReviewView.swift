import SwiftUI

/// 复盘：线上结果、线下结果、双明手最优对比，逐墩走势和关键失误，可从任意一墩重打。
struct ReviewView: View {
    let boardID: UUID
    let attemptID: UUID

    @EnvironmentObject private var store: BoardStore
    @StateObject private var model = ReviewModel()
    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        if let board = store.board(boardID), let attempt = board.attempts.first(where: { $0.id == attemptID }) {
            content(board, attempt)
                .task { await model.load(deal: board.deal, attempt: attempt) }
        } else {
            ContentUnavailableView("找不到这次记录", systemImage: "questionmark.circle")
        }
    }

    private func content(_ board: PracticeBoard, _ attempt: Attempt) -> some View {
        let contract = attempt.contract
        let vulnerable = board.vulnerability.isVulnerable(contract.declarer)
        return List {
            Section {
                HStack(spacing: 10) {
                    summaryTile(title: "这次线上", tricks: attempt.declarerTricks, contract: contract, vulnerable: vulnerable, prominent: false)
                    if let best = model.review?.declarerTricksAtTrickStart[0] {
                        summaryTile(title: "双明手最优", tricks: best, contract: contract, vulnerable: vulnerable, prominent: true)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if let offline = board.offlineTricks {
                    HStack {
                        Text("线下")
                        Spacer()
                        Text("\(offline) 墩 · \(contract.resultText(declarerTricks: offline))")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("\(board.title) · \(contract.fullLabel) · \(attempt.mode.name)")
            }

            if let review = model.review {
                Section {
                    trend(review)
                } header: {
                    Text("每墩后双明手可得")
                } footer: {
                    Text("格子里是打完这一墩后，双方都按最优打时你最终能拿到的墩数。红点表示这一墩里丢了墩。")
                }

                mistakesSection(review, board: board, attempt: attempt)

                Section("逐墩记录") {
                    ForEach(tricks(attempt), id: \.number) { trick in
                        trickRow(trick, review: review, contract: contract)
                    }
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView(value: model.progress)
                        Text("双明手分析中…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("复盘")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summaryTile(title: String, tricks: Int, contract: Contract, vulnerable: Bool, prominent: Bool) -> some View {
        let score = contract.score(declarerTricks: tricks, vulnerable: vulnerable)
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).opacity(0.8)
            Text("\(tricks) 墩").font(.system(.title, design: .serif).weight(.bold))
            Text("\(contract.resultText(declarerTricks: tricks)) · \(score > 0 ? "+" : "")\(score)").font(.footnote)
        }
        .foregroundStyle(prominent ? Color.white : Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(prominent ? Theme.felt : Color.white))
    }

    private func trend(_ review: PlayReview) -> some View {
        HStack(spacing: 3) {
            ForEach(1...13, id: \.self) { n in
                let value = review.declarerTricksAtTrickStart[n]
                let previous = review.declarerTricksAtTrickStart[n - 1]
                let lost = value != nil && previous != nil && value! < previous!
                VStack(spacing: 2) {
                    Text(value.map { "\($0)" } ?? "·")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Circle().fill(lost ? Theme.red : Color.clear).frame(width: 5, height: 5)
                    Text("\(n)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(lost ? Theme.red.opacity(0.1) : Color.black.opacity(0.04)))
            }
        }
    }

    @ViewBuilder
    private func mistakesSection(_ review: PlayReview, board: PracticeBoard, attempt: Attempt) -> some View {
        let mistakes = review.mistakes
        Section {
            if mistakes.isEmpty {
                Label("这次没有丢墩，每一张都是双明手最优。", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.felt)
            }
            ForEach(mistakes) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("第 \(item.trickNumber) 墩")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(item.swing < 0 ? Theme.red : Theme.brass))
                            .foregroundStyle(.white)
                        Text(item.byDeclarerSide ? "庄家丢了 \(-item.swing) 墩" : "防守送了 \(item.swing) 墩")
                            .font(.subheadline.weight(.semibold))
                        if item.index < attempt.startPlayCount {
                            Text("线下")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .overlay(Capsule().strokeBorder(Color.secondary))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(item.play.seat.name)家出了")
                        cardText(item.play.card)
                        Text("，更好的是")
                        ForEach(item.bestCards.sorted { $0.rank > $1.rank }.prefix(4), id: \.self) { card in
                            cardText(card)
                        }
                    }
                    .font(.subheadline)
                    if item.byDeclarerSide {
                        NavigationLink(value: Route.play(board.id, PlayLaunch(mode: attempt.mode,
                                                                              robotLevel: attempt.robotLevel,
                                                                              contract: attempt.contract,
                                                                              startPlays: PlayState.prefix(attempt.plays, beforeTrick: item.trickNumber)))) {
                            Label("从第 \(item.trickNumber) 墩重打", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("关键的牌（含补录的线下出牌）")
        }
    }

    private struct TrickSummary {
        let number: Int
        let plays: [Play]
        let winner: Seat
    }

    private func tricks(_ attempt: Attempt) -> [TrickSummary] {
        let state = PlayState(deal: store.board(boardID)?.deal ?? Deal(), contract: attempt.contract, plays: attempt.plays)
        return state.completedTricks.enumerated().map { TrickSummary(number: $0.offset + 1, plays: $0.element.plays, winner: $0.element.winner) }
    }

    private func trickRow(_ trick: TrickSummary, review: PlayReview, contract: Contract) -> some View {
        let byIndex = Dictionary(uniqueKeysWithValues: review.items.map { ($0.index, $0) })
        let start = (trick.number - 1) * 4
        return HStack(spacing: 8) {
            Text("\(trick.number)")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            ForEach(Array(trick.plays.enumerated()), id: \.offset) { offset, play in
                let item = byIndex[start + offset]
                VStack(spacing: 1) {
                    Text(play.seat.name).font(.system(size: 10)).foregroundStyle(.secondary)
                    cardText(play.card)
                        .font(.system(.subheadline, design: .serif).weight(play.seat == trick.winner ? .bold : .regular))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(play.seat == trick.winner ? Theme.brass.opacity(0.3) : Color.clear))
                    Circle()
                        .fill((item?.swing ?? 0) != 0 ? ((item?.swing ?? 0) < 0 ? Theme.red : Theme.brass) : Color.clear)
                        .frame(width: 5, height: 5)
                }
                .frame(maxWidth: .infinity)
            }
            Text(trick.winner.isSameSide(as: contract.declarer) ? "庄" : "防")
                .font(.caption.weight(.bold))
                .foregroundStyle(trick.winner.isSameSide(as: contract.declarer) ? Theme.felt : Color.secondary)
                .frame(width: 22)
        }
    }

    private func cardText(_ card: Card) -> some View {
        (Text(card.suit.symbol).foregroundColor(Theme.color(for: card.suit, fourColor: fourColor)) + Text(card.rankLabel))
            .accessibilityLabel(card.spokenName)
    }
}

@MainActor
final class ReviewModel: ObservableObject {
    @Published private(set) var review: PlayReview?
    @Published private(set) var progress: Double = 0
    private var loadedAttempt: UUID?

    func load(deal: Deal, attempt: Attempt) async {
        guard loadedAttempt != attempt.id else { return }
        loadedAttempt = attempt.id
        review = nil
        progress = 0
        let result = await DoubleDummyEngine.shared.review(deal: deal, contract: attempt.contract, plays: attempt.plays) { value in
            Task { @MainActor [weak self] in self?.progress = value }
        }
        review = result
    }
}
