import Foundation

/// Everything the hover card needs to show for one word.
public struct LookupResult: Sendable, Identifiable {
    public enum Direction: Sendable { case toTarget, fromTarget }

    public var id = UUID()
    /// The word as it appeared on screen ("tables", "Tische").
    public var word: String
    /// The line or sentence around it.
    public var context: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var direction: Direction
    /// Lexicon entry for the target-language side, when known (may be a synthesized compound).
    public var entry: LexEntry?
    /// Target-language headword to learn: "der Tisch", "fahren", or a machine translation.
    public var headword: String
    /// Meaning in helper languages ("en": "table", "pt": "mesa").
    public var meanings: [String: String]
    /// The context translated (into the target language, or into the helper language when reading German).
    public var contextTranslation: String?
    /// The words in `contextTranslation` that correspond to the hovered word ("Bücher", "will call").
    public var aligned: String?
    public var alignedRange: Range<String.Index>?
    /// True when the sentence translation confirmed this sense. False means "probably a different word here".
    public var confirmedByContext: Bool = false
    /// For compounds: the part that decides gender ("Ufer" in "Flussufer").
    public var compoundHead: LexEntry?
    /// The expression the word belongs to in this sentence ("Daumen drücken", "running late → zu spät").
    public var expression: ContextExpression?
    /// German word on screen: the meaning the translator used in this sentence ("bench" for "Bank").
    public var senseHere: String?

    /// Key used for the word bank.
    public var cardKey: String { entry?.id ?? Card.key(for: headword) }
    /// Term stored on the card (lemma without article).
    public var term: String { entry?.lemma ?? headword }

    /// Whether this lookup is reliable enough to auto-save as a card.
    public var isConfident: Bool { confirmedByContext || expression != nil || contextTranslation == nil }
}

/// A German word inside a translated phrase, for the Ask bar's breakdown row.
public struct WordGloss: Sendable, Hashable, Identifiable {
    public var id: String { "\(surface)|\(entry?.id ?? "")" }
    public var surface: String
    public var entry: LexEntry?
    public var display: String
    public var meaning: String?
}

public struct PhraseResult: Sendable {
    public var input: String
    public var inputLanguage: String
    public var output: String
    public var outputLanguage: String
    /// Breakdown of the target-language side (the output when translating into German, else the input).
    public var breakdown: [WordGloss]
    /// Extra translation into the second helper language, when the input was German.
    public var secondaryOutput: String?
    public var secondaryLanguage: String?
}

/// Turns "the word under the mouse" into a learnable result: the sentence is translated with word
/// alignment, the aligned word is matched to the lexicon (gender, forms), and the lexicon fills in
/// when alignment fails.
public final class LookupEngine: @unchecked Sendable {
    public let lexicon: Lexicon
    public let translator: Translator
    public var target: String { lexicon.info.code }
    public var helpers: [String]
    public var primaryHelper: String

    public init(lexicon: Lexicon, translator: Translator, helpers: [String] = ["en", "pt"], primaryHelper: String = "en") {
        self.lexicon = lexicon
        self.translator = translator
        self.helpers = helpers
        self.primaryHelper = primaryHelper
    }

    public var languages: [String] { [target] + helpers }

    // MARK: Language

    /// Detects the language of a line, using the lexicon to settle short or ambiguous strings.
    public func language(of text: String, word: String? = nil) -> String {
        let candidates = languages
        if let (lang, confidence) = TextTools.detectLanguageWithConfidence(text, candidates: candidates),
           confidence > 0.55 || text.split(separator: " ").count >= 4 {
            return lang
        }
        if let word {
            let inTarget = !lexicon.entries(forGerman: word).isEmpty
            let inHelpers = helpers.filter { !lexicon.entries(forGloss: word, language: $0).isEmpty }
            if inTarget && inHelpers.isEmpty { return target }
            if !inTarget, let h = inHelpers.first { return h }
        }
        return TextTools.detectLanguage(text, candidates: candidates) ?? primaryHelper
    }

    // MARK: Word lookup

