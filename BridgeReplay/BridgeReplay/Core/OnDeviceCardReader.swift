import Foundation
import UIKit
import Vision

/// 在手机本地识别照片里的牌，不联网。
///
/// 做法：
/// 1. 把照片里的红色、黑色笔画分成一块块连通区域。
/// 2. 找出实心、小块的区域作为牌角的花色符号候选。
/// 3. 在它旁边找同颜色的笔画当作点数（牌角里点数在花色上方），由此得到这张牌"朝上"的方向。
/// 4. 花色：红色看形状上下是否对称（♥ 上宽下尖，♦ 上下对称），黑色看轮廓凹口数量（♣ 三瓣有 3 个以上凹口，♠ 只有 2 个）。
/// 5. 点数：把点数区域转正、放大、二值化后交给 Vision 文字识别。
/// 6. 另外把整张照片按 12 个角度转着交给 Vision 找点数字符，再到字符下方找花色，补上第一步漏掉的牌。
/// 7. 按在照片里的位置分成上下左右四手牌。
enum OnDeviceCardReader {
    static func read(_ image: UIImage) async throws -> RecognitionResult {
        try await Task.detached(priority: .userInitiated) {
            guard let bitmap = Bitmap(image: image, maxLongEdge: 2000) else { throw RecognitionError.imageEncoding }
            return recognize(bitmap)
        }.value
    }

    // MARK: - 主流程

    static func recognize(_ bitmap: Bitmap) -> RecognitionResult {
        let masks = InkMasks(bitmap)
        let blobs = Blob.find(in: masks.red, color: .red, width: bitmap.width, height: bitmap.height)
            + Blob.find(in: masks.black, color: .black, width: bitmap.width, height: bitmap.height)

        var detections: [Detection] = []
        for suitBlob in blobs where suitBlob.isSuitLike {
            guard let glyph = bestRankGlyph(for: suitBlob, among: blobs) else { continue }
            let dx = glyph.cx - suitBlob.cx, dy = glyph.cy - suitBlob.cy
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 0 else { continue }
            let up = (x: dx / distance, y: dy / distance)
            let suit = classifySuit(suitBlob, up: up)
            let glyphSize = Double(max(glyph.width, glyph.height))
            var rank: Int?
            // 先用二值化的图读，读不出再用灰度图读一次。
            for binarize in [true, false] where rank == nil {
                if let crop = bitmap.uprightCrop(centerX: glyph.cx, centerY: glyph.cy, up: up,
                                                 width: 2.0 * glyphSize, height: 1.5 * glyphSize,
                                                 scale: 4, red: suitBlob.color == .red, binarize: binarize) {
                    rank = readRank(crop)
                }
            }
            guard let rank else { continue }
            detections.append(Detection(card: Card(suit: suit, rank: rank),
                                        x: suitBlob.cx, y: suitBlob.cy, size: suitBlob.size, blobID: suitBlob.id))
        }

        // 第二条路：整图找点数字符，补上漏掉的牌。
        detections += textPass(bitmap, blobs: blobs, used: Set(detections.map(\.blobID)))

        // 牌面中间的大花色比牌角的大很多，去掉。
        if !detections.isEmpty {
            let sizes = detections.map(\.size).sorted()
            let median = sizes[sizes.count / 2]
            detections.removeAll { $0.size > 1.7 * median }
        }
        return group(detections)
    }

    struct Detection {
        let card: Card
        let x: Double
        let y: Double
        let size: Double
        let blobID: Int
    }

    // MARK: - 整图文字识别

