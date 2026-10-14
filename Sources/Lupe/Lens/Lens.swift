import AppKit
import LupeCore
import SwiftUI

@MainActor
final class LensState: ObservableObject {
    struct Block: Identifiable, Equatable {
        var id: Int
        var original: String
        var language: String
        var translation: String?
        /// Rect in the overlay's SwiftUI coordinates (top-left origin).
        var rect: CGRect
        var lineCount: Int
        var lineHeight: CGFloat
    }

    @Published var blocks: [Block] = []
    @Published var status = "Reading your screen…"
    @Published var done = 0
    @Published var hovered: Int?
    @Published var toast: String?
}

struct LensActions {
    var close: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var speak: (String) -> Void = { _ in }
    var save: (LensState.Block) -> Void = { _ in }
    var copyAll: () -> Void = {}
}

/// Full-screen overlay showing every text block translated in place.
struct LensView: View {
    @ObservedObject var state: LensState
    var target: String
    var actions: LensActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.close)
            ForEach(state.blocks) { b in
                block(b)
            }
            toolbar
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func block(_ b: LensState.Block) -> some View {
        let fontSize = max(10, min(b.lineHeight * 0.68, 30))
        let hovered = state.hovered == b.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: hovered ? 6 : 2, y: 1)
            if let t = b.translation {
                Text(t)
                    .font(.system(size: fontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.45)
                    .lineLimit(max(b.lineCount + 1, 1))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                ShimmerBar().padding(6)
            }
            if hovered {
                HStack(spacing: 4) {
                    miniButton("speaker.wave.2.fill") { actions.speak(b.language == target ? b.original : (b.translation ?? "")) }
                    miniButton("doc.on.doc") { actions.copy(b.translation ?? "") }
                    miniButton("plus") { actions.save(b) }
                }
                .padding(4)
                .background(Capsule().fill(.thickMaterial))
                .offset(x: b.rect.width - 82, y: -26)
            }
        }
        .frame(width: max(b.rect.width + 8, 40), height: max(b.rect.height + 4, 16))
        .position(x: b.rect.midX, y: b.rect.midY)
        .help(b.original)
        .onHover { inside in
            if inside { state.hovered = b.id } else if state.hovered == b.id { state.hovered = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder").foregroundStyle(Theme.accent)
            Text(state.status).font(.system(size: 12, weight: .medium))
            if let toast = state.toast {
                Text(toast).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.success)
            }
            Divider().frame(height: 14)
            Button("Copy all", action: actions.copyAll).buttonStyle(.borderless).font(.system(size: 12))
            KeyHint(keys: "esc")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func miniButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
    }
}

struct ShimmerBar: View {
    var body: some View {
        // TimelineView instead of @State: SwiftUI's @State macro needs Xcode's macro plugins.
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.2) / 1.2) * 2 - 1
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.primary.opacity(0.06), .primary.opacity(0.16), .primary.opacity(0.06)],
                                         startPoint: UnitPoint(x: phase, y: 0.5), endPoint: UnitPoint(x: phase + 1, y: 0.5)))
                    .frame(height: min(geo.size.height, 12))
            }
        }
    }
}

/// Key-capable full-screen window for the lens.
final class LensWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// ⌃⌥L: translate everything on the screen under the mouse, in place.
@MainActor
final class LensController {
    private let model: AppModel
    private var window: LensWindow?
    private var state = LensState()
    private var task: Task<Void, Never>?
    private var previousApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
    }

    /// Open (or still reading the screen before the window appears).
    var isVisible: Bool { (window?.isVisible ?? false) || task != nil }

    func toggle() {
        isVisible ? close() : open()
    }

    func open() {
        guard model.permissions.screenRecording else {
            model.permissions.requestScreenRecording()
            return
        }
        guard let screen = ScreenCapturer.screen(containing: NSEvent.mouseLocation) else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        state = LensState()
        task = Task {
            guard let shot = try? await ScreenCapturer.shared.captureScreen(screen), !Task.isCancelled else {
                task = nil
                return
            }
            showWindow(on: screen)
            let image = shot.image
            let lines: [RecognizedLine] = await Task.detached(priority: .userInitiated) {
                (try? TextRecognizer.recognize(image, options: RecognitionOptions(accurate: true))) ?? []
            }.value
            guard !Task.isCancelled else { return }
            let blocks = TextBlocks.group(lines).filter { $0.text.count >= 2 && TextTools.isMostlyLetters($0.text) }
            let frame = shot.frame
            var items: [LensState.Block] = []
            for b in blocks {
                let r = b.rect.denormalized(in: frame)
                let local = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
                let lang = model.engine.language(of: b.text)
                let lineHeight = b.lines.map { $0.rect.height * frame.height }.max() ?? 14
                items.append(.init(id: b.id, original: b.text, language: lang, translation: nil, rect: local,
                                   lineCount: b.lines.count, lineHeight: lineHeight))
            }
            // Translate the blocks nearest the mouse first.
            let mouseLocal = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
            items.sort { hypot($0.rect.midX - mouseLocal.x, $0.rect.midY - mouseLocal.y) < hypot($1.rect.midX - mouseLocal.x, $1.rect.midY - mouseLocal.y) }
            state.blocks = items
            state.status = items.isEmpty ? "No text found on this screen" : "Translating 0 of \(items.count)…"
            for i in items.indices {
                guard !Task.isCancelled else { return }
                let b = items[i]
                let to = b.language == model.target ? model.settings.primaryHelper : model.target
                let out = (try? await model.translator.translate(b.original, from: b.language, to: to)) ?? b.original
                guard !Task.isCancelled else { return }
                if let idx = state.blocks.firstIndex(where: { $0.id == b.id }) { state.blocks[idx].translation = out }
                state.done = i + 1
                state.status = i + 1 == items.count ? "\(items.count) blocks translated" : "Translating \(i + 1) of \(items.count)…"
            }
        }
    }

    private func showWindow(on screen: NSScreen) {
        let w = LensWindow(screen: screen)
        w.onEscape = { [weak self] in self?.close() }
        let actions = LensActions(
            close: { [weak self] in self?.close() },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            speak: { [weak self] text in self?.model.speak(text) },
            save: { [weak self] b in self?.save(b) },
            copyAll: { [weak self] in self?.copyAll() }
        )
        let host = NSHostingView(rootView: LensView(state: state, target: model.target, actions: actions))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        w.contentView = host
        w.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            w.animator().alphaValue = 1
        }
        window = w
    }

    func close() {
        task?.cancel()
        task = nil
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in w.orderOut(nil) }
        })
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp.activate() }
    }

    private func save(_ b: LensState.Block) {
        guard let t = b.translation else { return }
        let german = b.language == model.target ? b.original : t
        let meaning = b.language == model.target ? t : b.original
        let meaningLang = b.language == model.target ? model.settings.primaryHelper : b.language
        let (_, created) = model.savePhrase(german: german, meaning: meaning, meaningLanguage: meaningLang, source: .lens)
        state.toast = created ? "Saved" : "Already saved"
    }

    private func copyAll() {
        let text = state.blocks.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .compactMap(\.translation).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.toast = "Copied"
    }
}
