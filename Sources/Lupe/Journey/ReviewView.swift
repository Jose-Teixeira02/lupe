import LupeCore
import SwiftUI

/// One review sitting: due cards first, then a few new ones. Cards you miss come back in the same session.
@MainActor
final class ReviewSession: ObservableObject {
    @Published private(set) var queue: [UUID] = []
    @Published private(set) var current: Card?
    @Published var revealed = false
    @Published private(set) var reviewed = 0
    @Published private(set) var correct = 0
    @Published private(set) var started = false
    @Published private(set) var startedAt = Date()
    /// Cards in a short learning step that will come back later today (not shown again right away).
    @Published private(set) var comingBack = 0
    @Published var confirmingRemove = false

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var finished: Bool { started && current == nil }
    var remaining: Int { queue.count + (current == nil ? 0 : 1) }

    func start() {
        queue = model.bank.dueQueue(newLimit: model.settings.dailyNewCards).map(\.id)
        reviewed = 0
        correct = 0
        comingBack = 0
        started = true
        startedAt = Date()
        next()
    }

    func stop() {
        started = false
        current = nil
        queue = []
    }

    private func next() {
        revealed = false
        while let id = queue.first {
            queue.removeFirst()
            if let c = model.bank.card(id: id), c.status == .active {
                current = c
                if isRecognition(c) { model.speak(c.term) }
                return
            }
        }
        current = nil
    }

    func reveal() {
        guard let c = current, !revealed else { return }
        revealed = true
        if !isRecognition(c) { model.speak(c.term) }
    }

    func rate(_ rating: Rating) {
        guard let c = current, revealed else { return }
        model.bank.review(c.id, rating: rating)
        reviewed += 1
        if rating != .again { correct += 1 }
        // Short learning steps come back later in this session, but only after a few other cards;
        // seeing the same card again immediately teaches nothing.
        if let updated = model.bank.card(id: c.id), updated.memory.due.timeIntervalSinceNow < 20 * 60 {
            let gap = rating == .again ? 3 : 6
            if !queue.isEmpty {
                queue.insert(c.id, at: min(queue.count, gap))
            } else {
                comingBack += 1
            }
        }
        next()
    }

    /// A card that shouldn't be there (a wrong lookup, a word you don't want) leaves the deck from the review itself.
    func removeCurrent() {
        guard let c = current else { return }
        model.bank.remove(c.id)
        queue.removeAll { $0 == c.id }
        next()
    }

    func preview(for c: Card) -> [Rating: String] {
        var out: [Rating: String] = [:]
        for (r, t) in model.bank.scheduler.preview(c.memory) { out[r] = FSRS.format(t) }
        return out
    }

    /// Cards met while reading German test recognition (German → meaning); others test production.
    func isRecognition(_ c: Card) -> Bool {
        guard c.kind == .word, let e = c.latestEncounter else { return false }
        return e.language == model.target
    }
}