    /// 把整张照片转 12 个角度交给 Vision，找到点数字符后，在它下方找花色符号。
    static func textPass(_ bitmap: Bitmap, blobs: [Blob], used: Set<Int>) -> [Detection] {
        guard let base = bitmap.cgImage() else { return [] }
        let suitBlobs = blobs.filter(\.isSuitLike)
        var taken = used
        var result: [Detection] = []
        for degrees in stride(from: 0, to: 360, by: 30) {
            guard let rotated = RotatedImage(base, degrees: Double(degrees)) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.008
            let handler = VNImageRequestHandler(cgImage: rotated.image, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                for token in rankTokens(in: candidate.string) {
                    guard let box = (try? candidate.boundingBox(for: token.range))?.boundingBox else { continue }
                    let center = rotated.toOriginal(x: Double(box.midX), y: Double(box.midY))
                    let below = rotated.toOriginal(x: Double(box.midX), y: Double(box.midY - box.height))
                    let dx = below.x - center.x, dy = below.y - center.y
                    let glyphHeight = (dx * dx + dy * dy).squareRoot()
                    guard glyphHeight > 4 else { continue }
                    let target = (x: center.x + dx * 1.1, y: center.y + dy * 1.1)
                    var best: Blob?
                    var bestDistance = Double.infinity
                    for b in suitBlobs where !taken.contains(b.id) {
                        let d = ((b.cx - target.x) * (b.cx - target.x) + (b.cy - target.y) * (b.cy - target.y)).squareRoot()
                        if d < bestDistance, d < 0.9 * glyphHeight, b.size > 0.3 * glyphHeight, b.size < 1.5 * glyphHeight {
                            best = b
                            bestDistance = d
                        }
                    }
                    guard let suitBlob = best else { continue }
                    taken.insert(suitBlob.id)
                    let up = (x: -dx / glyphHeight, y: -dy / glyphHeight)
                    result.append(Detection(card: Card(suit: classifySuit(suitBlob, up: up), rank: token.rank),
                                            x: suitBlob.cx, y: suitBlob.cy, size: suitBlob.size, blobID: suitBlob.id))
                }
            }
        }
        return result
    }

    /// 从一行文字里挑出点数字符（A K Q J 10 9…2）及其位置。
    static func rankTokens(in text: String) -> [(range: Range<String.Index>, rank: Int)] {
        var tokens: [(range: Range<String.Index>, rank: Int)] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = String(text[i]).uppercased()
            let next = text.index(after: i)
            if ["1", "I", "L"].contains(c), next < text.endIndex, ["0", "O"].contains(String(text[next]).uppercased()) {
                let end = text.index(after: next)
                tokens.append((i..<end, 8))
                i = end
                continue
            }
            if c != "T", let rank = Card.rank(from: c) {
                tokens.append((i..<next, rank))
            }
            i = next
        }
        return tokens
    }

    /// 以所有识别到的牌的中心为原点，按方位分成上下左右四手。
    static func group(_ detections: [Detection]) -> RecognitionResult {
        guard !detections.isEmpty else { return RecognitionResult(hands: [:], compass: [:], boardNumber: nil, notes: "") }
        let cx = detections.map(\.x).reduce(0, +) / Double(detections.count)
        let cy = detections.map(\.y).reduce(0, +) / Double(detections.count)
        var hands: [PhotoSide: [PartialCard]] = [:]
        var seen: [PhotoSide: Set<Card>] = [:]
        for d in detections {
            let vx = d.x - cx, vy = d.y - cy
            let side: PhotoSide = abs(vy) > abs(vx) ? (vy < 0 ? .top : .bottom) : (vx < 0 ? .left : .right)
            // 同一手里同一张牌（例如最上面那张的两个牌角）只算一次。
            if seen[side, default: []].insert(d.card).inserted {
                hands[side, default: []].append(PartialCard(suit: d.card.suit, rank: d.card.rank))
            }
        }
        return RecognitionResult(hands: hands, compass: [:], boardNumber: nil, notes: "")
    }

    // MARK: - 找点数

    static func bestRankGlyph(for suit: Blob, among blobs: [Blob]) -> Blob? {
        var best: (score: Double, blob: Blob)?
        for g in blobs where g.id != suit.id && g.color == suit.color {
            let dx = g.cx - suit.cx, dy = g.cy - suit.cy
            let d = (dx * dx + dy * dy).squareRoot()
            guard d > 0.7 * suit.size, d < 3.0 * suit.size else { continue }
            let areaRatio = Double(g.area) / Double(suit.area)
            guard areaRatio > 0.3, areaRatio < 8 else { continue }
            if g.isSuitLike && areaRatio > 0.6 && areaRatio < 1.6 { continue }  // 旁边另一张牌的花色
            if g.solidity > 0.85 && g.fill > 0.6 { continue }                   // 实心色块，不是字
            let score = d / suit.size - 0.3 * min(areaRatio, 3)
            if best == nil || score < best!.score { best = (score, g) }
        }
        return best?.blob
    }

    // MARK: - 花色

    static func classifySuit(_ blob: Blob, up: (x: Double, y: Double)) -> Suit {
        switch blob.color {
        case .black:
            let deep = blob.defectDepths.filter { $0 > 0.11 }.count
            return deep >= 3 ? .clubs : .spades
        case .red:
            // 沿"朝上"方向看：♥ 上半部分宽、下面是尖，♦ 上下对称。
            var top = 0.0, bottom = 0.0
            var points: [(t: Double, s: Double)] = []
            for (px, py) in blob.pixels {
                let x = Double(px) + 0.5 - blob.cx, y = Double(py) + 0.5 - blob.cy
                let t = x * up.x + y * up.y
                let s = x * -up.y + y * up.x
                points.append((t, s))
                top = max(top, t)
                bottom = max(bottom, -t)
            }
            guard top > 0, bottom > 0 else { return .diamonds }
            var high = 0.0, low = 0.0
            for p in points {
                if p.t > 0.35 * top { high = max(high, abs(p.s)) }
                if p.t < -0.35 * bottom { low = max(low, abs(p.s)) }
            }
            let ratio = top / bottom
            let widthRatio = (high + 0.001) / (low + 0.001)
            var heartScore = (0.85 - ratio) * 4 + (widthRatio - 1.1)
            if (blob.defectDepths.first ?? 0) > 0.15 { heartScore += 0.3 }
            return heartScore > 0 ? .hearts : .diamonds
        }
    }

    // MARK: - 点数（Vision）

    static func readRank(_ crop: CGImage) -> Int? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.1
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                if let rank = rank(fromOCR: candidate.string) { return rank }
            }
        }
        return nil
    }

    /// 把识别出的文字换成点数（0...12 对应 2...A），顺便纠正常见的认错。
    static func rank(fromOCR text: String) -> Int? {
        let t = text.uppercased().filter { !$0.isWhitespace }
        for ten in ["10", "1O", "IO", "LO", "TO", "1D"] where t.contains(ten) { return 8 }
        guard let c = t.first else { return nil }
        switch c {
        case "A", "K", "Q", "J", "9", "8", "7", "6", "5", "4", "3", "2":
            return Card.rank(from: String(c))
        case "O", "0": return 10   // Q
        case "B": return 6         // 8
        case "S": return 3         // 5
        case "G": return 4         // 6
        case "Z": return 0         // 2
        case "T": return 5         // 7
        default: return nil
        }
    }
}

