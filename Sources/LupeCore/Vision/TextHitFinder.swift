import CoreGraphics
import Foundation

/// A word found under the mouse, with the sentence around it.
public struct TextHit: Sendable {
    public enum Source: Sendable { case accessibility, ocr }

    public var word: String
    /// Sentence or line around the word.
    public var context: String
    /// Range of the word inside `context`.
    public var range: Range<String.Index>
    /// Word rectangle in global Cocoa points, when known.
    public var rect: CGRect?
    public var source: Source

    public init(word: String, context: String, range: Range<String.Index>, rect: CGRect?, source: Source) {
        self.word = word
        self.context = context
        self.range = range
        self.rect = rect
        self.source = source
    }
}

/// One visual line of text: OCR sometimes returns a line as several pieces ("…meeting." | "Can you…").
public struct VisualLine: Sendable {
    public var text: String
    /// Normalized rect (Vision coordinates).
    public var rect: CGRect
    /// Each OCR piece in this line: its index in the input and the character offset of its text in `text`.
    public var parts: [(index: Int, offset: Int)]
}

/// Picks the OCR word under a point and rebuilds the sentence around it, across wrapped lines.
public enum TextHitFinder {
    /// Merges OCR pieces that sit on the same line and are close together (not separate columns).
    /// - Parameter aspect: width / height of the captured area, to compare horizontal gaps with line height.
    public static func visualLines(_ lines: [RecognizedLine], aspect: CGFloat) -> [VisualLine] {
        let order = lines.indices.sorted { lines[$0].rect.midY > lines[$1].rect.midY }
        var groups: [[Int]] = []
        var rects: [CGRect] = []
        for i in order {
            let r = lines[i].rect
            let match = rects.indices.first { j in
                let g = rects[j]
                let overlap = min(g.maxY, r.maxY) - max(g.minY, r.minY)
                guard overlap > 0.5 * min(g.height, r.height), !(g.minX < r.maxX && r.minX < g.maxX) else { return false }
                // Horizontal gap measured in line heights; columns are much further apart than words.
                let gap = (r.minX >= g.maxX ? r.minX - g.maxX : g.minX - r.maxX) * aspect / max(min(g.height, r.height), 0.0001)
                return gap < 4
            }
            if let j = match {
                groups[j].append(i)
                rects[j] = rects[j].union(r)
            } else {
                groups.append([i])
                rects.append(r)
            }
        }
        var out: [VisualLine] = []
        for (g, members) in groups.enumerated() {
            var text = ""
            var parts: [(index: Int, offset: Int)] = []
            for (k, i) in members.sorted(by: { lines[$0].rect.minX < lines[$1].rect.minX }).enumerated() {
                if k > 0 { text += " " }
                parts.append((i, text.count))
                text += lines[i].text
            }
            out.append(VisualLine(text: text, rect: rects[g], parts: parts))
        }
        return out.sorted { $0.rect.maxY > $1.rect.maxY } // top first
    }

