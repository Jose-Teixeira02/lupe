import LupeCore
import SwiftUI

struct TodayView: View {
    @ObservedObject var model: AppModel
    var openSection: (JourneySection) -> Void
    var openAsk: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statsRow
                HStack(alignment: .top, spacing: 16) {
                    metToday.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(spacing: 16) {
                        if let w = model.wordOfTheDay { wordOfTheDay(w) }
                        readCard
                        tipCard
                    }
                    .frame(width: 280)
                }
            }
            .padding(28)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.greeting).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(Date.now.formatted(date: .complete, time: .omitted) + " · " + subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let due = model.bank.dueCount(newLimit: model.settings.dailyNewCards)
        if model.bank.cards.isEmpty { return "Your deck is empty. Hold ⌃ on any word to start it." }
        if due == 0 { return "Nothing due. A perfect day to explore." }
        return due == 1 ? "1 card is waiting for you." : "\(due) cards are waiting for you."
    }

    private var statsRow: some View {
        let j = model.journey
        let due = model.bank.dueCount(newLimit: model.settings.dailyNewCards)
        return HStack(spacing: 14) {
            statCard {
                HStack(spacing: 14) {
                    ZStack {
                        ProgressRing(progress: j.goalProgress, lineWidth: 7)
                        Text("\(Int(j.goalProgress * 100))%").font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily goal").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(j.today.xp) / \(j.dailyGoalXP) XP").font(.system(size: 18, weight: .bold, design: .rounded))
                    }
                }
            }
            statCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Streak").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("🔥 \(j.streak) day\(j.streak == 1 ? "" : "s")").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("best \(j.bestStreak)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Button { openSection(.review) } label: {
                statCard(tint: due > 0 ? Theme.accent : nil) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Due now").font(.system(size: 11)).foregroundStyle(due > 0 ? Color.white.opacity(0.85) : .secondary)
                        Text(due == 1 ? "1 card" : "\(due) cards").font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(due > 0 ? "Start review →" : "All caught up").font(.system(size: 11))
                            .foregroundStyle(due > 0 ? Color.white.opacity(0.85) : .secondary)
                    }
                    .foregroundStyle(due > 0 ? Color.white : .primary)
                }
            }
            .buttonStyle(.plain)
            statCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vocabulary").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("~\(model.estimatedKnownWords) words").font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(model.bank.cards.count) in your deck").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func statCard<Content: View>(tint: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint ?? Color.primary.opacity(0.04)))
    }

    private var metToday: some View {
        let start = Calendar.current.startOfDay(for: Date())
        let today = model.bank.cards.filter { $0.createdAt >= start }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Met today").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                if !today.isEmpty { Text("\(today.count) new").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if today.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No new words yet today.").foregroundStyle(.secondary)
                    Text("Try it: hold ⌃ and rest the mouse on any word, in any app. Or press ⌃⌥D and type something you'd like to say.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Open the Ask bar", action: openAsk)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                ForEach(today.prefix(10)) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(Theme.color(for: c.pos, gender: c.gender)).frame(width: 8, height: 8).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                GenderedWord(display: c.display, gender: c.gender, pos: c.pos, size: 15)
                                Text(c.meaning(model.settings.primaryHelper)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let e = c.latestEncounter {
                                Text("“\(e.sentence)”").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let app = c.latestEncounter?.app {
                            Text(app).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Button { model.speak(c.term) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func wordOfTheDay(_ e: LexEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORD OF THE DAY").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack {
                GenderedWord(display: model.lexicon.display(e), gender: e.gender, pos: e.pos, size: 24)
                Spacer()
                Button { model.speak(e.lemma) } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.borderless)
            }
            Text(e.glossList(model.settings.primaryHelper, limit: 3)).foregroundStyle(.secondary)
            if let other = model.settings.helpers.dropFirst().first {
                Text("\(Theme.flag(other)) \(e.glossList(other, limit: 3))").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Text(model.lexicon.grammarLine(e)).font(.system(size: 11)).foregroundStyle(.tertiary)
            Button("Add to my deck") { model.addWordOfTheDay() }.controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.color(for: e.pos, gender: e.gender).opacity(0.08)))
    }

    private var readCard: some View {
        Button { openSection(.read) } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read a short story").font(.system(size: 13, weight: .semibold))
                    Text("Click any word for its meaning in context").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tipCard: some View {
        let tip = Tips.today
        return VStack(alignment: .leading, spacing: 6) {
            Label("Tipp des Tages", systemImage: "lightbulb").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.warm)
            Text(tip).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.warm.opacity(0.07)))
    }
}

/// Short, practical German-learning tips, one per day.
enum Tips {
    static let all = [
        "Always learn nouns with their article. Lupe colours them: blue der, red die, green das, orange plural.",
        "Nouns ending in -ung, -heit, -keit, -schaft, -ion and -tät are almost always die.",
        "Nouns ending in -chen and -lein are always das: das Mädchen, das Brötchen.",
        "Compound nouns take the gender of their last part: die Haustür (die Tür), der Bahnhof (der Hof).",
        "Two-way prepositions (in, an, auf…): accusative for movement (Wohin?), dative for location (Wo?).",
        "In subordinate clauses (weil, dass, wenn…) the verb goes to the end: …, weil ich müde bin.",
        "Verbs of movement form the Perfekt with sein: ich bin gefahren, ich bin gegangen.",
        "Separable verbs split in main clauses: anrufen → Ich rufe dich morgen an.",
        "Spaced repetition works best in short daily sessions. Five minutes beats an hour once a week.",
        "Say words out loud when you review them. Speaking engages a second memory channel.",
        "Read things you'd read anyway, in German: news, Reddit, recipes. Hold ⌃ when you're stuck.",
        "Watch with German subtitles, not English ones, and use ⌃⌥L to translate a tricky frame.",
        "\"Doch\" contradicts a negative: Kommst du nicht? Doch! (Yes, I am!)",
        "Most masculine nouns ending in -e are weak: der Junge → den Jungen, dem Jungen.",
        "The dative plural adds -n: mit den Kindern, in den Häusern.",
        "Sie (formal you) is capitalised and takes the same verb form as sie (they).",
        "Feierabend is the time after work. Germans protect it fiercely. Schönen Feierabend!",
        "Word order is flexible, but the verb stays second: Heute gehe ich ins Kino.",
    ]

    static var today: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return all[day % all.count]
    }
}