    public func lookup(word rawWord: String, context: String, wordRange: Range<String.Index>? = nil,
                       languageHint: String? = nil) async -> LookupResult {
        let word = TextTools.clean(rawWord)
        let rawContext = context
        let context = rawContext.trimmingCharacters(in: .whitespacesAndNewlines)
        // The caller's range indexes the raw string; keep it only if trimming changed nothing.
        let range = rawContext == context ? wordRange : nil
        let lang = languageHint ?? language(of: context.isEmpty ? word : context, word: word)
        if lang == target {
            return await lookupTarget(word: word, context: context, wordRange: range)
        }
        return await lookupHelper(word: word, context: context, wordRange: range, language: lang)
    }

    /// German word on screen → meaning in helper languages.
    private func lookupTarget(word: String, context: String, wordRange: Range<String.Index>?) async -> LookupResult {
        let text = context.isEmpty ? word : context
        let tokens = TextTools.analyze(text, language: target)
        let token = Self.token(for: word, range: wordRange, in: tokens)
        let sentenceInitial = token.map { $0.range.lowerBound == tokens.first?.range.lowerBound } ?? false
        let capitalized = (token?.isCapitalized ?? (word.first?.isUppercase ?? false)) && !sentenceInitial
        var entry = lexicon.bestEntry(forGerman: word, lemma: token?.lemma, capitalized: capitalized)
        if entry == nil && sentenceInitial {
            entry = lexicon.bestEntry(forGerman: word, lemma: token?.lemma, capitalized: true)
        }
        if let e = entry, e.pos == .verb, let token {
            entry = separableVerb(base: e, token: token, tokens: tokens, text: text) ?? e
        }
        var head: LexEntry?
        if entry == nil, word.first?.isUppercase == true, let c = lexicon.compound(word) {
            entry = c.entry
            head = c.head
        }

        // Idioms and verb patterns from the pack ("Ich drücke dir die Daumen" → "Daumen drücken").
        var expression: ContextExpression?
        if let token, let phrase = lexicon.expressions(in: tokens, around: token).first {
            expression = ContextExpression(source: phrase.lemma, german: phrase.lemma,
                                    meaning: phrase.glossList(primaryHelper, limit: 2), entry: phrase, origin: .pack)
        }

        // Sentence translation with the hovered word aligned ("rufe … an" → "will call").
        var translation: AlignedTranslation?
        if !context.isEmpty && context != word, let highlight = token?.range ?? text.range(of: word) {
            translation = try? await translator.translateAligned(text, highlight: highlight, from: target, to: primaryHelper)
        }

        // The sense used here picks the homograph and orders the meanings ("Bank" → bench, not bank).
        var senseHere: String?
        var senseIndex: Int?
        if let aligned = translation?.aligned, !aligned.isEmpty, let e = entry {
            senseHere = aligned
            let (best, index) = homograph(for: e, word: word, lemma: token?.lemma, aligned: aligned)
            entry = best
            senseIndex = index
        }

        var meanings: [String: String] = [:]
        if let entry, !(entry.glosses[primaryHelper] ?? []).isEmpty {
            meanings = self.meanings(for: entry, senseFirst: senseIndex)
        } else {
            // Not in the pack (or a compound): translate the lemma into every helper language.
            let source = entry?.lemma ?? token?.lemma ?? word
            for h in helpers {
                if let t = try? await translator.translate(source, from: target, to: h) { meanings[h] = Self.wordGloss(t) }
            }
            if entry != nil {
                entry?.glosses = meanings.mapValues { [$0] }
            } else if lexicon.info.capitalizeNouns, word.first?.isUppercase == true, !sentenceInitial || token?.wordClass == .noun,
                      let english = meanings["en"], let gender = await guessGender(of: source, english: english) {
                // A noun the pack doesn't know: "the thumb" → "der Daumen" gives us its article.
                entry = LexEntry(rank: 40_000, lemma: source, pos: .noun, gender: gender, forms: "",
                                 glosses: meanings.mapValues { [$0] }, cefr: "C1", id: "\(source)#n")
            }
        }
        let headword = entry.map { lexicon.display($0) } ?? (token?.lemma ?? word)
        return LookupResult(word: word, context: context, sourceLanguage: target, targetLanguage: primaryHelper,
                            direction: .fromTarget, entry: entry, headword: headword, meanings: meanings,
                            contextTranslation: translation?.text, aligned: translation?.aligned,
                            alignedRange: translation?.alignedRange, confirmedByContext: true, compoundHead: head,
                            expression: expression, senseHere: senseHere)
    }

