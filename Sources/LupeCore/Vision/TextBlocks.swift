import CoreGraphics
import Foundation

/// A paragraph-like group of OCR lines.
public struct TextBlock: Sendable, Hashable, Identifiable {
    public var id: Int
    public var text: String
    /// Union of the line rects, normalized like Vision (origin bottom-left).
    public var rect: CGRect
    public var lines: [RecognizedLine]
}

public enum TextBlocks {
    /// Groups lines into blocks by vertical proximity, alignment and similar text height.
    /// - Parameter aspect: width / height of the capture, used to re-join lines OCR returned in pieces.
    public static func group(_ rawLines: [RecognizedLine], aspect: CGFloat = 1.6) -> [TextBlock] {
        // Same-line pieces become one line first, so a block reads in order.
        let lines = TextHitFinder.visualLines(rawLines, aspect: aspect).map { v -> RecognizedLine in
            let members = v.parts.map { rawLines[$0.index] }
            let confidence = members.map(\.confidence).min() ?? 1
            return RecognizedLine(text: v.text, rect: v.rect, confidence: confidence, words: [])
        }
        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY } // top to bottom
        var blocks: [[RecognizedLine]] = []
        for line in sorted {
            var placed = false
            for i in blocks.indices.reversed() {
                guard let last = blocks[i].last else { continue }
                let h = max(last.rect.height, line.rect.height)
                let gap = last.rect.minY - line.rect.maxY
                let ratio = line.rect.height / max(last.rect.height, 0.0001)
                let overlap = min(last.rect.maxX, line.rect.maxX) - max(last.rect.minX, line.rect.minX)
                let aligned = abs(last.rect.minX - line.rect.minX) < 0.02 || overlap > 0.5 * min(last.rect.width, line.rect.width)
                if gap > -h * 0.3, gap < h * 0.85, ratio > 0.7, ratio < 1.4, aligned {
                    blocks[i].append(line)
                    placed = true
                    break
                }
                // Only look back a few blocks: older ones are far above.
                if blocks.count - i > 4 { break }
            }
            if !placed { blocks.append([line]) }
        }
        return blocks.enumerated().map { i, ls in
            var text = ""
            for (j, l) in ls.enumerated() {
                var t = l.text
                if j < ls.count - 1, t.hasSuffix("-"), ls[j + 1].text.first?.isLowercase == true {
                    t.removeLast()
                    text += t
                } else {
                    text += t + (j < ls.count - 1 ? " " : "")
                }
            }
            let rect = ls.dropFirst().reduce(ls[0].rect) { $0.union($1.rect) }
            return TextBlock(id: i, text: text, rect: rect, lines: ls)
        }
    }
}
