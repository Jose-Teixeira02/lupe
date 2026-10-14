import AppKit
import Combine
import LupeCore
import SwiftUI

/// Hold the hover key (⌃ by default) and rest the mouse on a word: a card appears with the German,
/// gender, forms and the sentence translated. Polls modifier state and mouse position, which
/// needs no permissions; reading the text needs Accessibility or Screen Recording.
@MainActor
final class HoverController {
    private let model: AppModel
    private let state = LookupCardState()
    private var panel: HostedPanel<LookupCardView>!
    private var timer: Timer?

    private var modifierDownSince: Date?
    private var movedDuringHold = false
    private var lastMouse = CGPoint.zero
    private var lastMoveAt = Date()
    private var lookupTask: Task<Void, Never>?
    private var lookupPoint: CGPoint?
    private var hitRect: CGRect?
    private var hideDeadline: Date?
    private var shownPermissionHint = false
    private var lastResultApp: String?
    private var stateObserver: AnyCancellable?

    /// Lets sprinkles answer "what's under the mouse" without OCR.
    var sprinkleHit: ((CGPoint) -> SprinkleCandidate?)?

    init(model: AppModel) {
        self.model = model
        let actions = LookupCardActions(
            speak: { [weak self] text in self?.model.speak(text) },
            save: { [weak self] in self?.saveCurrent() },
            undo: { [weak self] in self?.undo() },
            markKnown: { [weak self] in self?.markKnown() },
            explain: { [weak self] in self?.explain() },
            hintAction: { [weak self] in self?.model.permissions.requestScreenRecording() }
        )
        panel = HostedPanel(rootView: LookupCardView(state: state, lexicon: model.lexicon, helpers: model.settings.helpers, actions: actions))
        // SwiftUI lays out on the next run-loop turn; re-anchor the card whenever its content changes.
        stateObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible, let r = self.hitRect else { return }
                self.panel.place(near: r)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Rebuilds the card view (language or helper changes).
    func refreshView() {
        let actions = panel.hosting.rootView.actions
        panel.hosting.rootView = LookupCardView(state: state, lexicon: model.lexicon, helpers: model.settings.helpers, actions: actions)
    }

    var isCardVisible: Bool { panel.isVisible }

    // MARK: Loop

    private func tick() {
        let now = Date()
        let mouse = NSEvent.mouseLocation
        let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let wanted = model.settings.hoverModifier.flag
        let flags = NSEvent.modifierFlags
        let isDown: Bool = wanted == .function
            ? flags.contains(.function) && flags.intersection(relevant).isEmpty
            : flags.intersection(relevant) == wanted

        if hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2 {
            lastMouse = mouse
            lastMoveAt = now
            if isDown { movedDuringHold = true }
        }
        if isDown {
            if modifierDownSince == nil { modifierDownSince = now; movedDuringHold = false }
        } else {
            modifierDownSince = nil
        }

        // Keep the card while the mouse is over the word or the card (with a little grace area).
        if panel.isVisible {
            let keep = keepAliveArea.contains(mouse) || isDown || state.explaining
            if keep {
                hideDeadline = nil
            } else if hideDeadline == nil {
                hideDeadline = now.addingTimeInterval(0.35)
            } else if let d = hideDeadline, now >= d {
                hideCard()
            }
        }

        guard model.settings.hoverEnabled, let since = modifierDownSince else { return }
        let dwell = model.settings.hoverDwellMs / 1000
        let still = now.timeIntervalSince(lastMoveAt) >= dwell
        // Typing shortcuts (⌃C, ⌥2…) are short and don't move the mouse; require intent.
        let intent = movedDuringHold || now.timeIntervalSince(since) > 0.6
        guard still, intent else { return }
        if let r = hitRect, r.insetBy(dx: -3, dy: -3).contains(mouse) { return }
        if panel.isVisible && panel.panel.frame.contains(mouse) { return }
        if let p = lookupPoint, lookupTask != nil, hypot(p.x - mouse.x, p.y - mouse.y) < 4 { return }
        trigger(at: mouse)
    }

    private var keepAliveArea: CGRect {
        var area = panel.panel.frame.insetBy(dx: -16, dy: -16)
        if let r = hitRect { area = area.union(r.insetBy(dx: -10, dy: -10)) }
        return area
    }

    // MARK: Lookup

    /// Lupe's own floating panels (Ask bar, Lens) are hidden from capture, so OCR would read what's
    /// underneath them; don't look things up there. Click-through tag overlays don't count.
    private func isOverOwnPanel(_ point: CGPoint) -> Bool {
        NSApp.windows.contains { w in
            w.isVisible && !(w is OverlayWindow) && w !== panel.panel
                && w.level.rawValue > NSWindow.Level.normal.rawValue && w.frame.contains(point)
        }
    }

    private func trigger(at point: CGPoint) {
        if isOverOwnPanel(point) { return }
        lookupTask?.cancel()
        lookupPoint = point
        let app = model.frontmostAppName
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, model.settings.excludedApps.contains(bundle) { return }
        lookupTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.lookupTask = nil } }
            let hit = await self.textHit(at: point)
            guard !Task.isCancelled else { return }
            guard let hit else {
                self.showPermissionHintIfNeeded(at: point)
                return
            }
            let rect = hit.rect ?? CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            self.hitRect = rect
            self.state.reset(.loading(hit.word))
            self.panel.place(near: rect)
            self.panel.show()

