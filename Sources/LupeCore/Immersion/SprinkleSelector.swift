import CoreGraphics
import Foundation

/// A word on screen that deserves a tiny label.
public struct SprinkleCandidate: Sendable, Hashable, Identifiable {
    public enum Mode: String, Sendable { case teach, assist }
    public enum Reason: String, Sendable { case reinforce, frontier, beyond }

    /// Stable across scans of the same content (used for "stickiness" and animations).
    public var id: String
    public var word: String
    /// Range of `word` inside `lineText`.
    public var wordRange: Range<String.Index>
    /// Word rectangle in global screen points (Cocoa coordinates, origin bottom-left).
    public var wordRect: CGRect
    public var lineText: String
    public var lineLanguage: String
    public var entry: LexEntry
    /// Other senses to try if the context check rejects `entry` ("bank" → Bank / Ufer).
    public var alternates: [LexEntry]
    public var mode: Mode
    public var reason: Reason
    public var score: Double
    /// Label text: "der Tisch" (teach) or "table" (assist).
    public var label: String
    /// The word's form in the translated sentence, when verified ("Bücher").
    public var formInContext: String?
    /// Free space (points) between the word and the nearest text above/below, for placing the tag.
    public var spaceAbove: CGFloat = 40
    public var spaceBelow: CGFloat = 40
}

public struct SprinkleConfig: Sendable {
    /// Maximum labels on one screen.
    public var budget: Int = 6
    public var maxPerLine: Int = 1
    /// Minimum distance between two labelled words, in points.
    public var minSpacing: CGFloat = 110
    /// CEFR levels assumed known from the placement in onboarding (e.g. ["A1"]); never tagged.
    public var knownLevels: Set<String> = []
    /// The level you're working towards; its words are the most useful to tag.
    public var nextLevel: String? = "A1"
    /// Label German text with helper-language glosses.
    public var assistGerman: Bool = true
    /// Label English/Portuguese text with German.
    public var teachFromHelpers: Bool = true
    /// Skip text smaller than this (points).
    public var minWordHeight: CGFloat = 8
    public var minLineConfidence: Float = 0.35

    public init() {}
}

/// What the selector needs to know about the learner.
public struct LearnerSnapshot: Sendable {
    public var knownKeys: Set<String>
    /// Card key → reinforcement score 0...1 (due cards ≈ 1).
    public var reinforcement: [String: Double]
    /// Candidate ids shown on the previous scan (kept for stability).
    public var previous: Set<String>
    /// Entry ids hidden for this session ("not now").
    public var dismissed: Set<String>

    public init(knownKeys: Set<String> = [], reinforcement: [String: Double] = [:], previous: Set<String> = [], dismissed: Set<String> = []) {
        self.knownKeys = knownKeys
        self.reinforcement = reinforcement
        self.previous = previous
        self.dismissed = dismissed
    }
}

