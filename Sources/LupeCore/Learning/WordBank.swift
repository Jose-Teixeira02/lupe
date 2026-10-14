import Combine
import Foundation

/// Your personal deck for one target language, saved as JSON in Application Support.
@MainActor
public final class WordBank: ObservableObject {
    @Published public private(set) var cards: [Card] = []
    /// Lexicon entry ids (or folded terms) you told Lupe you already know, without making a card.
    @Published public private(set) var known: Set<String> = []

    public let language: String
    public var scheduler = FSRS()
    public weak var journey: Journey?

    private let directory: URL
    private var saveWork: DispatchWorkItem?
    private var indexByKey: [String: Int] = [:]

    public init(language: String, directory: URL? = nil) {
        self.language = language
        self.directory = directory ?? LupePaths.dataDirectory(for: language)
        load()
    }

    // MARK: Persistence

    private var cardsURL: URL { directory.appendingPathComponent("cards.json") }
    private var knownURL: URL { directory.appendingPathComponent("known.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        if let data = try? Data(contentsOf: cardsURL), let decoded = try? Self.decoder.decode([Card].self, from: data) {
            cards = decoded
        }
        if let data = try? Data(contentsOf: knownURL), let decoded = try? Self.decoder.decode([String].self, from: data) {
            known = Set(decoded)
        }
        reindex()
    }

    private func reindex() {
        indexByKey = [:]
        for (i, c) in cards.enumerated() { indexByKey[c.key] = i }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes everything to disk now (atomic).
    public func flush() {
        saveWork?.cancel()
        saveWork = nil
        if let data = try? Self.encoder.encode(cards) { try? data.write(to: cardsURL, options: .atomic) }
        if let data = try? Self.encoder.encode(known.sorted()) { try? data.write(to: knownURL, options: .atomic) }
    }

    // MARK: Queries

    public func card(id: UUID) -> Card? { cards.first { $0.id == id } }

    public func card(forKey key: String) -> Card? {
        indexByKey[key].map { cards[$0] }
    }

    public func card(for entry: LexEntry) -> Card? { card(forKey: entry.id) }

    public func isKnown(_ key: String) -> Bool {
        known.contains(key) || card(forKey: key)?.status == .known
    }

    public var activeCards: [Card] { cards.filter { $0.status == .active } }

    /// Cards due now: reviews first (oldest due first), then up to `newLimit` new cards (oldest first).
    public func dueQueue(now: Date = Date(), newLimit: Int = 10) -> [Card] {
        let active = activeCards
        let reviews = active.filter { $0.memory.state != .new && $0.memory.due <= now }.sorted { $0.memory.due < $1.memory.due }
        let newOnes = active.filter { $0.memory.state == .new }.sorted { $0.createdAt < $1.createdAt }.prefix(max(newLimit, 0))
        return reviews + newOnes
    }

    public func dueCount(now: Date = Date(), newLimit: Int = 10) -> Int { dueQueue(now: now, newLimit: newLimit).count }

    /// Learning cards that are due soonest; used by sprinkles to reinforce what you're learning.
    public func reinforcementKeys(limit: Int = 200, now: Date = Date()) -> [String: Double] {
        var out: [String: Double] = [:]
        for c in activeCards {
            // Score: due or overdue cards highest, then cards still in learning.
            let overdue = now.timeIntervalSince(c.memory.due) / 86_400
            var score = 0.0
            if c.memory.state == .new { score = 0.6 }
            else if c.memory.state == .learning || c.memory.state == .relearning { score = 0.9 }
            else if overdue >= 0 { score = 1.0 }
            else { score = max(0.1, 0.5 - (-overdue) / 30) }
            out[c.key] = score
        }
        if out.count > limit {
            let top = out.sorted { $0.value > $1.value }.prefix(limit)
            return Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
        }
        return out
    }

    // MARK: Mutations

    /// Adds a new card or merges a new encounter into an existing one. Returns the card and whether it was created.
    @discardableResult
    public func add(term: String, entry: LexEntry?, display: String, meanings: [String: String],
                    encounter: Encounter?, source: CardSource, kind: Card.Kind = .word) -> (card: Card, created: Bool) {
        let key = entry?.id ?? Card.key(for: term)
        if let i = indexByKey[key] {
            if let encounter { appendEncounter(encounter, to: i) }
            for (k, v) in meanings where cards[i].meanings[k] == nil { cards[i].meanings[k] = v }
            // Looking up a card you marked as known means you forgot it: bring it back.
            if cards[i].status == .known && source != .sprinkle {
                cards[i].status = .active
            }
            known.remove(key)
            scheduleSave()
            return (cards[i], false)
        }
        let card = Card(kind: kind, term: term, entryID: entry?.id, display: display, gender: entry?.gender,
                        pos: entry?.pos, forms: entry?.forms ?? "", meanings: meanings,
                        encounters: encounter.map { [$0] } ?? [], source: source)
        cards.append(card)
        indexByKey[card.key] = cards.count - 1
        known.remove(key)
        journey?.record(.newCard)
        scheduleSave()
        return (card, true)
    }

    private func appendEncounter(_ e: Encounter, to i: Int) {
        if cards[i].encounters.contains(where: { $0.sentence == e.sentence }) { return }
        cards[i].encounters.append(e)
        if cards[i].encounters.count > 6 { cards[i].encounters.removeFirst(cards[i].encounters.count - 6) }
    }

    /// Records a review and reschedules the card.
    public func review(_ id: UUID, rating: Rating, now: Date = Date()) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].memory = scheduler.review(cards[i].memory, rating: rating, now: now)
        journey?.record(.review(rating))
        scheduleSave()
    }

    public func setStatus(_ id: UUID, _ status: Card.Status) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].status = status
        if status == .known { journey?.record(.markedKnown) }
        scheduleSave()
    }

    /// Marks a word as known without needing a card (from a sprinkle or hover card).
    public func markKnown(key: String) {
        if let i = indexByKey[key] {
            cards[i].status = .known
        } else {
            known.insert(key)
        }
        journey?.record(.markedKnown)
        scheduleSave()
    }

    public func unmarkKnown(key: String) {
        known.remove(key)
        if let i = indexByKey[key], cards[i].status == .known { cards[i].status = .active }
        scheduleSave()
    }

    public func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
        reindex()
        scheduleSave()
    }

    public func updateNotes(_ id: UUID, notes: String) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].notes = notes.isEmpty ? nil : notes
        scheduleSave()
    }

    /// Replaces everything (used by import and tests).
    public func replaceAll(cards newCards: [Card], known newKnown: Set<String>) {
        cards = newCards
        known = newKnown
        reindex()
        scheduleSave()
    }

    // MARK: Stats

    public struct Stats: Sendable {
        public var total = 0, new = 0, learning = 0, young = 0, mature = 0, known = 0
    }

    public var stats: Stats {
        var s = Stats()
        for c in cards {
            s.total += 1
            if c.status == .known { s.known += 1; continue }
            switch c.memory.state {
            case .new: s.new += 1
            case .learning, .relearning: s.learning += 1
            case .review: if c.memory.isMature { s.mature += 1 } else { s.young += 1 }
            }
        }
        s.known += known.count
        return s
    }
}
