import LupeCore
import SwiftUI

/// What the hover card is showing right now.
@MainActor
final class LookupCardState: ObservableObject {
    enum Phase {
        case loading(String)
        case ready(LookupResult)
        case hint(title: String, message: String, action: String?)
    }

    enum Saved: Equatable {
        case none
        case saved(UUID, created: Bool)
        case known
    }

    @Published var phase: Phase = .loading("")
    @Published var saved: Saved = .none
    @Published var explanation: String?
    @Published var explaining = false
    /// Set by the controller from the current tutor.
    @Published var canExplain = true
    @Published var aiLabel = "AI note"

    func reset(_ phase: Phase) {
        self.phase = phase
        saved = .none
        explanation = nil
        explaining = false
    }

    var result: LookupResult? {
        if case .ready(let r) = phase { return r }
        return nil
    }
}

/// Callbacks from the card back to the controller.
struct LookupCardActions {
    var speak: (String) -> Void = { _ in }
    var save: () -> Void = {}
    var undo: () -> Void = {}
    var markKnown: () -> Void = {}
    var explain: () -> Void = {}
    var hintAction: () -> Void = {}
}

struct LookupCardView: View {
    @ObservedObject var state: LookupCardState
    var lexicon: Lexicon
    var helpers: [String]
    var actions: LookupCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.phase {
            case .loading(let word):
                loading(word)
            case .ready(let r):
                ready(r)
            case .hint(let title, let message, let action):
                hint(title: title, message: message, action: action)
            }
        }
        .frame(width: 340, alignment: .leading)
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: Phases

    private func loading(_ word: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(word.isEmpty ? "Reading…" : word)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }

    private func hint(title: String, message: String, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: actions.hintAction).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func ready(_ r: LookupResult) -> some View {
        let entry = r.entry
        // When the word only makes sense as part of an expression, the expression leads and the word steps back.
        let wordIsSecondary = r.expression != nil && !r.confirmedByContext
        VStack(alignment: .leading, spacing: 10) {
            if let ex = r.expression {
                if ex.german == r.entry?.lemma {
                    // "gave up" → aufhören: the expression *is* the headword; just say which words it covers.
                    HStack(spacing: 5) {
                        Text("IN THIS SENTENCE").font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                        Text("\(Theme.flag(r.sourceLanguage)) \(ex.source)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    expressionBox(ex, r)
                }
            }
            if wordIsSecondary, let entry {
                HStack(spacing: 6) {
                    Text("On its own:").font(.system(size: 11)).foregroundStyle(.tertiary)
                    GenderedWord(display: r.headword, gender: entry.gender, pos: entry.pos, size: 13, weight: .medium)
                    Text("· \(entry.gloss(helpers.first ?? "en") ?? "")").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
            // Headword
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                GenderedWord(display: r.headword, gender: entry?.gender, pos: entry?.pos,
                             size: r.expression == nil || r.expression?.german == entry?.lemma ? 24 : 19)
                Spacer(minLength: 4)
                Button { actions.speak(entry?.lemma ?? r.term) } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Pronounce")
            }
            // Grammar line
            if let entry {
                HStack(spacing: 6) {
                    Tag(text: entry.pos.label, color: Theme.color(for: entry.pos, gender: entry.gender))
                    if !entry.forms.isEmpty {
                        Text(entry.pos == .noun ? "pl. \(entry.forms)" : entry.forms)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else if entry.pos == .noun {
                        Text("no plural").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if entry.rank < 20_000 { Tag(text: entry.cefr, color: .secondary) }
                }
                if let head = r.compoundHead {
                    Text("Compound: …\(head.lemma.lowercased()) decides the gender (\(lexicon.display(head)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if r.direction == .fromTarget, r.expression == nil, let here = r.senseHere {
                HStack(spacing: 5) {
                    Text("here").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                    Text(here).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            // Meanings
            VStack(alignment: .leading, spacing: 3) {
                ForEach(helpers, id: \.self) { h in
                    if let m = r.meanings[h], !(r.direction == .toTarget && h == r.sourceLanguage && m.lowercased() == r.word.lowercased()) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Theme.flag(h)).font(.system(size: 11))
                            Text(m).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                        }
                    }
                }
            }
            if !r.confirmedByContext {
                Label("In this sentence it's probably a different word, so check the translation below.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Theme.warm)
                    .fixedSize(horizontal: false, vertical: true)
            }
            } // end of single-word block
            // Context
            if !r.context.isEmpty && r.context != r.word {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(highlight(r.context, word: r.word, range: nil, color: .primary))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    if let t = r.contextTranslation {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(highlight(t, word: r.aligned, range: r.alignedRange, color: Theme.color(for: entry?.pos, gender: entry?.gender)))
                                .font(.system(size: 12.5))
                                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !r.confusables.isEmpty { ConfusablesBox(items: r.confusables, speak: actions.speak) }
            if state.explaining {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Thinking…").font(.system(size: 11)).foregroundStyle(.secondary) }
            } else if let e = state.explanation {
                VStack(alignment: .leading, spacing: 4) {
                    Label(state.aiLabel, systemImage: "sparkles").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(e).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            footer(r)
        }
        .padding(14)
    }

    /// "In this sentence: zu spät · running late" or an idiom from the pack.
    private func expressionBox(_ ex: ContextExpression, _ r: LookupResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ex.origin == .pack ? "EXPRESSION" : "IN THIS SENTENCE")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(Theme.accent)
                Spacer()
                Button { actions.speak(ex.german) } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)) }
                    .buttonStyle(.borderless)
            }
            Text(ex.german)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            if r.direction == .toTarget {
                HStack(spacing: 5) {
                    Text(Theme.flag(r.sourceLanguage)).font(.system(size: 11))
                    Text(ex.source).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if !ex.meaning.isEmpty && (r.direction == .fromTarget || ex.origin == .pack) && ex.meaning != ex.source {
                HStack(spacing: 5) {
                    Text(Theme.flag(helpers.first ?? "en")).font(.system(size: 11))
                    Text(ex.meaning).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.85))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))
    }

    private func footer(_ r: LookupResult) -> some View {
        HStack(spacing: 8) {
            switch state.saved {
            case .saved(_, let created):
                Label(created ? "Added to your deck" : "Already in your deck", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.success)
                if created {
                    Button("Undo", action: actions.undo).buttonStyle(.link).font(.system(size: 11))
                }
            case .known:
                Label("Marked as known", systemImage: "hand.thumbsup.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            case .none:
                Button(action: actions.save) { Label("Save", systemImage: "plus.circle") }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
            }
            Spacer()
            if state.saved != .known {
                Button("I know it", action: actions.markKnown).buttonStyle(.borderless).font(.system(size: 11))
            }
            if state.canExplain && r.contextTranslation != nil && state.explanation == nil {
                Button(action: actions.explain) { Label("Explain", systemImage: "sparkles") }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
    }

    /// Bold + coloured word inside a sentence.
    private func highlight(_ text: String, word: String?, range: Range<String.Index>?, color: Color) -> AttributedString {
        var a = AttributedString(text)
        var target: Range<String.Index>? = range
        if target == nil, let word, !word.isEmpty { target = text.range(of: word) }
        guard let target, target.lowerBound >= text.startIndex, target.upperBound <= text.endIndex,
              let lo = AttributedString.Index(target.lowerBound, within: a),
              let hi = AttributedString.Index(target.upperBound, within: a) else { return a }
        a[lo..<hi].font = .system(size: 12.5, weight: .bold)
        a[lo..<hi].foregroundColor = color
        return a
    }
}

/// "Don't mix up": a word next to the words learners confuse it with, each with when to use it.
struct ConfusablesBox: View {
    var items: [Confusable]
    var speak: (String) -> Void
    var wordWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(items.contains { $0.curated } ? "DON'T MIX UP" : "SIMILAR MEANING", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Theme.warm)
            ForEach(items) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GenderedWord(display: c.display, gender: c.entry?.gender, pos: c.entry?.pos, size: 13,
                                 weight: c.isCurrent ? .bold : .semibold)
                        .frame(minWidth: wordWidth, alignment: .leading)
                        .fixedSize()
                    Text(c.note).font(.system(size: 11)).foregroundStyle(c.isCurrent ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(c.isCurrent ? 1 : 0.92)
                .contentShape(Rectangle())
                .onTapGesture { speak(c.entry?.lemma ?? c.display) }
                .help("Click to hear it")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warm.opacity(0.07)))
    }
}
