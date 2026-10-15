import AppKit
import CoreMedia
import LupeCore
import ScreenCaptureKit
import SwiftUI

/// `Lupe --demo-video <file.mp4>`: records a scripted product tour.
///
/// Private by construction: a throwaway profile (seeded demo deck, no name in the greeting), and the
/// recording only includes Lupe's own windows and the TextEdit window of the demo document, so the
/// menu bar, Dock, notifications, other apps and other documents can't appear in the video.
/// Open `Project Alpine.rtf` in TextEdit before starting.
enum Demo {
    static var output: URL?
    static var isOn: Bool { output != nil }
    /// The hover key, held by the director instead of the keyboard.
    static var holdingHoverKey = false
    /// The recorded area in Cocoa points (bottom-left origin); panels are kept inside it.
    static var region: CGRect?
    static let documentName = "Project Alpine"

    /// Called from main before anything reads paths or settings.
    static func configure(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--demo-video"), i + 1 < arguments.count else { return }
        output = URL(fileURLWithPath: arguments[i + 1])
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lupe-demo-\(UUID().uuidString)")
        setenv("LUPE_HOME", home.path, 1)
    }

    @MainActor
    static func makeSettings() -> LupeSettings {
        let s = LupeSettings(defaults: UserDefaults(suiteName: "lupe.demo.\(UUID().uuidString)")!)
        s.hasOnboarded = true
        s.placementLevel = "A2"
        s.primaryHelper = "en"
        s.speakOnLookup = false
        s.autoSaveLookups = true
        s.reminderEnabled = false
        return s
    }

    /// A believable deck: words met at work and around the web over the past weeks.
    @MainActor
    static func seed(_ model: AppModel) {
        let lex = model.lexicon
        let samples: [(String, String, String, String, String)] = [
            ("Besprechung", "Can we move the meeting to Thursday?", "Können wir die Besprechung auf Donnerstag verschieben?", "Besprechung", "Mail"),
            ("Rechnung", "The invoice is attached.", "Die Rechnung ist im Anhang.", "Rechnung", "Mail"),
            ("Kunde", "The customer loved the new design.", "Der Kunde war vom neuen Design begeistert.", "Kunde", "Slack"),
            ("verschieben", "Wir müssen den Launch verschieben.", "We need to postpone the launch.", "verschieben", "Slack"),
            ("Termin", "I have an appointment at three.", "Ich habe um drei einen Termin.", "Termin", "Calendar"),
            ("Schlüssel", "I lost my keys at the station.", "Ich habe meine Schlüssel am Bahnhof verloren.", "Schlüssel", "Messages"),
            ("Wohnung", "Our new flat has a big kitchen.", "Unsere neue Wohnung hat eine große Küche.", "Wohnung", "Safari"),
            ("Zeitung", "Ele lê o jornal todas as manhãs.", "Er liest jeden Morgen die Zeitung.", "Zeitung", "Safari"),
            ("vergessen", "Don't forget your umbrella!", "Vergiss deinen Regenschirm nicht!", "Vergiss", "Notes"),
        ]
        for (i, (lemma, sentence, translation, form, app)) in samples.enumerated() {
            guard let e = lex.entries(forGerman: lemma).first else { continue }
            let lang = TextTools.detectLanguage(sentence, candidates: ["en", "pt", "de"]) ?? "en"
            var meanings: [String: String] = [:]
            for h in ["en", "pt"] { if let g = e.gloss(h) { meanings[h] = g } }
            let enc = Encounter(sentence: sentence, translation: translation, language: lang, app: app,
                                date: Date().addingTimeInterval(-Double(i + 1) * 86_400 * 2), targetForm: form)
            let (card, _) = model.bank.add(term: e.lemma, entry: e, display: lex.display(e), meanings: meanings, encounter: enc, source: .hover)
            if i % 2 == 1 { model.bank.review(card.id, rating: .good, now: Date().addingTimeInterval(-86_400 * 9)) }
        }
        let j = model.journey
        let cal = Calendar.current
        for d in 1...60 where d != 24 && d != 41 {
            j.clock = { cal.date(byAdding: .day, value: -d, to: Date())! }
            for _ in 0..<(10 + (d * 7) % 25) { j.record(.review(.good)) }
        }
        j.clock = { Date() }
        for _ in 0..<5 { j.record(.review(.good)) }
    }
}

// MARK: - Stage

/// What the overlay shows: a title card, a caption (text with keycaps) and click ripples.
@MainActor
final class DemoStageState: ObservableObject {
    enum Card: Equatable { case title, end }
    enum Piece: Hashable { case text(String), em(String), key(String) }

    @Published var card: Card? = .title
    @Published var caption: [Piece] = []
    @Published var captionID = 0
    @Published var ripples: [Ripple] = []

    struct Ripple: Identifiable, Equatable {
        let id = UUID()
        var point: CGPoint
    }
}