    /// English/Portuguese word on screen → German headword, using alignment and the lexicon.
    private func lookupHelper(word: String, context: String, wordRange: Range<String.Index>?, language: String) async -> LookupResult {
        let text = context.isEmpty ? word : context
        let tokens = TextTools.analyze(text, language: language)
        let token = Self.token(for: word, range: wordRange, in: tokens)
        let candidates = candidateEntries(word: word, token: token, tokens: tokens, language: language)

        var translation: AlignedTranslation?
        if let highlight = token?.range ?? text.range(of: word) {
            translation = try? await translator.translateAligned(text, highlight: highlight, from: language, to: target)
        }
        let germanTokens = translation.map { TextTools.analyze($0.text, language: target) } ?? []

        var chosen: LexEntry?
        var head: LexEntry?
        var aligned = translation?.aligned
        var alignedRange = translation?.alignedRange
        var confirmed = false
        var expression: ContextExpression?
        if let token { expression = packExpression(token: token, tokens: tokens, text: text, language: language) }

        // 0. Phrasal verbs ("gave up", "look after"): align the verb together with its particle.
        if expression == nil, let token, token.wordClass == .verb, let i = tokens.firstIndex(of: token), i + 1 < tokens.count,
           Self.englishParticles.contains(tokens[i + 1].text.lowercased()), language == "en",
           let span = await spanExpression(token: token, tokens: tokens, text: text, language: language, preferNext: true) {
            expression = span
            if let e = span.entry { chosen = e; confirmed = true }
        }

        // 1. The aligned German words (best signal: it's what the translator actually used).
        let englishIsAuxiliary = ["have", "be", "will", "get", "go"].contains(token?.lemma.lowercased() ?? "")
        if chosen == nil, let ar = translation?.alignedRange {
            let span = germanTokens.filter { $0.range.overlaps(ar) }
            // "hat" in "hat … aufgehört" is just the tense auxiliary unless the English word was one too.
            let content = span.filter {
                !Stopwords.de.contains(Lexicon.fold($0.text))
                    && (englishIsAuxiliary || !Self.auxiliaries.contains(Lexicon.fold($0.lemma)))
            }
            for t in content {
                if let e = candidates.first(where: { Self.matches($0, token: t, lexicon: lexicon) }) {
                    chosen = e; confirmed = true; break
                }
            }
            if chosen == nil {
                for t in content {
                    let capitalized = t.isCapitalized && t.range.lowerBound != germanTokens.first?.range.lowerBound
                    if var e = lexicon.bestEntry(forGerman: t.text, lemma: t.lemma, capitalized: capitalized), e.pos != .article {
                        if e.pos == .verb { e = separableVerb(base: e, token: t, tokens: germanTokens, text: translation!.text) ?? e }
                        chosen = e; confirmed = true; break
                    }
                    if t.isCapitalized, let c = lexicon.compound(t.text) {
                        chosen = c.entry; head = c.head; confirmed = true; break
                    }
                }
            }
            if chosen == nil, let t = content.first {
                // Aligned to a word the pack doesn't know: learn the translator's word.
                var e = LexEntry(rank: 50_000, lemma: t.lemma, pos: Self.pos(for: t.wordClass), gender: nil, forms: "",
                                 glosses: [:], cefr: "B2", id: "\(t.lemma)#mt")
                if e.pos == .noun { e.lemma = t.lemma.prefix(1).uppercased() + t.lemma.dropFirst() }
                chosen = e; confirmed = true
            }
            if content.isEmpty { aligned = nil; alignedRange = nil }
        }

        // 2. A candidate sense that appears somewhere in the translation (also inside compounds).
        if chosen == nil, !germanTokens.isEmpty, let (e, form) = Self.firstConfirmed(candidates, in: germanTokens, lexicon: lexicon) {
            chosen = e; confirmed = true
            aligned = form
            alignedRange = translation?.text.range(of: form)
        }

        // 3. Still nothing: the word may be part of an expression ("running late" → "zu spät").
        if chosen == nil, expression == nil, translation != nil, let token,
           let span = await spanExpression(token: token, tokens: tokens, text: text, language: language, preferNext: false) {
            expression = span
            if let e = span.entry { chosen = e; confirmed = true }
        }

        // 4. Nothing confirmed: fall back to the lexicon's first sense (flagged as unconfirmed).
        if chosen == nil, let first = candidates.first {
            chosen = first
            confirmed = translation == nil
        }

        var meanings: [String: String] = [:]
        var headword: String
        if var e = chosen {
            if (e.glosses[primaryHelper] ?? []).isEmpty {
                // Synthesized entry (compound or translator word): describe it with the source word.
                for h in helpers where h != language {
                    if let t = try? await translator.translate(e.lemma, from: target, to: h) { e.glosses[h] = [Self.wordGloss(t)] }
                }
                e.glosses[language] = [token?.lemma ?? word]
                chosen = e
            }
            headword = lexicon.display(e)
            for h in helpers { if let g = e.glossList(h, limit: 3).nilIfEmpty { meanings[h] = g } }
        } else {
            // No candidates and no alignment: translate the word alone ("the X" gives English nouns an article).
            let source = token?.lemma ?? word
            let query = language == "en" && token?.wordClass == .noun ? "the \(source)" : source
            let mt = TextTools.clean((try? await translator.translate(query, from: language, to: target)) ?? source)
            headword = mt
            let lastWord = mt.split(separator: " ").last.map(String.init) ?? mt
            if let e = lexicon.bestEntry(forGerman: lastWord, capitalized: lastWord.first?.isUppercase ?? false) {
                chosen = e
                headword = lexicon.display(e)
                for h in helpers { if let g = e.glossList(h, limit: 3).nilIfEmpty { meanings[h] = g } }
            } else if let first = mt.split(separator: " ").first, ["Der", "Die", "Das"].contains(first) {
                headword = first.lowercased() + mt.dropFirst(first.count)
            }
            confirmed = translation == nil
        }
        meanings[language] = meanings[language] ?? (token?.lemma ?? word)

        // Highlight what the expression became in the translation ("aufgehört", "zu spät") instead of an auxiliary.
        if let form = expression?.targetForm, let t = translation?.text, let r = t.range(of: form) {
            aligned = form
            alignedRange = r
        }

        // An expression found by alignment that is just the chosen verb adds nothing.
        if let ex = expression, ex.origin == .alignment, let e = ex.entry, e.id == chosen?.id, ex.german == e.lemma,
           ex.source.split(separator: " ").count < 2 {
            expression = nil
        }

        return LookupResult(word: word, context: context, sourceLanguage: language, targetLanguage: target,
                            direction: .toTarget, entry: chosen, headword: headword, meanings: meanings,
                            contextTranslation: translation?.text, aligned: aligned, alignedRange: alignedRange,
                            confirmedByContext: confirmed, compoundHead: head, expression: expression)
    }