struct ReviewView: View {
    @ObservedObject var session: ReviewSession
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !session.started {
                startScreen
            } else if let card = session.current {
                progressBar
                ScrollView {
                    cardView(card).padding(.horizontal, 40).padding(.top, 30)
                }
                controls(card)
            } else {
                finishedScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Screens

    private var startScreen: some View {
        let due = model.bank.dueQueue(newLimit: model.settings.dailyNewCards)
        let newCount = due.filter { $0.memory.state == .new }.count
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: due.isEmpty ? "checkmark.seal.fill" : "rectangle.stack.fill")
                .font(.system(size: 54)).foregroundStyle(due.isEmpty ? Theme.success : Theme.accent)
            if due.isEmpty {
                Text("All caught up").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Nothing is due. Go read something in German or English and hold ⌃ on words you don't know: they'll show up here.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            } else {
                Text(due.count == 1 ? "1 card ready" : "\(due.count) cards ready").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(due.count - newCount) reviews · \(newCount) new · about \(max(1, due.count / 6)) min")
                    .foregroundStyle(.secondary)
                Button { session.start() } label: {
                    Text("Start review").font(.system(size: 15, weight: .semibold)).frame(width: 200, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Text("Space to reveal · 1 2 3 4 to rate").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(40)
    }

    private var finishedScreen: some View {
        let accuracy = session.reviewed == 0 ? 0 : Int(Double(session.correct) / Double(session.reviewed) * 100)
        let minutes = max(1, Int(Date().timeIntervalSince(session.startedAt) / 60))
        return VStack(spacing: 16) {
            Spacer()
            Text("🎉").font(.system(size: 54))
            Text("Fertig! Session complete").font(.system(size: 26, weight: .bold, design: .rounded))
            HStack(spacing: 28) {
                stat("\(session.reviewed)", "cards")
                stat("\(accuracy)%", "remembered")
                stat("\(minutes) min", "time")
                stat("🔥 \(model.journey.streak)", "day streak")
            }
            Text(encouragement(accuracy)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if session.comingBack > 0 {
                Label(session.comingBack == 1 ? "1 card comes back in a few minutes for a second look."
                      : "\(session.comingBack) cards come back in a few minutes for a second look.", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Done") { session.stop() }.keyboardShortcut(.defaultAction)
            Spacer()
        }
        .padding(40)
    }

    private func encouragement(_ accuracy: Int) -> String {
        switch accuracy {
        case 90...: "Excellent memory. These words are settling in for the long term."
        case 70..<90: "Solid work. The ones you missed will come back sooner, and that's how they stick."
        default: "Tough round, and that's normal: forgetting and re-learning is exactly what makes memories durable."
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var progressBar: some View {
        let total = session.reviewed + session.remaining
        return HStack(spacing: 10) {
            ProgressView(value: Double(session.reviewed), total: Double(max(total, 1)))
                .tint(Theme.accent)
            Text("\(session.remaining) left").font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            Button { session.confirmingRemove = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                .help("Remove this card from your deck (a wrong translation, or a word you don't need)")
            Button { session.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("End session")
        }
        .padding(.horizontal, 24).padding(.top, 16)
        .confirmationDialog("Remove “\(session.current?.display ?? "")” from your deck?", isPresented: $session.confirmingRemove) {
            Button("Remove card", role: .destructive) { session.removeCurrent() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Its review history goes too. You can always look it up again.")
        }
    }

    // MARK: Card

    @ViewBuilder
    private func cardView(_ c: Card) -> some View {
        let recognition = session.isRecognition(c)
        let encounter = c.latestEncounter
        let color = Theme.color(for: c.pos, gender: c.gender)
        VStack(spacing: 22) {
            // Prompt side
            VStack(spacing: 10) {
                Text(recognition ? "WHAT DOES IT MEAN?" : (c.kind == .phrase ? "SAY IT IN \(model.lexicon.info.nativeName.uppercased())" : "HOW DO YOU SAY IT?"))
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                if recognition {
                    GenderedWord(display: c.display, gender: c.gender, pos: c.pos, size: 38)
                    if let s = encounter?.sentence {
                        Text(highlight(s, form: encounter?.targetForm ?? c.term, color: color))
                            .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                } else {
                    Text(c.meaning(model.settings.primaryHelper))
                        .font(.system(size: c.kind == .phrase ? 24 : 34, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    if let other = model.settings.helpers.dropFirst().first, let m = c.meanings[other], m != c.meaning(model.settings.primaryHelper) {
                        Text("\(Theme.flag(other)) \(m)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if c.kind == .word, let ts = encounter?.targetSentence(target: model.target), let form = encounter?.targetForm,
                       ts.contains(form), !session.revealed {
                        Text(Self.cloze(ts, hiding: form))
                            .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if c.kind == .word, let g = c.gender, !session.revealed {
                        Text("noun · \(genderHint(g))").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            if session.revealed {
                Divider().frame(maxWidth: 360)
                VStack(spacing: 10) {
                    if recognition {
                        Text(c.meaning(model.settings.primaryHelper)).font(.system(size: 26, weight: .semibold, design: .rounded))
                        if let other = model.settings.helpers.dropFirst().first, let m = c.meanings[other] {
                            Text("\(Theme.flag(other)) \(m)").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let t = encounter?.translation {
                            Text(t).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    } else {
                        HStack(spacing: 10) {
                            GenderedWord(display: c.display, gender: c.gender, pos: c.pos, size: c.kind == .phrase ? 26 : 40)
                            Button { model.speak(c.term) } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.borderless)
                        }
                        if c.kind == .word, !c.forms.isEmpty {
                            Text(c.pos == .noun ? "plural: \(c.forms)" : c.forms).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if let ts = encounter?.targetSentence(target: model.target) {
                            Text(highlight(ts, form: encounter?.targetForm ?? c.term, color: color))
                                .font(.system(size: 15)).multilineTextAlignment(.center)
                        }
                    }
                    if let e = encounter {
                        HStack(spacing: 6) {
                            Image(systemName: "eye").font(.system(size: 10))
                            Text(metLine(e)).font(.system(size: 11))
                        }
                        .foregroundStyle(.tertiary)
                        if e.language != model.target && !recognition {
                            Text("“\(e.sentence)”").font(.system(size: 12)).italic().foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    if let notes = c.notes {
                        Text(notes).font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: 560)
        .padding(.vertical, 34).padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(alignment: .top) {
            Rectangle().fill(color).frame(height: 4).clipShape(Capsule()).padding(.horizontal, 60)
        }
        .animation(.easeOut(duration: 0.18), value: session.revealed)
    }

    /// Blanks whole-word occurrences of `form` only ("Buch" but not "Buchhandlung").
    static func cloze(_ sentence: String, hiding form: String) -> String {
        var out = sentence
        for r in TextTools.wordRanges(in: sentence).reversed() where sentence[r].caseInsensitiveCompare(form) == .orderedSame {
            out.replaceSubrange(r, with: "＿＿＿")
        }
        return out
    }

    private func genderHint(_ g: Gender) -> String {
        "(der, die or das?)"
    }

    private func metLine(_ e: Encounter) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let when = f.localizedString(for: e.date, relativeTo: Date())
        if let app = e.app { return "Met in \(app), \(when)" }
        return "Met \(when)"
    }

    private func highlight(_ text: String, form: String, color: Color) -> AttributedString {
        var a = AttributedString(text)
        if let r = a.range(of: form, options: .caseInsensitive) {
            a[r].foregroundColor = color
            a[r].font = .system(size: 15, weight: .bold)
        }
        return a
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ c: Card) -> some View {
        HStack(spacing: 10) {
            if session.revealed {
                let preview = session.preview(for: c)
                rateButton(.again, color: Theme.die, interval: preview[.again] ?? "", key: "1")
                rateButton(.hard, color: Theme.warm, interval: preview[.hard] ?? "", key: "2")
                rateButton(.good, color: Theme.das, interval: preview[.good] ?? "", key: "3")
                rateButton(.easy, color: Theme.der, interval: preview[.easy] ?? "", key: "4")
            } else {
                Button { session.reveal() } label: {
                    Text("Show answer").font(.system(size: 14, weight: .semibold)).frame(width: 220, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.02))
    }

    private func rateButton(_ r: Rating, color: Color, interval: String, key: Character) -> some View {
        Button { session.rate(r) } label: {
            VStack(spacing: 2) {
                Text(r.label).font(.system(size: 13, weight: .semibold))
                Text(interval).font(.system(size: 10, design: .rounded)).opacity(0.75)
            }
            .frame(width: 96, height: 40)
            .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.14)))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
        .help("Key \(key)")
    }
}
