import SwiftUI

extension BoardStore {
    /// 叫牌练习叫到的定约，拿来坐庄用的牌局。
    func biddingBoard(for item: PracticeDeal, contract: Contract) -> PracticeBoard? {
        let key = "bidding:" + item.id
        if var existing = practiceBoards.first(where: { $0.practiceID == key }) {
            existing.contract = contract
            save(existing)
            return existing
        }
        guard let deal = item.deal else { return nil }
        var board = PracticeBoard(boardNumber: item.board, deal: deal)
        board.contract = contract
        board.practiceID = key
        save(board)
        return board
    }
}

/// 叫牌练习首页：按专题分组。
struct BiddingHomeView: View {
    @EnvironmentObject private var store: BoardStore

    var body: some View {
        List {
            Section {
                Text("你来叫南北两手，东西一直不叫。专题练习先判断北家该怎么开叫，叫完按双明手墩数表给定约打分，也可以直接去坐庄。叫牌体系按自然制：五张高花、1NT 15–17 点、强 2♣、弱二。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("专题") {
                ForEach(BiddingTopic.allCases) { topic in
                    let deals = PracticeLibrary.shared.bidding(topic)
                    let played = deals.filter { !(store.biddingResults[$0.id] ?? []).isEmpty }.count
                    NavigationLink(value: Route.biddingTopic(topic)) {
                        HStack(spacing: 14) {
                            Image(systemName: topic.systemImage)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.felt))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(topic.name).font(.body.weight(.semibold))
                                    Spacer()
                                    Text("\(played) / \(deals.count)").font(.footnote).foregroundStyle(.secondary)
                                }
                                Text(topic.rule).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("叫牌练习")
    }
}

/// 一个专题里的所有牌。
struct BiddingTopicView: View {
    let topic: BiddingTopic
    @EnvironmentObject private var store: BoardStore
    @Environment(\.navigator) private var navigator

    var body: some View {
        let deals = PracticeLibrary.shared.bidding(topic)
        let perfect = deals.filter { deal in (store.biddingResults[deal.id] ?? []).contains { $0.score >= $0.bestScore } }.count
        List {
            Section {
                Text(topic.rule).font(.subheadline).foregroundStyle(.secondary)
                if deals.isEmpty {
                    Text("这个专题还没有牌。").foregroundStyle(Theme.red)
                } else {
                    Text("叫到最佳定约 \(perfect) / \(deals.count) 副").font(.subheadline)
                }
            }
            if let next = deals.first(where: { (store.biddingResults[$0.id] ?? []).isEmpty }) ?? deals.first {
                Section {
                    Button {
                        navigator.push(.bidding(next.id))
                    } label: {
                        Label("开始：第 \(next.number) 副", systemImage: "play.fill")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            Section("\(deals.count) 副") {
                ForEach(deals) { deal in
                    NavigationLink(value: Route.bidding(deal.id)) {
                        BiddingRow(deal: deal, results: store.biddingResults[deal.id] ?? [])
                    }
                }
            }
        }
        .navigationTitle(topic.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BiddingRow: View {
    let deal: PracticeDeal
    let results: [BiddingResult]

    var body: some View {
        let best = results.max { $0.score < $1.score }
        let perfect = best.map { $0.score >= $0.bestScore } ?? false
        HStack(spacing: 12) {
            Image(systemName: perfect ? "checkmark.seal.fill" : (best == nil ? "circle" : "minus.circle"))
                .font(.title3)
                .foregroundStyle(perfect ? Theme.felt : (best == nil ? Color.secondary : Theme.brassText))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("第 \(deal.number) 副").font(.body.weight(.medium))
                Text("\(deal.dealer.name)发牌 · \(deal.vulnerability.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let best {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(best.contract.map { $0.fullLabel } ?? "都不叫").font(.footnote.weight(.medium))
                    Text("\(best.score) / 最佳 \(best.bestScore)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 叫一副牌。
struct BiddingView: View {
    let dealID: String

    @EnvironmentObject private var store: BoardStore
    @Environment(\.navigator) private var navigator
    @State private var auction: Auction?
    @State private var level: Int?
    @State private var showBothHands = false
    @State private var recorded = false
    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        if let item = PracticeLibrary.shared.deal(id: dealID), let deal = item.deal {
            let current = auction ?? Auction(dealer: item.dealer)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("第 \(item.number) 副 · \(item.dealer.name)发牌 · \(item.vulnerability.name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    AuctionTable(auction: current)
                    openingFeedback(item: item, deal: deal, auction: current)
                    if current.isFinished {
                        resultCard(item: item, deal: deal, auction: current)
                    } else {
                        handPanel(deal: deal, auction: current)
                        biddingBox(auction: current)
                    }
                }
                .padding()
            }
            .background(Theme.ivory)
            .navigationTitle("叫牌练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("同时显示南北两手", isOn: $showBothHands)
                        Button("重新叫") { restart(item) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
            }
            .onAppear {
                if auction == nil { restart(item) }
            }
        } else {
            ContentUnavailableView("找不到这副牌", systemImage: "questionmark.circle")
        }
    }

    // MARK: - 叫牌

    private func restart(_ item: PracticeDeal) {
        var a = Auction(dealer: item.dealer)
        autoPass(&a)
        auction = a
        level = nil
        recorded = false
    }

    /// 东西一直不叫。
    private func autoPass(_ a: inout Auction) {
        while !a.isFinished && !a.nextSeat.isNorthSouth {
            a.make(.pass)
        }
    }

    private func make(_ call: Call) {
        guard var a = auction, a.isLegal(call) else { return }
        a.make(call)
        autoPass(&a)
        auction = a
        level = nil
    }

    /// 撤回你最后一次叫牌（连同后面东西的不叫）。
    private func undo() {
        guard var a = auction else { return }
        guard let lastMine = a.calls.indices.last(where: { a.seat(at: $0).isNorthSouth }) else { return }
        a.undo(to: lastMine)
        auction = a
        level = nil
    }

    // MARK: - 开叫判断

    /// 专题练习：北家第一口叫牌和推荐开叫对比。
    @ViewBuilder
    private func openingFeedback(item: PracticeDeal, deal: Deal, auction: Auction) -> some View {
        if let recommended = item.openingCall,
           let index = auction.calls.indices.first(where: { auction.seat(at: $0) == .north }) {
            let made = auction.calls[index]
            let right = made == recommended
            let hand = deal[.north]
            VStack(alignment: .leading, spacing: 4) {
                Label(right ? "开叫正确：\(made.label)" : "推荐开叫 \(recommended.label)（你叫了 \(made.label)）",
                      systemImage: right ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(right ? Theme.felt : Theme.brassText)
                Text("北家 \(hand.hcp) 点，牌型 \(hand.shapeText)。\(item.biddingTopic.rule)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(right ? Theme.felt.opacity(0.1) : Theme.brass.opacity(0.18)))
        }
    }

    // MARK: - 手牌

    private func handPanel(deal: Deal, auction: Auction) -> some View {
        let seat = auction.nextSeat
        let seats = showBothHands ? [Seat.north, Seat.south] : [seat]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(seats) { s in
                let hand = deal[s]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(s == seat ? "轮到\(s.name)家叫" : "\(s.name)家")
                            .font(.headline)
                            .foregroundStyle(s == seat ? Theme.felt : Color.secondary)
                        Spacer()
                        Text("\(hand.hcp) 点 · \(hand.shapeText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Suit.allCases) { suit in
                        HStack(spacing: 8) {
                            Text(suit.symbol)
                                .foregroundStyle(Theme.color(for: suit, fourColor: fourColor))
                                .frame(width: 22)
                            Text(deal.holding(s, suit))
                        }
                        .font(.system(.title3, design: .serif))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            }
        }
    }

    private func biddingBox(auction: Auction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(level == nil ? "选阶数" : "选花色（\(level!) 阶）")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { n in
                    let possible = Strain.allCases.contains { auction.isLegal(.bid(n, $0)) }
                    Button { level = (level == n ? nil : n) } label: {
                        Text("\(n)")
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(level == n ? Color.white : Theme.ink)
                            .background(RoundedRectangle(cornerRadius: 10).fill(level == n ? Theme.felt : Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(!possible)
                    .opacity(possible ? 1 : 0.35)
                }
            }
            HStack(spacing: 6) {
                ForEach(Strain.allCases) { strain in
                    let call = Call.bid(level ?? 0, strain)
                    let legal = level != nil && auction.isLegal(call)
                    Button { make(call) } label: {
                        Text(strain.symbol)
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(Theme.color(for: strain, fourColor: fourColor))
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(!legal)
                    .opacity(legal ? 1 : 0.35)
                    .accessibilityLabel(level.map { "\($0) \(strain.name)" } ?? strain.name)
                }
            }
            HStack(spacing: 10) {
                Button { make(.pass) } label: {
                    Text("不叫").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button { undo() } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!auction.calls.indices.contains { auction.seat(at: $0).isNorthSouth })
            }
        }
    }

    // MARK: - 结果

    private func resultCard(item: PracticeDeal, deal: Deal, auction: Auction) -> some View {
        let contract = auction.finalContract
        let tricks = contract.flatMap { item.ddTricks(strain: $0.strain, declarer: $0.declarer) }
        let score: Int = {
            guard let contract, let tricks else { return 0 }
            let vul = item.vulnerability.isVulnerable(contract.declarer)
            let s = contract.score(declarerTricks: tricks, vulnerable: vul)
            return contract.declarer.isNorthSouth ? s : -s
        }()
        let best = item.bestScore ?? 0
        let perfect = score >= best
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(contract.map { $0.fullLabel } ?? "四家都不叫")
                    .font(.system(.title, design: .serif).weight(.bold))
                    .foregroundStyle(Theme.felt)
                Spacer()
                Label(perfect ? "最佳定约" : "差 \(best - score) 分", systemImage: perfect ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(perfect ? Theme.felt : Theme.brassText)
            }
            if let contract, let tricks {
                Text("双明手 \(contract.declarer.name)家能拿 \(tricks) 墩，\(contract.resultText(declarerTricks: tricks))，得分 \(score > 0 ? "+" : "")\(score)")
                    .font(.subheadline)
            }
            Text("最佳：\((item.best ?? []).map(bestLabel).joined(separator: "、"))，得分 +\(best)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            DDTableView(item: item)

            DealDiagram(deal: deal, highlight: contract?.declarer)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))

            VStack(spacing: 10) {
                if let contract {
                    Button {
                        if let board = store.biddingBoard(for: item, contract: contract) {
                            navigator.push(.play(board.id, PlayLaunch(mode: .robotDefense, robotLevel: .expert, contract: contract, startPlays: [])))
                        }
                    } label: {
                        Label("去坐庄这个定约", systemImage: "suit.spade.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 10) {
                    Button { restart(item) } label: {
                        Text("重新叫").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    if let next = PracticeLibrary.shared.next(after: item.id) {
                        Button { navigator.replaceTop(.bidding(next.id)) } label: {
                            Text("下一副").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onAppear {
            guard !recorded else { return }
            recorded = true
            store.recordBidding(BiddingResult(calls: auction.calls, contract: contract, score: score, bestScore: best), for: item.id)
        }
    }

    /// "4SN" → "4♠ 北家"
    private func bestLabel(_ text: String) -> String {
        guard let seatChar = text.last, let seat = Seat(letter: seatChar),
              let contract = Contract(text: String(text.dropLast()), declarer: seat) else { return text }
        return contract.fullLabel
    }
}

/// 叫牌过程：四列，从北开始。
private struct AuctionTable: View {
    let auction: Auction

    /// 按 北 东 南 西 四列排好的叫品；发牌人之前留空，轮到的位置显示"?"。
    static func rows(for auction: Auction) -> [[String?]] {
        var cells: [String?] = Array(repeating: nil, count: auction.dealer.rawValue)
        for call in auction.calls { cells.append(call.label) }
        if !auction.isFinished { cells.append("?") }
        var rows: [[String?]] = []
        var start = 0
        while start < max(cells.count, 1) {
            var row: [String?] = []
            for i in 0..<4 { row.append(start + i < cells.count ? cells[start + i] : nil) }
            rows.append(row)
            start += 4
        }
        return rows
    }

    var body: some View {
        let rows = AuctionTable.rows(for: auction)
        VStack(spacing: 6) {
            HStack {
                ForEach(Seat.allCases) { seat in
                    Text(seat.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(seat.isNorthSouth ? Theme.felt : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                HStack {
                    ForEach(0..<4, id: \.self) { c in
                        Text(rows[r][c] ?? "")
                            .font(.system(.body, design: .serif).weight(rows[r][c] == "?" ? .regular : .semibold))
                            .foregroundStyle(rows[r][c] == "?" ? Theme.brassText : Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("叫牌过程：" + auction.calls.enumerated().map { "\(auction.seat(at: $0.offset).name)\($0.element.label)" }.joined(separator: "，"))
    }
}

/// 双明手墩数表（南北）。
private struct DDTableView: View {
    let item: PracticeDeal
    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        let strains: [Strain] = [.notrump, .spades, .hearts, .diamonds, .clubs]
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("双明手").font(.caption).foregroundStyle(.secondary)
                ForEach(strains) { strain in
                    Text(strain.symbol)
                        .font(.system(.body, design: .serif).weight(.bold))
                        .foregroundStyle(Theme.color(for: strain, fourColor: fourColor))
                }
            }
            ForEach([Seat.north, Seat.south, Seat.east, Seat.west]) { seat in
                GridRow {
                    Text("\(seat.name)打").font(.caption).foregroundStyle(seat.isNorthSouth ? Theme.felt : Color.secondary)
                    ForEach(strains) { strain in
                        Text(item.ddTricks(strain: strain, declarer: seat).map { "\($0)" } ?? "—")
                            .font(.system(.subheadline, design: .rounded).weight(seat.isNorthSouth ? .semibold : .regular))
                            .foregroundStyle(seat.isNorthSouth ? Theme.ink : Color.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
    }
}
