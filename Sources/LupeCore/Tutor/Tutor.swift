import Foundation
import FoundationModels

/// Explains sentences and checks the learner's own German. Implementations: on-device (default), Claude (opt-in).
public protocol Tutor: Sendable {
    var name: String { get }
    /// Whether this tutor sends text off the device (shown in the UI).
    var isOnDevice: Bool { get }
    func explain(sentence: String, translation: String?, focus: String?, explainIn language: String) async throws -> String
    /// Returns the corrected sentence only (unchanged when already correct).
    func proofread(german: String) async throws -> String
    /// Explains the differences between the learner's sentence and the corrected one.
    func explainCorrection(original: String, corrected: String, explainIn language: String) async throws -> String
}

public enum TutorError: Error, LocalizedError {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): why
        case .failed(let why): why
        }
    }
}

enum TutorPrompts {
    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// A compact grammar crib so small models don't improvise wrong rules.
    static let germanCrib = """
    Reference rules (German):
    - Verb is the 2nd element in main clauses; in subordinate clauses (dass, weil, wenn, ob, obwohl...) the conjugated verb goes to the end.
    - Accusative prepositions: durch, für, gegen, ohne, um, bis, entlang.
    - Dative prepositions: aus, bei, mit, nach, seit, von, zu, gegenüber, außer.
    - Genitive prepositions (formal): wegen, trotz, während, statt.
    - Two-way prepositions (an, auf, hinter, in, neben, über, unter, vor, zwischen): accusative for movement towards a place (Wohin?), dative for location (Wo?).
    - Articles: der/die/das (nom.), den/die/das (acc.), dem/der/dem, plural den (+n) (dat.), des/der/des (gen.).
    - Separable verbs split in main clauses: anrufen → "Ich rufe dich an".
    - Perfekt uses "sein" for movement/change of state (gehen, fahren, werden) and "haben" otherwise.
    - Modal verbs push the infinitive to the end: "Ich muss heute arbeiten."
    """

    static func explain(sentence: String, translation: String?, focus: String?, language: String) -> String {
        var p = "Sentence: \(sentence)\n"
        if let translation { p += "Translation: \(translation)\n" }
        if let focus, !focus.isEmpty { p += "The learner is asking specifically about: \(focus)\n" }
        p += """

        In \(languageName(language)), explain this to a learner in at most 4 short bullet points:
        word order, case/article choices, and anything idiomatic. Quote the German words you discuss.
        If you are not sure about a rule, say so instead of guessing. No introduction, no summary.
        """
        return p
    }

    static let proofreadInstructions = """
    You are an expert German proofreader. You fix grammar mistakes (verb position, auxiliary haben/sein in Perfekt, \
    cases after prepositions, adjective endings, gender of articles, spelling). You keep the learner's words and meaning. \
    You output only the corrected sentence.
    """

    static func proofread(_ german: String) -> String {
        "Correct this German sentence. If it is already correct, output it unchanged.\n\n\(german)"
    }

    static func explainCorrection(original: String, corrected: String, language: String) -> String {
        let changes = WordDiff.changes(original, corrected)
        let list = changes.enumerated().map { i, c in
            "\(i + 1). \"\(c.from.isEmpty ? "∅" : c.from)\" → \"\(c.to.isEmpty ? "∅" : c.to)\""
        }.joined(separator: "\n")
        return """
        Learner wrote: \(original)
        Corrected: \(corrected)
        Changes:
        \(list)

        In \(languageName(language)), give exactly one short sentence per numbered change explaining the grammar rule.
        Use the format "1. … 2. …". Do not mention anything that is not in the list.
        """
    }