// MARK: - 位图

/// RGBA 位图，第 0 行是照片最上面一行。
struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: UIImage, maxLongEdge: CGFloat) {
        let w0 = image.size.width * image.scale
        let h0 = image.size.height * image.scale
        guard w0 > 0, h0 > 0 else { return nil }
        let ratio = min(1, maxLongEdge / max(w0, h0))
        let w = max(1, Int((w0 * ratio).rounded()))
        let h = max(1, Int((h0 * ratio).rounded()))
        var buffer = [UInt8](repeating: 255, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // 翻转成 UIKit 坐标，照片方向（EXIF）由 UIImage.draw 处理。
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            UIGraphicsPopContext()
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// 以 (centerX, centerY) 为中心、让 up 方向朝上，裁出一块放大并二值化的灰度图（字为黑、底为白）。
    func uprightCrop(centerX: Double, centerY: Double, up: (x: Double, y: Double),
                     width cw: Double, height ch: Double, scale: Double, red: Bool, binarize: Bool = true) -> CGImage? {
        let ow = Int(cw * scale), oh = Int(ch * scale)
        guard ow > 4, oh > 4 else { return nil }
        let right = (x: -up.y, y: up.x)
        var gray = [Double](repeating: 255, count: ow * oh)
        var reds = [Bool](repeating: false, count: ow * oh)
        for v in 0..<oh {
            for u in 0..<ow {
                let du = (Double(u) - Double(ow) / 2) / scale
                let dv = (Double(v) - Double(oh) / 2) / scale
                let sx = centerX + right.x * du - up.x * dv
                let sy = centerY + right.y * du - up.y * dv
                let xi = Int(sx), yi = Int(sy)
                guard xi >= 0, yi >= 0, xi < width, yi < height else { continue }
                let (r, g, b) = rgb(xi, yi)
                gray[v * ow + u] = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
                reds[v * ow + u] = r - g > 40 && r - b > 25
            }
        }
        let sorted = gray.sorted()
        let paper = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let pad = 30
        let pw = ow + 2 * pad, ph = oh + 2 * pad
        var out = [UInt8](repeating: 255, count: pw * ph)
        for v in 0..<oh {
            for u in 0..<ow {
                if binarize {
                    let ink = red ? reds[v * ow + u] : gray[v * ow + u] < 0.55 * paper
                    if ink { out[(v + pad) * pw + u + pad] = 0 }
                } else {
                    out[(v + pad) * pw + u + pad] = UInt8(max(0, min(255, gray[v * ow + u] / max(paper, 1) * 255)))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pw,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - 红黑笔画

struct InkMasks {
    let red: [Bool]
    let black: [Bool]

    init(_ bitmap: Bitmap) {
        let w = bitmap.width, h = bitmap.height
        var gray = [Float](repeating: 0, count: w * h)
        var red = [Bool](repeating: false, count: w * h)
        var chroma = [Int](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = bitmap.rgb(x, y)
                let i = y * w + x
                gray[i] = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
                red[i] = r - g > 45 && r - b > 30 && r > 60
                chroma[i] = max(r, g, b) - min(r, g, b)
            }
        }
        // 局部纸面亮度：在缩小 8 倍的图上取邻域最大值，再模糊一下。
        let cell = 8
        let sw = (w + cell - 1) / cell, sh = (h + cell - 1) / cell
        var small = [Float](repeating: 0, count: sw * sh)
        for y in 0..<h {
            for x in 0..<w {
                let j = (y / cell) * sw + x / cell
                small[j] = max(small[j], gray[y * w + x])
            }
        }
        let radius = max(1, (max(15, min(w, h) / 40) / cell) / 2)
        small = InkMasks.boxFilter(InkMasks.maxFilter(small, sw, sh, radius), sw, sh, radius)
        var black = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let paper = small[(y / cell) * sw + x / cell]
                black[i] = gray[i] < 0.5 * paper && !red[i] && chroma[i] < 60
            }
        }
        self.red = red
        self.black = black
    }

    static func maxFilter(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var tmp = a, out = a
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, x - r)...min(w - 1, x + r) { m = max(m, a[y * w + k]) }
                tmp[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for k in max(0, y - r)...min(h - 1, y + r) { m = max(m, tmp[k * w + x]) }
                out[y * w + x] = m
            }
        }
        return out
    }

    static func boxFilter(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var out = a
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                var n: Float = 0
                for yy in max(0, y - r)...min(h - 1, y + r) {
                    for xx in max(0, x - r)...min(w - 1, x + r) {
                        sum += a[yy * w + xx]
                        n += 1
                    }
                }
                out[y * w + x] = sum / n
            }
        }
        return out
    }
}