    /// Picks the word at `point` (global points) among OCR lines captured from `frame`.
    public static func hit(in lines: [RecognizedLine], frame: CGRect, at point: CGPoint) -> TextHit? {
        guard !lines.isEmpty else { return nil }
        // Find the word box containing the point (slightly inflated), else the closest on the same line.
        var best: (line: Int, word: Int, distance: CGFloat)?
        for (li, line) in lines.enumerated() {
            for (wi, w) in line.words.enumerated() {
                let r = w.rect.denormalized(in: frame)
                let d = r.insetBy(dx: -2, dy: -3).contains(point) ? 0 : r.distance(to: point)
                if d < 10, d < (best?.distance ?? .infinity) { best = (li, wi, d) }
            }
        }
        guard let best else { return nil }
        let line = lines[best.line]
        let word = line.words[best.word]
        guard TextTools.isMostlyLetters(word.text) else { return nil }

        // Work on visual lines so a sentence split into OCR pieces stays in order.
        let visual = visualLines(lines, aspect: frame.width / max(frame.height, 1))
        guard let pos = visual.firstIndex(where: { $0.parts.contains { $0.index == best.line } }),
              let part = visual[pos].parts.first(where: { $0.index == best.line }) else { return nil }
        let wordOffsetInLine = part.offset + line.text.distance(from: line.text.startIndex, to: word.range.lowerBound)

        // Paragraph: neighbouring visual lines with similar left edge and small vertical gaps.
        func related(_ a: VisualLine, _ b: VisualLine) -> Bool {
            let gap = a.rect.minY - b.rect.maxY // a above b
            let leftAligned = abs(a.rect.minX - b.rect.minX) < 0.04 || a.rect.minX < b.rect.maxX && b.rect.minX < a.rect.maxX
            // Lines of one paragraph sit close together; a heading has a bigger gap below it. OCR line heights
            // vary a lot with descenders, so compare the gap with the smaller line and only reject huge size jumps
            // (a ruler or a caption next to body text).
            let h = min(a.rect.height, b.rect.height)
            // Average character width tracks font size without the descender noise of box heights.
            let charWidth = { (v: VisualLine) in v.rect.width / CGFloat(max(v.text.count, 1)) }
            let size = charWidth(a) / max(charWidth(b), 0.000001)
            let shortLine = min(a.text.count, b.text.count) < 12 // too few characters to judge size
            let sameSize = shortLine || (size > 0.78 && size < 1.28)
            // Wrapped lines inside a paragraph run (nearly) full width. A clearly narrower line above with no
            // closing punctuation is a heading, a label or a ruler, not the start of this sentence.
            let ending = a.text.trimmingCharacters(in: .whitespaces).last
            let continues = ending.map { ",;:-–".contains($0) || $0.isLowercase && b.text.first?.isLowercase == true } ?? false
            let headingAbove = a.rect.width < b.rect.width * 0.7 && !continues && !(ending.map { ".!?".contains($0) } ?? false)
            return gap > -h * 0.5 && gap < h * 1.3 && leftAligned && sameSize && !headingAbove
        }
        var lo = pos, hi = pos
        while lo > 0, related(visual[lo - 1], visual[lo]), pos - lo < 4 { lo -= 1 }
        while hi < visual.count - 1, related(visual[hi], visual[hi + 1]), hi - pos < 4 { hi += 1 }

        var paragraph = ""
        var wordOffset = 0
        for i in lo...hi {
            var text = visual[i].text
            if i == pos { wordOffset = paragraph.count + wordOffsetInLine }
            if i < hi, text.hasSuffix("-"), visual[i + 1].text.first?.isLowercase == true {
                text.removeLast() // re-join hyphenated words
                paragraph += text
            } else {
                paragraph += text + (i < hi ? " " : "")
            }
        }
        guard wordOffset < paragraph.count else { return nil }
        let start = paragraph.index(paragraph.startIndex, offsetBy: wordOffset)
        guard let end = paragraph.index(start, offsetBy: word.text.count, limitedBy: paragraph.endIndex),
              paragraph[start..<end] == word.text else { return nil }
        let paraRange = start..<end
        let sentence = TextTools.sentence(in: paragraph, containing: paraRange)
        var rangeInSentence = sentence.range(of: word.text)
        if let sStart = paragraph.range(of: sentence)?.lowerBound {
            let off = paragraph.distance(from: sStart, to: start)
            if off >= 0, off + word.text.count <= sentence.count {
                let a = sentence.index(sentence.startIndex, offsetBy: off)
                let b = sentence.index(a, offsetBy: word.text.count)
                if sentence[a..<b] == word.text { rangeInSentence = a..<b }
            }
        }
        guard let rangeInSentence else { return nil }
        return TextHit(word: word.text, context: sentence, range: rangeInSentence,
                       rect: word.rect.denormalized(in: frame), source: .ocr)
    }
}
