import SwiftUI

@MainActor
final class PlayViewModel: ObservableObject {
    let boardID: UUID
    let deal: Deal
    let contract: Contract
    let vulnerable: Bool
    let startPlays: [Play]

    @Published private(set) var state: PlayState
    @Published var mode: PracticeMode { didSet { if mode != oldValue { refresh() } } }
    @Published var robotLevel: RobotLevel
    /// 当前局面的双明手结果（轮到出牌那家每张牌的墩数）。
    @Published private(set) var dd: DDPosition?
    @Published private(set) var ddLoading = false
    /// 第 k 墩开始前（k 从 0 起，13 表示打完）双明手下庄家方最终能拿的墩数。
    @Published private(set) var ddAtTrickStart: [Int: Int] = [:]
    @Published var finishedAttempt: Attempt?

    var onFinish: ((Attempt) -> Void)?

    private var robotTask: Task<Void, Never>?
    private var ddTask: Task<Void, Never>?
    private let engine = DoubleDummyEngine.shared

    init(board: PracticeBoard, launch: PlayLaunch) {
        boardID = board.id
        deal = board.deal
        contract = launch.contract
        vulnerable = board.vulnerability.isVulnerable(launch.contract.declarer)
        startPlays = launch.startPlays
        mode = launch.mode
        robotLevel = launch.robotLevel
        state = PlayState(deal: board.deal, contract: launch.contract, plays: launch.startPlays)
    }

    // MARK: - 座位

    var declarer: Seat { contract.declarer }
    var bottomSeat: Seat { declarer }
    var topSeat: Seat { declarer.partner }
    var leftSeat: Seat { declarer.next }
    var rightSeat: Seat { declarer.previous }

    func isHumanControlled(_ seat: Seat) -> Bool {
        mode == .allFour || seat.isSameSide(as: declarer)
    }

    func isVisible(_ seat: Seat, showDefenders: Bool) -> Bool {
        if mode == .allFour || state.isFinished { return true }
        if seat == declarer { return true }
        if seat == contract.dummy { return !state.plays.isEmpty }
        return showDefenders
    }

    func role(of seat: Seat) -> String {
        if seat == declarer { return "庄家" }
        if seat == contract.dummy { return "明手" }
        return mode == .robotDefense ? "机器人" : "防守"
    }

    // MARK: - 出牌

    func canPlay(_ card: Card, from seat: Seat) -> Bool {
        state.turn == seat && isHumanControlled(seat) && state.legalCards(for: seat).contains(card)
    }

    func tap(_ card: Card, from seat: Seat) {
        guard canPlay(card, from: seat) else { return }
        state.apply(Play(seat: seat, card: card))
        refresh()
    }

    func undo() {
        robotTask?.cancel()
        var plays = state.plays
        guard plays.count > 0 else { return }
        if mode == .robotDefense {
            while let last = plays.last, !isHumanControlled(last.seat) { plays.removeLast() }
        }
        if !plays.isEmpty { plays.removeLast() }
        reset(to: plays)
    }

    var canUndo: Bool {
        state.plays.contains { isHumanControlled($0.seat) }
    }

    func restart() {
        reset(to: startPlays)
    }

    /// 从第 n 墩开始重打（保留前面的出牌）。
    func restart(fromTrick n: Int) {
        reset(to: PlayState.prefix(state.plays, beforeTrick: n))
    }

    private func reset(to plays: [Play]) {
        robotTask?.cancel()
        finishedAttempt = nil
        state = PlayState(deal: deal, contract: contract, plays: plays)
        let completed = state.completedTricks.count
        ddAtTrickStart = ddAtTrickStart.filter { $0.key <= completed }
        refresh()
    }

    private var startedHistory = false

    func start() {
        if dd == nil && !ddLoading { refresh() }
        if !startedHistory {
            startedHistory = true
            fillStartHistory()
        }
    }

