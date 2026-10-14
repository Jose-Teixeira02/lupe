import Foundation

public enum Rating: Int, Codable, CaseIterable, Sendable {
    case again = 1, hard, good, easy

    public var label: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

public enum CardState: String, Codable, Sendable {
    case new, learning, review, relearning
}

/// FSRS memory state of a card.
public struct MemoryState: Codable, Hashable, Sendable {
    public var state: CardState = .new
    public var stability: Double = 0
    public var difficulty: Double = 0
    public var due: Date
    public var lastReview: Date?
    public var reps: Int = 0
    public var lapses: Int = 0
    /// Index into the learning/relearning steps while in those states.
    public var step: Int = 0

    public init(due: Date = Date()) { self.due = due }

    /// Days a review-state card can go without review and still be recalled with ~90 % probability.
    public var isMature: Bool { state == .review && stability >= 21 }
}

/// FSRS-4.5 scheduler (https://github.com/open-spaced-repetition) with Anki-style learning steps.
public struct FSRS: Sendable {
    public var w: [Double] = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474,
                              0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755]
    public var requestRetention: Double = 0.9
    public var maximumInterval: Double = 36500
    public var learningSteps: [TimeInterval] = [60, 600]
    public var relearningSteps: [TimeInterval] = [600]

    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let day: TimeInterval = 86_400

    public init() {}

    // MARK: Model

    public func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(1 + Self.factor * max(t, 0) / s, Self.decay)
    }

    public func intervalDays(stability s: Double) -> Double {
        let i = s / Self.factor * (pow(requestRetention, 1 / Self.decay) - 1)
        return min(max(i.rounded(), 1), maximumInterval)
    }

    func initialStability(_ r: Rating) -> Double { max(w[r.rawValue - 1], 0.1) }

    func initialDifficulty(_ r: Rating) -> Double {
        clamp(w[4] - Double(r.rawValue - 3) * w[5])
    }

    func nextDifficulty(_ d: Double, _ r: Rating) -> Double {
        let next = d - w[6] * Double(r.rawValue - 3)
        return clamp(w[7] * initialDifficulty(.good) + (1 - w[7]) * next)
    }

    func recallStability(d: Double, s: Double, r: Double, rating: Rating) -> Double {
        let hardPenalty = rating == .hard ? w[15] : 1
        let easyBonus = rating == .easy ? w[16] : 1
        return s * (1 + exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp((1 - r) * w[10]) - 1) * hardPenalty * easyBonus)
    }

    func forgetStability(d: Double, s: Double, r: Double) -> Double {
        let next = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        return min(next, s)
    }

    private func clamp(_ d: Double) -> Double { min(max(d, 1), 10) }

    // MARK: Scheduling

    /// Applies a rating and returns the new memory state.
    public func review(_ m: MemoryState, rating: Rating, now: Date = Date()) -> MemoryState {
        var n = m
        n.reps += 1
        n.lastReview = now

        switch m.state {
        case .new:
            n.stability = initialStability(rating)
            n.difficulty = initialDifficulty(rating)
            switch rating {
            case .again:
                n.state = .learning; n.step = 0
                n.due = now + (learningSteps.first ?? 60)
            case .hard:
                n.state = .learning; n.step = 0
                n.due = now + hardStepDelay(learningSteps)
            case .good:
                if learningSteps.count > 1 {
                    n.state = .learning; n.step = 1
                    n.due = now + learningSteps[1]
                } else {
                    graduate(&n, now: now)
                }
            case .easy:
                graduate(&n, now: now)
            }

        case .learning, .relearning:
            let steps = m.state == .learning ? learningSteps : relearningSteps
            n.difficulty = nextDifficulty(m.difficulty, rating)
            switch rating {
            case .again:
                n.step = 0
                n.due = now + (steps.first ?? 60)
            case .hard:
                n.due = now + (m.step == 0 ? hardStepDelay(steps) : steps[min(m.step, steps.count - 1)])
            case .good:
                let next = m.step + 1
                if next >= steps.count {
                    graduate(&n, now: now)
                } else {
                    n.step = next
                    n.due = now + steps[next]
                }
            case .easy:
                graduate(&n, now: now, bonusDays: 1)
            }

        case .review:
            let elapsed = m.lastReview.map { now.timeIntervalSince($0) / Self.day } ?? 0
            let r = retrievability(elapsedDays: elapsed, stability: m.stability)
            n.difficulty = nextDifficulty(m.difficulty, rating)
            if rating == .again {
                n.stability = forgetStability(d: m.difficulty, s: m.stability, r: r)
                n.lapses += 1
                if relearningSteps.isEmpty {
                    n.due = now + intervalDays(stability: n.stability) * Self.day
                } else {
                    n.state = .relearning; n.step = 0
                    n.due = now + relearningSteps[0]
                }
            } else {
                let hardS = recallStability(d: m.difficulty, s: m.stability, r: r, rating: .hard)
                let goodS = recallStability(d: m.difficulty, s: m.stability, r: r, rating: .good)
                let easyS = recallStability(d: m.difficulty, s: m.stability, r: r, rating: .easy)
                var hardI = intervalDays(stability: hardS)
                var goodI = intervalDays(stability: goodS)
                hardI = min(hardI, goodI)
                goodI = max(goodI, hardI + 1)
                let easyI = max(intervalDays(stability: easyS), goodI + 1)
                switch rating {
                case .hard: n.stability = hardS; n.due = now + hardI * Self.day
                case .good: n.stability = goodS; n.due = now + goodI * Self.day
                case .easy: n.stability = easyS; n.due = now + easyI * Self.day
                case .again: break
                }
            }
        }
        return n
    }

    private func graduate(_ n: inout MemoryState, now: Date, bonusDays: Double = 0) {
        n.state = .review
        n.step = 0
        n.due = now + (intervalDays(stability: n.stability) + bonusDays) * Self.day
    }

    private func hardStepDelay(_ steps: [TimeInterval]) -> TimeInterval {
        guard let first = steps.first else { return 300 }
        if steps.count > 1 { return (first + steps[1]) / 2 }
        return first * 1.5
    }

    /// What each button would do, for showing "1m · 6m · 10m · 4d" under the buttons.
    public func preview(_ m: MemoryState, now: Date = Date()) -> [Rating: TimeInterval] {
        var out: [Rating: TimeInterval] = [:]
        for r in Rating.allCases {
            out[r] = review(m, rating: r, now: now).due.timeIntervalSince(now)
        }
        return out
    }

    /// "45s", "10m", "3h", "4d", "2mo", "1.2y".
    public static func format(_ t: TimeInterval) -> String {
        let s = max(t, 0)
        if s < 60 { return "\(Int(s.rounded()))s" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        if s < day { return "\(Int((s / 3600).rounded()))h" }
        let d = s / day
        if d < 30 { return "\(Int(d.rounded()))d" }
        if d < 365 { return "\(Int((d / 30).rounded()))mo" }
        return String(format: "%.1fy", d / 365)
    }
}
