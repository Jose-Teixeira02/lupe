import AppKit
import LupeCore
import SwiftUI

/// Reading room: graded stories (or your own text) where every word is clickable and explained in context.
@MainActor
final class ReadingState: ObservableObject {
    @Published var stories: [Story] = []
    @Published var storyID: String?
    @Published var customText: String?
    @Published var paragraphs: [ReadingParagraph] = []
    @Published var selected: Int?
    @Published var showGenders = true
    @Published var showMine = true
    @Published var translations: [Int: String] = [:]
    @Published var showPaste = false
    @Published var pasteDraft = ""
    let card = LookupCardState()

    private let model: AppModel
    private var lookupTask: Task<Void, Never>?
    private var lastApp: String? = "Lupe · Reading"

    init(model: AppModel) {
        self.model = model
    }

    private var storiesLanguage: String?

    func loadStories() {
        guard storiesLanguage != model.target else { return }
        storiesLanguage = model.target
        stories = Story.load(language: model.target)
        storyID = nil
        customText = nil
        paragraphs = []
        if storyID == nil, customText == nil, let first = stories.first { open(first) }
    }

    var title: String {
        if customText != nil { return "Your text" }
        return stories.first { $0.id == storyID }?.title ?? "Reading"
    }

    var level: String? {
        customText == nil ? stories.first { $0.id == storyID }?.level : nil
    }

    func open(_ story: Story) {
        storyID = story.id
        customText = nil
        parse(story.text)
    }

    func openPasted() {
        let text = pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        customText = String(text.prefix(20_000))
        storyID = nil
        showPaste = false
        parse(customText!)
    }

    private var parseTask: Task<Void, Never>?

    private func parse(_ text: String) {
        selected = nil
        translations = [:]
        card.reset(.loading(""))
        parseTask?.cancel()
        let engine = model.engine
        parseTask = Task {
            let parsed = await Task.detached(priority: .userInitiated) { ReadingDocument.parse(text, engine: engine) }.value
            guard !Task.isCancelled else { return }
            paragraphs = parsed
        }
    }

    // MARK: Words

    func select(_ token: ReadingToken) {
        guard let p = paragraphs.first(where: { $0.id == token.paragraph }),
              let (sentence, range) = ReadingDocument.sentence(around: token.range, in: p.text) else { return }
        selected = token.id
        card.reset(.loading(token.text))
        lookupTask?.cancel()
        lookupTask = Task {
            let r = await model.engine.lookup(word: token.text, context: sentence, wordRange: range, languageHint: p.language)
            guard !Task.isCancelled else { return }
            card.reset(.ready(r))
            card.canExplain = model.canExplain
            card.aiLabel = model.aiLabel
            model.journey.record(.lookup)
            if model.settings.autoSaveLookups, r.isConfident, HoverController.isWorthSaving(r) {
                let (c, created) = model.save(r, source: .manual, app: lastApp)
                card.saved = .saved(c.id, created: created)
            }
            if model.settings.speakOnLookup, let lemma = r.entry?.lemma { model.speak(lemma) }
        }
    }

    var cardActions: LookupCardActions {
        LookupCardActions(
            speak: { [weak self] text in self?.model.speak(text) },
            save: { [weak self] in
                guard let self, let r = self.card.result else { return }
                let (c, created) = self.model.save(r, source: .manual, app: self.lastApp)
                self.card.saved = .saved(c.id, created: created)
            },
            undo: { [weak self] in
                guard let self else { return }
                if case .saved(let id, true) = self.card.saved { self.model.bank.remove(id) }
                self.card.saved = .none
            },
            markKnown: { [weak self] in
                guard let self, let r = self.card.result else { return }
                var saved: UUID?
                if case .saved(let id, _) = self.card.saved { saved = id }
                self.model.markKnown(r, savedCard: saved)
                self.card.saved = .known
            },
            explain: { [weak self] in self?.explain() }
        )
    }

    private func explain() {
        guard let r = card.result else { return }
        card.explaining = true
        let german = r.direction == .fromTarget ? r.context : (r.contextTranslation ?? r.headword)
        let other = r.direction == .fromTarget ? r.contextTranslation : r.context
        Task {
            card.explanation = (try? await model.tutor.explain(sentence: german, translation: other, focus: r.entry?.lemma ?? r.headword,
                                                               explainIn: model.settings.primaryHelper)) ?? "Couldn't explain this one."
            card.explaining = false
        }
    }

    // MARK: Paragraphs

