import Foundation

/// A multi-word expression the hovered word belongs to in this sentence:
/// "Ich drücke dir die **Daumen**" → *Daumen drücken* (to keep one's fingers crossed),
/// "I'm **running** late" → *zu spät*, "She **gave** up smoking" → *aufhören*.
public struct ContextExpression: Sendable, Hashable {
    public enum Origin: String, Sendable {
        /// From the pack's phrases (idioms, verbs with prepositions).
        case pack
        /// From the translator's alignment of a multi-word span.
        case alignment
    }

    /// The expression as it appears in the sentence's language ("running late", "drücke … Daumen").
    public var source: String
    /// The German expression to learn ("zu spät", "Daumen drücken", "sich verlassen auf").
    public var german: String
    /// Its meaning in the helper language ("to keep one's fingers crossed"); for English sources, the source itself.
    public var meaning: String
    /// The pack entry behind it, when there is one.
    public var entry: LexEntry?
    public var origin: Origin
    /// How it appears in the translated sentence ("aufgehört"), for highlighting.
    public var targetForm: String?

    public init(source: String, german: String, meaning: String, entry: LexEntry?, origin: Origin, targetForm: String? = nil) {
        self.source = source
        self.german = german
        self.meaning = meaning
        self.entry = entry
        self.origin = origin
        self.targetForm = targetForm
    }
}

// MARK: - German phrases in context

extension Lexicon {
    static let reflexivePronouns: Set<String> = ["mich", "dich", "sich", "uns", "euch"]
    static let reflexiveKey = "#refl"

    /// Matching key for a German token: folded lemma, with reflexive pronouns collapsed so "sich" in a
    /// pattern matches "mich"/"dich"/… in the sentence.
    static func phraseKey(_ t: AnalyzedToken) -> String {
        let text = fold(t.text)
        if reflexivePronouns.contains(text) { return reflexiveKey }
        return fold(t.lemma)
    }

