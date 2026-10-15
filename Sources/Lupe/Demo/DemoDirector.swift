import AppKit
import LupeCore

/// Runs the product tour for `Lupe --demo-video`: glides the real cursor, holds the hover key virtually,
/// types into the Ask bar and walks through the Journey window, with captions, while recording.
/// Words and buttons are found on screen with Lupe's own OCR, so nothing depends on fixed coordinates.
@MainActor
final class DemoDirector {
    private let model: AppModel
    private let hover: HoverController
    private let ask: AskController
    private let sprinkles: SprinkleController
    private let journey: JourneyWindowController
    private let stage = DemoStage()
    private let recorder = DemoRecorder()
    private var screen: NSScreen!
    private var region: CGRect = .zero
    private var documentWords: [(text: String, rect: CGRect)] = []
    /// Apps hidden for the take (shown again afterwards).
    private var hiddenApps: [NSRunningApplication] = []
    private var interrupted = false

    init(model: AppModel, hover: HoverController, ask: AskController, sprinkles: SprinkleController, journey: JourneyWindowController) {
        self.model = model
        self.hover = hover
        self.ask = ask
        self.sprinkles = sprinkles
        self.journey = journey
    }

    func run() async {
        guard let output = Demo.output else { return }
        do {
            // The tour moves the real cursor: wait until nobody is using the Mac.
            log("waiting for the Mac to be idle for 15 s…")
            while Self.userIdleSeconds() < 15 { await pause(1) }
            clearScreen()
            try await prepare()
            log("recording → \(output.path)")
            try await recorder.start(screen: screen, region: region, to: output)
            // Touching the mouse or keyboard stops the take (it would end up in the video).
            let tourTask = Task { await tour() }
            let watchdog = Task {
                while !Task.isCancelled {
                    if Self.userIdleSeconds() < 0.8 { interrupted = true; tourTask.cancel(); return }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await tourTask.value
            watchdog.cancel()
            await recorder.stop()
            if interrupted {
                try? FileManager.default.removeItem(at: output)
                log("✗ interrupted by mouse or keyboard: take discarded")
            } else {
                log("✓ done")
            }
        } catch {
            log("✗ \(error.localizedDescription)")
        }
        ask.close()
        restoreScreen()
        Demo.holdingHoverKey = false
        if model.settings.sprinklesEnabled { sprinkles.toggle() }
        journey.window?.orderOut(nil)
        stage.close()
        NSApp.terminate(nil)
    }

    // MARK: Preparation

    /// Seconds since the last real mouse or keyboard input (cursor warps don't count).
    static func userIdleSeconds() -> Double {
        [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    /// Only TextEdit and Lupe on screen during the take, so Lupe reads the document and nothing covers it.
    private func clearScreen() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden
            && app.processIdentifier != me && app.bundleIdentifier != "com.apple.TextEdit" {
            if app.hide() { hiddenApps.append(app) }
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.unhide()
    }

    private func restoreScreen() {
        for app in hiddenApps { app.unhide() }
        hiddenApps = []
    }

    private func prepare() async throws {
        screen = NSScreen.screens.first ?? NSScreen.main!
        // A 16:9 area a little narrower than the screen, so text reads well on a phone.
        let f = screen.frame
        let width = min(f.width, 1344)
        let height = (width * 9 / 16).rounded()
        region = CGRect(x: (f.midX - width / 2).rounded(), y: (f.midY - height / 2).rounded(), width: width, height: height)
        // Cards and the Ask bar stay inside the frame, above the caption band.
        Demo.region = CGRect(x: region.minX, y: region.minY + 76, width: region.width, height: region.height - 76)
        stage.show(screen: screen, region: region)

        guard let doc = documentFrame() else {
            throw NSError(domain: "Demo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Open \(Demo.documentName).rtf in TextEdit first"])
        }
        // Read the document (this also warms up Vision, whose first run is slow). The capturer caches the window
        // list for a second; refresh it so the title card that just appeared is left out like Lupe's other overlays.
        await pause(0.5)
        ScreenCapturer.shared.invalidate()
        let shot = try await ScreenCapturer.shared.capture(rect: doc)
        let image = shot.image
        let lines = await Task.detached { (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? [] }.value
        documentWords = lines.flatMap { line in line.words.map { (TextTools.clean($0.text), $0.rect.denormalized(in: shot.frame)) } }
        log("document: \(lines.count) lines, \(documentWords.count) words")

        // Warm up translation and the on-device tutor so nothing waits on camera.
        for (word, sentence) in Self.hovers {
            _ = await model.engine.lookup(word: word, context: sentence)
        }
        _ = try? await model.engine.translatePhrase(Self.askEnglish)
        _ = try? await model.engine.translatePhrase(Self.askGerman)
        _ = try? await model.tutor.proofread(german: Self.askGerman)
        hideCursor()
        log("warmed up")
    }

    /// The demo document's window in TextEdit, in Cocoa points.
    private func documentFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "TextEdit"
            && ((w[kCGWindowName as String] as? String) ?? "").contains(Demo.documentName) {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let top = screen.frame.maxY
            return CGRect(x: b["X"] ?? 0, y: top - (b["Y"] ?? 0) - (b["Height"] ?? 0), width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        return nil
    }

    // MARK: Script

    static let hovers: [(String, String)] = [
        ("running", "Sorry, I'm running late today, so let's meet after lunch."),
        ("bank", "The budget is approved, and the payment from the bank should arrive on Friday."),
        ("bank", "By the way, our team picnic by the river bank was great!"),
        ("schön", "Das Wetter war wirklich schön, und das neue Team ist sehr nett."),
        ("Daumen", "Ich drücke dir die Daumen für die Präsentation morgen."),
    ]
    static let askEnglish = "The meeting is postponed until Monday."
    static let askGerman = "Ich habe gestern nach Berlin gefahren."

    private func tour() async {
        // Title (the cursor waits outside the frame)
        await pause(2.8)
        stage.card(nil)
        await pause(0.7)
        await glide(to: CGPoint(x: region.maxX - 220, y: region.minY + 150))

        // Hover: English → German, in context
        stage.caption([.text("Hold"), .key("⌃"), .text("over any word, in any app")])
        await hoverWord("running", read: 3.2)
        stage.caption([.text("It reads the whole sentence: here, “bank” is"), .em("die Bank")])
        await hoverWord("bank", occurrence: 0, read: 2.6)
        stage.caption([.text("…and by the river, it’s"), .em("das Ufer")])
        await hoverWord("bank", occurrence: 1, read: 2.8)

        // Hover: German → English
        stage.caption([.text("German too: meaning, article, and the words people mix up")])
        await hoverWord("schön", read: 4.4)
        stage.caption([.text("Idioms are recognised as idioms")])
        await hoverWord("Daumen", read: 3.6)
        await glide(to: CGPoint(x: region.maxX - 60, y: region.maxY - 60))
        hideCursor()
        await pause(0.5)

        // Ask bar
        stage.caption([.key("⌃"), .key("⌥"), .key("D"), .text("Ask how to say anything, without leaving your app")])
        await pause(0.8)
        ask.open(prefill: nil)
        await pause(0.7)
        await type(Self.askEnglish)
        _ = await waitUntil(20) { self.ask.state.result != nil && !self.ask.state.loading }
        await pause(2.6)
        stage.caption([.text("Write German, and get it checked on your Mac")])
        ask.state.clearResults()
        ask.state.input = ""
        await pause(0.5)
        await type(Self.askGerman)
        _ = await waitUntil(45) { self.ask.state.corrected != nil }
        await pause(1.2)
        ask.explainCorrection()
        _ = await waitUntil(45) { self.ask.state.explanation != nil }
        await pause(3.6)
        ask.close()
        await pause(0.6)

        // Sprinkles
        stage.caption([.key("⌃"), .key("⌥"), .key("I"), .text("Sprinkles: German words on what you’re already reading")])
        sprinkles.toggle()
        _ = await waitUntil(15) { self.sprinkles.labelCount > 0 }
        await pause(3.6)
        sprinkles.toggle()
        await pause(0.6)

        // Journey
        journey.show(.today)
        placeJourney()
        stage.caption([.text("Every word you look up is kept, with the sentence where you met it")])
        await pause(0.6)
        if let w = await findInJourney("Met today") { await glide(to: CGPoint(x: w.midX + 60, y: w.minY - 80)) }
        await pause(3.0)

        stage.caption([.text("Spaced repetition brings each word back just before you’d forget it")])
        await clickInJourney("Review") { self.journey.nav.section = .review }
        await pause(1.0)
        await clickInJourney("Start review") { self.journey.review.start() }
        await pause(2.6)
        await clickInJourney("Show answer") { self.journey.review.reveal() }
        await pause(3.4)
        await clickInJourney("Good") { self.journey.review.rate(.good) }
        await pause(1.6)

        stage.caption([.text("Graded stories: click any word to see what it means right there")])
        await clickInJourney("Read") { self.journey.nav.section = .read }
        await pause(1.8)
        if let token = journey.reading.paragraphs.flatMap(\.tokens).first(where: { $0.text == "schön" }) {
            await clickInJourney("schön") { self.journey.reading.select(token) }
            _ = await waitUntil(15) { self.journey.reading.card.result != nil }
        }
        await pause(3.8)

        stage.caption([.text("Your path from A1 to B2, one word at a time")])
        await clickInJourney("Path") { self.journey.nav.section = .path }
        await pause(3.2)

        // End
        stage.caption([])
        stage.card(.end)
        await pause(0.8)
        hideCursor()
        await pause(3.4)
    }

    // MARK: Actions

    /// Glides to a word in the document holding the hover key, and waits for the card.
    private func hoverWord(_ word: String, occurrence: Int = 0, read: Double) async {
        let matches = documentWords.filter { $0.text.caseInsensitiveCompare(word) == .orderedSame }
        guard !Task.isCancelled else { return }
        guard occurrence < matches.count else { log("✗ can't find “\(word)”"); return }
        let r = matches[occurrence].rect
        Demo.holdingHoverKey = true
        await glide(to: CGPoint(x: r.midX, y: r.midY))
        if !(await waitUntil(15) { self.hover.isCardReady }) { log("✗ no card for “\(word)”") }
        await pause(read)
        Demo.holdingHoverKey = false
    }

    private func placeJourney() {
        guard let w = journey.window else { return }
        let size = CGSize(width: 1040, height: 690)
        w.setFrame(CGRect(x: (region.midX - size.width / 2).rounded(), y: (region.midY - size.height / 2 + 24).rounded(),
                          width: size.width, height: size.height), display: true)
    }

    /// Finds text in the Journey window with OCR (global Cocoa rect).
    private func findInJourney(_ text: String) async -> CGRect? {
        guard let w = journey.window else { return nil }
        await pause(0.25)
        ScreenCapturer.shared.invalidate()
        guard let shot = try? await ScreenCapturer.shared.capture(rect: w.frame) else { return nil }
        let image = shot.image
        let lines = await Task.detached { (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? [] }.value
        let words = lines.flatMap { line in line.words.map { (TextTools.clean($0.text), $0.rect.denormalized(in: shot.frame)) } }
        if !text.contains(" "), let hit = words.first(where: { $0.0 == text }) { return hit.1 }
        return lines.first { $0.text.localizedCaseInsensitiveContains(text) }.map { $0.rect.denormalized(in: shot.frame) }
    }

    /// Moves to a button or word, shows a click, then performs the action.
    private func clickInJourney(_ text: String, action: @escaping () -> Void) async {
        guard !Task.isCancelled else { return }
        if let r = await findInJourney(text) {
            let p = CGPoint(x: r.midX, y: r.midY)
            await glide(to: p)
            await pause(0.15)
            stage.ripple(at: p)
        } else {
            log("✗ can't find “\(text)” in the Journey window")
        }
        action()
    }

    private func type(_ text: String) async {
        for c in text where !Task.isCancelled {
            ask.state.input.append(c)
            let base = c == " " ? 0.07 : 0.045
            await pause(base + Double.random(in: 0...0.04))
        }
    }

    // MARK: Cursor

    /// Parks the cursor just above the recorded area (it isn't in the video there).
    private func hideCursor() {
        warp(CGPoint(x: region.maxX - 220, y: min(screen.frame.maxY - 2, region.maxY + 30)))
    }

    private func warp(_ p: CGPoint) {
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: screen.frame.maxY - p.y))
    }

    /// An eased, slightly curved move, like a hand on a trackpad.
    private func glide(to target: CGPoint) async {
        let start = NSEvent.mouseLocation
        let distance = hypot(target.x - start.x, target.y - start.y)
        guard distance > 1 else { return }
        let duration = min(1.0, max(0.4, Double(distance) / 950))
        let steps = max(12, Int(duration * 60))
        let normal = CGPoint(x: -(target.y - start.y) / distance, y: (target.x - start.x) / distance)
        let bow = min(60, distance * 0.08)
        let control = CGPoint(x: (start.x + target.x) / 2 + normal.x * bow, y: (start.y + target.y) / 2 + normal.y * bow)
        for i in 1...steps where !Task.isCancelled {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let u = 1 - e
            let x = u * u * start.x + 2 * u * e * control.x + e * e * target.x
            let y = u * u * start.y + 2 * u * e * control.y + e * e * target.y
            warp(CGPoint(x: x, y: y))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: Timing

    private func pause(_ seconds: Double) async {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(_ timeout: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func log(_ s: String) {
        print("[demo] \(s)")
        fflush(stdout)
    }
}
