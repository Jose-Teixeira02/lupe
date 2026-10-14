import LupeCore
import SwiftUI

@MainActor
final class AskState: ObservableObject {
    @Published var input = ""
    @Published var result: PhraseResult?
    @Published var loading = false
    @Published var error: String?
    @Published var corrected: String?
    @Published var diff: [WordDiff.Op] = []
    @Published var proofreading = false
    @Published var explanation: String?
    @Published var explaining = false
    @Published var toast: String?
    /// Bumped to move focus back to the text field.
    @Published var focusToken = 0

    func clearResults() {
        result = nil
        error = nil
        corrected = nil
        diff = []
        explanation = nil
        proofreading = false
        explaining = false
    }
}

struct AskActions {
    var copyAndClose: () -> Void = {}
    var save: () -> Void = {}
    var speak: (String) -> Void = { _ in }
    var check: () -> Void = {}
    var explainCorrection: () -> Void = {}
    var close: () -> Void = {}
    var useRecent: (String) -> Void = { _ in }
}

/// Spotlight-style bar: type English/Portuguese → German; type German → meaning + grammar check.
struct AskView: View {
    @ObservedObject var state: AskState
    @ObservedObject var model: AppModel
    var actions: AskActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if hasContent { Divider().opacity(0.6) }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warm)
                    .padding(16)
            } else if let r = state.result {
                result(r).padding(16)
            } else if state.input.isEmpty && !model.recentAsks.isEmpty {
                recents.padding(.vertical, 8)
            }
            footer
        }
        .frame(width: 640)
        .background(VisualEffect(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear { focused = true }
        .onChange(of: state.focusToken) { _, _ in focused = true }
        .onExitCommand(perform: actions.close)
    }

    private var hasContent: Bool {
        state.result != nil || state.error != nil || (state.input.isEmpty && !model.recentAsks.isEmpty)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.magnify")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
            TextField("How do I say…?  Type English, Português, or Deutsch to check it", text: $state.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(actions.copyAndClose)
            if state.loading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func result(_ r: PhraseResult) -> some View {
        let intoTarget = r.outputLanguage == model.target
        VStack(alignment: .leading, spacing: 12) {
            if intoTarget {
                // English/Portuguese → German
                HStack(alignment: .top, spacing: 10) {
                    Text(Theme.flag(model.target)).font(.system(size: 18))
                    Text(r.output)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    iconButton("speaker.wave.2.fill", help: "Listen") { actions.speak(r.output) }
                    iconButton("doc.on.doc", help: "Copy (⏎)") { actions.copyAndClose() }
                    iconButton("plus.circle", help: "Save phrase (⌘S)") { actions.save() }
                        .keyboardShortcut("s", modifiers: .command)
                }
                if !(isSingleWord(r) && !r.senses.isEmpty) { breakdown(r.breakdown) }
                sensesRow(r)
            } else {
                // German → meaning (+ grammar check)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(Theme.flag(r.outputLanguage)).font(.system(size: 16))
                        Text(r.output).font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        iconButton("speaker.wave.2.fill", help: "Listen to your German") { actions.speak(r.input) }
                        iconButton("plus.circle", help: "Save phrase (⌘S)") { actions.save() }
                            .keyboardShortcut("s", modifiers: .command)
                    }
                    if let s = r.secondaryOutput, let lang = r.secondaryLanguage {
                        HStack(spacing: 10) {
                            Text(Theme.flag(lang)).font(.system(size: 13))
                            Text(s).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !isSingleWord(r) { checkSection(r) }
                sensesRow(r)
                if !(isSingleWord(r) && !r.senses.isEmpty) { breakdown(r.breakdown) }
            }
            if let toast = state.toast {
                Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.success)
            }
        }
    }

    @ViewBuilder
    private func checkSection(_ r: PhraseResult) -> some View {
        if state.proofreading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.tutor.isOnDevice ? "Checking your German on-device…" : "Asking Claude…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if let corrected = state.corrected {
            let same = WordDiff.isEquivalent(r.input, corrected)
            VStack(alignment: .leading, spacing: 8) {
                if same {
                    Label("Looks correct. Schön!", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.success)
                } else {
                    Label("Suggested fix", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warm)
                    diffText.font(.system(size: 17, design: .rounded)).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button { actions.speak(corrected) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                        Button { actions.explainCorrection() } label: { Label("Why?", systemImage: "questionmark.circle") }
                            .disabled(state.explaining || state.explanation != nil)
                            .keyboardShortcut("e", modifiers: .command)
                    }
                    .buttonStyle(.borderless).font(.system(size: 12))
                }
                if state.explaining {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Explaining…").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if let e = state.explanation {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(model.aiLabel, systemImage: "sparkles")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Text(e).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        } else if model.canExplain {
            Button { actions.check() } label: { Label("Check my German", systemImage: "checkmark.bubble") }
                .buttonStyle(.borderless).font(.system(size: 12))
                .keyboardShortcut("k", modifiers: .command)
        }
    }

    private func isSingleWord(_ r: PhraseResult) -> Bool { !r.input.contains(" ") }

    /// "Depending on context: die Bank (money) · das Ufer (river)".
    @ViewBuilder
    private func sensesRow(_ r: PhraseResult) -> some View {
        if !r.senses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.inputLanguage == model.target ? "THIS WORD CAN MEAN" : "DEPENDING ON CONTEXT")
                    .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(r.senses) { g in
                        HStack(spacing: 5) {
                            if r.inputLanguage != model.target {
                                Text(g.display).font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.color(for: g.entry?.pos, gender: g.entry?.gender))
                            }
                            if let m = g.meaning { Text(m).font(.system(size: 11)).foregroundStyle(r.inputLanguage == model.target ? .primary : .secondary) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().strokeBorder(Theme.color(for: g.entry?.pos, gender: g.entry?.gender).opacity(0.35)))
                    }
                }
            }
        }
    }

    private var diffText: Text {
        var t = Text("")
        for (i, op) in state.diff.enumerated() {
            let sep = i == 0 ? "" : " "
            switch op {
            case .same(let w): t = t + Text(sep + w)
            case .removed(let w): t = t + Text(sep) + Text(w).strikethrough().foregroundColor(Theme.die.opacity(0.75))
            case .added(let w): t = t + Text(sep) + Text(w).bold().foregroundColor(Theme.das)
            }
        }
        return t
    }

    @ViewBuilder
    private func breakdown(_ items: [WordGloss]) -> some View {
        if !items.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(items) { g in
                    Button { actions.speak(g.entry?.lemma ?? g.surface) } label: {
                        HStack(spacing: 5) {
                            Text(g.display).font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.color(for: g.entry?.pos, gender: g.entry?.gender))
                            if let m = g.meaning {
                                Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.color(for: g.entry?.pos, gender: g.entry?.gender).opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help(g.entry.map { model.lexicon.grammarLine($0) } ?? "")
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 18)
            ForEach(model.recentAsks.prefix(6), id: \.self) { q in
                Button { actions.useRecent(q) } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
                        Text(q).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 18).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("⏎", "copy German")
            hint("⌘S", "save")
            hint("⌘K", "check")
            hint("esc", "close")
            Spacer()
            Text(model.tutor.isOnDevice ? "On-device · private" : "Translation on-device · checks by Claude").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyHint(keys: key)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
