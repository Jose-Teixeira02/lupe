import AppKit
import Combine
import LupeCore
import SwiftUI

/// The "how do I say…?" bar (⌃⌥D). Works with no permissions at all.
@MainActor
final class AskController {
    private let model: AppModel
    let state = AskState()
    private var panel: HostedPanel<AskView>!
    private var previousApp: NSRunningApplication?
    private var inputSub: AnyCancellable?
    private var stateSub: AnyCancellable?
    private var translateTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var topLeft: CGPoint = .zero
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let actions = AskActions(
            copyAndClose: { [weak self] in self?.copyAndClose() },
            save: { [weak self] in self?.save() },
            speak: { [weak self] text in self?.model.speak(text) },
            check: { [weak self] in self?.check() },
            explainCorrection: { [weak self] in self?.explainCorrection() },
            close: { [weak self] in self?.close() },
            useRecent: { [weak self] q in self?.state.input = q }
        )
        panel = HostedPanel(rootView: AskView(state: state, model: model, actions: actions), level: .popUpMenu, allowsKey: true)
        inputSub = state.$input
            .removeDuplicates()
            .debounce(for: .milliseconds(280), scheduler: RunLoop.main)
            .sink { [weak self] text in self?.translate(text) }
        stateSub = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.relayout() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? close() : open(prefill: nil)
    }

    func open(prefill: String?) {
        if !isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            let screen = ScreenCapturer.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
            let size = panel.fittingSize
            let f = Demo.region ?? screen.visibleFrame
            topLeft = CGPoint(x: (f.midX - size.width / 2).rounded(), y: (f.minY + f.height * (Demo.isOn ? 0.86 : 0.72)).rounded())
        }
        if let prefill {
            state.clearResults()
            state.input = prefill
        }
        relayout()
        NSApp.activate(ignoringOtherApps: true)
        panel.panel.makeKeyAndOrderFront(nil)
        panel.show()
        state.focusToken += 1
        installKeyMonitor()
    }

    func close() {
        guard isVisible else { return }
        if !state.input.isEmpty { model.rememberAsk(state.input) }
        panel.hide()
        removeKeyMonitor()
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        state.input = ""
        state.clearResults()
        state.toast = nil
    }

    private func relayout() {
        let size = panel.fittingSize
        panel.panel.setFrame(CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
    }

    /// Esc closes even when the text field swallows it.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // esc
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Work

    private func translate(_ text: String) {
        translateTask?.cancel()
        checkTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.clearResults()
            state.loading = false
            return
        }
        state.loading = true
        state.toast = nil
        translateTask = Task {
            do {
                let r = try await model.engine.translatePhrase(trimmed)
                guard !Task.isCancelled else { return }
                state.error = nil
                state.result = r
                state.corrected = nil
                state.diff = []
                state.explanation = nil
                model.journey.record(.ask)
                if r.breakdown.contains(where: { $0.meaning == nil }) {
                    let filled = await model.engine.fillMeanings(r.breakdown)
                    if !Task.isCancelled, state.result?.input == r.input { state.result?.breakdown = filled }
                }
                // German with a few words: check it automatically (on-device only; Claude checks cost money, so ⌘K).
                if r.inputLanguage == model.target, trimmed.split(separator: " ").count >= 3, model.tutor.isOnDevice, model.canExplain {
                    check()
                }
            } catch {
                guard !Task.isCancelled else { return }
                state.result = nil
                state.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            state.loading = false
        }
    }

    private func check() {
        guard let r = state.result, r.inputLanguage == model.target else { return }
        checkTask?.cancel()
        state.proofreading = true
        state.explanation = nil
        let input = r.input
        checkTask = Task {
            let fixed = try? await model.tutor.proofread(german: input)
            guard !Task.isCancelled, state.result?.input == input else { return }
            state.proofreading = false
            if let fixed, !fixed.isEmpty {
                state.corrected = fixed
                state.diff = WordDiff.diff(input, fixed)
            }
        }
    }

    func explainCorrection() {
        guard let r = state.result, let corrected = state.corrected else { return }
        state.explaining = true
        Task {
            let text = try? await model.tutor.explainCorrection(original: r.input, corrected: corrected, explainIn: model.settings.primaryHelper)
            state.explanation = text ?? "Couldn't explain this one."
            state.explaining = false
        }
    }

    private func germanText() -> String? {
        guard let r = state.result else { return nil }
        if r.outputLanguage == model.target { return r.output }
        if let c = state.corrected, !WordDiff.isEquivalent(r.input, c) { return c }
        return r.input
    }

    private func copyAndClose() {
        guard let german = germanText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(german, forType: .string)
        close()
    }

    private func save() {
        guard let r = state.result, let german = germanText() else { return }
        let meaning = r.outputLanguage == model.target ? r.input : r.output
        let meaningLang = r.outputLanguage == model.target ? r.inputLanguage : r.outputLanguage
        let (_, created) = model.savePhrase(german: german, meaning: meaning, meaningLanguage: meaningLang, source: .ask)
        state.toast = created ? "Saved to your deck" : "Already in your deck"
        model.rememberAsk(state.input)
    }
}
