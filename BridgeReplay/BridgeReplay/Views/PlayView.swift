import SwiftUI

/// 牌桌。你这一方在下方：坐庄时是庄家，防守练习时是你防守的那一家。
struct PlayView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.navigator) private var navigator
    @StateObject private var model: PlayViewModel
    @State private var showAll = false
    @State private var savedRestoreNote = false
    @State private var showSaveExample = false
    @AppStorage("showCardTricks") private var showCardTricks = true
    /// 坐庄练习默认不显示双明手墩数（打完后在结果和复盘里看）。
    @State private var revealHints = false
    @AppStorage("fourColorDeck") private var fourColor = false

    private let board: PracticeBoard
    /// 分级练习时"下一副"去的地方。
    private let next: Route?

    init(board: PracticeBoard, launch: PlayLaunch, next: Route? = nil) {
        self.board = board
        self.next = next
        _model = StateObject(wrappedValue: PlayViewModel(board: board, launch: launch))
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            seatTag(model.topSeat)
            HandFan(seat: model.topSeat, model: model, visible: model.isVisible(model.topSeat, showAll: showAll), showCardTricks: showCardTricks && showHints)
            HStack(alignment: .center, spacing: 4) {
                SideHand(seat: model.leftSeat, model: model, visible: model.isVisible(model.leftSeat, showAll: showAll), showCardTricks: showCardTricks && showHints)
                    .frame(width: model.isVisible(model.leftSeat, showAll: showAll) ? 100 : 64)
                TrickTable(model: model)
                    .frame(maxWidth: .infinity)
                SideHand(seat: model.rightSeat, model: model, visible: model.isVisible(model.rightSeat, showAll: showAll), showCardTricks: showCardTricks && showHints)
                    .frame(width: model.isVisible(model.rightSeat, showAll: showAll) ? 100 : 64)
            }
            .frame(maxHeight: .infinity)
            Text(model.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
            HandFan(seat: model.bottomSeat, model: model, visible: true, showCardTricks: showCardTricks && showHints)
            seatTag(model.bottomSeat)
            TrickHistoryStrip(model: model, showValues: showHints)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(Theme.felt.ignoresSafeArea())
        .navigationTitle("\(board.title) · \(model.contract.fullLabel)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.feltDark, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            ToolbarItemGroup(placement: .bottomBar) { bottomBar }
        }
        .toolbarBackground(Theme.ivory, for: .bottomBar)
        .toolbarBackground(.visible, for: .bottomBar)
        .overlay {
            if let attempt = model.finishedAttempt {
                resultCard(attempt)
            }
        }
        .alert("已设为恢复点", isPresented: $savedRestoreNote) {
            Button("好") {}
        } message: {
            Text("下次可以从这 \(model.state.plays.count) 张牌之后接着打，也可以切换到「机器人防守」现在就接着打。")
        }
        .sheet(isPresented: $showSaveExample) {
            SaveExampleSheet(board: board, contract: model.contract, plays: model.state.plays, viewer: model.viewer)
        }
        .onAppear {
            model.onFinish = { [boardID = model.boardID] attempt in
                store.update(boardID) { $0.attempts.append(attempt) }
            }
            model.start()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.mode.name + (model.mode == .allFour ? "" : " · 防守机器人\(model.robotLevel.name)"))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                Text((model.viewerIsDeclarerSide ? "完成定约需 \(model.contract.target) 墩" : "打宕需防守 \(model.viewerGoal) 墩")
                     + " · \(board.vulnerability.name)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            scoreBox(title: "庄", value: model.state.declarerTricks, color: Theme.brass)
            scoreBox(title: "防", value: model.state.defenderTricks, color: .white)
            if showHints { ddBox }
        }
        .padding(.top, 4)
    }

    private func scoreBox(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75))
            Text("\(value)").font(.system(.title3, design: .serif).weight(.bold)).foregroundStyle(color)
        }
        .frame(minWidth: 34)
        .accessibilityElement(children: .combine)
    }

    /// 双明手下你这一方最终能拿到的墩数。
    private var ddBox: some View {
        let value = model.viewerDD
        let ok = (value ?? 0) >= model.viewerGoal
        return VStack(spacing: 0) {
            Text(model.viewerIsDeclarerSide ? "可得" : "防守可得").font(.caption2).foregroundStyle(Theme.ink.opacity(0.7))
            if let value {
                Text("\(value)").font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(ok ? Theme.felt : Theme.red)
            } else {
                ProgressView().controlSize(.small).frame(height: 24)
            }
        }
        .frame(minWidth: 48)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ivory))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "双明手下\(model.viewerSideName)可得 \($0) 墩" } ?? "正在计算双明手")
    }

    private func seatTag(_ seat: Seat) -> some View {
        let isTurn = model.state.turn == seat
        return Text("\(seat.name) · \(model.role(of: seat)) · \(model.state.hand(seat).count) 张")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(isTurn ? Theme.brass : Color.clear, lineWidth: 1.5))
    }

    // MARK: - 工具栏

    @ViewBuilder
    private var bottomBar: some View {
        Button { model.undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
            .disabled(!model.canUndo)
        Spacer()
        Button { model.restart() } label: { Label("重来", systemImage: "arrow.counterclockwise") }
        Spacer()
        if model.mode != .allFour {
            Button { showAll.toggle() } label: {
                Label(showAll ? "盖上暗牌" : "亮出全部牌", systemImage: showAll ? "eye.slash" : "eye")
            }
            Spacer()
        }
        if showHints {
            Toggle(isOn: $showCardTricks) { Label("每张牌墩数", systemImage: "number.circle") }
                .toggleStyle(.button)
        }
    }

    /// 分级坐庄练习（编号 P 开头）打的时候不显示墩数提示。
    private var isDeclarerPractice: Bool { model.practiceID?.hasPrefix("P") == true }

    private var showHints: Bool {
        !isDeclarerPractice || revealHints || model.state.isFinished
    }

    private var availableModes: [PracticeMode] {
        model.viewerIsDeclarerSide ? [.robotDefense, .allFour] : [.defense, .allFour]
    }

    /// 可以改成手工出牌的座位：当前由机器人出牌的，以及已经改成手工的。
    private var manualCandidates: [Seat] {
        Seat.allCases.filter { model.robotSeats.contains($0) || model.manualSeats.contains($0) }
    }

    private var moreMenu: some View {
        Menu {
            Picker("练习方式", selection: $model.mode) {
                ForEach(availableModes) { Text($0.name).tag($0) }
            }
            if !manualCandidates.isEmpty {
                Section("手工出牌") {
                    ForEach(manualCandidates) { seat in
                        Toggle("\(seat.name)家由我出牌", isOn: Binding(
                            get: { model.manualSeats.contains(seat) },
                            set: { _ in model.toggleManual(seat) }))
                    }
                }
            }
            if model.mode != .allFour {
                Picker("防守机器人水平", selection: $model.robotLevel) {
                    ForEach(RobotLevel.allCases) { Text($0.name).tag($0) }
                }
            }
            if isDeclarerPractice {
                Toggle("显示双明手墩数提示", isOn: $revealHints)
            }
            Divider()
            Button {
                showSaveExample = true
            } label: {
                Label("保存为牌例", systemImage: "star")
            }
            if board.practiceID == nil {
                Button {
                    let plays = model.state.plays
                    store.update(model.boardID) { $0.restorePlays = plays }
                    savedRestoreNote = true
                } label: {
                    Label("设为恢复点", systemImage: "bookmark")
                }
            }
            Toggle("四色牌", isOn: $fourColor)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
    }

    // MARK: - 结束

    private func resultCard(_ attempt: Attempt) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("本副结束").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Label(model.viewerSucceeded ? (model.viewerIsDeclarerSide ? "完成定约" : "打宕定约") : "没有成功",
                          systemImage: model.viewerSucceeded ? "checkmark.seal.fill" : "xmark.seal")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.viewerSucceeded ? Theme.felt : Theme.red)
                }
                Text(model.resultTitle)
                    .font(.system(.title, design: .serif).weight(.bold))
                    .foregroundStyle(Theme.felt)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.resultLine)
                    if let best = model.viewerValue(atTrickStart: 0) {
                        Text("双明手最优：\(model.viewerSideName) \(best) 墩")
                    }
                    if model.viewerIsDeclarerSide, let offline = board.offlineTricks {
                        Text("线下：\(offline) 墩（\(model.contract.resultText(declarerTricks: offline))）")
                    }
                }
                .font(.subheadline)
                HStack(spacing: 10) {
                    Button { model.restart() } label: {
                        Text("再打一次").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    NavigationLink(value: Route.review(model.boardID, attempt.id)) {
                        Text("看复盘").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                if let next {
                    Button { navigator.replaceTop(next) } label: {
                        Text("下一副").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 22).fill(Theme.ivory))
            .padding(24)
        }
    }
}

