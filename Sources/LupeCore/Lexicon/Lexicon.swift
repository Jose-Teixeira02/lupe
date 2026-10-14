import Foundation

/// Metadata stored next to a lexicon in `packs/<code>/pack.json`.
public struct PackInfo: Codable, Sendable, Hashable {
    public var code: String
    public var name: String
    public var nativeName: String
    public var flag: String
    /// Article per gender code, e.g. ["m": "der", "f": "die", "n": "das", "pl": "die"].
    public var articles: [String: String]
    /// Nouns are capitalised in running text (German).
    public var capitalizeNouns: Bool
    /// BCP-47 voice language for speech, e.g. "de-DE".
    public var speechLanguage: String
    /// Prefixes of separable verbs (an, auf, aus, ...) used to match "kommt ... an" to "ankommen".
    public var separablePrefixes: [String]

    public init(code: String, name: String, nativeName: String, flag: String, articles: [String: String],
                capitalizeNouns: Bool, speechLanguage: String, separablePrefixes: [String] = []) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
        self.flag = flag
        self.articles = articles
        self.capitalizeNouns = capitalizeNouns
        self.speechLanguage = speechLanguage
        self.separablePrefixes = separablePrefixes
    }
}

public enum LexiconError: Error, CustomStringConvertible {
    case packNotFound(String)
    case badLine(file: String, line: Int, reason: String)

    public var description: String {
        switch self {
        case .packNotFound(let code): "No lexicon pack found for '\(code)'"
        case .badLine(let file, let line, let reason): "\(file):\(line): \(reason)"
        }
    }
}

/// An in-memory dictionary for one target language with forward (German → entry)
/// and reverse (English/Portuguese gloss → entry) indexes.
public final class Lexicon: @unchecked Sendable {
    public let info: PackInfo
    public let entries: [LexEntry]

    private var forward: [String: [Int]] = [:]
    private var byForm: [String: [Int]] = [:]
    private var reverse: [String: [String: [Int]]] = [:]
    /// Longest gloss (in words) per helper language, so lookups know how many n-grams to try.
    public private(set) var maxGlossWords: [String: Int] = [:]

    public init(info: PackInfo, entries: [LexEntry]) {
        self.info = info
        self.entries = entries
        buildIndexes()
    }

    // MARK: Loading