    /// 从恢复点开始时，补算前面几墩结束时的双明手墩数。
    private func fillStartHistory() {
        let completed = PlayState(deal: deal, contract: contract, plays: startPlays).completedTricks.count
        guard completed > 0 || !startPlays.isEmpty else { return }
        let deal = self.deal, contract = self.contract, plays = startPlays
        Task { [weak self] in
            for k in 0...completed {
                let snapshot = PlayState(deal: deal, contract: contract, plays: PlayState.prefix(plays, beforeTrick: k + 1))
                guard let position = await DoubleDummyEngine.shared.analyze(snapshot) else { continue }
                guard let self else { return }
                if self.ddAtTrickStart[k] == nil { self.ddAtTrickStart[k] = position.declarerTricks }
            }
        }
    }

    /// 每次局面变化后：更新双明手结果、打完就记录、轮到机器人就让它出。
    private func refresh() {
        robotTask?.cancel()
        ddTask?.cancel()

        if state.isFinished {
            dd = nil
            ddLoading = false
            ddAtTrickStart[13] = state.declarerTricks
            if finishedAttempt == nil {
                let attempt = Attempt(mode: mode,
                                      robotLevel: robotLevel,
                                      contract: contract,
                                      startPlayCount: startPlays.count,
                                      plays: state.plays,
                                      declarerTricks: state.declarerTricks)
                finishedAttempt = attempt
                onFinish?(attempt)
            }
            return
        }

        let snapshot = state
        ddLoading = true
        ddTask = Task { [weak self] in
            guard let self else { return }
            let position = await engine.analyze(snapshot)
            guard !Task.isCancelled, snapshot.plays == self.state.plays else { return }
            self.dd = position
            self.ddLoading = false
            if let position, snapshot.currentTrick.isEmpty {
                self.ddAtTrickStart[snapshot.completedTricks.count] = position.declarerTricks
            }
            self.scheduleRobotIfNeeded(with: position)
        }
    }

    private func scheduleRobotIfNeeded(with position: DDPosition?) {
        guard let seat = state.turn, !isHumanControlled(seat) else { return }
        let snapshot = state
        let level = robotLevel
        robotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard let self, !Task.isCancelled, snapshot.plays == self.state.plays else { return }
            let card = PlayViewModel.robotChoice(seat: seat, state: snapshot, level: level, position: position)
            self.state.apply(Play(seat: seat, card: card))
            self.refresh()
        }
    }

    nonisolated static func robotChoice(seat: Seat, state: PlayState, level: RobotLevel, position: DDPosition?) -> Card {
        let heuristic = HeuristicDefender.choose(for: seat, in: state)
        guard level == .expert, let position, position.mover == seat, !position.bestCards.isEmpty else {
            return heuristic
        }
        if position.bestCards.contains(heuristic) { return heuristic }
        // 同样最优的牌里，出最小的非将牌。
        return position.bestCards.sorted { a, b in
            let at = a.suit == state.trump, bt = b.suit == state.trump
            return at != bt ? !at : a.rank < b.rank
        }[0]
    }

    // MARK: - 展示用

    /// 桌面中间显示的牌：当前这墩，或者刚结束的上一墩。
    var displayedTrick: (plays: [Play], winner: Seat?) {
        if !state.currentTrick.isEmpty { return (state.currentTrick, nil) }
        if let last = state.lastTrick { return (last.plays, last.winner) }
        return ([], nil)
    }

    func ddValue(for card: Card, seat: Seat) -> Int? {
        guard let dd, dd.mover == seat else { return nil }
        return dd.values[card]
    }

    var statusText: String {
        guard let turn = state.turn else { return "本副结束" }
        var prefix = ""
        if state.currentTrick.isEmpty, let last = state.lastTrick {
            prefix = "\(last.winner.name)家赢得第 \(state.completedTricks.count) 墩 · "
        }
        if isHumanControlled(turn) {
            return prefix + "轮到\(turn.name)家（\(role(of: turn))）" + (state.currentTrick.isEmpty ? "出牌" : "跟牌")
        }
        return prefix + "\(turn.name)家出牌中…"
    }

    var resultTitle: String {
        "\(contract.label) \(declarer.name)家 " + contract.resultText(declarerTricks: state.declarerTricks)
    }

    var score: Int { contract.score(declarerTricks: state.declarerTricks, vulnerable: vulnerable) }
}
