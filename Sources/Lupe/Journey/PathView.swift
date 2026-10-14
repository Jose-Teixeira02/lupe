import LupeCore
import SwiftUI

/// The journey: estimated vocabulary on the CEFR path, an activity heatmap and deck stats.
struct PathView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let known = model.estimatedKnownWords
        let pos = Journey.position(knownWords: known)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your path").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("An estimate from your starting level plus every word you've proven in reviews.")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 30) {
                    milestones(known: known, current: pos.current)
                        .frame(width: 360, alignment: .leading)
                    VStack(alignment: .leading, spacing: 22) {
                        summary(known: known, pos: pos)
                        heatmap
                        deckStats
                    }
                }
            }
            .padding(28)
        }
    }

    private func summary(known: Int, pos: (current: Milestone?, next: Milestone?, progress: Double)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("~\(known)").font(.system(size: 44, weight: .heavy, design: .rounded)) + Text(" words").font(.system(size: 18, weight: .medium)).foregroundColor(.secondary)
            if let next = pos.next {
                ProgressView(value: pos.progress).tint(Theme.accent)
                Text("\(max(0, next.words - known)) words to \(next.level) · \(next.title)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Beyond C1. Unglaublich!").foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
    }

    private func milestones(known: Int, current: Milestone?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Journey.milestones.enumerated()), id: \.offset) { i, m in
                let reached = known >= m.words
                let isNext = !reached && (i == 0 || known >= Journey.milestones[i - 1].words)
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(reached ? Theme.accent : Color.clear).frame(width: 30, height: 30)
                            Circle().strokeBorder(reached || isNext ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: isNext ? 3 : 2)
                                .frame(width: 30, height: 30)
                            Text(m.level).font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(reached ? Color.white : (isNext ? Theme.accent : .secondary))
                        }
                        if i < Journey.milestones.count - 1 {
                            Rectangle().fill(reached ? Theme.accent : Color.secondary.opacity(0.2)).frame(width: 2, height: 54)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(m.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text("\(m.words) words").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Text(m.blurb).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if isNext { Tag(text: "you are here →", color: Theme.accent) }
                    }
                    .padding(.top, 4)
                }
                .opacity(reached || isNext ? 1 : 0.6)
            }
        }
    }

    private var heatmap: some View {
        let days = model.journey.recentDays(7 * 18)
        let maxXP = max(model.journey.dailyGoalXP, days.map(\.xp).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 18 weeks").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<18, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { d in
                            let idx = week * 7 + d
                            let xp = idx < days.count ? days[idx].xp : 0
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(xp == 0 ? Color.primary.opacity(0.06) : Theme.das.opacity(0.25 + 0.75 * min(1, Double(xp) / Double(maxXP))))
                                .frame(width: 13, height: 13)
                                .help(idx < days.count ? "\(days[idx].day): \(xp) XP" : "")
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                Text("Total \(model.journey.totalXP) XP").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Best streak \(model.journey.bestStreak) days").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var deckStats: some View {
        let s = model.bank.stats
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your deck").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                pill("New", s.new, Theme.neutral)
                pill("Learning", s.learning, Theme.warm)
                pill("Young", s.young, Theme.der)
                pill("Mature", s.mature, Theme.das)
                pill("Known", s.known, .secondary)
            }
            Text("Mature = you'd still remember it 3+ weeks from now.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func pill(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(width: 70, height: 54)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}
