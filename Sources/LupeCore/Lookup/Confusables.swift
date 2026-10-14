import Foundation

/// A group of words learners mix up, with a "when to use it" note per word and language.
public struct ConfusableGroup: Sendable {
    /// Words as written in the pack: "schön", or "der See" to pin a gender.
    public var items: [String]
    /// language → item → note.
    public var notes: [String: [String: String]]

    /// Parses `confusables.txt`: `words | English notes | Portuguese notes`, notes as `word: text ; word: text`.
    public static func parse(_ text: String) -> [ConfusableGroup] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let cols = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2 else { return nil }
            let items = cols[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var notes: [String: [String: String]] = [:]
            for (lang, col) in zip(["en", "pt"], cols.dropFirst()) {
                var map: [String: String] = [:]
                for segment in col.components(separatedBy: " ; ") {
                    guard let colon = segment.range(of: ": ") else { continue }
                    let key = segment[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
                    map[key] = curlyQuotes(segment[colon.upperBound...].trimmingCharacters(in: .whitespaces))
                }
                notes[lang] = map
            }
            return items.count >= 2 ? ConfusableGroup(items: items, notes: notes) : nil
        }
    }

    /// The file uses plain "…" for easy editing; cards show “…”.
    public static func curlyQuotes(_ s: String) -> String {
        var open = true
        return String(s.map { c -> Character in
            guard c == "\"" else { return c }
            defer { open.toggle() }
            return open ? "\u{201C}" : "\u{201D}"
        })
    }
}

/// One line of the "Don't mix up" box.
public struct Confusable: Sendable, Hashable, Identifiable {
    public var id: String { display }
    /// "nett", "der See".
    public var display: String
    public var entry: LexEntry?
    /// When to use it ("nice as in kind, friendly — mostly people").
    public var note: String
    /// The word on the card itself (shown first, for contrast).
    public var isCurrent: Bool
    /// From the hand-written notes (true) or from shared meanings in the dictionary (false).
    public var curated: Bool
}

extension Lexicon {
    /// Resolves a pack item ("schön", "der See", "Kind") to an entry.
    func entry(forConfusable item: String) -> LexEntry? {
        let parts = item.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let gender = info.articles.first(where: { $0.value == parts[0] && $0.key != "pl" })?.key {
            return entries(forGerman: parts[1]).first { $0.pos == .noun && $0.gender?.rawValue == gender }
        }
        return bestEntry(forGerman: item, capitalized: item.first?.isUppercase == true)
    }

    /// A German word written like a word of another language: "das Kind" and "kind", "Gift" and "gift".
    public static func spelledLike(_ german: String, _ word: String) -> Bool {
        fold(german.split(separator: " ").last.map(String.init) ?? german) == fold(word)
    }

    /// Same word for the purposes of a group: lemma, part of speech and (for nouns) gender.
    static func sameWord(_ a: LexEntry, _ b: LexEntry) -> Bool {
        fold(a.lemma) == fold(b.lemma) && a.pos == b.pos && a.gender == b.gender
    }
}

extension LookupEngine {
    /// "Don't mix up" for an entry: hand-written groups first; otherwise other words that share a meaning.
    /// `sourceWord` is the English/Portuguese word that led here: a German look-alike of it ("kind" → das Kind) comes first.
    public func confusables(for entry: LexEntry, sourceWord: String? = nil, limit: Int = 4) -> [Confusable] {
        // Synthesized entries (compounds, translator words) have no reliable neighbours.
        guard entry.rank < 20_000, entry.pos.isContentWord || entry.pos == .conjunction || entry.pos == .preposition
                || entry.pos == .adverb || entry.pos == .pronoun, entry.pos != .phrase else { return [] }
        let language = primaryHelper
        var out: [Confusable] = []
        var seen = Set<String>()
        var groups = lexicon.confusableGroups
        if let source = sourceWord.map(Lexicon.fold) {
            let looksAlike = { (g: ConfusableGroup) in g.items.contains { Lexicon.spelledLike($0, source) } }
            groups = groups.filter(looksAlike) + groups.filter { !looksAlike($0) }
        }
        for group in groups {
            let resolved = group.items.map { ($0, lexicon.entry(forConfusable: $0)) }
            guard let mine = resolved.first(where: { $0.1.map { Lexicon.sameWord($0, entry) } ?? false }) else { continue }
            let notes = group.notes[language] ?? group.notes["en"] ?? [:]
            if seen.insert(mine.0).inserted {
                out.insert(Confusable(display: displayName(mine.0, mine.1), entry: mine.1, note: notes[mine.0] ?? "", isCurrent: true, curated: true), at: 0)
            }
            for (item, e) in resolved where item != mine.0 && seen.insert(item).inserted {
                out.append(Confusable(display: displayName(item, e), entry: e, note: notes[item] ?? e?.glossList(language, limit: 2) ?? "",
                                      isCurrent: false, curated: true))
            }
        }
        if !out.isEmpty {
            // Current word first, then up to `limit` others.
            let current = out.filter(\.isCurrent).prefix(1)
            return Array(current) + out.filter { !$0.isCurrent }.prefix(limit)
        }

        // Fallback: other words glossed the same way ("lernen" and "studieren" are both "to study").
        let keys = Set((entry.glosses[language] ?? []).flatMap { Lexicon.glossKeys($0, language: language, pos: entry.pos) })
        var candidates: [LexEntry] = []
        for key in keys { candidates += lexicon.entries(forGloss: key, language: language) }
        var lemmas = Set([Lexicon.fold(entry.lemma)])
        candidates = candidates
            .filter { $0.id != entry.id && $0.pos.isContentWord && $0.pos != .phrase && lemmas.insert(Lexicon.fold($0.lemma)).inserted }
            .sorted { ($0.pos == entry.pos ? 0 : 1, $0.rank) < ($1.pos == entry.pos ? 0 : 1, $1.rank) }
        return candidates.prefix(2).map { e in
            Confusable(display: lexicon.display(e), entry: e, note: e.glossList(language, limit: 3), isCurrent: false, curated: false)
        }
    }

    /// The hand-written "when to use it" note for an entry, if it's in a group.
    public func curatedNote(for entry: LexEntry, language: String) -> String? {
        for group in lexicon.confusableGroups {
            for item in group.items {
                guard let e = lexicon.entry(forConfusable: item), Lexicon.sameWord(e, entry) else { continue }
                if let note = (group.notes[language] ?? group.notes["en"])?[item] { return note }
            }
        }
        return nil
    }

    private func displayName(_ item: String, _ entry: LexEntry?) -> String {
        if let entry, entry.pos == .noun { return lexicon.display(entry) }
        return item
    }
}