/// The backdrop behind the windows and the overlay with titles and captions. Both belong to Lupe,
/// so they're in the recording; both ignore the mouse, and Lupe's OCR never reads them.
@MainActor
final class DemoStage {
    let state = DemoStageState()
    private var backdrop: NSWindow?
    private var overlay: NSWindow?
    private var region: CGRect = .zero

    func show(screen: NSScreen, region: CGRect) {
        self.region = region
        // Above desktop icons and widgets (so Lupe's OCR never reads them), below every app window.
        let back = Self.window(frame: screen.frame, level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1))
        back.contentView = NSHostingView(rootView: DemoBackdrop(region: region, screen: screen.frame))
        back.orderFrontRegardless()
        backdrop = back

        let over = Self.window(frame: region, level: .screenSaver)
        over.contentView = NSHostingView(rootView: DemoOverlay(state: state))
        over.orderFrontRegardless()
        overlay = over
    }

    func close() {
        backdrop?.orderOut(nil)
        overlay?.orderOut(nil)
    }

    func caption(_ pieces: [DemoStageState.Piece]) {
        withAnimation(.easeOut(duration: 0.35)) {
            state.caption = pieces
            state.captionID += 1
        }
    }

    func card(_ card: DemoStageState.Card?) {
        withAnimation(.easeInOut(duration: 0.7)) { state.card = card }
    }

    /// A ripple where the "click" happens (global Cocoa point).
    func ripple(at p: CGPoint) {
        let local = CGPoint(x: p.x - region.minX, y: region.maxY - p.y)
        let r = DemoStageState.Ripple(point: local)
        state.ripples.append(r)
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            state.ripples.removeAll { $0.id == r.id }
        }
    }

    private static func window(frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = level
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrame(frame, display: false)
        return w
    }
}

private let stageTop = Color(red: 0.11, green: 0.10, blue: 0.24)
private let stageBottom = Color(red: 0.04, green: 0.05, blue: 0.11)

private struct DemoBackdrop: View {
    var region: CGRect
    var screen: CGRect

    var body: some View {
        ZStack {
            LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

private struct DemoOverlay: View {
    @ObservedObject var state: DemoStageState

    var body: some View {
        ZStack {
            ForEach(state.ripples) { r in RippleView().position(r.point) }
            VStack {
                Spacer()
                if !state.caption.isEmpty {
                    CaptionView(pieces: state.caption)
                        .id(state.captionID)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).animation(.easeOut(duration: 0.35).delay(0.12)),
                                                removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
            }
            .padding(.bottom, 26)
            if let card = state.card {
                TitleCardView(card: card).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CaptionView: View {
    var pieces: [DemoStageState.Piece]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                switch p {
                case .text(let t):
                    Text(t).font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
                case .em(let t):
                    Text(t).font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(Color(red: 0.62, green: 0.78, blue: 1))
                case .key(let k):
                    Text(k)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 30, minHeight: 30)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

private final class RippleModel: ObservableObject {
    @Published var grown = false
}

private struct RippleView: View {
    @StateObject private var model = RippleModel()

    var body: some View {
        Circle()
            .strokeBorder(Color.white.opacity(model.grown ? 0 : 0.85), lineWidth: 3)
            .background(Circle().fill(Color.white.opacity(model.grown ? 0 : 0.18)))
            .frame(width: model.grown ? 56 : 14, height: model.grown ? 56 : 14)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { model.grown = true } }
    }
}

private struct TitleCardView: View {
    var card: DemoStageState.Card

    var body: some View {
        ZStack {
            LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 520)
            VStack(spacing: 18) {
                AppMark(size: 116)
                Text("Lupe").font(.system(size: 66, weight: .bold, design: .rounded)).foregroundStyle(.white)
                if card == .title {
                    Text("Learn German from everything you already read.")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    Text("A language companion for macOS  ·  on-device  ·  private")
                        .font(.system(size: 17)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text("Hover any word. Ask anything. Remember what matters.")
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    Text("German today, Norwegian next  ·  Runs entirely on your Mac")
                        .font(.system(size: 17)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }
}

// MARK: - Recorder

/// Records the demo area with ScreenCaptureKit, keeping only Lupe and the demo document in TextEdit.
@MainActor
final class DemoRecorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?

    func start(screen: NSScreen, region: CGRect, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let id = ScreenCapturer.displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == pid || $0.bundleIdentifier == "com.apple.TextEdit" }
        // Any other TextEdit document stays out of the video.
        let others = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.TextEdit" && !($0.title ?? "").contains(Demo.documentName)
        }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: others)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                                   width: region.width, height: region.height)
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 8
        config.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.11, alpha: 1).cgColor

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            Task { try? await stream.stopCapture() }
            // Don't hang if the delegate never calls back.
            Task {
                try? await Task.sleep(for: .seconds(8))
                self.finish()
            }
        }
        self.stream = nil
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        print("✗ Recording failed: \(error.localizedDescription)")
        Task { @MainActor in self.finish() }
    }
}