    /// Gender of a German noun outside the pack, by translating "the <English meaning>" back into German.
    func guessGender(of noun: String, english: String) async -> Gender? {
        let gloss = english.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? english
        guard !gloss.isEmpty, gloss.split(separator: " ").count <= 3,
              let back = try? await translator.translate("the \(gloss)", from: "en", to: target) else { return nil }
        let words = back.split(separator: " ").map { Lexicon.fold(String($0)) }
        guard words.count >= 2, words.last == Lexicon.fold(noun) || Lexicon.fold(noun).hasPrefix(words.last ?? "#") else { return nil }
        switch words.first {
        case "der": return .masculine
        case "die": return gloss.hasSuffix("s") && !gloss.hasSuffix("ss") ? .plural : .feminine
        case "das": return .neuter
        default: return nil
        }
    }

    /// Machine translations of single words come back capitalised ("Porta da frente"); glosses read better lowercased.
    static func wordGloss(_ t: String) -> String {
        let trimmed = TextTools.clean(t)
        guard let first = trimmed.first, first.isUppercase else { return trimmed }
        // Keep names ("Berlin"), lowercase ordinary words ("Polegar" → "polegar").
        if TextTools.isName(trimmed) { return trimmed }
        return first.lowercased() + trimmed.dropFirst()
    }

