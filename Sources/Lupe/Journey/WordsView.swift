import AppKit
import LupeCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WordsState: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", due = "Due", learning = "Learning", mature = "Mature", known = "Known", phrases = "Phrases"
        var id: String { rawValue }
    }

    @Published var search = ""
    @Published var filter: Filter = .all
    @Published var selected: UUID?
    @Published var notesDraft = ""
}

/// Browse, search and edit your deck; export to Anki.
struct WordsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WordsState

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                list
            }
            .frame(minWidth: 360)
            Divider()
            detail.frame(width: 340)
        }
    }

    private var filtered: [Card] {
        let q = state.search.lowercased().trimmingCharacters(in: .whitespaces)
        let now = Date()
        return model.bank.cards.filter { c in
            switch state.filter {
            case .all: break
            case .due: guard c.status == .active, c.memory.due <= now else { return false }
            case .learning: guard c.status == .active, c.memory.state != .review else { return false }
            case .mature: guard c.memory.isMature else { return false }
            case .known: guard c.status == .known else { return false }
            case .phrases: guard c.kind == .phrase else { return false }
            }
            if q.isEmpty { return true }
            return c.display.lowercased().contains(q) || c.meanings.values.contains { $0.lowercased().contains(q) }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search German, English or Português", text: $state.search).textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Picker("", selection: $state.filter) {
                ForEach(WordsState.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Menu {
                Button("Anki (tab-separated)…") { export(anki: true) }
                Button("CSV…") { export(anki: false) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .help("Export your deck")
        }
        .padding(12)
    }

    private var list: some View {
        let cards = filtered
        return Group {
            if cards.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.bank.cards.isEmpty ? "Your deck is empty" : "No matches").foregroundStyle(.secondary)
                    if model.bank.cards.isEmpty {
                        Text("Hold ⌃ over words in any app. They land here with the sentence you met them in.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 280)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $state.selected) {
                    ForEach(cards) { c in
                        row(c).tag(c.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ c: Card) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.color(for: c.pos, gender: c.gender)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                GenderedWord(display: c.display, gender: c.gender, pos: c.pos, size: 14)
                Text(c.meaning(model.settings.primaryHelper)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            statusBadge(c)
        }
        .padding(.vertical, 3)
    }

    private func statusBadge(_ c: Card) -> some View {
        let (text, color): (String, Color) = {
            if c.status == .known { return ("known", .secondary) }
            if c.status == .suspended { return ("paused", .secondary) }
            switch c.memory.state {
            case .new: return ("new", Theme.neutral)
            case .learning, .relearning: return ("learning", Theme.warm)
            case .review:
                if c.memory.due <= Date() { return ("due", Theme.accent) }
                return (FSRS.format(c.memory.due.timeIntervalSinceNow), c.memory.isMature ? Theme.das : Theme.der)
            }
        }()
        return Tag(text: text, color: color)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = state.selected, let c = model.bank.card(id: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        GenderedWord(display: c.display, gender: c.gender, pos: c.pos, size: 28)
                        Spacer()
                        Button { model.speak(c.term) } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.borderless)
                    }
                    if let pos = c.pos {
                        HStack {
                            Tag(text: pos.label, color: Theme.color(for: pos, gender: c.gender))
                            if !c.forms.isEmpty { Text(pos == .noun ? "pl. \(c.forms)" : c.forms).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(c.meanings.keys.sorted(), id: \.self) { k in
                            Text("\(Theme.flag(k)) \(c.meanings[k] ?? "")").font(.system(size: 13))
                        }
                    }
                    if !c.encounters.isEmpty {
                        Text("WHERE YOU MET IT").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                        ForEach(Array(c.encounters.reversed().enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.sentence).font(.system(size: 12)).textSelection(.enabled)
                                if let t = e.translation { Text(t).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                                Text([e.app, e.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        }
                    }
                    Text("NOTES").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { c.notes ?? "" }, set: { model.bank.updateNotes(c.id, notes: $0) }))
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    scheduleInfo(c)
                    HStack {
                        if c.status == .known {
                            Button("Learn again") { model.bank.setStatus(c.id, .active) }
                        } else {
                            Button("I know it") { model.bank.setStatus(c.id, .known) }
                        }
                        Button(c.status == .suspended ? "Resume" : "Pause") {
                            model.bank.setStatus(c.id, c.status == .suspended ? .active : .suspended)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.bank.remove(c.id)
                            state.selected = nil
                        } label: { Image(systemName: "trash") }
                    }
                    .controlSize(.small)
                }
                .padding(18)
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("\(model.bank.cards.count)").font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("words and phrases in your deck").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func scheduleInfo(_ c: Card) -> some View {
        let m = c.memory
        return VStack(alignment: .leading, spacing: 2) {
            Text("MEMORY").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
            Text(m.state == .new ? "Not reviewed yet" :
                    "Next review \(m.due.formatted(date: .abbreviated, time: .shortened)) · stability \(String(format: "%.1f", m.stability))d · \(m.reps) reviews · \(m.lapses) lapses")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func export(anki: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = anki ? "lupe-\(model.target)-anki.txt" : "lupe-\(model.target).csv"
        panel.allowedContentTypes = anki ? [.plainText] : [.commaSeparatedText]
        let text = anki ? DeckExporter.ankiTSV(model.bank.cards) : DeckExporter.csv(model.bank.cards)
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
