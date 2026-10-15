import AppKit
import Combine
import LupeCore
import SwiftUI

/// Immersion mode: a small budget of German tags over English/Portuguese words on screen (and
/// English glosses over hard German words). Scans only when the screen changed and then settled,
/// hides while you scroll, and never labels words you know.
@MainActor
final class SprinkleController {
    private let model: AppModel
    private var overlays: [CGDirectDisplayID: (window: OverlayWindow, state: SprinkleOverlayState)] = [:]
    private var timer: Timer?
    private var hoverTimer: Timer?
    private var scrollMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var settingsSub: AnyCancellable?

    private var lastFingerprint: [UInt8] = []
    private var fingerprintScreen: CGDirectDisplayID?
    private var stableSince = Date()
    private var scannedFingerprint: [UInt8]?
    private var scanning = false
    private var scanGeneration = 0

    /// What's currently shown (global coordinates), for hover lookups.
    private(set) var current: [SprinkleCandidate] = []
    private var previousIDs: Set<String> = []
    private var dismissed: Set<String> = []
    private var hoverStart: (id: String, since: Date)?
    private var hoveredOnce: Set<String> = []

    init(model: AppModel) {
        self.model = model
        settingsSub = model.settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.contentChanged() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.teardownOverlays()
                    ScreenCapturer.shared.invalidate()
                }
            })
        applySettings()
    }

    // MARK: Lifecycle

    func applySettings() {
        let active = model.sprinklesActive
        if active && timer == nil {
            start()
        } else if !active && timer != nil {
            stop()
        }
        for (_, o) in overlays { o.state.style = model.settings.sprinkleStyle }
        if !current.isEmpty { render() }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: max(0.6, model.settings.sprinkleIntervalSec), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverTick() }
        }
        // Scrolling moves text under the tags: hide them at once; the next tick rescans if the page moved.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.softHide() }
        }
        tick()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        hoverTimer?.invalidate(); hoverTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        clear()
    }

    var labelCount: Int { overlays.values.reduce(0) { $0 + $1.state.labels.count } }

    func toggle() {
        if model.settings.sprinklesEnabled && model.sprinklesPausedUntil == nil {
            model.settings.sprinklesEnabled = false
        } else {
            model.sprinklesPausedUntil = nil
            model.settings.sprinklesEnabled = true
        }
        applySettings()
    }

    func pause(for seconds: TimeInterval) {
        model.sprinklesPausedUntil = Date().addingTimeInterval(seconds)
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { [weak self] in
            guard let self, let until = self.model.sprinklesPausedUntil, until <= Date() else { return }
            self.model.sprinklesPausedUntil = nil
            self.applySettings()
        }
    }

    /// "Not now" for one entry during this session.
    func dismiss(entryID: String) {
        dismissed.insert(entryID)
        current.removeAll { $0.entry.id == entryID }
        render()
    }

    // MARK: Scanning

    private func softHide() {
        for (_, o) in overlays where o.state.visible && !o.state.labels.isEmpty { o.state.visible = false }
        stableSince = Date()
    }

    private func contentChanged() {
        // Hide immediately; rescan after things settle.
        for (_, o) in overlays where !o.state.labels.isEmpty { o.state.visible = false }
        scannedFingerprint = nil
        stableSince = Date()
        scanGeneration += 1
    }

    private func tick() {
        guard model.sprinklesActive, model.permissions.screenRecording else { clear(); return }
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           model.settings.excludedApps.contains(bundle) || bundle == Bundle.main.bundleIdentifier {
            clear(); return
        }
        guard !scanning, let screen = ScreenCapturer.screen(containing: NSEvent.mouseLocation),
              let displayID = ScreenCapturer.displayID(of: screen) else { return }
        Task {
            guard let fp = try? await ScreenCapturer.shared.fingerprint(of: screen) else { return }
            let changed = displayID != fingerprintScreen || ScreenCapturer.difference(fp, lastFingerprint) > 1.5
            if changed {
                if let scanned = scannedFingerprint, ScreenCapturer.difference(fp, scanned) > 4 || displayID != fingerprintScreen {
                    contentChanged()
                }
                lastFingerprint = fp
                fingerprintScreen = displayID
                stableSince = Date()
                return
            }
            // Unchanged since the last scan: just make sure labels are visible.
            if let scanned = scannedFingerprint, ScreenCapturer.difference(fp, scanned) <= 4 {
                if Date().timeIntervalSince(stableSince) >= 0.3 { overlay(for: screen).state.visible = true }
                return
            }
            guard Date().timeIntervalSince(stableSince) >= 0.4 else { return }
            await scan(screen: screen, fingerprint: fp)
        }
    }

    private func scan(screen: NSScreen, fingerprint: [UInt8]) async {
        scanning = true
        defer { scanning = false }
        let generation = scanGeneration
        guard let shot = try? await ScreenCapturer.shared.captureScreen(screen) else { return }
        let image = shot.image
        let lines: [RecognizedLine] = await Task.detached(priority: .utility) {
            (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? []
        }.value
        guard generation == scanGeneration else { return }

        var config = SprinkleConfig()
        config.budget = model.settings.sprinkleBudget
        config.knownLevels = model.settings.knownLevels
        config.nextLevel = model.settings.nextLevel
        config.assistGerman = model.settings.sprinkleAssistGerman
        config.teachFromHelpers = model.settings.sprinkleTeach
        config.minWordHeight = 9
        let learner = model.learnerSnapshot(previous: previousIDs, dismissed: dismissed)
        let ranked = SprinkleSelector.rank(lines: lines, frame: shot.frame, engine: model.engine, config: config, learner: learner)

        // Show labels as they're confirmed, replacing the previous set.
        current = []
        let overlay = overlay(for: screen)
        overlay.state.labels = []
        overlay.state.visible = true
        let verify = SprinkleSelector.verifier(engine: model.engine)
        let picked = await SprinkleSelector.pick(ranked, config: config, maxVerifications: 16, verify: verify) { [weak self] c in
            await MainActor.run {
                guard let self, generation == self.scanGeneration else { return }
                self.current.append(c)
                self.render(shot: shot)
            }
        }
        guard generation == scanGeneration else { return }
        previousIDs = Set(picked.map(\.id))
        scannedFingerprint = fingerprint
        model.lastActivity = picked.isEmpty ? "Sprinkles: nothing new on this screen" : "Sprinkles: \(picked.count) words on screen"
    }

    private var lastShot: CapturedImage?

    private func render(shot: CapturedImage? = nil) {
        if let shot { lastShot = shot }
        guard let shot = lastShot else { return }
        let screen = shot.screen
        let overlay = overlay(for: screen)
        let frame = screen.frame
        overlay.state.style = model.settings.sprinkleStyle
        overlay.state.labels = current.map { c in
            let local = CGRect(x: c.wordRect.minX - frame.minX, y: frame.maxY - c.wordRect.maxY,
                               width: c.wordRect.width, height: c.wordRect.height)
            let norm = CGRect(x: (c.wordRect.minX - shot.frame.minX) / shot.frame.width,
                              y: (c.wordRect.minY - shot.frame.minY) / shot.frame.height,
                              width: c.wordRect.width / shot.frame.width, height: c.wordRect.height / shot.frame.height)
            let dark = ScreenCapturer.luminance(of: shot.image, normalizedRect: norm) < 0.45
            let gloss: String
            switch c.mode {
            case .teach: gloss = c.entry.gloss(model.settings.primaryHelper) ?? ""
            case .assist: gloss = model.lexicon.display(c.entry)
            }
            return SprinkleLabel(id: c.id, text: c.label, gloss: gloss, gender: c.entry.gender, pos: c.entry.pos,
                                 wordRect: local, mode: c.mode, darkBackground: dark,
                                 placement: SprinkleLabel.placement(style: model.settings.sprinkleStyle,
                                                                    spaceAbove: c.spaceAbove, spaceBelow: c.spaceBelow))
        }
    }

    private func overlay(for screen: NSScreen) -> (window: OverlayWindow, state: SprinkleOverlayState) {
        let id = ScreenCapturer.displayID(of: screen) ?? 0
        if let o = overlays[id] { return o }
        let state = SprinkleOverlayState()
        state.style = model.settings.sprinkleStyle
        let window = OverlayWindow(screen: screen)
        let host = NSHostingView(rootView: SprinkleOverlayView(state: state))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        window.contentView = host
        window.orderFrontRegardless()
        overlays[id] = (window, state)
        return (window, state)
    }

    private func clear() {
        current = []
        for (_, o) in overlays { o.state.labels = [] }
        scannedFingerprint = nil
    }

    private func teardownOverlays() {
        for (_, o) in overlays { o.window.orderOut(nil) }
        overlays.removeAll()
        current = []
    }

    // MARK: Hover

    /// The sprinkle under a point (word or its tag), used by the hover lens.
    func hit(at point: CGPoint) -> SprinkleCandidate? {
        current.first { c in
            if c.wordRect.insetBy(dx: -2, dy: -2).contains(point) { return true }
            switch SprinkleLabel.placement(style: model.settings.sprinkleStyle, spaceAbove: c.spaceAbove, spaceBelow: c.spaceBelow) {
            case .above: return CGRect(x: c.wordRect.midX - 60, y: c.wordRect.maxY, width: 120, height: 18).contains(point)
            case .below: return CGRect(x: c.wordRect.midX - 60, y: c.wordRect.minY - 18, width: 120, height: 18).contains(point)
            case .cover: return false
            }
        }
    }

    /// Resting the mouse on a tagged word expands the tag to show the meaning.
    private func hoverTick() {
        guard !current.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let over = hit(at: mouse)
        for (_, o) in overlays {
            if let over {
                if hoverStart?.id != over.id { hoverStart = (over.id, Date()) }
                if let h = hoverStart, Date().timeIntervalSince(h.since) > 0.45, o.state.expanded != over.id {
                    o.state.expanded = over.id
                    if hoveredOnce.insert(over.id).inserted { model.journey.record(.sprinkleHover) }
                }
            } else {
                hoverStart = nil
                if o.state.expanded != nil { o.state.expanded = nil }
            }
        }
    }
}
