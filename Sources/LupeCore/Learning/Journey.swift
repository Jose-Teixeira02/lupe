import Combine
import Foundation

/// One day of activity.
public struct DayLog: Codable, Hashable, Sendable {
    public var day: String
    public var reviews = 0
    public var correct = 0
    public var newCards = 0
    public var lookups = 0
    public var asks = 0
    public var sprinkleHovers = 0
    public var markedKnown = 0
    public var xp = 0

    public init(day: String) { self.day = day }
}

public enum JourneyEvent: Sendable {
    case review(Rating)
    case newCard
    case lookup
    case ask
    case sprinkleHover
    case markedKnown

    var xp: Int {
        switch self {
        case .review(let r): r == .again ? 1 : 2
        case .newCard: 3
        case .lookup: 1
        case .ask: 1
        case .sprinkleHover: 1
        case .markedKnown: 1
        }
    }
}

/// A step on the CEFR path, with the vocabulary size usually associated with it.
public struct Milestone: Sendable, Hashable {
    public var level: String
    public var words: Int
    public var title: String
    public var blurb: String
}

/// CEFR levels used for placement and the learning frontier.
public enum CEFR {
    public static let order = ["A1", "A2", "B1", "B2", "C1"]

    /// Levels assumed known for a placement ("none", "A1", "A2", …).
    public static func known(upTo placement: String) -> Set<String> {
        guard let i = order.firstIndex(of: placement) else { return [] }
        return Set(order[...i])
    }

    /// The level being worked towards.
    public static func next(after placement: String) -> String? {
        guard let i = order.firstIndex(of: placement) else { return order.first }
        return i + 1 < order.count ? order[i + 1] : nil
    }
}

/// Streaks, XP and the CEFR path. Kept deliberately gentle: no losses, no nagging.
@MainActor
public final class Journey: ObservableObject {
    @Published public private(set) var days: [String: DayLog] = [:]
    @Published public var dailyGoalXP: Int { didSet { scheduleSave() } }

    private let url: URL
    private var saveWork: DispatchWorkItem?
    public var calendar = Calendar.current
    /// Lets tests inject "now".
    public var clock: () -> Date = { Date() }

    public static let streakThresholdXP = 10

    public static let milestones: [Milestone] = [
        Milestone(level: "A1", words: 500, title: "Erste Schritte", blurb: "Greetings, numbers, everyday objects. You can survive a café."),
        Milestone(level: "A2", words: 1000, title: "Unterwegs", blurb: "Shopping, directions, simple chats. Signs start making sense."),
        Milestone(level: "B1", words: 2000, title: "Selbstständig", blurb: "You follow the gist of articles and can tell a story."),
        Milestone(level: "B2", words: 4000, title: "Fließend", blurb: "Films without subtitles, real discussions, work emails."),
        Milestone(level: "C1", words: 8000, title: "Kompetent", blurb: "Nuance, idioms, and reading for pleasure."),
    ]

    public init(language: String, directory: URL? = nil) {
        let dir = directory ?? LupePaths.dataDirectory(for: language)
        url = dir.appendingPathComponent("journey.json")
        dailyGoalXP = 40
        load()
    }

    private struct Stored: Codable {
        var days: [DayLog]
        var dailyGoalXP: Int
    }

    private func load() {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        days = Dictionary(uniqueKeysWithValues: s.days.map { ($0.day, $0) })
        dailyGoalXP = s.dailyGoalXP
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    public func flush() {
        saveWork?.cancel()
        let stored = Stored(days: days.values.sorted { $0.day < $1.day }, dailyGoalXP: dailyGoalXP)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Recording

    public func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func record(_ event: JourneyEvent) {
        let key = dayKey(clock())
        var log = days[key] ?? DayLog(day: key)
        switch event {
        case .review(let r):
            log.reviews += 1
            if r != .again { log.correct += 1 }
        case .newCard: log.newCards += 1
        case .lookup: log.lookups += 1
        case .ask: log.asks += 1
        case .sprinkleHover: log.sprinkleHovers += 1
        case .markedKnown: log.markedKnown += 1
        }
        log.xp += event.xp
        days[key] = log
        scheduleSave()
    }

    // MARK: Derived

    public var today: DayLog {
        let key = dayKey(clock())
        return days[key] ?? DayLog(day: key)
    }

    public var goalProgress: Double {
        min(1, Double(today.xp) / Double(max(dailyGoalXP, 1)))
    }

    /// Consecutive active days ending today; today counts once it reaches the threshold,
    /// and an unfinished today doesn't break yesterday's streak.
    public var streak: Int {
        var count = 0
        var date = clock()
        if (days[dayKey(date)]?.xp ?? 0) < Self.streakThresholdXP {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        while (days[dayKey(date)]?.xp ?? 0) >= Self.streakThresholdXP {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return count
    }

    public var bestStreak: Int {
        let active = days.values.filter { $0.xp >= Self.streakThresholdXP }.map(\.day).sorted()
        var best = 0, run = 0
        var previous: Date?
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        for key in active {
            guard let d = f.date(from: key) else { continue }
            if let p = previous, let next = calendar.date(byAdding: .day, value: 1, to: p), calendar.isDate(next, inSameDayAs: d) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = d
        }
        return best
    }

    public var totalXP: Int { days.values.reduce(0) { $0 + $1.xp } }

    /// The last `count` days (oldest first), for the activity heatmap.
    public func recentDays(_ count: Int) -> [DayLog] {
        let now = clock()
        return (0..<count).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = dayKey(d)
            return days[key] ?? DayLog(day: key)
        }
    }

    /// Current and next milestone for an estimated vocabulary size.
    public static func position(knownWords: Int) -> (current: Milestone?, next: Milestone?, progress: Double) {
        var current: Milestone?
        for m in milestones where knownWords >= m.words { current = m }
        let next = milestones.first { knownWords < $0.words }
        let lower = current?.words ?? 0
        let upper = next?.words ?? lower
        let progress = upper > lower ? Double(knownWords - lower) / Double(upper - lower) : 1
        return (current, next, progress)
    }
}
