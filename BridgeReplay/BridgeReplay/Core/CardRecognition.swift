import Foundation
import UIKit

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
    case missingAPIKey
    case imageEncoding
    case http(Int, String)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "还没有设置 API Key。"
        case .imageEncoding: return "照片处理失败。"
        case .http(let code, let message):
            switch code {
            case 401: return "API Key 无效，请在设置里检查。"
            case 429: return "请求太频繁，请稍后再试。"
            case 529, 503: return "识别服务繁忙，请稍后再试。"
            default: return "识别失败（\(code)）：\(message)"
            }
        case .refused: return "这张照片没能识别，请换一张再试。"
        case .truncated: return "识别结果不完整，请再试一次。"
        case .badResponse: return "识别结果格式不对，请再试一次。"
        }
    }
}

/// 调用 Claude 读取照片里的四手牌。
struct ClaudeCardReader {
    let apiKey: String

    static let model = "claude-opus-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func read(_ image: UIImage) async throws -> RecognitionResult {
        guard let jpeg = ClaudeCardReader.prepare(image) else { throw RecognitionError.imageEncoding }
        let body = try JSONSerialization.data(withJSONObject: requestBody(jpeg: jpeg))

        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: ClaudeCardReader.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // 安全分类器拒绝时，服务端自动换推荐的模型重试。
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            request.httpBody = body

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return try ClaudeCardReader.parse(data) }

            let retryable = status == 429 || status >= 500
            if retryable && attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                continue
            }
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error.message ?? ""
            throw RecognitionError.http(status, message)
        }
    }

    /// 统一方向（按屏幕上看到的方向重画）并把长边缩到 2576 像素以内。
    static func prepare(_ image: UIImage, maxLongEdge: CGFloat = 2576) -> Data? {
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width > 0, height > 0 else { return nil }
        let ratio = min(1, maxLongEdge / max(width, height))
        let target = CGSize(width: floor(width * ratio), height: floor(height * ratio))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.jpegData(compressionQuality: 0.85)
    }

    private func requestBody(jpeg: Data) -> [String: Any] {
        let image: [String: Any] = [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
        ]
        let text: [String: Any] = ["type": "text", "text": ClaudeCardReader.instructions]
        let message: [String: Any] = ["role": "user", "content": [image, text]]
        let format: [String: Any] = ["type": "json_schema", "schema": ClaudeCardReader.schema]
        let outputConfig: [String: Any] = ["effort": "high", "format": format]
        let body: [String: Any] = [
            "model": ClaudeCardReader.model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "thinking": ["type": "adaptive"],
            "output_config": outputConfig,
            "system": ClaudeCardReader.systemPrompt,
            "messages": [message],
        ]
        return body
    }

    private static let systemPrompt = "You read contract bridge deals from photos of a bridge table so they can be replayed in an app."

    private static let instructions = """
    This photo shows a bridge table with four hands laid face up, usually fanned, one hand on each side of the photo. Read every card in every hand.

    - Report each hand by where it sits in the image as displayed: top, right, bottom or left.
    - A complete hand has 13 cards. Read each card's rank and suit from its corner index; neighbouring cards often cover most of a card, so also use pips, colour and court-card artwork.
    - Ranks are A K Q J 10 9 8 7 6 5 4 3 2. Cards near the far side of the table are upside down to the camera, so check 6 against 9 carefully.
    - If you can see that a card is there but cannot read its rank or its suit, include it with "?" for the part you cannot read (for example a red card whose index is hidden: suit H or D if you can tell which, otherwise "?"). Do not guess. The app fills unreadable cards by elimination, so an honest "?" is better than a wrong card.
    - Across the four hands each of the 52 cards appears exactly once. Use that to resolve doubtful readings.
    - If a duplicate board, card tray or table marker shows compass letters (N, E, S, W), report which compass direction each side of the image faces; use "unknown" for sides you cannot determine. If the board number is printed on the board or tray, report it, otherwise null.
    - Put anything the player should double-check in notes, in Chinese, in one or two short sentences. Leave notes empty if everything is clear.
    """

    private static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "hands": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "position": {"type": "string", "enum": ["top", "right", "bottom", "left"]},
              "cards": {
                "type": "array",
                "items": {
                  "type": "object",
                  "properties": {
                    "rank": {"type": "string", "enum": ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2", "?"]},
                    "suit": {"type": "string", "enum": ["S", "H", "D", "C", "?"]}
                  },
                  "required": ["rank", "suit"],
                  "additionalProperties": false
                }
              }
            },
            "required": ["position", "cards"],
            "additionalProperties": false
          }
        },
        "compass": {
          "type": "object",
          "properties": {
            "top": {"type": "string", "enum": ["N", "E", "S", "W", "unknown"]},
            "right": {"type": "string", "enum": ["N", "E", "S", "W", "unknown"]},
            "bottom": {"type": "string", "enum": ["N", "E", "S", "W", "unknown"]},
            "left": {"type": "string", "enum": ["N", "E", "S", "W", "unknown"]}
          },
          "required": ["top", "right", "bottom", "left"],
          "additionalProperties": false
        },
        "board_number": {"anyOf": [{"type": "integer"}, {"type": "null"}]},
        "notes": {"type": "string"}
      },
      "required": ["hands", "compass", "board_number", "notes"],
      "additionalProperties": false
    }
    """

    // swiftlint:disable:next force_try
    private static let schema: Any = try! JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))

    // MARK: - 解析

    private struct APIErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stop_reason: String?
    }

    private struct Payload: Decodable {
        struct Hand: Decodable {
            struct Item: Decodable {
                let rank: String
                let suit: String
            }
            let position: String
            let cards: [Item]
        }
        struct Compass: Decodable {
            let top: String
            let right: String
            let bottom: String
            let left: String
        }
        let hands: [Hand]
        let compass: Compass
        let board_number: Int?
        let notes: String
    }

    static func parse(_ data: Data) throws -> RecognitionResult {
        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        switch message.stop_reason {
        case "refusal": throw RecognitionError.refused
        case "max_tokens": throw RecognitionError.truncated
        default: break
        }
        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let json = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: json) else {
            throw RecognitionError.badResponse
        }

        var hands: [PhotoSide: [PartialCard]] = [:]
        for hand in payload.hands {
            guard let side = PhotoSide(rawValue: hand.position) else { continue }
            let cards = hand.cards.map { item in
                PartialCard(suit: item.suit.first.flatMap { Suit(letter: $0) },
                            rank: Card.rank(from: item.rank))
            }
            hands[side, default: []].append(contentsOf: cards)
        }

        var compass: [PhotoSide: Seat] = [:]
        let sides: [(PhotoSide, String)] = [(.top, payload.compass.top), (.right, payload.compass.right),
                                            (.bottom, payload.compass.bottom), (.left, payload.compass.left)]
        for (side, value) in sides where value.count == 1 {
            if let seat = Seat(letter: value.first!) { compass[side] = seat }
        }

        return RecognitionResult(hands: hands, compass: compass, boardNumber: payload.board_number, notes: payload.notes)
    }
}

/// API Key 存在钥匙串里。
enum APIKeyStore {
    private static let service = "com.yaogame.BridgeReplay.anthropic"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        delete()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
