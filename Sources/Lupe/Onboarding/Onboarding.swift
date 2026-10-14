import AppKit
import LupeCore
import SwiftUI

@MainActor
final class OnboardingState: ObservableObject {
    @Published var page = 0
    let pages = 5
}

struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LupeSettings
    @ObservedObject var permissions: Permissions
    var tryAsk: () -> Void
    var finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.page {
                case 0: welcome
                case 1: languages
                case 2: level
                case 3: permissionsPage
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(state.page)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<state.pages, id: \.self) { i in
                        Capsule().fill(i == state.page ? Theme.accent : Color.secondary.opacity(0.25))
                            .frame(width: i == state.page ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                if state.page > 0 {
                    Button("Back") { withAnimation { state.page -= 1 } }
                }
                Button(state.page == state.pages - 1 ? "Start my journey" : "Continue") {
                    if state.page == state.pages - 1 { finish() } else { withAnimation { state.page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
        .animation(.easeOut(duration: 0.25), value: state.page)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                AppMark(size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lupe").font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("German, everywhere you look.").font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Text("No more copying sentences into DeepL. Lupe lives in your menu bar and turns everything you already read into practice, without changing any app or system language.")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                feature("character.magnify", "Ask", "⌃⌥D: type English or Português, get German. Type German, get it checked.")
                feature("hand.point.up.left", "Hover", "Hold ⌃ on any word in any app for gender, forms and the sentence translated.")
                feature("sparkles", "Sprinkles", "A few German tags on what you read, picked from what you're learning.")
                feature("rectangle.stack", "Remember", "Every word you meet becomes a card with your sentence, reviewed just before you'd forget it.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your languages").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Meanings and explanations will be shown in…").foregroundStyle(.secondary)
            HStack(spacing: 14) {
                choice(selected: settings.primaryHelper == "en", title: "🇬🇧  English", subtitle: "Portuguese shown second") { settings.primaryHelper = "en" }
                choice(selected: settings.primaryHelper == "pt", title: "🇵🇹  Português", subtitle: "English shown second") { settings.primaryHelper = "pt" }
            }
            Text("I'm learning…").foregroundStyle(.secondary).padding(.top, 8)
            HStack(spacing: 14) {
                ForEach(LupePaths.availablePacks(), id: \.code) { p in
                    choice(selected: settings.targetLanguage == p.code, title: "\(p.flag)  \(p.nativeName)",
                           subtitle: "\(p.name) · on-device") { settings.targetLanguage = p.code }
                }
                choice(selected: false, title: "🇳🇴  Norsk", subtitle: "Coming as a pack", enabled: false) {}
            }
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where are you starting?").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Lupe won't put tags on words you probably know, and your path starts from here. You can change this later.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                levelRow("none", "Just starting", "I know a few words like Hallo and danke.")
                levelRow("A1", "A1 · Basics", "I can introduce myself and order in a café.")
                levelRow("A2", "A2 · Everyday", "I handle shopping, directions and simple chats.")
                levelRow("B1", "B1 · Independent", "I follow the gist of articles and conversations.")
                levelRow("B2", "B2 · Fluent-ish", "I watch series and discuss most topics.")
            }
        }
    }

    private func levelRow(_ tag: String, _ title: String, _ text: String) -> some View {
        let selected = settings.placementLevel == tag
        return Button { settings.placementLevel = tag } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.1) : Color.primary.opacity(0.03)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let Lupe read your screen").font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Both are optional: the Ask bar and your reviews work without them. Everything happens on this Mac; nothing on your screen is ever uploaded.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            permissionCard(granted: permissions.screenRecording, symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                           text: "Reads words under the mouse in every app (even PDFs, images and videos), and powers Sprinkles and Lens. macOS asks again every few weeks; that's normal.",
                           action: { permissions.requestScreenRecording() })
            permissionCard(granted: permissions.accessibility, symbol: "accessibility", title: "Accessibility",
                           text: "Gives exact text in native apps like Safari, Mail and Notes, and lets ⌃⌥S translate your selection.",
                           action: { permissions.requestAccessibility() })
            Text("After allowing Screen Recording, macOS may ask you to quit and reopen Lupe.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func permissionCard(granted: Bool, symbol: String, title: String, text: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.system(size: 12, weight: .medium))
            } else {
                Button("Allow…", action: action)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it now").font(.system(size: 28, weight: .bold, design: .rounded))
            step("1", "Press ⌃⌥D and type “I'm running late”.", "You'll get the German, every word coloured by gender, and ⏎ copies it.")
            step("2", "Hold ⌃ and rest the mouse on any word in this window or in Safari.", "A card shows the German, its article and plural, and the whole sentence translated.")
            step("3", "Open the Journey (⌃⌥J) tomorrow.", "The words you looked up today come back as cards, with the sentence where you met them.")
            HStack {
                Button { tryAsk() } label: { Label("Open the Ask bar", systemImage: "character.magnify") }
                Spacer()
                Text("Lupe lives in the menu bar ↗︎").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private func step(_ n: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choice(selected: Bool, title: String, subtitle: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 190, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The app mark: a lens over a gendered "ä", drawn in SwiftUI (also used to render the app icon).
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.85), Color(red: 0.36, green: 0.22, blue: 0.80)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // Lens ring
            Circle()
                .strokeBorder(Color.white, lineWidth: size * 0.075)
                .frame(width: size * 0.52, height: size * 0.52)
                .offset(x: -size * 0.06, y: -size * 0.06)
            // Handle
            Capsule()
                .fill(Color.white)
                .frame(width: size * 0.09, height: size * 0.26)
                .rotationEffect(.degrees(-45))
                .offset(x: size * 0.2, y: size * 0.2)
            Text("ä")
                .font(.system(size: size * 0.30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .offset(x: -size * 0.06, y: -size * 0.08)
            // Three gender dots
            HStack(spacing: size * 0.035) {
                Circle().fill(Theme.der).frame(width: size * 0.07)
                Circle().fill(Theme.die).frame(width: size * 0.07)
                Circle().fill(Theme.das).frame(width: size * 0.07)
            }
            .offset(x: -size * 0.06, y: size * 0.36)
        }
        .frame(width: size, height: size)
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private let state = OnboardingState()
    var tryAsk: () -> Void = {}
    var onFinish: () -> Void = {}

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        state.page = 0
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView(
                state: state, model: model, settings: model.settings, permissions: model.permissions,
                tryAsk: { [weak self] in self?.tryAsk() },
                finish: { [weak self] in self?.finish() }))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        model.settings.hasOnboarded = true
        window?.close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        model.settings.hasOnboarded = true
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}
