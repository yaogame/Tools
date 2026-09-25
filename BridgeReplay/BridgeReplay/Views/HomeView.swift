import SwiftUI
import PhotosUI

/// 录入中的一副牌（还没保存）。
struct DealDraft: Identifiable {
    let id = UUID()
    var board: PracticeBoard
    var photo: UIImage?
}

struct HomeView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var path: [Route] = []
    @State private var draft: DealDraft?
    @State private var showCamera = false
    @State private var showPaste = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("线下没打成的那副牌，拍下来，到线上再坐一次庄。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            entryLabel("拍照录入", detail: "四家摊开拍一张，照着照片点选", systemImage: "camera")
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        entryLabel("从相册选照片", detail: "用拍好的牌桌照片对照录入", systemImage: "photo")
                    }
                    Button {
                        draft = DealDraft(board: PracticeBoard())
                    } label: {
                        entryLabel("手动输入", detail: "点选 52 张牌分给四家", systemImage: "square.grid.4x3.fill")
                    }
                    Button {
                        showPaste = true
                    } label: {
                        entryLabel("粘贴牌型", detail: "支持 PBN / BBO LIN", systemImage: "doc.on.clipboard")
                    }
                }

                Section("最近的牌") {
                    if store.boards.isEmpty {
                        Text("还没有牌。每副牌重打后都会存在这里，可以反复重打，也能从任意一墩接着打。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.boards) { board in
                        NavigationLink(value: Route.board(board.id)) {
                            BoardRow(board: board)
                        }
                    }
                    .onDelete { store.delete(at: $0) }
                }
            }
            .navigationTitle("坐庄复盘")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .board(let id):
                    BoardDetailView(boardID: id)
                case .play(let id, let launch):
                    if let board = store.board(id) {
                        PlayView(board: board, launch: launch)
                    }
                case .review(let id, let attemptID):
                    ReviewView(boardID: id, attemptID: attemptID)
                }
            }
        }
        .sheet(item: $draft) { draft in
            DealEditorView(draft: draft) { board, photo in
                var board = board
                if let photo, board.photoFileName == nil {
                    board.photoFileName = store.savePhoto(photo)
                }
                store.save(board)
                path.append(.board(board.id))
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image { present(DealDraft(board: PracticeBoard(), photo: image)) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPaste) {
            PasteImportView { imported in
                var board = PracticeBoard(boardNumber: imported.board ?? 1, deal: imported.deal)
                if let dealer = imported.dealer { board.dealer = dealer }
                if let vul = imported.vulnerability { board.vulnerability = vul }
                board.contract = imported.contract
                present(DealDraft(board: board))
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    draft = DealDraft(board: PracticeBoard(), photo: image)
                }
                photoItem = nil
            }
        }
    }

    /// 等上一个弹窗收起后再弹出录入页，避免两个弹窗冲突。
    private func present(_ newDraft: DealDraft) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { draft = newDraft }
    }

    private func entryLabel(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.felt.opacity(0.12)))
                .foregroundStyle(Theme.felt)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BoardRow: View {
    let board: PracticeBoard

    var body: some View {
        HStack(spacing: 12) {
            Text("\(board.boardNumber)")
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBack))
            VStack(alignment: .leading, spacing: 3) {
                Text(board.title + (board.contract.map { " · \($0.fullLabel)" } ?? ""))
                    .font(.body.weight(.semibold))
                Text("\(board.dealer.name)发牌 · \(board.vulnerability.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = board.attempts.last {
                Text(last.contract.resultText(declarerTricks: last.declarerTricks))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.brassText)
            } else {
                Text("待重打")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.brass.opacity(0.25)))
                    .foregroundStyle(Theme.brassText)
            }
        }
    }
}

/// 调用系统相机拍照。
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void
        init(onFinish: @escaping (UIImage?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

/// 粘贴 PBN / LIN 文本导入。
struct PasteImportView: View {
    let onImport: (ImportedDeal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("例如 N:A753.JT5.T94.KJ4 KQT2.K74.A73.T96 86.Q9863.QJ.8532 J94.A2.K8652.AQ7，也可以直接粘贴 BBO 的 LIN 或整段 PBN 记录。")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.red)
                }
            }
            .navigationTitle("粘贴牌型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        do {
                            let imported = try DealParser.parse(text)
                            dismiss()
                            onImport(imported)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("从剪贴板粘贴") { text = UIPasteboard.general.string ?? text }
                }
            }
        }
    }
}
