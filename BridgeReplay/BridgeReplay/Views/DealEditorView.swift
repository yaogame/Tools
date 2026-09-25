import SwiftUI

/// 录入 / 核对四手牌。选中一家，再点牌把它分给这家；照片放在上方对照。
struct DealEditorView: View {
    let onSave: (PracticeBoard, UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var board: PracticeBoard
    @State private var photo: UIImage?
    @State private var seat: Seat = .north
    @State private var showPhoto = false
    @State private var recognizing = false
    @State private var recognitionError: String?
    @State private var recognitionNote: String?
    @State private var pending: PendingRecognition?
    @State private var autoStarted = false
    /// 按排除法推断出来的牌（黄色）和识别冲突的牌（红框），需要核对。
    @State private var inferred = Set<Card>()
    @State private var conflicts = Set<Card>()
    @AppStorage("fourColorDeck") private var fourColor = false

    private struct PendingRecognition: Identifiable {
        let id = UUID()
        let result: RecognitionResult
    }

    init(draft: DealDraft, onSave: @escaping (PracticeBoard, UIImage?) -> Void) {
        self.onSave = onSave
        _board = State(initialValue: draft.board)
        _photo = State(initialValue: draft.photo)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let photo {
                        Button { showPhoto = true } label: {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .bottomTrailing) {
                                    Label("放大", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption)
                                        .padding(6)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(8)
                                }
                        }
                        .accessibilityLabel("放大照片")

                        recognitionPanel
                    }

                    boardInfo

                    handSummary

                    VStack(alignment: .leading, spacing: 8) {
                        Text("点牌分给：").font(.subheadline.weight(.semibold))
                        Picker("编辑哪一家", selection: $seat) {
                            ForEach(Seat.allCases) { s in
                                Text("\(s.name) \(board.deal[s].count)").tag(s)
                            }
                        }
                        .pickerStyle(.segmented)

                        cardGrid

                        HStack {
                            Button("清空\(seat.name)家") { board.deal[seat] = [] }
                                .disabled(board.deal[seat].isEmpty)
                            Spacer()
                            Button("剩余的牌补给最后一家") { board.deal.autoComplete() }
                                .disabled(!board.deal.canAutoComplete)
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
            }
            .background(Theme.ivory)
            .navigationTitle("核对四手牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        dismiss()
                        onSave(board, photo)
                    }
                    .disabled(!board.deal.isComplete)
                }
            }
            .fullScreenCover(isPresented: $showPhoto) {
                if let photo { ZoomablePhotoView(image: photo) }
            }
            .sheet(item: $pending) { item in
                if let photo {
                    OrientationConfirmView(image: photo, result: item.result) { assembled in
                        apply(assembled, boardNumber: item.result.boardNumber)
                    }
                }
            }
            .task {
                // 有照片、还没录入任何牌时，自动开始识别。
                guard !autoStarted, photo != nil, board.deal.hands.allSatisfy({ $0.isEmpty }) else { return }
                autoStarted = true
                startRecognition()
            }
        }
    }

    // MARK: - 照片识别

    private var recognitionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recognizing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在识别照片里的牌，大约需要 10–20 秒…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    startRecognition()
                } label: {
                    Label(board.deal.hands.allSatisfy({ $0.isEmpty }) ? "自动识别这张照片" : "重新识别照片",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
            }
            if let recognitionError {
                Text(recognitionError)
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
            }
            if let recognitionNote {
                Text(recognitionNote)
                    .font(.footnote)
                    .foregroundStyle(Theme.brassText)
            }
        }
    }

    private func startRecognition() {
        guard let photo else { return }
        recognizing = true
        recognitionError = nil
        Task {
            do {
                let result = try await OnDeviceCardReader.read(photo)
                if result.hands.values.allSatisfy({ $0.isEmpty }) {
                    recognitionError = RecognitionError.noCards.localizedDescription
                } else {
                    pending = PendingRecognition(result: result)
                }
            } catch {
                recognitionError = error.localizedDescription
            }
            recognizing = false
        }
    }

    private func apply(_ assembled: AssembledDeal, boardNumber: Int?) {
        board.deal = assembled.deal
        inferred = assembled.inferred
        conflicts = assembled.conflicts
        if let boardNumber, (1...128).contains(boardNumber) { setBoardNumber(boardNumber) }
        let filled = assembled.deal.hands.reduce(0) { $0 + $1.count }
        var note = "已自动填入 \(filled) 张"
        if !inferred.isEmpty { note += "，其中 \(inferred.count) 张按排除法推断（黄色）" }
        if !conflicts.isEmpty { note += "，\(conflicts.count) 张识别重复（红框）" }
        if !assembled.deal.isComplete { note += "，还差 \(assembled.deal.unassigned.count) 张需要手动补上" }
        recognitionNote = note + "。请对照照片核对。"
    }

    private func setBoardNumber(_ n: Int) {
        board.boardNumber = n
        board.dealer = BoardNumbering.dealer(board: n)
        board.vulnerability = BoardNumbering.vulnerability(board: n)
    }

    private var boardInfo: some View {
        VStack(spacing: 10) {
            Stepper(value: Binding(get: { board.boardNumber }, set: { setBoardNumber($0) }), in: 1...128) {
                Text("副号 \(board.boardNumber)").font(.headline)
            }
            HStack {
                Picker("发牌人", selection: $board.dealer) {
                    ForEach(Seat.allCases) { Text("\($0.name)发牌").tag($0) }
                }
                Spacer()
                Picker("局况", selection: $board.vulnerability) {
                    ForEach(Vulnerability.allCases) { Text($0.name).tag($0) }
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }

    private var handSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("四手牌").font(.subheadline.weight(.semibold))
                Spacer()
                if board.deal.isComplete {
                    Label("每家 13 张", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.felt)
                } else {
                    Text("还差 \(board.deal.unassigned.count) 张")
                        .font(.footnote)
                        .foregroundStyle(Theme.brassText)
                }
            }
            DealDiagram(deal: board.deal, highlight: seat)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
    }

    private var cardGrid: some View {
        VStack(spacing: 5) {
            ForEach(Suit.allCases) { suit in
                HStack(spacing: 3) {
                    Text(suit.symbol)
                        .font(.body)
                        .foregroundStyle(Theme.color(for: suit, fourColor: fourColor))
                        .frame(width: 18)
                    ForEach((0...12).reversed(), id: \.self) { rank in
                        cardCell(Card(suit: suit, rank: rank))
                    }
                }
            }
        }
    }

    private func cardCell(_ card: Card) -> some View {
        let owner = board.deal.owner(of: card)
        let mine = owner == seat
        let border: Color = conflicts.contains(card) ? Theme.red : (inferred.contains(card) ? Theme.brass : Color.black.opacity(0.12))
        let borderWidth: CGFloat = conflicts.contains(card) || inferred.contains(card) ? 2.5 : 1
        var spoken: String = card.spokenName
        spoken += owner.map { "，在\($0.name)家" } ?? "，未分配"
        if inferred.contains(card) { spoken += "，推断的" }
        if conflicts.contains(card) { spoken += "，识别重复" }
        return Button {
            board.deal.toggle(card, for: seat)
            inferred.remove(card)
            conflicts.remove(card)
        } label: {
            VStack(spacing: 0) {
                Text(card.rankLabel)
                    .font(.system(size: 13, weight: .bold, design: .serif))
                    .minimumScaleFactor(0.7)
                Text(owner.map { mine ? "✓" : $0.name } ?? " ")
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(mine ? Color.white : (owner == nil ? Theme.ink : Color.secondary))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(mine ? Theme.felt : (owner == nil ? Color.white : Color.black.opacity(0.06)))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: borderWidth))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
    }
}

/// 全屏查看照片，双指缩放、拖动。
struct ZoomablePhotoView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, lastScale * $0.magnification) }
                        .onEnded { _ in lastScale = scale }
                        .simultaneously(with: DragGesture()
                            .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                            .onEnded { _ in lastOffset = offset })
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        scale = scale > 1 ? 1 : 2.5
                        lastScale = scale
                        if scale == 1 { offset = .zero; lastOffset = .zero }
                    }
                }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.white.opacity(0.3))
            }
            .padding()
            .accessibilityLabel("关闭")
        }
    }
}