    /// Loads `pack.json` and every `*.tsv` file (sorted by name) from a pack directory.
    /// Rank is the global line order, so files are written from most to least frequent.
    public static func load(from directory: URL) throws -> Lexicon {
        let infoURL = directory.appendingPathComponent("pack.json")
        let info = try JSONDecoder().decode(PackInfo.self, from: Data(contentsOf: infoURL))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tsv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [LexEntry] = []
        var seen = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard var entry = try parse(line: rawLine, file: file.lastPathComponent, lineNumber: offset + 1) else { continue }
                // Homographs (die Bank "bank" / die Bank "bench") get numbered ids.
                var n = 2
                let base = entry.id
                while seen.contains(entry.id) {
                    entry.id = "\(base)#\(n)"
                    n += 1
                }
                seen.insert(entry.id)
                entry.rank = entries.count + 1
                entries.append(entry)
            }
        }
        return Lexicon(info: info, entries: entries)
    }

    /// Columns: lemma, pos, gender, forms, en, pt, cefr — separated by tabs or `|`.
    /// Multiple glosses are separated by `;`.
    static func parse(line: String, file: String, lineNumber: Int) throws -> LexEntry? {
        let cols = line.contains("\t") ? line.components(separatedBy: "\t") : line.components(separatedBy: "|")
        guard cols.count >= 7 else {
            throw LexiconError.badLine(file: file, line: lineNumber, reason: "expected 7 columns, got \(cols.count)")
        }
        let lemma = cols[0].trimmingCharacters(in: .whitespaces)
        guard let pos = PartOfSpeech(rawValue: cols[1].trimmingCharacters(in: .whitespaces)) else {
            throw LexiconError.badLine(file: file, line: lineNumber, reason: "unknown pos '\(cols[1])'")
        }
        let genderRaw = cols[2].trimmingCharacters(in: .whitespaces)
        let gender = genderRaw.isEmpty || genderRaw == "-" ? nil : Gender(rawValue: genderRaw)
        if pos == .noun && gender == nil && genderRaw != "-" {
            throw LexiconError.badLine(file: file, line: lineNumber, reason: "noun '\(lemma)' without gender")
        }
        func split(_ s: String) -> [String] {
            s.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let forms = cols[3].trimmingCharacters(in: .whitespaces)
        return LexEntry(rank: 0, lemma: lemma, pos: pos, gender: gender,
                        forms: forms == "-" ? "" : forms,
                        glosses: ["en": split(cols[4]), "pt": split(cols[5])],
                        cefr: cols[6].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Indexes

    private func buildIndexes() {
        let noise = Set(info.separablePrefixes).union(["ist", "hat", "sich", "(sich)", "am", "zu", "es", "-"])
        for (i, e) in entries.enumerated() {
            forward[Self.fold(e.lemma), default: []].append(i)
            for form in Self.inflectedForms(of: e, noise: noise) {
                byForm[Self.fold(form), default: []].append(i)
            }
            for (lang, glosses) in e.glosses {
                for g in glosses {
                    for key in Self.glossKeys(g, language: lang, pos: e.pos) {
                        reverse[lang, default: [:]][key, default: []].append(i)
                        let n = key.split(separator: " ").count
                        maxGlossWords[lang] = max(maxGlossWords[lang] ?? 1, n)
                    }
                }
            }
        }
    }

    /// Lowercase, without surrounding punctuation. Keeps umlauts/ß (they matter in German).
    public static func fold(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    /// Word forms listed in the `forms` column that should map back to the lemma.
    static func inflectedForms(of e: LexEntry, noise: Set<String> = ["ist", "hat", "sich", "am", "zu"]) -> [String] {
        guard !e.forms.isEmpty else { return [] }
        let parts = e.forms
            .replacingOccurrences(of: "·", with: ",")
            .components(separatedBy: CharacterSet(charactersIn: ",;/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for p in parts where !p.isEmpty && p != "-" {
            // "ist gefahren" → "gefahren"; "kommt an" → "kommt"; "am besten" → "besten".
            let words = p.split(separator: " ").map(String.init).filter { !noise.contains($0.lowercased()) }
            out.append(contentsOf: words)
        }
        return out
    }

    /// Reverse-index keys for a gloss: "to look for (sth)" → ["look for"]; "lembrar-se" → ["lembrar-se", "lembrar"].
    public static func glossKeys(_ gloss: String, language: String, pos: PartOfSpeech) -> [String] {
        var g = gloss.lowercased()
        // Drop parenthetical notes: "bank (money)" → "bank".
        while let open = g.firstIndex(of: "("), let close = g[open...].firstIndex(of: ")") {
            g.removeSubrange(open...close)
        }
        let placeholders: Set<String> = ["sth", "sth.", "sb", "sb.", "something", "someone", "algo", "alguém"]
        g = g.split(separator: " ").map(String.init).filter { !placeholders.contains($0) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !g.isEmpty else { return [] }
        var keys = [g]
        if language == "en" {
            if g.hasPrefix("to ") { keys = [String(g.dropFirst(3))] }
            for article in ["the ", "a ", "an "] where g.hasPrefix(article) {
                keys.append(String(g.dropFirst(article.count)))
            }
        }
        if language == "pt" {
            if g.hasSuffix("-se") { keys.append(String(g.dropLast(3))) }
            for article in ["o ", "a ", "os ", "as "] where g.hasPrefix(article) {
                keys.append(String(g.dropFirst(article.count)))
            }
        }
        return keys
    }

    // MARK: Queries

    /// Entries whose lemma or listed inflected form equals `word` (case-insensitive).
    public func entries(forGerman word: String) -> [LexEntry] {
        let key = Self.fold(word)
        var idx = forward[key] ?? []
        if idx.isEmpty { idx = byForm[key] ?? [] }
        return idx.map { entries[$0] }.sorted { $0.rank < $1.rank }
    }

    /// Best entry for a German token, preferring nouns when capitalised mid-sentence.
    public func bestEntry(forGerman word: String, lemma: String? = nil, capitalized: Bool = false) -> LexEntry? {
        var candidates = entries(forGerman: word)
        if candidates.isEmpty, let lemma { candidates = entries(forGerman: lemma) }
        // Lowercase words are never nouns in German: "rufe" is a form of rufen, not der Ruf.
        if info.capitalizeNouns, !capitalized, word.first?.isLowercase == true,
           candidates.allSatisfy({ $0.pos == .noun }), let verb = guessVerb(word) {
            return verb
        }
        if candidates.isEmpty { return nil }
        if info.capitalizeNouns {
            if capitalized, let noun = candidates.first(where: { $0.pos == .noun }) { return noun }
            if !capitalized, let other = candidates.first(where: { $0.pos != .noun }) { return other }
        }
        return candidates.first
    }

    /// Regular verb forms not listed in the pack: "rufe", "spielst", "macht", "wartet" → the infinitive.
    func guessVerb(_ word: String) -> LexEntry? {
        let w = Self.fold(word)
        for suffix in ["est", "et", "st", "en", "e", "t", "n", ""] where w.hasSuffix(suffix) && w.count > suffix.count + 1 {
            let stem = String(w.dropLast(suffix.count))
            for candidate in [stem + "en", stem + "n"] {
                if let v = (forward[candidate] ?? []).map({ entries[$0] }).first(where: { $0.pos == .verb }) { return v }
            }
        }
        return nil
    }

    /// Entries whose gloss in `language` equals `text` (already lemmatised by the caller if needed).
    public func entries(forGloss text: String, language: String) -> [LexEntry] {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let idx = reverse[language]?[key] ?? []
        return idx.map { entries[$0] }.sorted { $0.rank < $1.rank }
    }

    /// German compound nouns take the gender of their last part: "Flussufer" → das (Ufer),
    /// "Hausaufgaben" → die Hausaufgabe (Aufgabe). Returns a synthesized entry without glosses.
    public func compound(_ word: String) -> (entry: LexEntry, head: LexEntry, prefix: String)? {
        guard info.capitalizeNouns else { return nil }
        let w = Self.fold(word)
        let chars = Array(w)
        guard chars.count >= 6 else { return nil }
        for start in 3...(chars.count - 3) {
            let suffix = String(chars[start...])
            var head = (forward[suffix] ?? []).map { entries[$0] }.first { $0.pos == .noun }
            if head == nil {
                head = (byForm[suffix] ?? []).map { entries[$0] }.first { $0.pos == .noun }
            }
            guard let head else { continue }
            let prefixRaw = String(chars[..<start])
            let prefix = prefixRaw.prefix(1).uppercased() + prefixRaw.dropFirst()
            let lemma = prefix + head.lemma.lowercased()
            let plural = head.forms.isEmpty ? "" : prefix + head.forms.lowercased()
            let entry = LexEntry(rank: head.rank + 20_000, lemma: lemma, pos: .noun, gender: head.gender,
                                 forms: plural, glosses: [:], cefr: head.cefr, id: "\(lemma)#n")
            return (entry, head, prefix)
        }
        return nil
    }

    public func entry(id: String) -> LexEntry? {
        let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (forward[Self.fold(parts[0])] ?? []).map { entries[$0] }.first { $0.id == id }
    }

    public func article(for gender: Gender?) -> String? {
        guard let gender else { return nil }
        return info.articles[gender.rawValue]
    }

    /// "der Tisch", "fahren", "schön".
    public func display(_ e: LexEntry) -> String {
        if e.pos == .noun, let a = article(for: e.gender) { return "\(a) \(e.lemma)" }
        return e.lemma
    }

    /// Short grammar line, e.g. "noun · plural Tische" or "verb · fährt · fuhr · ist gefahren".
    public func grammarLine(_ e: LexEntry) -> String {
        var parts = [e.pos.label]
        if !e.forms.isEmpty {
            parts.append(e.pos == .noun ? "pl. \(e.forms)" : e.forms)
        } else if e.pos == .noun {
            parts.append("no plural")
        }
        return parts.joined(separator: " · ")
    }
}
