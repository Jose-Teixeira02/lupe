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

/// Picks the OCR word under a point and rebuilds the sentence around it, across wrapped lines.
public enum TextHitFinder {
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

        // Paragraph: neighbouring lines with similar left edge and small vertical gaps.
        let ordered = lines.enumerated().sorted { $0.element.rect.maxY > $1.element.rect.maxY } // top first
        guard let pos = ordered.firstIndex(where: { $0.offset == best.line }) else { return nil }
        let lineHeight = line.rect.height
        func related(_ a: RecognizedLine, _ b: RecognizedLine) -> Bool {
            let gap = a.rect.minY - b.rect.maxY // a above b
            let leftAligned = abs(a.rect.minX - b.rect.minX) < 0.04 || a.rect.minX < b.rect.maxX && b.rect.minX < a.rect.maxX
            return gap > -lineHeight * 0.5 && gap < lineHeight * 0.9 && leftAligned
        }
        var lo = pos, hi = pos
        while lo > 0, related(ordered[lo - 1].element, ordered[lo].element), pos - lo < 4 { lo -= 1 }
        while hi < ordered.count - 1, related(ordered[hi].element, ordered[hi + 1].element), hi - pos < 4 { hi += 1 }

        var paragraph = ""
        var wordOffset = 0
        for i in lo...hi {
            var text = ordered[i].element.text
            if i == pos { wordOffset = paragraph.count + line.text.distance(from: line.text.startIndex, to: word.range.lowerBound) }
            if i < hi, text.hasSuffix("-"), ordered[i + 1].element.text.first?.isLowercase == true {
                text.removeLast() // re-join hyphenated words
                paragraph += text
            } else {
                paragraph += text + (i < hi ? " " : "")
            }
        }
        guard wordOffset < paragraph.count else { return nil }
        let start = paragraph.index(paragraph.startIndex, offsetBy: wordOffset)
        guard let end = paragraph.index(start, offsetBy: word.text.count, limitedBy: paragraph.endIndex) else { return nil }
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
