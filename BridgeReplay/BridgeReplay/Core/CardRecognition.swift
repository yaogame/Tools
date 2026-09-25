import Foundation

/// 照片里的四个方位（以屏幕上看到的照片为准）。
enum PhotoSide: String, CaseIterable, Codable, Identifiable {
    case top, right, bottom, left

    var id: String { rawValue }
    var name: String {
        switch self {
        case .top: return "上方"
        case .right: return "右边"
        case .bottom: return "下方"
        case .left: return "左边"
        }
    }

    /// 已知照片上方是哪一家，推出这一边是哪一家（顺时针 北→东→南→西）。
    func seat(top: Seat) -> Seat {
        switch self {
        case .top: return top
        case .right: return top.next
        case .bottom: return top.partner
        case .left: return top.previous
        }
    }
}

/// 识别出的一张牌；看不清的部分为 nil。
struct PartialCard: Hashable {
    let suit: Suit?
    let rank: Int?

    var card: Card? {
        guard let suit, let rank else { return nil }
        return Card(suit: suit, rank: rank)
    }

    func matches(_ card: Card) -> Bool {
        (suit == nil || suit == card.suit) && (rank == nil || rank == card.rank)
    }
}

struct RecognitionResult {
    var hands: [PhotoSide: [PartialCard]]
    /// 牌套 / 桌面上能看出来的方位（看不出来就没有）。
    var compass: [PhotoSide: Seat]
    var boardNumber: Int?
    var notes: String

    /// 推荐的"照片上方是哪一家"。
    var suggestedTopSeat: Seat {
        if let top = compass[.top] { return top }
        for side in PhotoSide.allCases {
            guard let seat = compass[side] else { continue }
            // 反推：seat(top:) 的逆运算
            for top in Seat.allCases where side.seat(top: top) == seat { return top }
        }
        return .north
    }
}

/// 把识别结果按方向组装成四手牌，并用排除法补上看不清的牌。
struct AssembledDeal {
    var deal: Deal
    /// 靠排除法推断出来的牌（需要核对）。
    var inferred: Set<Card>
    /// 被识别到两家都有的牌（需要核对）。
    var conflicts: Set<Card>

    static func assemble(_ result: RecognitionResult, topSeat: Seat) -> AssembledDeal {
        var deal = Deal()
        var owner: [Card: Seat] = [:]
        var conflicts = Set<Card>()
        var partials: [(seat: Seat, card: PartialCard)] = []

        for side in PhotoSide.allCases {
            let seat = side.seat(top: topSeat)
            for item in result.hands[side] ?? [] {
                if let card = item.card {
                    if let other = owner[card] {
                        if other != seat { conflicts.insert(card) }
                        continue
                    }
                    owner[card] = seat
                    deal[seat].append(card)
                } else {
                    partials.append((seat, item))
                }
            }
        }

        // 排除法：看不清的牌如果只剩一张能对上，就是它。
        var inferred = Set<Card>()
        var changed = true
        while changed {
            changed = false
            for (index, partial) in partials.enumerated().reversed() {
                guard deal[partial.seat].count < 13 else {
                    partials.remove(at: index)
                    continue
                }
                let candidates = deal.unassigned.filter { partial.card.matches($0) }
                if candidates.count == 1 {
                    deal[partial.seat].append(candidates[0])
                    inferred.insert(candidates[0])
                    partials.remove(at: index)
                    changed = true
                }
            }
        }

        // 只差一家没满时，剩下的牌都是这家的。
        if deal.canAutoComplete {
            let rest = deal.unassigned
            deal.autoComplete()
            inferred.formUnion(rest)
        }
        return AssembledDeal(deal: deal, inferred: inferred, conflicts: conflicts)
    }
}

enum RecognitionError: LocalizedError {
    case imageEncoding
    case noCards

    var errorDescription: String? {
        switch self {
        case .imageEncoding: return "照片处理失败。"
        case .noCards: return "没有认出牌。请把四家的牌摊开、牌角露出来，正对着拍清楚再试。"
        }
    }
}