// MARK: - 上下两家：扇形手牌

private struct HandFan: View {
    let seat: Seat
    @ObservedObject var model: PlayViewModel
    let visible: Bool
    let showCardTricks: Bool

    @AppStorage("confirmPlay") private var confirmPlay = true

    private let cardWidth: CGFloat = 48
    private let cardHeight: CGFloat = 70

    var body: some View {
        let hand = model.state.hand(seat).sortedForDisplay()
        GeometryReader { geo in
            if visible {
                let positions = layout(hand, width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(hand.enumerated()), id: \.element) { index, card in
                        let playable = model.canPlay(card, from: seat)
                        let isTurn = model.state.turn == seat && model.isHumanControlled(seat)
                        let value = showCardTricks ? model.ddValue(for: card, seat: seat) : nil
                        let selected = model.isSelected(card, seat: seat)
                        Button { model.tap(card, from: seat, confirm: confirmPlay) } label: {
                            CardFace(card: card, width: cardWidth, height: cardHeight,
                                     dimmed: isTurn && !playable,
                                     highlighted: selected,
                                     badge: value,
                                     badgeIsBest: model.dd?.bestCards.contains(card) ?? false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable)
                        .offset(x: positions[index], y: selected ? -4 : (playable ? 4 : 12))
                        .zIndex(selected ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: playable)
                        .animation(.easeOut(duration: 0.12), value: selected)
                    }
                }
            } else {
                Text(seat == model.contract.dummy ? "首攻后明手亮牌" : "")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: visible ? cardHeight + 16 : 24)
    }

    /// 每张牌的横向位置：同花色重叠，花色之间留一点空。
    private func layout(_ hand: [Card], width: CGFloat) -> [CGFloat] {
        guard !hand.isEmpty else { return [] }
        let groups = Set(hand.map(\.suit)).count
        let gap: CGFloat = 8
        let step = hand.count > 1 ? min(34, (width - cardWidth - gap * CGFloat(groups - 1)) / CGFloat(hand.count - 1)) : 0
        let total = cardWidth + step * CGFloat(hand.count - 1) + gap * CGFloat(groups - 1)
        var x = max(0, (width - total) / 2)
        var result: [CGFloat] = []
        for (i, card) in hand.enumerated() {
            if i > 0 {
                x += step
                if hand[i - 1].suit != card.suit { x += gap }
            }
            result.append(x)
        }
        return result
    }
}

// MARK: - 左右两家：按花色一行一行

private struct SideHand: View {
    let seat: Seat
    @ObservedObject var model: PlayViewModel
    let visible: Bool
    let showCardTricks: Bool