            let result = await self.model.engine.lookup(word: hit.word, context: hit.context, wordRange: hit.range)
            guard !Task.isCancelled else { return }
            self.state.reset(.ready(result))
            self.state.canExplain = self.model.canExplain
            self.state.aiLabel = self.model.aiLabel
            self.lastResultApp = app
            self.panel.place(near: rect)
            self.model.journey.record(.lookup)
            self.model.lastActivity = "Looked up “\(hit.word)”"
            if self.model.settings.autoSaveLookups, result.isConfident, Self.isWorthSaving(result) {
                let (card, created) = self.model.save(result, source: .hover, app: app)
                self.state.saved = .saved(card.id, created: created)
            }
            if self.model.settings.speakOnLookup, let lemma = result.entry?.lemma ?? (result.direction == .toTarget ? result.headword : nil) {
                self.model.speak(lemma)
            }
        }
    }

    private func textHit(at point: CGPoint) async -> TextHit? {
        if let s = sprinkleHit?(point) {
            return TextHit(word: s.word, context: s.lineText, range: s.wordRange, rect: s.wordRect, source: .ocr)
        }
        if model.settings.preferAccessibilityText && AXReader.isTrusted {
            let hit = await Task.detached(priority: .userInitiated) { AXReader.word(at: point) }.value
            if let hit { return hit }
        }
        if model.permissions.screenRecording {
            return await OCRReader.word(at: point)
        }
        return nil
    }

    static func isWorthSaving(_ r: LookupResult) -> Bool {
        guard let pos = r.entry?.pos else { return r.headword.count > 1 }
        return ![.article, .pronoun, .numeral].contains(pos)
    }

    private func showPermissionHintIfNeeded(at point: CGPoint) {
        guard !model.permissions.screenRecording, !shownPermissionHint else { return }
        shownPermissionHint = true
        hitRect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        state.reset(.hint(title: "Lupe can't read this text yet",
                          message: "Allow Screen Recording so Lupe can read words under the mouse in any app. Everything stays on your Mac. (Accessibility also works for native apps.)",
                          action: "Open Screen Recording settings"))
        panel.place(near: hitRect!)
        panel.show()
    }

    private func hideCard() {
        panel.hide()
        hitRect = nil
        hideDeadline = nil
        lookupPoint = nil
    }

    // MARK: Card actions

    private func saveCurrent() {
        guard let r = state.result else { return }
        let (card, created) = model.save(r, source: .hover, app: lastResultApp)
        state.saved = .saved(card.id, created: created)
    }

    private func undo() {
        if case .saved(let id, true) = state.saved { model.bank.remove(id) }
        state.saved = .none
    }

    private func markKnown() {
        guard let r = state.result else { return }
        model.bank.markKnown(key: r.cardKey)
        state.saved = .known
    }

    private func explain() {
        guard let r = state.result else { return }
        state.explaining = true
        let german = r.direction == .fromTarget ? r.context : (r.contextTranslation ?? r.headword)
        let other = r.direction == .fromTarget ? r.contextTranslation : r.context
        let focus = r.entry?.lemma ?? r.headword
        Task {
            do {
                let text = try await model.tutor.explain(sentence: german, translation: other, focus: focus, explainIn: model.settings.primaryHelper)
                state.explanation = text
            } catch {
                state.explanation = error.localizedDescription
            }
            state.explaining = false
            if let rect = hitRect { panel.place(near: rect) }
        }
    }
}
