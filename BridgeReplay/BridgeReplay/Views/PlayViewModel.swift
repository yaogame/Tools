import SwiftUI

@MainActor
final class PlayViewModel: ObservableObject {
    let boardID: UUID
    let deal: Deal
    let contract: Contract
    let vulnerable: Bool
    let startPlays: [Play]
    /// 坐在下方的一家：坐庄时是庄家，防守练习时是你防守的那一家。
    let viewer: Seat
    let practiceID: String?

    @Published private(set) var state: PlayState
    @Published var mode: PracticeMode { didSet { if mode != oldValue { refresh() } } }
    @Published var robotLevel: RobotLevel
    /// 本来由机器人出牌、被改成由你手工出牌的座位。
    @Published var manualSeats: Set<Seat> = [] { didSet { if manualSeats != oldValue { refresh() } } }
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
    private var startedHistory = false

    init(board: PracticeBoard, launch: PlayLaunch) {
        boardID = board.id
        deal = board.deal
        contract = launch.contract
        vulnerable = board.vulnerability.isVulnerable(launch.contract.declarer)
        startPlays = launch.startPlays
        viewer = launch.viewer ?? launch.contract.declarer
        practiceID = launch.practiceID
        mode = launch.mode
        robotLevel = launch.robotLevel
        state = PlayState(deal: board.deal, contract: launch.contract, plays: launch.startPlays)
    }

    // MARK: - 座位

    var declarer: Seat { contract.declarer }
    var bottomSeat: Seat { viewer }
    var topSeat: Seat { viewer.partner }
    var leftSeat: Seat { viewer.next }
    var rightSeat: Seat { viewer.previous }
    var viewerIsDeclarerSide: Bool { viewer.isSameSide(as: declarer) }

    /// 在当前练习方式下，默认由机器人出牌的座位。
    var robotSeats: [Seat] {
        Seat.allCases.filter { seat in
            switch mode {
            case .allFour: return false
            case .robotDefense: return !seat.isSameSide(as: declarer)
            case .defense: return seat != viewer
            }
        }
    }

    func isHumanControlled(_ seat: Seat) -> Bool {
        manualSeats.contains(seat) || !robotSeats.contains(seat)
    }

    func isVisible(_ seat: Seat, showAll: Bool) -> Bool {
        if mode == .allFour || state.isFinished || showAll { return true }
        if seat == viewer || manualSeats.contains(seat) { return true }
        if seat == contract.dummy { return !state.plays.isEmpty }
        return mode == .robotDefense && seat == declarer
    }

    func role(of seat: Seat) -> String {
        let base: String
        if seat == declarer { base = "庄家" } else if seat == contract.dummy { base = "明手" } else { base = "防守" }
        if mode == .allFour { return base }
        if seat == viewer { return base + "·你" }
        return isHumanControlled(seat) ? base + "·手工" : base + "·机器人"
    }

    func toggleManual(_ seat: Seat) {
        if manualSeats.contains(seat) { manualSeats.remove(seat) } else { manualSeats.insert(seat) }
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
        guard !plays.isEmpty else { return }
        if mode != .allFour {
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

    private func reset(to plays: [Play]) {
        robotTask?.cancel()
        finishedAttempt = nil
        state = PlayState(deal: deal, contract: contract, plays: plays)
        let completed = state.completedTricks.count
        ddAtTrickStart = ddAtTrickStart.filter { $0.key <= completed }
        refresh()
    }

    func start() {
        if dd == nil && !ddLoading { refresh() }
        if !startedHistory {
            startedHistory = true
            fillStartHistory()
        }
    }

    /// 补算开局以及恢复点之前每墩结束时的双明手墩数。
    private func fillStartHistory() {
        let completed = PlayState(deal: deal, contract: contract, plays: startPlays).completedTricks.count
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
                                      declarerTricks: state.declarerTricks,
                                      viewer: viewer,
                                      practiceID: practiceID)
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
        // 替庄家出牌的机器人总是按双明手最优打；防守机器人按设置的水平。
        let level: RobotLevel = seat.isSameSide(as: declarer) ? .expert : robotLevel
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

    // MARK: - 以你这一方的角度显示

    /// 把"庄家方最终墩数"换成某一方的最终墩数。
    func sideTotal(_ declarerTotal: Int, for seat: Seat) -> Int {
        seat.isSameSide(as: declarer) ? declarerTotal : 13 - declarerTotal
    }

    var viewerSideName: String { viewerIsDeclarerSide ? "庄家" : "防守" }
    var viewerTricks: Int { viewerIsDeclarerSide ? state.declarerTricks : state.defenderTricks }
    /// 你这一方的目标墩数：坐庄要完成定约，防守要打宕。
    var viewerGoal: Int { viewerIsDeclarerSide ? contract.target : 14 - contract.target }

    /// 双明手下你这一方最终能拿到的墩数。
    var viewerDD: Int? {
        if state.isFinished { return viewerTricks }
        return dd.map { sideTotal($0.declarerTricks, for: viewer) }
    }

    func viewerValue(atTrickStart k: Int) -> Int? {
        ddAtTrickStart[k].map { sideTotal($0, for: viewer) }
    }

    /// 出这张牌后，出牌这一方最终能拿到的墩数。
    func ddValue(for card: Card, seat: Seat) -> Int? {
        guard let dd, dd.mover == seat, let value = dd.values[card] else { return nil }
        return sideTotal(value, for: seat)
    }

    /// 桌面中间显示的牌：当前这墩，或者刚结束的上一墩。
    var displayedTrick: (plays: [Play], winner: Seat?) {
        if !state.currentTrick.isEmpty { return (state.currentTrick, nil) }
        if let last = state.lastTrick { return (last.plays, last.winner) }
        return ([], nil)
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

    /// 你这一方的得分。
    var viewerScore: Int {
        let score = contract.score(declarerTricks: state.declarerTricks, vulnerable: vulnerable)
        return viewerIsDeclarerSide ? score : -score
    }

    var resultLine: String {
        let score = viewerScore
        let signed = (score > 0 ? "+" : "") + "\(score)"
        if viewerIsDeclarerSide {
            return "庄家拿到 \(state.declarerTricks) 墩，得分 \(signed)"
        }
        let beaten = state.declarerTricks < contract.target
        return "防守拿到 \(state.defenderTricks) 墩，" + (beaten ? "打宕了定约" : "没能打宕") + "，得分 \(signed)"
    }

    /// 这一副算不算成功：坐庄完成定约，或防守打宕定约。
    var viewerSucceeded: Bool { viewerTricks >= viewerGoal }
}
