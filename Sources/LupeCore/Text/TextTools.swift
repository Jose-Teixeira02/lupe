import Foundation
import NaturalLanguage

/// A word inside a line of text, with its lemma and coarse word class.
public struct AnalyzedToken: Hashable, Sendable {
    public var text: String
    public var range: Range<String.Index>
    public var lemma: String
    public var wordClass: WordClass

    public var isCapitalized: Bool { text.first?.isUppercase ?? false }
}

/// Coarse word class from NaturalLanguage, mapped onto lexicon parts of speech.
public enum WordClass: String, Sendable {
    case noun, verb, adjective, adverb, pronoun, determiner, preposition, conjunction, number, other

    init(_ tag: NLTag?) {
        switch tag {
        case .noun?, .personalName?, .placeName?, .organizationName?: self = .noun
        case .verb?: self = .verb
        case .adjective?: self = .adjective
        case .adverb?: self = .adverb
        case .pronoun?: self = .pronoun
        case .determiner?: self = .determiner
        case .preposition?, .particle?: self = .preposition
        case .conjunction?: self = .conjunction
        case .number?: self = .number
        default: self = .other
        }
    }

    public func matches(_ pos: PartOfSpeech) -> Bool {
        switch (self, pos) {
        case (.noun, .noun), (.verb, .verb), (.adjective, .adjective), (.adverb, .adverb),
             (.pronoun, .pronoun), (.preposition, .preposition), (.conjunction, .conjunction),
             (.number, .numeral), (.determiner, .article):
            return true
        // Taggers often confuse adjectives and adverbs, and German uses one form for both.
        case (.adjective, .adverb), (.adverb, .adjective):
            return true
        default:
            return false
        }
    }
}

public enum TextTools {
    /// Identifies the language of `text`, restricted to `candidates` (ISO codes like "en", "pt", "de").
    public static func detectLanguage(_ text: String, candidates: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        let hyps = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hyps.max(by: { $0.value < $1.value }) else { return nil }
        // Very short strings are unreliable; still return the best guess but callers can check confidence.
        return best.key.rawValue
    }

    /// Language plus confidence (0...1).
    public static func detectLanguageWithConfidence(_ text: String, candidates: [String]) -> (String, Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        let hyps = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hyps.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key.rawValue, best.value)
    }

    /// Word tokens of `text` with lemma and word class. Uses `language` when given.
    public static func analyze(_ text: String, language: String?) -> [AnalyzedToken] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text
        if let language {
            tagger.setLanguage(NLLanguage(rawValue: language), range: text.startIndex..<text.endIndex)
        }
        var out: [AnalyzedToken] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            let word = String(text[range])
            let lemmaTag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            let lemma = lemmaTag?.rawValue ?? word
            out.append(AnalyzedToken(text: word, range: range, lemma: lemma.isEmpty ? word : lemma, wordClass: WordClass(tag)))
            return true
        }
        return out
    }

    /// Plain word ranges (no tagging), cheap.
    public static func wordRanges(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    /// The word whose range contains `offset` (a character offset into `text`), if any.
    public static func word(in text: String, atCharacterOffset offset: Int) -> Range<String.Index>? {
        guard offset >= 0, offset <= text.count else { return nil }
        let target = text.index(text.startIndex, offsetBy: min(offset, max(0, text.count - 1)))
        return wordRanges(in: text).first { $0.contains(target) || $0.lowerBound == target }
    }

    /// Strips leading/trailing punctuation and quotes.
    public static func clean(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols))
    }

    /// The sentence that contains `range` within `text` (falls back to the whole text).
    public static func sentence(in text: String, containing range: Range<String.Index>) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        for s in tokenizer.tokens(for: text.startIndex..<text.endIndex) where s.overlaps(range) || s.contains(range.lowerBound) {
            return String(text[s]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isMostlyLetters(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return s.count > 0 && Double(letters) / Double(s.count) > 0.6
    }
}

/// Very common function words that are never worth a sprinkle label.
public enum Stopwords {
    public static let en: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "of", "to", "in", "on", "at", "by", "for", "with",
        "from", "as", "is", "are", "was", "were", "be", "been", "being", "am", "it", "its", "this", "that", "these",
        "those", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "our",
        "their", "not", "no", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "may", "might", "must", "there", "here", "what", "which", "who", "whom", "whose", "when", "where", "why",
        "how", "all", "any", "some", "into", "about", "up", "out", "over", "just", "than", "too", "very", "also",
        "s", "t", "re", "ll", "ve", "d", "m", "don", "isn", "aren", "won", "etc", "via", "per", "vs",
    ]
    public static let pt: Set<String> = [
        "a", "o", "as", "os", "um", "uma", "uns", "umas", "e", "ou", "mas", "se", "de", "do", "da", "dos", "das",
        "em", "no", "na", "nos", "nas", "por", "pelo", "pela", "para", "com", "sem", "que", "é", "são", "foi", "ser",
        "estar", "está", "eu", "tu", "ele", "ela", "nós", "eles", "elas", "me", "te", "lhe", "seu", "sua", "meu",
        "minha", "não", "sim", "já", "ao", "aos", "à", "às", "isto", "isso", "este", "esta", "esse", "essa", "há",
        "também", "muito", "mais", "como", "quando", "onde", "porque",
    ]
    public static let de: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "und", "oder",
        "aber", "zu", "in", "im", "an", "am", "auf", "mit", "von", "vom", "für", "ist", "sind", "war", "es", "ich",
        "du", "er", "sie", "wir", "ihr", "nicht", "zum", "zur", "bei", "aus", "so", "wie", "auch", "noch", "nur",
    ]

    public static func set(for language: String) -> Set<String> {
        switch language {
        case "en": en
        case "pt": pt
        case "de": de
        default: []
        }
    }
}
