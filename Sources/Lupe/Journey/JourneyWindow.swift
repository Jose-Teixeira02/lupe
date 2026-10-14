import AppKit
import LupeCore
import SwiftUI

enum JourneySection: String, CaseIterable, Identifiable {
    case today, review, read, words, path, settings, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .review: "Review"
        case .read: "Read"
        case .words: "Words"
        case .path: "Path"
        case .settings: "Settings"
        case .help: "How it works"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .review: "rectangle.stack"
        case .read: "book"
        case .words: "text.book.closed"
        case .path: "map"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }
}

@MainActor
final class JourneyNav: ObservableObject {
    @Published var section: JourneySection? = .today
}

struct JourneyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: JourneyNav
    var review: ReviewSession
    var reading: ReadingState
    var words: WordsState
    var openAsk: () -> Void
    var reminderChanged: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.section) {
                Section {
                    ForEach([JourneySection.today, .review, .read, .words, .path]) { s in
                        Label(s.title, systemImage: s.symbol)
                            .badge(s == .review ? model.bank.dueCount(newLimit: model.settings.dailyNewCards) : 0)
                            .tag(s)
                    }
                }
                Section {
                    ForEach([JourneySection.settings, .help]) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Text("🔥 \(model.journey.streak)").font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(model.lexicon.info.flag) \(model.lexicon.info.nativeName)").font(.system(size: 12))
                    Spacer()
                }
                .padding(12)
            }
        } detail: {
            switch nav.section ?? .today {
            case .today: TodayView(model: model, openSection: { nav.section = $0 }, openAsk: openAsk)
            case .review: ReviewView(session: review, model: model)
            case .read: ReadingView(state: reading, model: model)
            case .words: WordsView(model: model, state: words)
            case .path: PathView(model: model)
            case .settings: SettingsView(model: model, settings: model.settings, permissions: model.permissions, reminderChanged: reminderChanged)
            case .help: HelpView()
            }
        }
        .frame(minWidth: 860, minHeight: 580)
    }
}

/// The main window. While it's open Lupe shows in the Dock and ⌘-Tab; otherwise it's menu-bar only.
@MainActor
final class JourneyWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private let nav = JourneyNav()
    private lazy var review = ReviewSession(model: model)
    private lazy var reading = ReadingState(model: model)
    private let words = WordsState()
    var openAsk: () -> Void = {}
    var reminderChanged: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    func show(_ section: JourneySection = .today) {
        nav.section = section
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Lupe"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: JourneyView(model: model, nav: nav, review: review, reading: reading, words: words,
                                                               openAsk: { [weak self] in self?.openAsk() },
                                                               reminderChanged: { [weak self] in self?.reminderChanged() }))
            w.setFrameAutosaveName("LupeJourney")
            if !w.setFrameUsingName("LupeJourney") { w.center() }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if review.started && review.current == nil { review.stop() }
        model.bank.flush()
        model.journey.flush()
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