    /// Fills in meanings for breakdown words the pack doesn't know, using the translator.
    public func fillMeanings(_ items: [WordGloss]) async -> [WordGloss] {
        var out = items
        for i in out.indices where out[i].meaning == nil {
            let source = out[i].entry?.lemma ?? out[i].display
            if let t = try? await translator.translate(source, from: target, to: primaryHelper) {
                let g = Self.wordGloss(t)
                // Proper nouns translate to themselves; leave those without a meaning.
                if g.lowercased() != source.lowercased() { out[i].meaning = g }
            }
        }
        return out
    }

    static func pos(for wc: WordClass) -> PartOfSpeech {
        switch wc {
        case .noun: .noun
        case .verb: .verb
        case .adjective: .adjective
        case .adverb: .adverb
        case .pronoun: .pronoun
        case .preposition: .preposition
        case .conjunction: .conjunction
        case .number: .numeral
        case .determiner: .article
        case .other: .phrase
        }
    }

    // MARK: Candidates

    /// Lexicon entries whose gloss matches the word, trying multi-word glosses ("look for") first.
    public func candidateEntries(word: String, token: AnalyzedToken?, tokens: [AnalyzedToken], language: String) -> [LexEntry] {
        var out: [LexEntry] = []
        if let token, let i = tokens.firstIndex(of: token) {
            let maxN = min(lexicon.maxGlossWords[language] ?? 1, 3)
            if maxN >= 2 {
                for n in stride(from: maxN, through: 2, by: -1) {
                    for start in max(0, i - n + 1)...i where start + n <= tokens.count {
                        let slice = tokens[start..<start + n]
                        let surface = slice.map(\.text).joined(separator: " ")
                        let lemmaPhrase = slice.map(\.lemma).joined(separator: " ")
                        out += lexicon.entries(forGloss: surface, language: language)
                        out += lexicon.entries(forGloss: lemmaPhrase, language: language)
                    }
                    if !out.isEmpty { break }
                }
            }
        }
        if let lemma = token?.lemma { out += lexicon.entries(forGloss: lemma, language: language) }
        out += lexicon.entries(forGloss: word, language: language)
        out += lexicon.entries(forGloss: word.lowercased(), language: language)
        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }
        // Prefer entries whose part of speech matches the tagger's guess.
        if let wc = token?.wordClass {
            let matching = out.filter { wc.matches($0.pos) }
            if !matching.isEmpty { out = matching + out.filter { !wc.matches($0.pos) } }
        }
        return out
    }

    /// Whether a German token is an inflected form of `e` (or a compound ending in it).
    static func matches(_ e: LexEntry, token t: AnalyzedToken, lexicon: Lexicon) -> Bool {
        let lemma = Lexicon.fold(e.lemma)
        let tl = Lexicon.fold(t.lemma)
        let tw = Lexicon.fold(t.text)
        if tl == lemma || tw == lemma { return true }
        if lexicon.entries(forGerman: t.text).contains(where: { $0.id == e.id }) { return true }
        if e.pos == .noun, tw.count >= lemma.count + 3, tw.hasSuffix(lemma) || tl.hasSuffix(lemma) { return true }
        return false
    }

    /// The first candidate whose lemma appears (inflected, or as a compound head) in the German translation.
    static func firstConfirmed(_ candidates: [LexEntry], in germanTokens: [AnalyzedToken], lexicon: Lexicon) -> (LexEntry, String)? {
        let prefixes = lexicon.info.separablePrefixes
        for e in candidates {
            let lemma = Lexicon.fold(e.lemma)
            for t in germanTokens {
                if matches(e, token: t, lexicon: lexicon) { return (e, t.text) }
                // Separable verbs: "ankommen" shows up as "kommen ... an".
                if e.pos == .verb, let p = prefixes.first(where: { lemma.hasPrefix($0) && lemma.count > $0.count + 2 }) {
                    let base = String(lemma.dropFirst(p.count))
                    if Lexicon.fold(t.lemma) == base, germanTokens.contains(where: { Lexicon.fold($0.text) == p }) { return (e, t.text) }
                }
            }
        }
        return nil
    }

    /// "rufe ... an" → "anrufen" when the pack has it. The particle must close the clause
    /// ("Ich rufe dich morgen an."), so "Ich komme mit dem Bus" stays "kommen".
    func separableVerb(base: LexEntry, token: AnalyzedToken, tokens: [AnalyzedToken], text: String) -> LexEntry? {
        guard let i = tokens.firstIndex(of: token), i + 1 < tokens.count else { return nil }
        for t in tokens[(i + 1)...] {
            let p = Lexicon.fold(t.text)
            guard lexicon.info.separablePrefixes.contains(p) else { continue }
            let rest = text[t.range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || ".,;:!?)\"»“”".contains(rest.first!) else { continue }
            if let e = lexicon.entries(forGerman: p + Lexicon.fold(base.lemma)).first(where: { $0.pos == .verb }) {
                return e
            }
        }
        return nil
    }

    static func token(for word: String, range: Range<String.Index>?, in tokens: [AnalyzedToken]) -> AnalyzedToken? {
        if let range, let t = tokens.first(where: { $0.range.overlaps(range) }) { return t }
        let w = Lexicon.fold(word)
        return tokens.first { Lexicon.fold($0.text) == w }
    }

    // MARK: Phrase translation (Ask bar, selection)

    public func translatePhrase(_ input: String, forceLanguage: String? = nil) async throws -> PhraseResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranslatorError.empty }
        let lang = forceLanguage ?? language(of: text, word: text.split(separator: " ").count == 1 ? text : nil)
        if lang == target {
            async let main = translator.translate(text, from: target, to: primaryHelper)
            let second = helpers.first { $0 != primaryHelper }
            var secondary: String?
            if let second { secondary = try? await translator.translate(text, from: target, to: second) }
            return PhraseResult(input: text, inputLanguage: target, output: try await main, outputLanguage: primaryHelper,
                                breakdown: breakdown(of: text), secondaryOutput: secondary, secondaryLanguage: second)
        }
        let out = try await translator.translate(text, from: lang, to: target)
        return PhraseResult(input: text, inputLanguage: lang, output: out, outputLanguage: target,
                            breakdown: breakdown(of: out), secondaryOutput: nil, secondaryLanguage: nil)
    }

    /// Content words of a German text with their lexicon entries.
    public func breakdown(of germanText: String) -> [WordGloss] {
        let tokens = TextTools.analyze(germanText, language: target)
        var seen = Set<String>()
        var out: [WordGloss] = []
        // Expressions first ("um … kümmern" → sich kümmern um); their words aren't listed again.
        var covered = Set<Int>()
        for (i, t) in tokens.enumerated() where !covered.contains(i) {
            guard let phrase = lexicon.expressions(in: tokens, around: t).first, seen.insert(phrase.id).inserted else { continue }
            let pattern = Set(lexicon.phrasePatterns.first { $0.entry.id == phrase.id }?.pattern ?? [])
            for (j, u) in tokens.enumerated() where pattern.contains(Lexicon.phraseKey(u)) || pattern.contains(Lexicon.fold(u.text)) {
                covered.insert(j)
            }
            out.append(WordGloss(surface: phrase.lemma, entry: phrase, display: phrase.lemma, meaning: phrase.gloss(primaryHelper)))
        }
        for (i, t) in tokens.enumerated() {
            let folded = Lexicon.fold(t.text)
            if covered.contains(i) || Stopwords.de.contains(folded) || folded.count < 2 { continue }
            let capitalized = t.isCapitalized && i > 0
            var entry = lexicon.bestEntry(forGerman: t.text, lemma: t.lemma, capitalized: capitalized || (i == 0 && t.isCapitalized && t.wordClass == .noun))
            if let e = entry, e.pos == .verb { entry = separableVerb(base: e, token: t, tokens: tokens, text: germanText) ?? e }
            if entry == nil, t.isCapitalized, i > 0, let c = lexicon.compound(t.text) { entry = c.entry }
            if let e = entry, [.article, .pronoun, .conjunction].contains(e.pos) { continue }
            let key = entry?.id ?? folded
            if !seen.insert(key).inserted { continue }
            out.append(WordGloss(surface: t.text, entry: entry,
                                 display: entry.map { lexicon.display($0) } ?? (Lexicon.restoringUmlauts(t.lemma) ?? t.lemma),
                                 meaning: entry?.gloss(primaryHelper)))
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
