import AppKit
import Combine
import LupeCore
import SwiftUI

/// Owns the language engine, the word bank and the journey, and offers the actions every UI uses.
@MainActor
final class AppModel: ObservableObject {
    let settings: LupeSettings
    let permissions = Permissions()
    let translator = AppleTranslator()
    private let onDeviceTutor = OnDeviceTutor()
    static let claudeKeyAccount = "anthropic-api-key"
    /// Whether a Claude API key is stored in the Keychain.
    @Published private(set) var hasClaudeKey = KeychainStore.read(AppModel.claudeKeyAccount) != nil

    @Published private(set) var lexicon: Lexicon
    @Published private(set) var engine: LookupEngine
    @Published private(set) var bank: WordBank
    @Published private(set) var journey: Journey
    @Published var sprinklesPausedUntil: Date?
    @Published private(set) var recentAsks: [String] = []
    /// Translation availability for the current pair ("installed" / "supported" / "unsupported").
    @Published private(set) var translationStatus: String = "checking"
    /// Last thing the hover lens or sprinkles did, shown in the menu for transparency.
    @Published var lastActivity: String = ""

    private var cancellables: Set<AnyCancellable> = []
    /// Forwarding from the current bank/journey; replaced when the language changes.
    private var nested: Set<AnyCancellable> = []