    func toggleTranslation(_ p: ReadingParagraph) {
        if translations[p.id] != nil {
            translations[p.id] = nil
            return
        }
        translations[p.id] = "…"
        let to = p.language == model.target ? model.settings.primaryHelper : model.target
        Task {
            translations[p.id] = (try? await model.translator.translate(p.text, from: p.language, to: to)) ?? "Couldn't translate this paragraph."
        }
    }

    func speak(_ p: ReadingParagraph) {
        if p.language == model.target { model.speak(p.text) }
    }

    func isInDeck(_ t: ReadingToken) -> Bool {
        guard let e = t.entry else { return false }
        return model.bank.card(forKey: e.id) != nil
    }
}

struct ReadingView: View {
    @ObservedObject var state: ReadingState
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(state.title).font(.system(size: 26, weight: .bold, design: .rounded))
                            if let level = state.level, !level.isEmpty { Tag(text: level, color: Theme.accent) }
                        }
                        ForEach(state.paragraphs) { p in paragraph(p) }
                    }
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            side.frame(width: 350)
        }
        .onAppear { state.loadStories() }
        .sheet(isPresented: $state.showPaste) { pasteSheet }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(state.stories) { s in
                    Button("\(s.level.isEmpty ? "" : s.level + " · ")\(s.title)") { state.open(s) }
                }
                Divider()
                Button("Paste your own text…") { state.showPaste = true }
            } label: {
                Label(state.title, systemImage: "book")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Toggle("Genders", isOn: $state.showGenders).toggleStyle(.checkbox).fixedSize()
                .help("Colour German nouns: der blue, die red, das green")
            Toggle("My words", isOn: $state.showMine).toggleStyle(.checkbox).fixedSize()
                .help("Underline words that are already in your deck")
            Button { state.showPaste = true } label: { Image(systemName: "doc.on.clipboard") }
                .help("Read your own text")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private func paragraph(_ p: ReadingParagraph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 0, lineSpacing: 7) {
                if !p.leading.isEmpty { Text(p.leading).font(.system(size: 17)) }
                ForEach(p.tokens) { t in token(t) }
            }
            HStack(spacing: 12) {
                if p.language == model.target {
                    Button { state.speak(p) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                }
                Button { state.toggleTranslation(p) } label: {
                    Label(state.translations[p.id] == nil ? "Translate" : "Hide translation", systemImage: "character.bubble")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let t = state.translations[p.id] {
                Text(t).font(.system(size: 14)).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .textSelection(.enabled)
            }
        }
    }

    private func token(_ t: ReadingToken) -> some View {
        let selected = state.selected == t.id
        let color: Color = state.showGenders && t.entry?.pos == .noun ? Theme.color(for: t.entry?.gender) : .primary
        let mine = state.showMine && state.isInDeck(t)
        return HStack(spacing: 0) {
            Text(t.text)
                .font(.system(size: 17, weight: t.entry?.pos == .noun && state.showGenders ? .medium : .regular))
                .foregroundStyle(color)
                .underline(mine, color: Theme.warm.opacity(0.8))
                .padding(.horizontal, selected ? 2 : 0)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { state.select(t) }
                .help(t.entry.map { "\(model.lexicon.display($0)) · \($0.gloss(model.settings.primaryHelper) ?? "")" } ?? "")
            if !t.trailing.isEmpty {
                Text(t.trailing).font(.system(size: 17))
            }
        }
    }

    @ViewBuilder
    private var side: some View {
        if state.selected == nil {
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                Image(systemName: "hand.point.up.left").font(.system(size: 30)).foregroundStyle(Theme.accent)
                Text("Click any word").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("You'll get its meaning in this sentence, its article and forms, and the expression it belongs to. Words you look up go to your deck with the sentence.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Tag(text: "der", color: Theme.der); Tag(text: "die", color: Theme.die)
                    Tag(text: "das", color: Theme.das); Tag(text: "plural", color: Theme.plural)
                }
                Spacer()
            }
            .padding(24)
        } else {
            ScrollView {
                LookupCardView(state: state.card, lexicon: model.lexicon, helpers: model.settings.helpers, actions: state.cardActions)
                    .padding(10)
            }
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read your own text").font(.system(size: 18, weight: .semibold, design: .rounded))
            Text("Paste an article, a message or song lyrics you own, in German, English or Portuguese.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $state.pasteDraft)
                .font(.system(size: 13))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Paste from clipboard") {
                    state.pasteDraft = NSPasteboard.general.string(forType: .string) ?? state.pasteDraft
                }
                Spacer()
                Button("Cancel") { state.showPaste = false }.keyboardShortcut(.cancelAction)
                Button("Read") { state.openPasted() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(state.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
