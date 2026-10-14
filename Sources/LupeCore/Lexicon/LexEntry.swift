import Foundation

/// Part of speech as written in a lexicon pack (`n`, `v`, `adj`, ...).
public enum PartOfSpeech: String, Codable, Sendable, CaseIterable {
    case noun = "n"
    case verb = "v"
    case adjective = "adj"
    case adverb = "adv"
    case preposition = "prep"
    case conjunction = "conj"
    case pronoun = "pron"
    case numeral = "num"
    case article = "art"
    case particle = "part"
    case interjection = "intj"
    case phrase = "phr"

    public var label: String {
        switch self {
        case .noun: "noun"
        case .verb: "verb"
        case .adjective: "adjective"
        case .adverb: "adverb"
        case .preposition: "preposition"
        case .conjunction: "conjunction"
        case .pronoun: "pronoun"
        case .numeral: "number"
        case .article: "article"
        case .particle: "particle"
        case .interjection: "interjection"
        case .phrase: "phrase"
        }
    }

    /// Content words are the ones worth sprinkling on screen.
    public var isContentWord: Bool {
        switch self {
        case .noun, .verb, .adjective, .adverb, .phrase: true
        default: false
        }
    }
}

/// Grammatical gender. `plural` marks plural-only nouns (die Leute, die Eltern).
public enum Gender: String, Codable, Sendable, CaseIterable {
    case masculine = "m"
    case feminine = "f"
    case neuter = "n"
    case plural = "pl"
}

/// One dictionary entry from a lexicon pack.
public struct LexEntry: Codable, Hashable, Sendable, Identifiable {
    /// Frequency rank inside the pack (1 = most frequent). Derived from file order.
    public var rank: Int
    public var lemma: String
    public var pos: PartOfSpeech
    public var gender: Gender?
    /// Nouns: plural ("Tische", "-" when none). Verbs: principal parts ("fährt · fuhr · ist gefahren").
    /// Adjectives: comparative/superlative when irregular.
    public var forms: String
    /// Glosses per helper language, primary sense first: ["en": ["table"], "pt": ["mesa"]].
    public var glosses: [String: [String]]
    /// CEFR level hint (A1, A2, B1, B2, C1).
    public var cefr: String
    /// "Tisch#n"; homographs get a suffix ("Bank#n#2").
    public var id: String

    public init(rank: Int, lemma: String, pos: PartOfSpeech, gender: Gender?, forms: String, glosses: [String: [String]],
                cefr: String, id: String? = nil) {
        self.id = id ?? "\(lemma)#\(pos.rawValue)"
        self.rank = rank
        self.lemma = lemma
        self.pos = pos
        self.gender = gender
        self.forms = forms
        self.glosses = glosses
        self.cefr = cefr
    }

    public func gloss(_ language: String) -> String? {
        glosses[language]?.first
    }

    public func glossList(_ language: String, limit: Int = 3) -> String {
        (glosses[language] ?? []).prefix(limit).joined(separator: ", ")
    }
}
