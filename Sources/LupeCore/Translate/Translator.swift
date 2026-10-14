import Foundation
import Translation

/// Anything that turns text in one language into another. Apple's on-device engine is the default;
/// other providers (DeepL, an LLM) can conform later without touching the UI.
public protocol Translator: Sendable {
    func translate(_ text: String, from source: String, to target: String) async throws -> String
    /// Translates `text` and reports which part of the output corresponds to `highlight` in the input.
    func translateAligned(_ text: String, highlight: Range<String.Index>, from source: String, to target: String) async throws -> AlignedTranslation
}

/// A translation plus the span of the output that corresponds to a highlighted input word.
public struct AlignedTranslation: Sendable, Hashable {
    public var text: String
    /// The aligned output text, trimmed ("Bücher", "anrufen", "will call"); nil when the engine couldn't align.
    public var aligned: String?
    public var alignedRange: Range<String.Index>?

    public init(text: String, aligned: String?, alignedRange: Range<String.Index>?) {
        self.text = text
        self.aligned = aligned
        self.alignedRange = alignedRange
    }
}

public extension Translator {
    /// Default: no alignment support.
    func translateAligned(_ text: String, highlight: Range<String.Index>, from source: String, to target: String) async throws -> AlignedTranslation {
        AlignedTranslation(text: try await translate(text, from: source, to: target), aligned: nil, alignedRange: nil)
    }
}

public enum TranslatorError: Error, LocalizedError {
    case languageNotInstalled(String, String)
    case unsupported(String, String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .languageNotInstalled(let s, let t):
            "The \(s)→\(t) language pack isn't downloaded yet. Open Lupe Settings → Languages to download it."
        case .unsupported(let s, let t):
            "Translating \(s)→\(t) isn't supported on this Mac."
        case .empty:
            "Nothing to translate."
        }
    }
}

