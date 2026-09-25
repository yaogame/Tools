import SwiftUI

/// 一副牌的详情：手动录入定约、线下结果、恢复点，选择练习方式开始坐庄。
struct BoardDetailView: View {
    let boardID: UUID

    @EnvironmentObject private var store: BoardStore
    @State private var editing: DealDraft?
    @State private var savingExample = false
    @State private var robotLevel: RobotLevel = .club
    @State private var fromRestorePoint = true
    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        if let board = store.board(boardID) {
            content(board)
        } else {
            ContentUnavailableView("这副牌已删除", systemImage: "trash")
        }
    }

    private func content(_ board: PracticeBoard) -> some View {
        Form {
            Section {
                DealDiagram(deal: board.deal, highlight: board.contract?.declarer,
                            labels: board.contract.map { [$0.declarer: "庄", $0.dummy: "明手"] } ?? [:])
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Button("修改四手牌") { editing = DealDraft(board: board, photo: store.photo(for: board)) }
                Button("保存为牌例") { savingExample = true }
            } header: {
                Text("\(board.title) · \(board.dealer.name)发牌 · \(board.vulnerability.name)")
            }

            contractSection(board)

            if let contract = board.contract {
                Section {
                    Toggle("填写线下结果", isOn: binding(board, \.offlineTricks).isPresent(default: contract.target - 1))
                    if let tricks = board.offlineTricks {
                        Stepper(value: binding(board, \.offlineTricks).unwrapped(default: tricks), in: 0...13) {
                            HStack {
                                Text("庄家拿到 \(tricks) 墩")
                                Spacer()
                                Text(contract.resultText(declarerTricks: tricks))
                                    .foregroundStyle(tricks >= contract.target ? Theme.felt : Theme.red)
                            }
                        }
                    }
                } header: {
                    Text("线下结果（选填）")
                } footer: {
                    Text("复盘时会和线上重打、双明手最优放在一起对比。")
                }

                restoreSection(board, contract: contract)

                Section {
                    Picker("机器人水平", selection: $robotLevel) {
                        ForEach(RobotLevel.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    let start = fromRestorePoint ? board.restorePlays : []
                    NavigationLink(value: Route.play(board.id, PlayLaunch(mode: .robotDefense, robotLevel: robotLevel, contract: contract, startPlays: start))) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("机器人防守").font(.body.weight(.semibold))
                                Text("你打\(contract.declarer.name)（庄）和\(contract.dummy.name)（明手），电脑防守").font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "person.2.fill") }
                    }
                    NavigationLink(value: Route.play(board.id, PlayLaunch(mode: .allFour, robotLevel: robotLevel, contract: contract, startPlays: start))) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("四家都由我出").font(.body.weight(.semibold))
                                Text("四手牌全部亮开，每一家都由你来出").font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "square.grid.2x2.fill") }
                    }
                    NavigationLink(value: Route.play(board.id, PlayLaunch(mode: .defense, robotLevel: .expert, contract: contract, startPlays: start, viewer: contract.openingLeader))) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("防守练习").font(.body.weight(.semibold))
                                Text("你坐\(contract.openingLeader.name)家首攻，庄家和同伴由机器人打").font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "shield.lefthalf.filled") }
                    }
                } header: {
                    Text("开始练习")
                } footer: {
                    Text("两种方式都会在每一墩后显示双明手下你最终能拿到的墩数。「最强」机器人按双明手最优防守。")
                }
            }

            if !board.attempts.isEmpty {
                Section("重打记录") {
                    ForEach(board.attempts.reversed()) { attempt in
                        NavigationLink(value: Route.review(board.id, attempt.id)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(attempt.contract.fullLabel) · \(attempt.contract.resultText(declarerTricks: attempt.declarerTricks))")
                                        .font(.body.weight(.medium))
                                    Text("\(attempt.mode.name)\(attempt.mode == .robotDefense ? "（\(attempt.robotLevel.name)）" : "") · \(attempt.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(attempt.viewerIsDeclarerSide ? "庄" : "防") \(attempt.viewerTricks) 墩")
                                    .font(.system(.title3, design: .serif).weight(.bold))
                                    .foregroundStyle(Theme.felt)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(board.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $savingExample) {
            SaveExampleSheet(board: board, contract: board.contract, plays: [], viewer: nil)
        }
        .sheet(item: $editing) { draft in
            DealEditorView(draft: draft) { updated, _ in
                var updated = updated
                // 牌变了，旧的恢复点和记录就对不上了。
                if updated.deal != board.deal {
                    updated.restorePlays = []
                    updated.attempts = []
                }
                store.save(updated)
            }
        }
    }

    // MARK: - 定约（手动录入）

    @ViewBuilder
    private func contractSection(_ board: PracticeBoard) -> some View {
        Section {
            if let contract = board.contract {
                let set = { (change: (inout Contract) -> Void) in
                    store.update(board.id) { b in
                        guard var c = b.contract else { return }
                        change(&c)
                        if c != b.contract { b.restorePlays = [] }
                        b.contract = c
                    }
                }
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { level in
                        choiceButton("\(level)", selected: contract.level == level) { set { $0.level = level } }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Strain.allCases) { strain in
                        choiceButton(strain.symbol, selected: contract.strain == strain,
                                     color: Theme.color(for: strain, fourColor: fourColor)) { set { $0.strain = strain } }
                            .accessibilityLabel(strain.name)
                    }
                }
                Picker("加倍", selection: Binding(get: { contract.doubling }, set: { d in set { $0.doubling = d } })) {
                    ForEach(Doubling.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("庄家", selection: Binding(get: { contract.declarer }, set: { s in set { $0.declarer = s } })) {
                    ForEach(Seat.allCases) { Text("\($0.name)家主打").tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                Button {
                    store.update(board.id) { $0.contract = Contract(level: 3, strain: .notrump, declarer: board.dealer) }
                } label: {
                    Label("录入定约", systemImage: "plus.circle.fill")
                }
            }
        } header: {
            Text("定约")
        } footer: {
            if let contract = board.contract {
                Text("\(contract.fullLabel)，\(contract.openingLeader.name)家首攻，\(contract.dummy.name)家是明手。需要 \(contract.target) 墩。改定约会清掉恢复点。")
            }
        }
    }

    private func choiceButton(_ title: String, selected: Bool, color: Color = Theme.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.body, design: .serif).weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(selected ? Color.white : color)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.felt : Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 恢复点

    @ViewBuilder
    private func restoreSection(_ board: PracticeBoard, contract: Contract) -> some View {
        Section {
            if board.restorePlays.isEmpty {
                Text("还没有补录线下的出牌，会从首攻开始打。")
                    .foregroundStyle(.secondary)
            } else {
                let count = board.restorePlays.count
                Text("已补录 \(count) 张牌：前 \(count / 4) 墩" + (count % 4 == 0 ? "" : "又 \(count % 4) 张"))
                Picker("从哪里开始", selection: $fromRestorePoint) {
                    Text("接着线下打").tag(true)
                    Text("从首攻重打").tag(false)
                }
                .pickerStyle(.segmented)
                Button("清除恢复点", role: .destructive) {
                    store.update(board.id) { $0.restorePlays = [] }
                }
            }
            NavigationLink(value: Route.play(board.id, PlayLaunch(mode: .allFour, robotLevel: robotLevel, contract: contract, startPlays: board.restorePlays))) {
                Label("补录线下出牌", systemImage: "pencil.and.list.clipboard")
            }
        } header: {
            Text("恢复点")
        } footer: {
            Text("用「四家都由我出」把线下已经出过的牌按顺序点出来，再点「设为恢复点」，就能从出错的那一墩接着打。")
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ board: PracticeBoard, _ keyPath: WritableKeyPath<PracticeBoard, T>) -> Binding<T> {
        Binding(get: { store.board(board.id)?[keyPath: keyPath] ?? board[keyPath: keyPath] },
                set: { value in store.update(board.id) { $0[keyPath: keyPath] = value } })
    }
}

private extension Binding {
    /// Optional 绑定 → 开关：打开时填入默认值，关闭时置空。
    func isPresent<Wrapped>(default value: Wrapped) -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { wrappedValue = $0 ? (wrappedValue ?? value) : nil })
    }

    func unwrapped<Wrapped>(default value: Wrapped) -> Binding<Wrapped> where Value == Wrapped? {
        Binding<Wrapped>(get: { wrappedValue ?? value }, set: { wrappedValue = $0 })
    }
}
