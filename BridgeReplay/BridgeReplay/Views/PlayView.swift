import SwiftUI

/// 线上坐庄的牌桌。庄家在下，明手在上，左边是庄家的下家，右边是上家。
struct PlayView: View {
    @EnvironmentObject private var store: BoardStore
    @StateObject private var model: PlayViewModel
    @State private var showDefenders = false
    @State private var savedRestoreNote = false
    @AppStorage("showCardTricks") private var showCardTricks = true
    @AppStorage("fourColorDeck") private var fourColor = false

    private let board: PracticeBoard

    init(board: PracticeBoard, launch: PlayLaunch) {
        self.board = board
        _model = StateObject(wrappedValue: PlayViewModel(board: board, launch: launch))
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            seatTag(model.topSeat)
            HandFan(seat: model.topSeat, model: model, visible: model.isVisible(model.topSeat, showDefenders: showDefenders), showCardTricks: showCardTricks)
            HStack(alignment: .center, spacing: 4) {
                SideHand(seat: model.leftSeat, model: model, visible: model.isVisible(model.leftSeat, showDefenders: showDefenders), showCardTricks: showCardTricks)
                    .frame(width: 100)
                TrickTable(model: model)
                    .frame(maxWidth: .infinity)
                SideHand(seat: model.rightSeat, model: model, visible: model.isVisible(model.rightSeat, showDefenders: showDefenders), showCardTricks: showCardTricks)
                    .frame(width: 100)
            }
            .frame(maxHeight: .infinity)
            Text(model.statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.updatesFrequently)
            HandFan(seat: model.bottomSeat, model: model, visible: true, showCardTricks: showCardTricks)
            seatTag(model.bottomSeat)
            TrickHistoryStrip(model: model)
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
                Text("\(model.mode.name)" + (model.mode == .robotDefense ? " · \(model.robotLevel.name)" : ""))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                Text("需要 \(model.contract.target) 墩 · \(board.vulnerability.name)")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            scoreBox(title: "庄", value: model.state.declarerTricks, color: Theme.brass)
            scoreBox(title: "防", value: model.state.defenderTricks, color: .white)
            ddBox
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

    /// 双明手下庄家最终能拿到的墩数。
    private var ddBox: some View {
        let value = model.state.isFinished ? model.state.declarerTricks : model.dd?.declarerTricks
        let ok = (value ?? 0) >= model.contract.target
        return VStack(spacing: 0) {
            Text("可得").font(.caption2).foregroundStyle(Theme.ink.opacity(0.7))
            if let value {
                Text("\(value)").font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(ok ? Theme.felt : Theme.red)
            } else {
                ProgressView().controlSize(.small).frame(height: 24)
            }
        }
        .frame(minWidth: 44)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ivory))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "双明手可得 \($0) 墩" } ?? "正在计算双明手")
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
        if model.mode == .robotDefense {
            Button { showDefenders.toggle() } label: {
                Label(showDefenders ? "盖上防守牌" : "亮出防守牌", systemImage: showDefenders ? "eye.slash" : "eye")
            }
            Spacer()
        }
        Toggle(isOn: $showCardTricks) { Label("每张牌墩数", systemImage: "number.circle") }
            .toggleStyle(.button)
    }

    private var moreMenu: some View {
        Menu {
            Picker("练习方式", selection: $model.mode) {
                ForEach(PracticeMode.allCases) { Text($0.name).tag($0) }
            }
            if model.mode == .robotDefense {
                Picker("机器人水平", selection: $model.robotLevel) {
                    ForEach(RobotLevel.allCases) { Text($0.name).tag($0) }
                }
            }
            Divider()
            Button {
                let plays = model.state.plays
                store.update(model.boardID) { $0.restorePlays = plays }
                savedRestoreNote = true
            } label: {
                Label("设为恢复点", systemImage: "bookmark")
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
                Text("本副结束").font(.footnote).foregroundStyle(.secondary)
                Text(model.resultTitle)
                    .font(.system(.title, design: .serif).weight(.bold))
                    .foregroundStyle(Theme.felt)
                VStack(alignment: .leading, spacing: 4) {
                    Text("庄家拿到 \(attempt.declarerTricks) 墩，得分 \(model.score > 0 ? "+" : "")\(model.score)")
                    if let best = model.ddAtTrickStart[0] {
                        Text("双明手最优：\(best) 墩")
                    }
                    if let offline = board.offlineTricks {
                        Text("线下：\(offline) 墩（\(model.contract.resultText(declarerTricks: offline))）")
                    }
                }
                .font(.subheadline)
                HStack(spacing: 10) {
                    Button { model.restart() } label: {
                        Text("再坐一次").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    NavigationLink(value: Route.review(model.boardID, attempt.id)) {
                        Text("看复盘").frame(maxWidth: .infinity, minHeight: 44)
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
                        Button { model.tap(card, from: seat) } label: {
                            CardFace(card: card, width: cardWidth, height: cardHeight,
                                     dimmed: isTurn && !playable,
                                     badge: value,
                                     badgeIsBest: model.dd?.bestCards.contains(card) ?? false)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playable)
                        .offset(x: positions[index], y: playable ? 2 : 10)
                        .animation(.easeOut(duration: 0.12), value: playable)
                    }
                }
            } else {
                HStack(spacing: -18) {
                    ForEach(0..<min(hand.count, 6), id: \.self) { _ in CardBack() }
                    Text("\(hand.count) 张").font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.leading, 26)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: cardHeight + 12)
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

    var body: some View {
        let hand = model.state.hand(seat)
        let isTurn = model.state.turn == seat
        VStack(alignment: .leading, spacing: 5) {
            Text("\(seat.name) · \(model.role(of: seat))")
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
            } else {
                HStack(spacing: -16) {
                    ForEach(0..<min(hand.count, 3), id: \.self) { _ in CardBack() }
                }
                Text("\(hand.count) 张").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.16)))
    }

    private func chip(_ card: Card) -> some View {
        let playable = model.canPlay(card, from: seat)
        let value = showCardTricks ? model.ddValue(for: card, seat: seat) : nil
        let best = model.dd?.bestCards.contains(card) ?? false
        return Button { model.tap(card, from: seat) } label: {
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
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.cardFace.opacity(playable ? 1 : 0.8)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(playable ? Theme.brass : Color.clear, lineWidth: 1.5))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("每墩后可得")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                if let start = model.ddAtTrickStart[0] {
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

    /// 第 n 墩：谁赢了这墩，以及打完这墩后庄家方最终能拿的墩数。
    private func cell(_ n: Int) -> some View {
        let trick = n <= model.state.completedTricks.count ? model.state.completedTricks[n - 1] : nil
        let declarerWon = trick.map { $0.winner.isSameSide(as: model.declarer) } ?? false
        let value = trick == nil ? nil : model.ddAtTrickStart[n]
        let previous = model.ddAtTrickStart[n - 1]
        var change = 0
        if let value, let previous { change = value - previous }
        let label = accessibilityText(n, played: trick != nil, declarerWon: declarerWon, value: value, change: change)
        let textColor: Color = trick == nil ? Color.white.opacity(0.4) : (declarerWon ? Theme.ink : Color.white)
        let fill: Color = trick == nil ? Color.white.opacity(0.08) : (declarerWon ? Theme.brass : Color.white.opacity(0.28))
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

    private func accessibilityText(_ n: Int, played: Bool, declarerWon: Bool, value: Int?, change: Int) -> String {
        guard played else { return "第 \(n) 墩未打" }
        var text = "第 \(n) 墩" + (declarerWon ? "庄家赢" : "防守赢")
        if let value { text += "，之后可得 \(value) 墩" }
        if change < 0 { text += "，丢了 \(-change) 墩" }
        if change > 0 { text += "，对方送了 \(change) 墩" }
        return text
    }
}