/// Apple's offline Translation framework with one session per language pair and an LRU cache.
public actor AppleTranslator: Translator {
    private var sessions: [String: TranslationSession] = [:]
    private var cache = LRUCache<String, String>(capacity: 4000)
    private var alignedCache = LRUCache<String, AlignedTranslation>(capacity: 1000)
    private let availability = LanguageAvailability()

    public init() {}

    public func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslatorError.empty }
        if source == target { return trimmed }
        let key = "\(source)>\(target)|\(trimmed)"
        if let hit = cache[key] { return hit }
        let session = try await session(from: source, to: target)
        let response = try await session.translate(trimmed)
        cache[key] = response.targetText
        return response.targetText
    }

    /// Uses attributed-string translation (macOS 26.4+): the highlighted word is emphasised and the
    /// emphasis survives translation on the corresponding output words.
    public func translateAligned(_ text: String, highlight: Range<String.Index>, from source: String, to target: String) async throws -> AlignedTranslation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, highlight.lowerBound >= text.startIndex, highlight.upperBound <= text.endIndex else { throw TranslatorError.empty }
        let key = "\(source)>\(target)|\(text)|\(text.distance(from: text.startIndex, to: highlight.lowerBound)):\(text.distance(from: highlight.lowerBound, to: highlight.upperBound))"
        if let hit = alignedCache[key] { return hit }
        guard #available(macOS 26.4, *) else {
            return AlignedTranslation(text: try await translate(text, from: source, to: target), aligned: nil, alignedRange: nil)
        }
        let session = try await session(from: source, to: target)
        var attributed = AttributedString(text)
        let lower = AttributedString.Index(highlight.lowerBound, within: attributed)
        let upper = AttributedString.Index(highlight.upperBound, within: attributed)
        guard let lower, let upper else {
            return AlignedTranslation(text: try await translate(text, from: source, to: target), aligned: nil, alignedRange: nil)
        }
        attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        let response = try await session.translate(attributed)
        let output = response.attributedTargetText ?? AttributedString(response.targetText)
        let plain = String(output.characters)
        var alignedRange: Range<String.Index>?
        for run in output.runs where run.inlinePresentationIntent != nil {
            let start = output.characters.distance(from: output.startIndex, to: run.range.lowerBound)
            let length = output.characters.distance(from: run.range.lowerBound, to: run.range.upperBound)
            let lo = plain.index(plain.startIndex, offsetBy: start)
            let hi = plain.index(lo, offsetBy: length)
            alignedRange = alignedRange.map { min($0.lowerBound, lo)..<max($0.upperBound, hi) } ?? lo..<hi
        }
        // Trim whitespace/punctuation from the aligned span.
        var alignedText: String?
        if var r = alignedRange {
            while r.lowerBound < r.upperBound, plain[r.lowerBound].isWhitespace || plain[r.lowerBound].isPunctuation {
                r = plain.index(after: r.lowerBound)..<r.upperBound
            }
            while r.lowerBound < r.upperBound, plain[plain.index(before: r.upperBound)].isWhitespace || plain[plain.index(before: r.upperBound)].isPunctuation {
                r = r.lowerBound..<plain.index(before: r.upperBound)
            }
            alignedRange = r.isEmpty ? nil : r
            alignedText = r.isEmpty ? nil : String(plain[r])
        }
        let result = AlignedTranslation(text: response.targetText, aligned: alignedText, alignedRange: alignedRange)
        alignedCache[key] = result
        cache["\(source)>\(target)|\(trimmed)"] = response.targetText
        return result
    }

    /// Whether a pair can be used right now (installed), could be downloaded (supported) or not at all.
    /// Checks both model strategies: binaries linked against older SDKs default to "low latency" models,
    /// while most Macs have the "high fidelity" ones installed.
    public func status(from source: String, to target: String) async -> LanguageAvailability.Status {
        let s = Locale.Language(identifier: source), t = Locale.Language(identifier: target)
        if #available(macOS 26.4, *) {
            var best = LanguageAvailability.Status.unsupported
            for strategy in [TranslationSession.Strategy.highFidelity, .lowLatency] {
                let st = await LanguageAvailability(preferredStrategy: strategy).status(from: s, to: t)
                if st == .installed { return .installed }
                if st == .supported { best = .supported }
            }
            return best
        }
        return await availability.status(from: s, to: t)
    }

    public func cachedTranslation(_ text: String, from source: String, to target: String) -> String? {
        cache["\(source)>\(target)|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"]
    }

    private func session(from source: String, to target: String) async throws -> TranslationSession {
        let pair = "\(source)>\(target)"
        if let s = sessions[pair] { return s }
        switch await status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslatorError.languageNotInstalled(source, target)
        case .unsupported: throw TranslatorError.unsupported(source, target)
        @unknown default: break
        }
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        var session = TranslationSession(installedSource: src, target: dst)
        if #available(macOS 26.4, *) {
            for strategy in [TranslationSession.Strategy.highFidelity, .lowLatency]
            where await LanguageAvailability(preferredStrategy: strategy).status(from: src, to: dst) == .installed {
                session = TranslationSession(installedSource: src, target: dst, preferredStrategy: strategy)
                break
            }
        }
        sessions[pair] = session
        return session
    }

    /// Runs one tiny translation so the first real lookup is fast.
    public func warmUp(pairs: [(String, String)]) async {
        for (s, t) in pairs {
            _ = try? await translate("Hello", from: s, to: t)
        }
    }
}

/// Small LRU cache (not thread-safe; use inside an actor or on one thread).
public struct LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    public let capacity: Int

    public init(capacity: Int) { self.capacity = capacity }

    public subscript(key: Key) -> Value? {
        mutating get {
            guard let v = storage[key] else { return nil }
            if let i = order.lastIndex(of: key), i != order.count - 1 {
                order.remove(at: i)
                order.append(key)
            }
            return v
        }
        set {
            if let newValue {
                if storage[key] == nil {
                    order.append(key)
                    if order.count > capacity {
                        let evicted = order.removeFirst()
                        storage[evicted] = nil
                    }
                }
                storage[key] = newValue
            } else {
                storage[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { storage.count }
}