    @AppStorage("fourColorDeck") private var fourColor = false
    @AppStorage("confirmPlay") private var confirmPlay = true

    var body: some View {
        let hand = model.state.hand(seat)
        let isTurn = model.state.turn == seat
        VStack(alignment: .leading, spacing: 5) {
            Text("\(seat.name) · \(model.role(of: seat))" + (visible ? "" : " · \(hand.count)张"))
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(isTurn ? Theme.brass : Color.clear, lineWidth: 1.5))
            if visible {
                ForEach(Suit.displayOrder) { suit in
                    HStack(alignment: .top, spacing: 2) {
                        Text(suit.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.color(for: suit, fourColor: fourColor))
                            .frame(width: 14)
                        FlowLayout(spacing: 2, lineSpacing: 2) {
                            ForEach(hand.cards(in: suit)) { card in
                                chip(card)
                            }
                        }
                    }
                }
            }
        }
        .padding(visible ? 8 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(visible ? 0.16 : 0)))
    }

    private func chip(_ card: Card) -> some View {
        let playable = model.canPlay(card, from: seat)
        let value = showCardTricks ? model.ddValue(for: card, seat: seat) : nil
        let best = model.dd?.bestCards.contains(card) ?? false
        let selected = model.isSelected(card, seat: seat)
        return Button { model.tap(card, from: seat, confirm: confirmPlay) } label: {
            VStack(spacing: 0) {
                Text(card.rankLabel)
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .foregroundStyle(Theme.color(for: card.suit, fourColor: fourColor))
                if let value {
                    Text("\(value)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(best ? Theme.felt : Theme.orange)
                }
            }
            .frame(minWidth: 18, minHeight: 22)
            .padding(.horizontal, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.brass : Theme.cardFace.opacity(playable ? 1 : 0.8)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(playable ? Theme.brass : Color.clear, lineWidth: selected ? 2.5 : 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!playable)
        .accessibilityLabel(card.spokenName + (value.map { "，双明手 \($0) 墩" } ?? ""))
    }
}

// MARK: - 中间的一墩

private struct TrickTable: View {
    @ObservedObject var model: PlayViewModel

    var body: some View {
        let shown = model.displayedTrick
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.12))
            Text("第 \(model.state.trickNumber) 墩")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            ForEach(shown.plays, id: \.self) { play in
                CardFace(card: play.card, width: 44, height: 64,
                         dimmed: false,
                         highlighted: shown.winner == play.seat)
                    .opacity(shown.winner != nil && shown.winner != play.seat ? 0.85 : 1)
                    .offset(offset(for: play.seat))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 150, height: 196)
        .animation(.easeOut(duration: 0.15), value: shown.plays)
    }

    private func offset(for seat: Seat) -> CGSize {
        switch seat {
        case model.topSeat: return CGSize(width: 0, height: -62)
        case model.bottomSeat: return CGSize(width: 0, height: 62)
        case model.leftSeat: return CGSize(width: -46, height: 0)
        default: return CGSize(width: 46, height: 0)
        }
    }
}