    /// Pack phrases (pos `phr`) whose words all appear near the hovered token, longest first.
    /// Works with conjugation and separated parts: "Ich **drücke** dir die Daumen" → "Daumen drücken",
    /// "Er hat sich auf seinen Freund **verlassen**" → "sich verlassen auf".
    public func expressions(in tokens: [AnalyzedToken], around token: AnalyzedToken) -> [LexEntry] {
        guard let hovered = tokens.firstIndex(of: token) else { return [] }
        let keys = tokens.map(Self.phraseKey)
        let texts = tokens.map { Self.fold($0.text) }
        let hoveredKeys: Set<String> = [keys[hovered], texts[hovered]]
        var found: [(LexEntry, Int)] = []

        for (entry, pattern) in phrasePatterns where !pattern.isEmpty && !hoveredKeys.isDisjoint(with: pattern) {
            // Place every pattern word on the nearest unused sentence token.
            var used = Set<Int>()
            var ok = true
            for p in pattern {
                let matches = tokens.indices.filter { !used.contains($0) && (keys[$0] == p || texts[$0] == p) }
                guard let best = matches.min(by: { abs($0 - hovered) < abs($1 - hovered) }) else { ok = false; break }
                used.insert(best)
            }
            guard ok, used.contains(hovered), let lo = used.min(), let hi = used.max() else { continue }
            // Phrases made only of small words ("noch nicht", "so weit") must be contiguous, unless the pack marks
            // a gap with "…" ("um … zu", "entweder … oder"); others may be split by a few words.
            let hasGap = entry.lemma.contains("…")
            let allSmall = pattern.allSatisfy { Stopwords.de.contains($0) || $0.count <= 4 || $0 == Self.reflexiveKey }
            let maxSpan = hasGap ? pattern.count + 10 : (allSmall ? pattern.count - 1 : pattern.count + 5)
            guard hi - lo <= maxSpan else { continue }
            found.append((entry, pattern.count))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

// MARK: - Sense selection and English expressions

extension LookupEngine {
    /// English particles that turn a verb into a phrasal verb ("give up", "look after", "turn down").
    static let englishParticles: Set<String> = [
        "up", "down", "out", "off", "on", "in", "over", "away", "back", "after", "through", "around", "along", "into", "about", "for",
    ]

    /// German verbs that are often just the auxiliary of a tense, not the meaning ("hat aufgehört").
    static let auxiliaries: Set<String> = ["haben", "sein", "werden"]

    /// Index of the gloss (in `language`) that matches the words the translator used here.
    func senseIndex(of entry: LexEntry, matching aligned: String, language: String) -> Int? {
        let glosses = entry.glosses[language] ?? []
        guard glosses.count > 0 else { return nil }
        let stop = Stopwords.set(for: language)
        let words = TextTools.analyze(aligned, language: language)
            .flatMap { [$0.lemma.lowercased(), $0.text.lowercased()] }
            .filter { !stop.contains($0) }
        guard !words.isEmpty else { return nil }
        for (i, g) in glosses.enumerated() {
            let keyWords = Set(Lexicon.glossKeys(g, language: language, pos: entry.pos).flatMap { $0.split(separator: " ").map(String.init) })
            if words.contains(where: keyWords.contains) { return i }
        }
        return nil
    }

    /// Glosses with sense `index` first, in every helper language whose list runs parallel.
    func meanings(for entry: LexEntry, senseFirst index: Int?) -> [String: String] {
        var out: [String: String] = [:]
        let primaryCount = entry.glosses[primaryHelper]?.count ?? 0
        for h in helpers {
            var list = entry.glosses[h] ?? []
            if let index, index < list.count, list.count == primaryCount {
                list.insert(list.remove(at: index), at: 0)
            }
            if !list.isEmpty { out[h] = list.prefix(3).joined(separator: ", ") }
        }
        return out
    }

    /// Among homographs ("die Bank" bank / bench), the one whose meaning the translator used here.
    func homograph(for entry: LexEntry, word: String, lemma: String?, aligned: String) -> (LexEntry, Int?) {
        var candidates = lexicon.entries(forGerman: word)
        if let lemma { candidates += lexicon.entries(forGerman: lemma) }
        var seen = Set<String>()
        candidates = candidates.filter { $0.pos == entry.pos && seen.insert($0.id).inserted }
        if !candidates.contains(where: { $0.id == entry.id }) { candidates.insert(entry, at: 0) }
        for e in [entry] + candidates.filter({ $0.id != entry.id }) {
            if let i = senseIndex(of: e, matching: aligned, language: primaryHelper) { return (e, i) }
        }
        return (entry, nil)
    }

    /// English/Portuguese phrase from the pack containing the hovered word ("good luck", "rely on").
    func packExpression(token: AnalyzedToken, tokens: [AnalyzedToken], text: String, language: String) -> ContextExpression? {
        guard let i = tokens.firstIndex(of: token) else { return nil }
        for n in stride(from: 3, through: 2, by: -1) {
            for start in max(0, i - n + 1)...i where start + n <= tokens.count {
                let slice = tokens[start..<start + n]
                for key in [slice.map(\.text).joined(separator: " "), slice.map(\.lemma).joined(separator: " ")] {
                    if let e = lexicon.entries(forGloss: key.lowercased(), language: language).first(where: { $0.pos == .phrase }) {
                        let source = String(text[slice.first!.range.lowerBound..<slice.last!.range.upperBound])
                        return ContextExpression(source: source, german: e.lemma, meaning: e.glossList(primaryHelper, limit: 2),
                                          entry: e, origin: .pack)
                    }
                }
            }
        }
        return nil
    }

    /// Translates the sentence with a two-word span highlighted ("gave up", "running late") and returns the
    /// German words it maps to, turned into something learnable (infinitive for verbs, particles merged).
    func spanExpression(token: AnalyzedToken, tokens: [AnalyzedToken], text: String, language: String,
                        preferNext: Bool) async -> ContextExpression? {
        guard let i = tokens.firstIndex(of: token) else { return nil }
        var spans: [Range<String.Index>] = []
        let blocked: [WordClass] = [.determiner, .pronoun, .conjunction, .number]
        if i + 1 < tokens.count, !blocked.contains(tokens[i + 1].wordClass) {
            spans.append(token.range.lowerBound..<tokens[i + 1].range.upperBound)
        }
        if !preferNext, i > 0, !blocked.contains(tokens[i - 1].wordClass) {
            spans.append(tokens[i - 1].range.lowerBound..<token.range.upperBound)
        }
        for span in spans {
            guard let at = try? await translator.translateAligned(text, highlight: span, from: language, to: target),
                  let ar = at.alignedRange else { continue }
            let germanTokens = TextTools.analyze(at.text, language: target)
            let spanTokens = germanTokens.filter { $0.range.overlaps(ar) }
            let content = spanTokens.filter { !Stopwords.de.contains(Lexicon.fold($0.text)) || Lexicon.fold($0.text) == "zu" }
            guard content.contains(where: { !Stopwords.de.contains(Lexicon.fold($0.text)) }) else { continue }

            // A main verb (not an auxiliary) becomes the infinitive, with separable particles merged.
            var verb: LexEntry?
            var verbForm: String?
            for t in content where t.wordClass == .verb || lexicon.bestEntry(forGerman: t.text, lemma: t.lemma)?.pos == .verb {
                guard var e = lexicon.bestEntry(forGerman: t.text, lemma: t.lemma), e.pos == .verb,
                      !Self.auxiliaries.contains(Lexicon.fold(e.lemma)) else { continue }
                e = separableVerb(base: e, token: t, tokens: germanTokens, text: at.text) ?? e
                verb = e
                verbForm = t.text
            }
            let source = String(text[span])
            if let verb {
                let preps = content.filter {
                    lexicon.bestEntry(forGerman: $0.text)?.pos == .preposition && !Lexicon.fold(verb.lemma).hasPrefix(Lexicon.fold($0.text))
                }.map(\.text)
                let german = preps.isEmpty ? verb.lemma : "\(verb.lemma) (\(preps.joined(separator: " ")))"
                return ContextExpression(source: source, german: german, meaning: source, entry: verb, origin: .alignment,
                                         targetForm: verbForm)
            }

            // Not a verb: an adjective/adverb phrase ("spät"). Keep a preceding "zu" ("zu spät") and, when the
            // hovered word was a verb, add the sentence's main verb so it reads as something you can say
            // ("zu spät kommen", "zu spät sein").
            guard var first = spanTokens.first(where: { !Stopwords.de.contains(Lexicon.fold($0.text)) }) ?? spanTokens.first else { continue }
            var phraseTokens = spanTokens.filter { $0.range.lowerBound >= first.range.lowerBound }
            let isNoun = first.isCapitalized && first.range.lowerBound != germanTokens.first?.range.lowerBound
                || lexicon.bestEntry(forGerman: first.text, capitalized: true)?.pos == .noun && first.isCapitalized
            // Keep the little word that makes the phrase: "zu spät", "am Ende", "im Moment".
            let leaders: Set<String> = isNoun ? ["am", "im", "zum", "zur", "beim", "vom", "ins", "ans"] : ["zu"]
            if let i = germanTokens.firstIndex(of: first), i > 0, leaders.contains(Lexicon.fold(germanTokens[i - 1].text)),
               !phraseTokens.contains(germanTokens[i - 1]) {
                first = germanTokens[i - 1]
                phraseTokens.insert(first, at: 0)
            }
            let joined = phraseTokens.map(\.text).joined(separator: " ")
            var german = isNoun ? joined : joined.prefix(1).lowercased() + joined.dropFirst()
            // Only adjective/adverb phrases get the sentence's verb ("zu spät kommen"); "am Ende" stands alone.
            if token.wordClass == .verb, !isNoun {
                // The verb of the same translated sentence, nearest to the phrase ("ich komme … zu spät" → kommen).
                let sentence = TextTools.sentence(in: at.text, containing: first.range)
                let sentenceRange = at.text.range(of: sentence) ?? at.text.startIndex..<at.text.endIndex
                let anchor = germanTokens.firstIndex(of: first) ?? 0
                let verbs = germanTokens.enumerated().compactMap { i, t -> (entry: LexEntry, distance: Int)? in
                    // Capitalised words mid-sentence are nouns ("zum Treffen"), never the verb we want.
                    guard sentenceRange.contains(t.range.lowerBound), !phraseTokens.contains(t), t.wordClass == .verb,
                          !t.isCapitalized || t.range.lowerBound == sentenceRange.lowerBound,
                          let e = lexicon.bestEntry(forGerman: t.text, lemma: t.lemma), e.pos == .verb else { return nil }
                    return (e, abs(i - anchor))
                }.sorted { $0.distance < $1.distance }
                if let main = verbs.first(where: { !Self.auxiliaries.contains(Lexicon.fold($0.entry.lemma)) }) ?? verbs.first {
                    german += " \(main.entry.lemma)"
                }
            }
            guard !german.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let form = String(at.text[first.range.lowerBound..<(phraseTokens.last?.range.upperBound ?? first.range.upperBound)])
            return ContextExpression(source: source, german: german, meaning: source, entry: nil, origin: .alignment, targetForm: form)
        }
        return nil
    }
}
