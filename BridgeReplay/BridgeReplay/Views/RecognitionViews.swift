import SwiftUI

/// 识别完成后确认方向：选"照片上方是哪一家"，其余三家按顺时针自动对应。
struct OrientationConfirmView: View {
    let image: UIImage
    let result: RecognitionResult
    let onApply: (AssembledDeal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var topSeat: Seat

    init(image: UIImage, result: RecognitionResult, onApply: @escaping (AssembledDeal) -> Void) {
        self.image = image
        self.result = result
        self.onApply = onApply
        _topSeat = State(initialValue: result.suggestedTopSeat)
    }

    var body: some View {
        let assembled = AssembledDeal.assemble(result, topSeat: topSeat)
        let recognized = result.hands.values.reduce(0) { $0 + $1.count }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("照片上方是哪一家？")
                        .font(.headline)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .top) { sideTag(.top) }
                        .overlay(alignment: .bottom) { sideTag(.bottom) }
                        .overlay(alignment: .leading) { sideTag(.left) }
                        .overlay(alignment: .trailing) { sideTag(.right) }

                    Picker("照片上方", selection: $topSeat) {
                        ForEach(Seat.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text(result.compass.isEmpty
                         ? "顺时针依次是北、东、南、西。选好上方那家，其余三家会自动对应。"
                         : "已按照片里牌套上的方位自动选好，不对的话可以改。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("识别到 \(recognized) 张牌", systemImage: "camera.viewfinder")
                        if !assembled.inferred.isEmpty {
                            Label("\(assembled.inferred.count) 张看不清，按排除法补上：\(labels(assembled.inferred))", systemImage: "questionmark.circle")
                                .foregroundStyle(Theme.brassText)
                        }
                        if !assembled.conflicts.isEmpty {
                            Label("\(assembled.conflicts.count) 张被认成两家都有：\(labels(assembled.conflicts))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.red)
                        }
                        if !assembled.deal.isComplete {
                            Label("还差 \(assembled.deal.unassigned.count) 张，填入后在下方点选补上", systemImage: "hand.tap")
                                .foregroundStyle(Theme.brassText)
                        }
                        if let board = result.boardNumber {
                            Label("牌套副号：\(board)", systemImage: "number")
                        }
                        if !result.notes.isEmpty {
                            Label(result.notes, systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)

                    DealDiagram(deal: assembled.deal)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                }
                .padding()
            }
            .background(Theme.ivory)
            .navigationTitle("确认方向")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("填入") {
                        onApply(assembled)
                        dismiss()
                    }
                }
            }
        }
    }

    private func sideTag(_ side: PhotoSide) -> some View {
        let count = result.hands[side]?.count ?? 0
        return Text("\(side.seat(top: topSeat).name) · \(count) 张")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.felt.opacity(0.9)))
            .padding(6)
            .accessibilityLabel("照片\(side.name)是\(side.seat(top: topSeat).name)家，识别到 \(count) 张")
    }

    private func labels(_ cards: Set<Card>) -> String {
        cards.sorted { $0.id < $1.id }.map(\.label).joined(separator: " ")
    }
}

/// 设置。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fourColorDeck") private var fourColor = false
    @AppStorage("showCardTricks") private var showCardTricks = true
    @AppStorage("confirmPlay") private var confirmPlay = true

    var body: some View {
        NavigationStack {
            Form {
                Section("牌面") {
                    Toggle("四色牌（方块橙色、梅花绿色）", isOn: $fourColor)
                    Toggle("出牌时在每张牌上显示双明手墩数", isOn: $showCardTricks)
                    Toggle("点一下选中，再点一次才出牌", isOn: $confirmPlay)
                }
                Section {
                    LabeledContent("照片识别", value: "在手机上完成，不联网")
                    LabeledContent("双明手计算", value: "DDS 2.9.0")
                } header: {
                    Text("关于")
                } footer: {
                    Text("照片识别看牌角的花色和点数；看不清的牌按排除法补上，识别后都可以手动修改。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