// MARK: - 每墩后双明手可得墩数

private struct TrickHistoryStrip: View {
    @ObservedObject var model: PlayViewModel
    /// 为 false 时只显示每墩谁赢，不显示双明手墩数。
    let showValues: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(showValues ? "每墩后\(model.viewerSideName)可得" : "每墩归属")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                if showValues, let start = model.viewerValue(atTrickStart: 0) {
                    Text("开局双明手 \(start) 墩")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            HStack(spacing: 3) {
                ForEach(1...13, id: \.self) { n in
                    cell(n)
                }
            }
        }
    }

    /// 第 n 墩：谁赢了这墩，以及打完这墩后你这一方最终能拿的墩数。
    private func cell(_ n: Int) -> some View {
        let trick: Trick? = n <= model.state.completedTricks.count ? model.state.completedTricks[n - 1] : nil
        let viewerWon = trick.map { $0.winner.isSameSide(as: model.viewer) } ?? false
        let value = trick == nil || !showValues ? nil : model.viewerValue(atTrickStart: n)
        let previous = showValues ? model.viewerValue(atTrickStart: n - 1) : nil
        var change = 0
        if let value, let previous { change = value - previous }
        let label = accessibilityText(n, played: trick != nil, viewerWon: viewerWon, value: value, change: change)
        let textColor: Color = trick == nil ? Color.white.opacity(0.4) : (viewerWon ? Theme.ink : Color.white)
        let fill: Color = trick == nil ? Color.white.opacity(0.08) : (viewerWon ? Theme.brass : Color.white.opacity(0.28))
        let dot: Color = change < 0 ? Theme.red : (change > 0 ? Theme.brass : Color.clear)
        let text: String = value.map { "\($0)" } ?? (trick == nil ? "\(n)" : "·")
        return VStack(spacing: 1) {
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
            Circle()
                .fill(dot)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func accessibilityText(_ n: Int, played: Bool, viewerWon: Bool, value: Int?, change: Int) -> String {
        guard played else { return "第 \(n) 墩未打" }
        var text = "第 \(n) 墩" + (viewerWon ? "你方赢" : "对方赢")
        if let value { text += "，之后可得 \(value) 墩" }
        if change < 0 { text += "，丢了 \(-change) 墩" }
        if change > 0 { text += "，对方送了 \(change) 墩" }
        return text
    }
}
