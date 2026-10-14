import Foundation

/// Where a card came from. Shown in reviews ("you looked this up in Safari").
public enum CardSource: String, Codable, Sendable {
    case hover, ask, sprinkle, lens, selection, manual, starter
}

/// A moment where you met a word: the sentence, its translation, and the app.
public struct Encounter: Codable, Hashable, Sendable {
    public var sentence: String
    public var translation: String?
    /// Language of `sentence` ("en", "pt", "de").
    public var language: String
    public var app: String?
    public var date: Date
    /// The word as it appears in the target-language sentence (for cloze reviews): "Bücher".
    public var targetForm: String?

    public init(sentence: String, translation: String?, language: String, app: String?, date: Date = Date(), targetForm: String? = nil) {
        self.sentence = sentence
        self.translation = translation
        self.language = language
        self.app = app
        self.date = date
        self.targetForm = targetForm
    }

    /// The sentence in the target language (the original when you were reading German, else the translation).
    public func targetSentence(target: String) -> String? {
        language == target ? sentence : translation
    }

    /// The sentence in the learner's language.
    public func helperSentence(target: String) -> String? {
        language == target ? translation : sentence
    }
}

public struct Card: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case word, phrase }
    public enum Status: String, Codable, Sendable { case active, known, suspended }

    public var id: UUID
    public var kind: Kind
    /// Target-language term: lemma for words ("Tisch"), full text for phrases.
    public var term: String
    /// Lexicon entry id when the word is in the pack ("Tisch#n").
    public var entryID: String?
    /// "der Tisch" for nouns, otherwise the term.
    public var display: String
    public var gender: Gender?
    public var pos: PartOfSpeech?
    public var forms: String
    /// Meaning per helper language: ["en": "table", "pt": "mesa"].
    public var meanings: [String: String]
    public var encounters: [Encounter]
    public var memory: MemoryState
    public var status: Status
    public var source: CardSource
    public var createdAt: Date
    public var notes: String?

    public init(id: UUID = UUID(), kind: Kind, term: String, entryID: String?, display: String, gender: Gender?,
                pos: PartOfSpeech?, forms: String, meanings: [String: String], encounters: [Encounter],
                source: CardSource, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.term = term
        self.entryID = entryID
        self.display = display
        self.gender = gender
        self.pos = pos
        self.forms = forms
        self.meanings = meanings
        self.encounters = encounters
        self.memory = MemoryState(due: createdAt)
        self.status = .active
        self.source = source
        self.createdAt = createdAt
    }

    public func meaning(_ preferred: String) -> String {
        meanings[preferred] ?? meanings.values.first ?? ""
    }

    public var latestEncounter: Encounter? { encounters.max { $0.date < $1.date } }

    /// Normalized key used to de-duplicate cards.
    public var key: String { entryID ?? Card.key(for: term) }

    public static func key(for term: String) -> String {
        term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