// MARK: - 连通区域

enum InkColor { case red, black }

struct Blob {
    let id: Int
    let color: InkColor
    let minX: Int, minY: Int, width: Int, height: Int
    let area: Int
    let cx: Double, cy: Double
    /// 像素坐标（整张图）。
    let pixels: [(Int, Int)]
    let solidity: Double
    /// 凸包凹口深度（相对尺寸），从大到小。
    let defectDepths: [Double]

    var size: Double { Double(area).squareRoot() }
    var fill: Double { Double(area) / Double(width * height) }
    var isSuitLike: Bool {
        let aspect = Double(width) / Double(max(height, 1))
        return solidity > 0.78 && fill > 0.4 && aspect > 0.45 && aspect < 2.2 && area >= 30
    }

    /// 找出掩码里所有面积在合理范围内的 8 连通区域。
    static func find(in mask: [Bool], color: InkColor, width w: Int, height h: Int) -> [Blob] {
        var visited = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        let idBase = color == .red ? 0 : 1_000_000
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            visited[start] = true
            stack.append(start)
            var pixels: [(Int, Int)] = []
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                pixels.append((x, y))
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let q = ny * w + nx
                        if mask[q] && !visited[q] {
                            visited[q] = true
                            stack.append(q)
                        }
                    }
                }
            }
            guard pixels.count >= 20, pixels.count <= 20_000 else { continue }
            let bw = maxX - minX + 1, bh = maxY - minY + 1
            var local = [Bool](repeating: false, count: bw * bh)
            var sx = 0.0, sy = 0.0
            for (x, y) in pixels {
                local[(y - minY) * bw + (x - minX)] = true
                sx += Double(x)
                sy += Double(y)
            }
            let contour = Shape.traceBoundary(local, bw, bh)
            let hullArea = Shape.polygonArea(Shape.convexHull(contour).map { contour[$0] })
            let solidity = hullArea > 0 ? Double(pixels.count) / hullArea : 0
            let isCandidate = solidity > 0.78
            blobs.append(Blob(id: idBase + blobs.count, color: color,
                              minX: minX, minY: minY, width: bw, height: bh, area: pixels.count,
                              cx: sx / Double(pixels.count) + 0.5, cy: sy / Double(pixels.count) + 0.5,
                              pixels: isCandidate ? pixels : [],
                              solidity: solidity,
                              defectDepths: isCandidate ? Shape.defectDepths(contour, size: max(bw, bh)) : []))
        }
        return blobs
    }
}