public enum SprinkleSelector {
    /// Scores every eligible word on screen, best first. No translation calls here; this is fast.
    /// - Parameters:
    ///   - lines: OCR lines with normalized rects relative to `frame`.
    ///   - frame: the captured area in global screen points.
    public static func rank(lines: [RecognizedLine], frame: CGRect, engine: LookupEngine,
                            config: SprinkleConfig, learner: LearnerSnapshot) -> [SprinkleCandidate] {
        let lexicon = engine.lexicon
        var out: [SprinkleCandidate] = []
        var languageCache: [String: String] = [:]
        let lineRects = lines.map { $0.rect.denormalized(in: frame) }
        func spaces(for r: CGRect, line: Int) -> (above: CGFloat, below: CGFloat) {
            var above = frame.maxY - r.maxY, below = r.minY - frame.minY
            for (i, l) in lineRects.enumerated() where i != line && l.minX < r.maxX && l.maxX > r.minX {
                if l.minY >= r.maxY - 2 { above = min(above, l.minY - r.maxY) }
                if l.maxY <= r.minY + 2 { below = min(below, r.minY - l.maxY) }
            }
            return (max(0, above), max(0, below))
        }

        for (lineIndex, line) in lines.enumerated() where line.confidence >= config.minLineConfidence {
            let text = line.text
            guard text.count >= 3, TextTools.isMostlyLetters(text) else { continue }
            let wordCount = text.split(separator: " ").count
            let lang: String
            if let cached = languageCache[text] { lang = cached } else {
                guard let (l, conf) = TextTools.detectLanguageWithConfidence(text, candidates: engine.languages) else { continue }
                // Single words (menu items, buttons) are too ambiguous to classify reliably.
                if wordCount < 3 && conf < 0.8 { continue }
                lang = l
                languageCache[text] = l
            }
            let isTarget = lang == engine.target
            if isTarget && !config.assistGerman { continue }
            if !isTarget && !config.teachFromHelpers { continue }

            let tokens = TextTools.analyze(text, language: lang)
            let stop = Stopwords.set(for: lang)
            let chromePenalty = wordCount < 3 ? 0.6 : 1.0

            for (ti, token) in tokens.enumerated() {
                let folded = Lexicon.fold(token.text)
                guard folded.count >= 3, !stop.contains(folded), token.wordClass != .number,
                      !(token.text.count > 1 && token.text == token.text.uppercased()) else { continue }
                guard let ocrWord = line.words.first(where: { $0.range.overlaps(token.range) }) else { continue }
                let rect = ocrWord.rect.denormalized(in: frame)
                guard rect.height >= config.minWordHeight else { continue }

                var entry: LexEntry?
                var alternates: [LexEntry] = []
                let mode: SprinkleCandidate.Mode
                if isTarget {
                    mode = .assist
                    let capitalized = token.isCapitalized && ti > 0
                    entry = lexicon.bestEntry(forGerman: token.text, lemma: token.lemma, capitalized: capitalized)
                } else {
                    mode = .teach
                    let cands = engine.candidateEntries(word: token.text, token: token, tokens: tokens, language: lang)
                        .filter { $0.pos.isContentWord }
                    entry = cands.first
                    alternates = Array(cands.dropFirst().prefix(3))
                }
                guard let e = entry, e.pos.isContentWord else { continue }
                if learner.dismissed.contains(e.id) { continue }

                let reinforce = learner.reinforcement[e.id] ?? 0
                if reinforce == 0 && learner.knownKeys.contains(e.id) { continue }

                var score: Double
                var reason: SprinkleCandidate.Reason
                if reinforce > 0 {
                    score = 60 + 40 * reinforce
                    reason = .reinforce
                } else if config.knownLevels.contains(e.cefr) {
                    continue // probably known already
                } else if e.cefr == config.nextLevel {
                    // More frequent words (lower rank) first.
                    score = 20 + 35 * (1 - min(1, Double(e.rank) / 4000))
                    reason = .frontier
                } else {
                    score = 12
                    reason = .beyond
                }
                switch e.pos {
                case .noun: score += 8
                case .verb, .adjective: score += 4
                default: break
                }
                if mode == .teach && !alternates.isEmpty { score -= 4 }
                score *= chromePenalty

                let id = "\(e.id)|\(folded)|\(stableHash(text))"
                if learner.previous.contains(id) { score += 25 }
                score += Double(stableHash(id) % 1000) / 100_000 // deterministic tie-break

                let label = mode == .teach ? lexicon.display(e) : (e.gloss(engine.primaryHelper) ?? e.gloss("en") ?? "")
                guard !label.isEmpty else { continue }
                let room = spaces(for: rect, line: lineIndex)
                out.append(SprinkleCandidate(id: id, word: token.text, wordRange: token.range, wordRect: rect, lineText: text, lineLanguage: lang,
                                             entry: e, alternates: alternates, mode: mode, reason: reason, score: score,
                                             label: label, formInContext: nil, spaceAbove: room.above, spaceBelow: room.below))
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// Greedy pick under the budget and spacing rules. `verify` may confirm, swap or reject a candidate
    /// (used for the sentence-translation sense check); it is called at most `maxVerifications` times.
    public static func pick(_ ranked: [SprinkleCandidate], config: SprinkleConfig, maxVerifications: Int = 14,
                            verify: ((SprinkleCandidate) async -> SprinkleCandidate?)? = nil,
                            onAccept: ((SprinkleCandidate) async -> Void)? = nil) async -> [SprinkleCandidate] {
        var picked: [SprinkleCandidate] = []
        var perLine: [String: Int] = [:]
        var usedEntries = Set<String>()
        var verifications = 0
        for c in ranked {
            if picked.count >= config.budget { break }
            if usedEntries.contains(c.entry.id) { continue }
            let lineKey = "\(c.lineText)|\(Int(c.wordRect.midY / 4))"
            if (perLine[lineKey] ?? 0) >= config.maxPerLine { continue }
            if picked.contains(where: { $0.wordRect.center.distance(to: c.wordRect.center) < config.minSpacing }) { continue }
            var accepted = c
            if let verify {
                if verifications >= maxVerifications { break }
                verifications += 1
                guard let v = await verify(c) else { continue }
                if usedEntries.contains(v.entry.id) { continue }
                accepted = v
            }
            picked.append(accepted)
            perLine[lineKey, default: 0] += 1
            usedEntries.insert(accepted.entry.id)
            await onAccept?(accepted)
        }
        return picked
    }

    /// Context check: translate the line and keep the sense that appears in the translation.
    public static func verifier(engine: LookupEngine) -> (SprinkleCandidate) async -> SprinkleCandidate? {
        { candidate in
            guard candidate.mode == .teach else { return candidate }
            guard let translated = try? await engine.translator.translateAligned(candidate.lineText, highlight: candidate.wordRange,
                                                                                  from: candidate.lineLanguage, to: engine.target) else {
                // Translation unavailable: only keep unambiguous words.
                return candidate.alternates.isEmpty ? candidate : nil
            }
            let germanTokens = TextTools.analyze(translated.text, language: engine.target)
            let senses = [candidate.entry] + candidate.alternates
            var confirmed: (LexEntry, String)?
            if let ar = translated.alignedRange {
                // Prefer the words the translator aligned with this one.
                let span = germanTokens.filter { $0.range.overlaps(ar) }
                outer: for t in span {
                    for e in senses where LookupEngine.matches(e, token: t, lexicon: engine.lexicon) {
                        confirmed = (e, t.text)
                        break outer
                    }
                }
                // Aligned to something else entirely: this word isn't translated with our entry here.
                if confirmed == nil && span.contains(where: { !Stopwords.de.contains(Lexicon.fold($0.text)) }) { return nil }
            }
            if confirmed == nil {
                confirmed = LookupEngine.firstConfirmed(senses, in: germanTokens, lexicon: engine.lexicon)
            }
            guard let (entry, form) = confirmed else { return nil }
            var c = candidate
            if entry.id != candidate.entry.id {
                c.entry = entry
                c.label = engine.lexicon.display(entry)
            }
            c.formInContext = form
            return c
        }
    }

    /// FNV-1a, stable across launches (unlike `hashValue`).
    public static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