    init(settings: LupeSettings) {
        self.settings = settings
        let lex = (try? LupePaths.loadLexicon(settings.targetLanguage)) ?? (try? LupePaths.loadLexicon("de"))
            ?? Lexicon(info: PackInfo(code: "de", name: "German", nativeName: "Deutsch", flag: "🇩🇪",
                                      articles: ["m": "der", "f": "die", "n": "das", "pl": "die"],
                                      capitalizeNouns: true, speechLanguage: "de-DE"), entries: [])
        lexicon = lex
        engine = LookupEngine(lexicon: lex, translator: translator, helpers: settings.helpers, primaryHelper: settings.primaryHelper)
        let j = Journey(language: lex.info.code)
        let b = WordBank(language: lex.info.code)
        b.journey = j
        bank = b
        journey = j
        recentAsks = UserDefaults.standard.stringArray(forKey: "recentAsks") ?? []

        // Forward nested changes so SwiftUI views observing the model refresh.
        bank.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &nested)
        journey.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &nested)
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        settings.$primaryHelper.dropFirst().sink { [weak self] helper in
            guard let self else { return }
            self.engine.primaryHelper = helper
            self.engine.helpers = helper == "pt" ? ["pt", "en"] : ["en", "pt"]
        }.store(in: &cancellables)
        settings.$targetLanguage.dropFirst().removeDuplicates().sink { [weak self] code in
            self?.switchLanguage(to: code)
        }.store(in: &cancellables)
        Task { await refreshTranslationStatus() }
    }

    var target: String { lexicon.info.code }

    // MARK: Tutor

    /// The tutor for Explain / Check: Claude when chosen and a key is stored, otherwise on-device.
    var tutor: Tutor {
        if settings.tutorProvider == "claude", let key = KeychainStore.read(Self.claudeKeyAccount), !key.isEmpty {
            return ClaudeTutor(apiKey: key)
        }
        return onDeviceTutor
    }

    var canExplain: Bool { !tutor.isOnDevice || OnDeviceTutor.isAvailable }

    var aiLabel: String { tutor.isOnDevice ? "AI note · on-device · may be imperfect" : "AI note · Claude" }

    func saveClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.save(trimmed, account: Self.claudeKeyAccount)
        hasClaudeKey = true
    }

    func removeClaudeKey() {
        KeychainStore.delete(Self.claudeKeyAccount)
        hasClaudeKey = false
        if settings.tutorProvider == "claude" { settings.tutorProvider = "device" }
    }

    func switchLanguage(to code: String) {
        guard let lex = try? LupePaths.loadLexicon(code) else { return }
        bank.flush()
        journey.flush()
        lexicon = lex
        engine = LookupEngine(lexicon: lex, translator: translator, helpers: settings.helpers, primaryHelper: settings.primaryHelper)
        let j = Journey(language: code)
        let b = WordBank(language: code)
        b.journey = j
        bank = b
        journey = j
        nested.removeAll()
        bank.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &nested)
        journey.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &nested)
        Task { await refreshTranslationStatus() }
    }

    func refreshTranslationStatus() async {
        let st = await translator.status(from: settings.primaryHelper, to: target)
        translationStatus = switch st {
        case .installed: "installed"
        case .supported: "supported"
        default: "unsupported"
        }
    }

    // MARK: Actions

    var frontmostAppName: String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app?.localizedName
    }

    func encounter(for r: LookupResult, app: String?) -> Encounter? {
        guard !r.context.isEmpty, r.context != r.word else { return nil }
        let targetForm = r.direction == .toTarget ? r.aligned : r.word
        return Encounter(sentence: r.context, translation: r.contextTranslation, language: r.sourceLanguage,
                         app: app, targetForm: targetForm)
    }

    /// Saves a lookup as a card (or adds the new sentence to an existing one).
    @discardableResult
    func save(_ r: LookupResult, source: CardSource, app: String?) -> (card: Card, created: Bool) {
        var meanings = r.meanings
        // Meanings shown on cards should be short.
        for (k, v) in meanings { meanings[k] = v.split(separator: ",").prefix(2).joined(separator: ",") }
        return bank.add(term: r.term, entry: r.entry, display: r.headword, meanings: meanings,
                        encounter: encounter(for: r, app: app), source: source)
    }

    /// Saves a whole phrase from the Ask bar or Lens.
    @discardableResult
    func savePhrase(german: String, meaning: String, meaningLanguage: String, source: CardSource) -> (card: Card, created: Bool) {
        bank.add(term: german, entry: nil, display: german, meanings: [meaningLanguage: meaning],
                 encounter: Encounter(sentence: german, translation: meaning, language: target, app: frontmostAppName),
                 source: source, kind: .phrase)
    }

    func speak(_ text: String) {
        Speech.shared.speak(text, language: lexicon.info.speechLanguage, slow: settings.slowSpeech)
    }

    func rememberAsk(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 1 else { return }
        recentAsks.removeAll { $0 == t }
        recentAsks.insert(t, at: 0)
        if recentAsks.count > 12 { recentAsks.removeLast(recentAsks.count - 12) }
        UserDefaults.standard.set(recentAsks, forKey: "recentAsks")
    }

    var sprinklesActive: Bool {
        settings.sprinklesEnabled && (sprinklesPausedUntil.map { $0 < Date() } ?? true)
    }

    func learnerSnapshot(previous: Set<String>, dismissed: Set<String>) -> LearnerSnapshot {
        var known = bank.known
        for c in bank.cards where c.status == .known { known.insert(c.key) }
        return LearnerSnapshot(knownKeys: known, reinforcement: bank.reinforcementKeys(), previous: previous, dismissed: dismissed)
    }

    // MARK: Progress

    /// Rough vocabulary estimate: the core words of the levels you placed into, plus every word proven since.
    var estimatedKnownWords: Int {
        let known = settings.knownLevels
        var n = Double(lexicon.entries.filter { known.contains($0.cefr) }.count)
        func assumed(_ id: String?) -> Bool {
            guard let id, let e = lexicon.entry(id: id) else { return false }
            return known.contains(e.cefr)
        }
        for c in bank.cards where !assumed(c.entryID) {
            if c.status == .known || c.memory.isMature { n += 1 }
            else if c.memory.state == .review { n += 0.5 }
        }
        for key in bank.known where !assumed(key) { n += 1 }
        return Int(n)
    }

    /// A frequent word at your next level that you haven't met yet; stable for the whole day.
    var wordOfTheDay: LexEntry? {
        let next = settings.nextLevel
        let known = settings.knownLevels
        let unseen = lexicon.entries.filter {
            $0.pos.isContentWord && !known.contains($0.cefr) && bank.card(forKey: $0.id) == nil && !bank.known.contains($0.id)
        }
        let atLevel = unseen.filter { $0.cefr == next }
        let pool = Array((atLevel.isEmpty ? unseen : atLevel).prefix(400))
        guard !pool.isEmpty else { return nil }
        let day = journey.dayKey(Date())
        let index = Int(SprinkleSelector.stableHash(day) % UInt64(pool.count))
        return pool[index]
    }

    func addWordOfTheDay() {
        guard let e = wordOfTheDay else { return }
        var meanings: [String: String] = [:]
        for h in settings.helpers { if let g = e.gloss(h) { meanings[h] = g } }
        bank.add(term: e.lemma, entry: e, display: lexicon.display(e), meanings: meanings, encounter: nil, source: .starter)
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        let hello = hour < 11 ? "Guten Morgen" : hour < 18 ? "Guten Tag" : "Guten Abend"
        return name.isEmpty ? hello : "\(hello), \(name)"
    }
}