    /// Small models sometimes invent extra "changes"; keep only the first `count` numbered points.
    static func keepNumbered(_ text: String, count: Int) -> String {
        guard count > 0 else { return text }
        var kept: [String] = []
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isItem = line.first?.isNumber == true && (line.dropFirst().hasPrefix(".") || line.dropFirst().hasPrefix(")"))
            if isItem {
                if let c = current { kept.append(c) }
                if kept.count >= count { current = nil; break }
                current = line
            } else if let c = current, !line.isEmpty {
                current = c + " " + line
            }
        }
        if let c = current, kept.count < count { kept.append(c) }
        return kept.isEmpty ? text : kept.joined(separator: "\n")
    }

    static let instructions = """
    You are Lupe, a warm, precise German tutor inside a language-learning app. The learner speaks Portuguese and English.
    Be brief and concrete. Never invent grammar rules. Use the reference rules when relevant.

    \(germanCrib)
    """
}

/// Apple Intelligence on-device model: free, private, offline. Quality is decent but not perfect,
/// so the UI labels its answers as AI notes.
public final class OnDeviceTutor: Tutor, @unchecked Sendable {
    public let name = "Apple Intelligence (on-device)"
    public let isOnDevice = true

    public init() {}

    public static var availabilityDescription: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return "On-device AI unavailable: \(reason)"
        }
    }

    public static var isAvailable: Bool { availabilityDescription == nil }

    public func explain(sentence: String, translation: String?, focus: String?, explainIn language: String) async throws -> String {
        try await ask(TutorPrompts.explain(sentence: sentence, translation: translation, focus: focus, language: language))
    }

    public func proofread(german: String) async throws -> String {
        let raw = try await ask(TutorPrompts.proofread(german), instructions: TutorPrompts.proofreadInstructions, temperature: 0)
        // Models sometimes wrap the answer in quotes or add a label; keep the first sentence-like line.
        let line = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? raw
        var cleaned = line
        for prefix in ["Corrected:", "Korrigiert:", "Correction:"] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“”«»"))
    }

    public func explainCorrection(original: String, corrected: String, explainIn language: String) async throws -> String {
        let raw = try await ask(TutorPrompts.explainCorrection(original: original, corrected: corrected, language: language))
        return TutorPrompts.keepNumbered(raw, count: WordDiff.changes(original, corrected).count)
    }

    private func ask(_ prompt: String, instructions: String = TutorPrompts.instructions, temperature: Double = 0.2) async throws -> String {
        if let why = Self.availabilityDescription { throw TutorError.unavailable(why) }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TutorError.failed("On-device AI couldn't answer: \(error.localizedDescription)")
        }
    }
}

/// Word-level diff between two sentences, for highlighting corrections.
public enum WordDiff {
    public enum Op: Hashable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Longest-common-subsequence diff over whitespace-separated words (punctuation kept on words).
    public static func diff(_ a: String, _ b: String) -> [Op] {
        let x = a.split(separator: " ").map(String.init)
        let y = b.split(separator: " ").map(String.init)
        let n = x.count, m = y.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if x[i] == y[j] { ops.append(.same(x[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.removed(x[i])); i += 1 }
            else { ops.append(.added(y[j])); j += 1 }
        }
        while i < n { ops.append(.removed(x[i])); i += 1 }
        while j < m { ops.append(.added(y[j])); j += 1 }
        return ops
    }

    /// Groups consecutive removals/additions into change pairs ("habe" → "bin").
    public static func changes(_ a: String, _ b: String) -> [(from: String, to: String)] {
        var out: [(from: String, to: String)] = []
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty || !added.isEmpty {
                out.append((removed.joined(separator: " "), added.joined(separator: " ")))
            }
            removed = []; added = []
        }
        for op in diff(a, b) {
            switch op {
            case .same: flush()
            case .removed(let w): removed.append(w)
            case .added(let w): added.append(w)
            }
        }
        flush()
        return out
    }

    /// True when only capitalisation/punctuation differ.
    public static func isEquivalent(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().unicodeScalars.filter { CharacterSet.letters.union(.decimalDigits).union(.whitespaces).contains($0) }
                .map(String.init).joined().split(separator: " ").joined(separator: " ")
        }
        return norm(a) == norm(b)
    }
}
