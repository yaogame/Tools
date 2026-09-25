import SwiftUI

enum Theme {
    static let felt = Color(red: 0.118, green: 0.302, blue: 0.247)       // #1E4D3F
    static let feltDark = Color(red: 0.078, green: 0.200, blue: 0.160)
    static let ivory = Color(red: 0.957, green: 0.945, blue: 0.918)      // #F4F1EA
    static let cardFace = Color(red: 1.0, green: 0.992, blue: 0.973)     // #FFFDF8
    static let ink = Color(red: 0.102, green: 0.110, blue: 0.102)        // #1A1C1A
    static let brass = Color(red: 0.878, green: 0.690, blue: 0.306)      // #E0B04E
    static let brassText = Color(red: 0.478, green: 0.294, blue: 0.055)  // #7A4B0E
    static let red = Color(red: 0.706, green: 0.137, blue: 0.094)        // #B42318
    static let orange = Color(red: 0.710, green: 0.278, blue: 0.031)     // #B54708
    static let green = Color(red: 0.110, green: 0.420, blue: 0.227)      // #1C6B3A
    static let cardBack = Color(red: 0.541, green: 0.180, blue: 0.141)   // #8A2E24

    static func color(for suit: Suit, fourColor: Bool) -> Color {
        switch suit {
        case .spades: return ink
        case .hearts: return red
        case .diamonds: return fourColor ? orange : red
        case .clubs: return fourColor ? green : ink
        }
    }

    static func color(for strain: Strain, fourColor: Bool) -> Color {
        guard let suit = strain.trump else { return ink }
        return color(for: suit, fourColor: fourColor)
    }
}

/// 一张牌的牌面。
struct CardFace: View {
    let card: Card
    var width: CGFloat = 48
    var height: CGFloat = 70
    var dimmed = false
    var highlighted = false
    /// 右下角的小数字（双明手墩数）。
    var badge: Int?
    var badgeIsBest = false

    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        let color = Theme.color(for: card.suit, fourColor: fourColor)
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.cardFace)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(highlighted ? Theme.brass : Color.black.opacity(0.18), lineWidth: highlighted ? 3 : 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.rankLabel)
                        .font(.system(size: width * 0.34, weight: .bold, design: .serif))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(card.suit.symbol)
                        .font(.system(size: width * 0.3))
                }
                .foregroundStyle(color)
                .padding(.leading, 4)
                .padding(.top, 3)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(badgeIsBest ? Theme.felt : Theme.orange))
                        .padding(3)
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.25), radius: 1.5, x: -1, y: 1)
            .opacity(dimmed ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.spokenName + (badge.map { "，双明手 \($0) 墩" } ?? ""))
    }
}

struct CardBack: View {
    var width: CGFloat = 30
    var height: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.cardBack)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.cardFace, lineWidth: 2))
            .frame(width: width, height: height)
    }
}

/// 简单的换行排列。
struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 四手牌的罗盘图（文字版）。
struct DealDiagram: View {
    let deal: Deal
    var highlight: Seat?
    var labels: [Seat: String] = [:]

    @AppStorage("fourColorDeck") private var fourColor = false

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 10) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                hand(.north)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
            GridRow {
                hand(.west)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.felt)
                    .frame(width: 44, height: 44)
                    .overlay(Text("♠♥\n♦♣").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7)).multilineTextAlignment(.center))
                    .accessibilityHidden(true)
                hand(.east)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                hand(.south)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    private func hand(_ seat: Seat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(seat.name) · \(deal.hcp(seat)) 点" + (labels[seat].map { " · \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(seat == highlight ? Theme.felt : Color.secondary)
                .fontWeight(seat == highlight ? .bold : .regular)
            ForEach(Suit.allCases) { suit in
                HStack(spacing: 4) {
                    Text(suit.symbol).foregroundStyle(Theme.color(for: suit, fourColor: fourColor))
                    Text(deal.holding(seat, suit))
                }
                .font(.system(.subheadline, design: .serif))
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}
