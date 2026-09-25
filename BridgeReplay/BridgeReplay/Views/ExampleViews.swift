import SwiftUI

/// 保存为牌例：起个标题、写点备注，可以从当前出牌位置开始保存。
struct SaveExampleSheet: View {
    let board: PracticeBoard
    let contract: Contract?
    let plays: [Play]
    let viewer: Seat?

    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var fromCurrent = true
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField(defaultTitle, text: $title)
                }
                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("这副牌的要点，比如：第 4 墩要飞 ♣Q")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                if !plays.isEmpty {
                    Section {
                        Toggle("从当前位置开始（已出 \(plays.count) 张）", isOn: $fromCurrent)
                    } footer: {
                        Text("打开牌例练习时，会先把这些牌出好，从这里接着打。")
                    }
                }
                Section {
                    DealDiagram(deal: board.deal, highlight: contract?.declarer)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("保存为牌例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.saveExample(DealExample(
                            title: trimmed.isEmpty ? defaultTitle : trimmed,
                            note: note,
                            boardNumber: board.boardNumber,
                            dealer: board.dealer,
                            vulnerability: board.vulnerability,
                            deal: board.deal,
                            contract: contract,
                            plays: fromCurrent ? plays : [],
                            viewer: viewer,
                            boardID: board.id))
                        dismiss()
                    }
                }
            }
        }
    }

    private var defaultTitle: String {
        var text = board.title
        if let contract { text += " · \(contract.fullLabel)" }
        if fromCurrent && !plays.isEmpty { text += " · 第 \(plays.count / 4 + 1) 墩起" }
        return text
    }
}

/// 牌例库。
struct ExamplesView: View {
    @EnvironmentObject private var store: BoardStore

    var body: some View {
        List {
            if store.examples.isEmpty {
                ContentUnavailableView {
                    Label("还没有牌例", systemImage: "star")
                } description: {
                    Text("在牌桌右上角「更多」里点「保存为牌例」，或在牌局详情里保存。")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.examples) { example in
                NavigationLink(value: Route.example(example.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(example.title).font(.body.weight(.semibold))
                        HStack(spacing: 6) {
                            if let contract = example.contract {
                                Text(contract.fullLabel)
                            }
                            if !example.plays.isEmpty {
                                Text("第 \(example.plays.count / 4 + 1) 墩起")
                            }
                            Text(example.createdAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        if !example.note.isEmpty {
                            Text(example.note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { store.deleteExamples(at: $0) }
        }
        .navigationTitle("牌例")
    }
}

/// 牌例详情：看牌、改备注、从保存的位置练习、分享 PBN。
struct ExampleDetailView: View {
    let exampleID: UUID

    @EnvironmentObject private var store: BoardStore
    @Environment(\.navigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        if let example = store.examples.first(where: { $0.id == exampleID }) {
            Form {
                Section {
                    DealDiagram(deal: example.deal, highlight: example.contract?.declarer)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } header: {
                    Text("第 \(example.boardNumber) 副 · \(example.dealer.name)发牌 · \(example.vulnerability.name)")
                }

                if let contract = example.contract {
                    Section("练习") {
                        Text("\(contract.fullLabel)，" + (example.plays.isEmpty ? "从首攻开始" : "从第 \(example.plays.count / 4 + 1) 墩开始（已出 \(example.plays.count) 张）"))
                        let viewer = example.viewer ?? contract.declarer
                        if viewer.isSameSide(as: contract.declarer) {
                            practiceButton("机器人防守", systemImage: "person.2.fill", example: example,
                                           launch: PlayLaunch(mode: .robotDefense, robotLevel: .expert, contract: contract, startPlays: example.plays))
                        } else {
                            practiceButton("防守练习（你坐\(viewer.name)家）", systemImage: "shield.lefthalf.filled", example: example,
                                           launch: PlayLaunch(mode: .defense, robotLevel: .expert, contract: contract, startPlays: example.plays, viewer: viewer))
                        }
                        practiceButton("四家都由我出", systemImage: "square.grid.2x2.fill", example: example,
                                       launch: PlayLaunch(mode: .allFour, robotLevel: .expert, contract: contract, startPlays: example.plays, viewer: viewer))
                    }
                }

                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .onChange(of: note) { _, value in
                            guard loaded, value != example.note else { return }
                            var updated = example
                            updated.note = value
                            store.saveExample(updated)
                        }
                }

                Section {
                    ShareLink(item: example.pbn, subject: Text(example.title)) {
                        Label("分享 PBN", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = example.pbn
                    } label: {
                        Label("复制 PBN", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        store.deleteExample(example.id)
                        dismiss()
                    } label: {
                        Label("删除这个牌例", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(example.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !loaded {
                    note = example.note
                    loaded = true
                }
            }
        } else {
            ContentUnavailableView("牌例已删除", systemImage: "trash")
        }
    }

    private func practiceButton(_ title: String, systemImage: String, example: DealExample, launch: PlayLaunch) -> some View {
        Button {
            if let board = store.boardForExample(example.id) {
                navigator.push(.play(board.id, launch))
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