// MARK: - 轮廓几何

enum Shape {
    /// Moore 邻域边界跟踪，返回按顺序排列的边界像素（局部坐标）。
    static func traceBoundary(_ m: [Bool], _ w: Int, _ h: Int) -> [(Int, Int)] {
        guard let first = m.firstIndex(of: true) else { return [] }
        let start = (first % w, first / w)   // 最上面一行里最左边的点
        let dirs = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        var contour = [start]
        var cur = start
        var back = 0
        for _ in 0..<(4 * m.count) {
            var moved = false
            for k in 0..<8 {
                let d = (back + 1 + k) % 8
                let nx = cur.0 + dirs[d].0, ny = cur.1 + dirs[d].1
                if inside(nx, ny) {
                    back = (d + 4) % 8
                    cur = (nx, ny)
                    moved = true
                    break
                }
            }
            if !moved || cur == start { break }
            contour.append(cur)
        }
        return contour
    }

    /// 单调链凸包，返回边界点下标。
    static func convexHull(_ pts: [(Int, Int)]) -> [Int] {
        guard pts.count >= 3 else { return Array(pts.indices) }
        let idx = pts.indices.sorted { pts[$0] < pts[$1] }
        func cross(_ o: Int, _ a: Int, _ b: Int) -> Int {
            (pts[a].0 - pts[o].0) * (pts[b].1 - pts[o].1) - (pts[a].1 - pts[o].1) * (pts[b].0 - pts[o].0)
        }
        var lower: [Int] = [], upper: [Int] = []
        for i in idx {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], i) <= 0 { lower.removeLast() }
            lower.append(i)
        }
        for i in idx.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], i) <= 0 { upper.removeLast() }
            upper.append(i)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    static func polygonArea(_ pts: [(Int, Int)]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var s = 0
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += a.0 * b.1 - b.0 * a.1
        }
        return abs(Double(s)) / 2
    }

    /// 轮廓相对凸包的凹口深度（除以尺寸），只保留大于 0.06 的，从大到小。
    static func defectDepths(_ contour: [(Int, Int)], size: Int) -> [Double] {
        guard contour.count >= 5 else { return [] }
        let hull = Array(Set(convexHull(contour))).sorted()
        guard hull.count >= 3 else { return [] }
        let n = contour.count
        var depths: [Double] = []
        for k in hull.indices {
            let a = hull[k]
            let b = k + 1 < hull.count ? hull[k + 1] : hull[0] + n
            guard b - a >= 2 else { continue }
            let p = contour[a % n], q = contour[b % n]
            let length = max(1, Double((q.0 - p.0) * (q.0 - p.0) + (q.1 - p.1) * (q.1 - p.1)).squareRoot())
            var deepest = 0.0
            for j in (a + 1)..<b {
                let r = contour[j % n]
                let cross = Double((q.0 - p.0) * (p.1 - r.1) - (p.0 - r.0) * (q.1 - p.1))
                deepest = max(deepest, abs(cross) / length)
            }
            depths.append(deepest / Double(size))
        }
        return depths.filter { $0 > 0.06 }.sorted(by: >)
    }
}

// MARK: - 旋转

/// 转过角度的整张照片，以及把 Vision 坐标换回原图像素坐标的方法。
struct RotatedImage {
    let image: CGImage
    let radians: Double
    let width: Double
    let height: Double
    let sourceWidth: Double
    let sourceHeight: Double

    init?(_ source: CGImage, degrees: Double) {
        let r = degrees * .pi / 180
        let w = Double(source.width), h = Double(source.height)
        let nw = Int((abs(w * cos(r)) + abs(h * sin(r))).rounded())
        let nh = Int((abs(w * sin(r)) + abs(h * cos(r))).rounded())
        guard nw > 0, nh > 0,
              let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
        ctx.rotate(by: CGFloat(r))
        ctx.draw(source, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        image = out
        radians = r
        width = Double(nw)
        height = Double(nh)
        sourceWidth = w
        sourceHeight = h
    }

    /// Vision 的归一化坐标（左下角为原点）→ 原图像素坐标（左上角为原点）。
    func toOriginal(x nx: Double, y ny: Double) -> (x: Double, y: Double) {
        let px = nx * width - width / 2
        let py = ny * height - height / 2
        let c = cos(-radians), s = sin(-radians)
        let qx = px * c - py * s
        let qy = px * s + py * c
        return (qx + sourceWidth / 2, sourceHeight / 2 - qy)
    }
}
