import Foundation

/// A short text to read in the Reading room, stored as `packs/<code>/stories/NN-title.txt`
/// with a first line `# Title | Level`.
public struct Story: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var level: String
    public var text: String

    public init(id: String, title: String, level: String, text: String) {
        self.id = id
        self.title = title
        self.level = level
        self.text = text
    }

    public static func parse(id: String, contents: String) -> Story {
        var lines = contents.components(separatedBy: .newlines)
        var title = id
        var level = ""
        if let first = lines.first, first.hasPrefix("#") {
            let header = first.dropFirst().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            title = header.first ?? id
            level = header.count > 1 ? header[1] : ""
            lines.removeFirst()
        }
        return Story(id: id, title: title, level: level, text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stories bundled with a pack (user packs first, so you can add your own).
    public static func load(language: String) -> [Story] {
        var seen = Set<String>()
        var out: [Story] = []
        for root in LupePaths.packRoots() {
            let dir = root.appendingPathComponent(language).appendingPathComponent("stories")
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "txt" {
                let id = f.deletingPathExtension().lastPathComponent
                guard seen.insert(id).inserted, let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                out.append(parse(id: id, contents: text))
            }
        }
        return out
    }
}

/// One clickable word, with the text that follows it up to the next word (spaces, punctuation).
public struct ReadingToken: Identifiable, Hashable, Sendable {
    public var id: Int
    public var text: String
    public var trailing: String
    public var paragraph: Int
    /// Range of `text` inside its paragraph.
    public var range: Range<String.Index>
    public var entry: LexEntry?
}

public struct ReadingParagraph: Identifiable, Sendable {
    public var id: Int
    public var text: String
    /// Text before the first word ("„").
    public var leading: String
    public var tokens: [ReadingToken]
    public var language: String
}

public enum ReadingDocument {
    /// Splits text into paragraphs of clickable words, each annotated with its lexicon entry when it's German.
    public static func parse(_ text: String, engine: LookupEngine) -> [ReadingParagraph] {
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var nextID = 0
        return paragraphs.enumerated().map { pi, p in
            let language = engine.language(of: p)
            let analyzed = TextTools.analyze(p, language: language)
            let ranges = TextTools.wordRanges(in: p)
            var tokens: [ReadingToken] = []
            for (i, r) in ranges.enumerated() {
                let end = i + 1 < ranges.count ? ranges[i + 1].lowerBound : p.endIndex
                let word = String(p[r])
                var entry: LexEntry?
                if language == engine.target, TextTools.isMostlyLetters(word) {
                    let token = analyzed.first { $0.range.overlaps(r) }
                    let capitalized = word.first?.isUppercase == true && i > 0 && !(p[..<r.lowerBound].trimmingCharacters(in: .whitespaces).last.map { ".!?:„\"".contains($0) } ?? false)
                    entry = engine.lexicon.bestEntry(forGerman: word, lemma: token?.lemma, capitalized: capitalized)
                }
                tokens.append(ReadingToken(id: nextID, text: word, trailing: String(p[r.upperBound..<end]), paragraph: pi, range: r, entry: entry))
                nextID += 1
            }
            let leading = ranges.first.map { String(p[..<$0.lowerBound]) } ?? p
            return ReadingParagraph(id: pi, text: p, leading: leading, tokens: tokens, language: language)
        }
    }

    /// The sentence around a word and the word's range inside it.
    public static func sentence(around range: Range<String.Index>, in text: String) -> (String, Range<String.Index>)? {
        let sentence = TextTools.sentence(in: text, containing: range)
        guard let start = text.range(of: sentence)?.lowerBound else { return nil }
        let offset = text.distance(from: start, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        guard offset >= 0, offset + length <= sentence.count else { return nil }
        let lo = sentence.index(sentence.startIndex, offsetBy: offset)
        let hi = sentence.index(lo, offsetBy: length)
        return (sentence, lo..<hi)
    }
}
