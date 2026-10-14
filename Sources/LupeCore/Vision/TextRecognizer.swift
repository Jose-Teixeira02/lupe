import CoreGraphics
import Foundation
import Vision

/// A word found by OCR. `rect` is in normalized image coordinates (0...1, origin bottom-left, like Vision).
public struct RecognizedWord: Hashable, Sendable {
    public var text: String
    public var rect: CGRect
    /// Range of the word inside its line's `text`.
    public var range: Range<String.Index>

    public init(text: String, rect: CGRect, range: Range<String.Index>) {
        self.text = text
        self.rect = rect
        self.range = range
    }
}

/// A line of text found by OCR.
public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var rect: CGRect
    public var confidence: Float
    public var words: [RecognizedWord]

    public init(text: String, rect: CGRect, confidence: Float, words: [RecognizedWord]) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.words = words
    }
}

public struct RecognitionOptions: Sendable {
    public var accurate: Bool = true
    public var languages: [String] = ["en-US", "de-DE", "pt-PT"]
    public var languageCorrection: Bool = true
    /// Ignore text smaller than this fraction of the image height (0 = Vision default).
    public var minimumTextHeight: Float = 0
    /// Compute per-word boxes (costs a little extra time).
    public var wordBoxes: Bool = true

    public init(accurate: Bool = true, languages: [String] = ["en-US", "de-DE", "pt-PT"],
                languageCorrection: Bool = true, minimumTextHeight: Float = 0, wordBoxes: Bool = true) {
        self.accurate = accurate
        self.languages = languages
        self.languageCorrection = languageCorrection
        self.minimumTextHeight = minimumTextHeight
        self.wordBoxes = wordBoxes
    }
}

/// Thin wrapper around Vision text recognition that also returns per-word boxes.
public enum TextRecognizer {
    public static func recognize(_ image: CGImage, options: RecognitionOptions = .init()) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accurate ? .accurate : .fast
        request.recognitionLanguages = options.languages
        request.usesLanguageCorrection = options.languageCorrection
        if options.minimumTextHeight > 0 { request.minimumTextHeight = options.minimumTextHeight }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var lines = (request.results ?? []).compactMap { obs -> RecognizedLine? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let text = candidate.string
            var words: [RecognizedWord] = []
            if options.wordBoxes {
                for range in TextTools.wordRanges(in: text) {
                    guard let box = try? candidate.boundingBox(for: range) else { continue }
                    let word = String(text[range])
                    words.append(RecognizedWord(text: word, rect: box.boundingBox, range: range))
                }
            }
            return RecognizedLine(text: text, rect: obs.boundingBox, confidence: candidate.confidence, words: words)
        }
        // Accurate mode occasionally returns nothing for very small text; fall back to fast mode once.
        if lines.isEmpty && options.accurate {
            var fast = options
            fast.accurate = false
            lines = try recognize(image, options: fast)
        }
        return lines
    }

    /// Loads the recognition model so the first real request is quick (the first call can take many seconds).
    public static func warmUp() {
        let width = 320, height = 64
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let img = ctx.makeImage() {
            _ = try? recognize(img, options: .init(accurate: true))
            _ = try? recognize(img, options: .init(accurate: false))
        }
    }
}

public extension CGRect {
    /// Maps a Vision-normalized rect (origin bottom-left) into `frame` (also origin bottom-left, e.g. Cocoa screen coords).
    func denormalized(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + minX * frame.width,
               y: frame.minY + minY * frame.height,
               width: width * frame.width,
               height: height * frame.height)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func distance(to p: CGPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

public extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot()
    }
}
