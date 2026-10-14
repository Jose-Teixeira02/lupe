import AppKit
import Combine
import LupeCore
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel!
    private var hover: HoverController!
    private var sprinkles: SprinkleController!
    private var ask: AskController!
    private var lens: LensController!
    private var journey: JourneyWindowController!
    private var onboarding: OnboardingWindowController!
    private var statusItem: StatusItemController!
    private var services: ServiceProvider!
    private var badgeTimer: Timer?
    private var subs: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(settings: LupeSettings())

        hover = HoverController(model: model)
        sprinkles = SprinkleController(model: model)
        hover.sprinkleHit = { [weak self] p in self?.sprinkles.hit(at: p) }
        ask = AskController(model: model)
        lens = LensController(model: model)
        journey = JourneyWindowController(model: model)
        journey.openAsk = { [weak self] in self?.ask.open(prefill: nil) }
        journey.reminderChanged = { [weak self] in self?.scheduleReminder() }
        onboarding = OnboardingWindowController(model: model)
        onboarding.tryAsk = { [weak self] in self?.ask.open(prefill: "I'm running late") }
        onboarding.onFinish = { [weak self] in self?.journey.show(.today) }

        statusItem = StatusItemController(model: model, actions: MenuActions(
            openAsk: { [weak self] in self?.ask.open(prefill: nil) },
            openLens: { [weak self] in self?.lens.toggle() },
            openJourney: { [weak self] s in self?.journey.show(s) },
            toggleSprinkles: { [weak self] in self?.sprinkles.toggle() },
            pauseSprinkles: { [weak self] in self?.sprinkles.pause(for: 3600) },
            openSettings: { [weak self] in self?.journey.show(.settings) },
            openOnboarding: { [weak self] in self?.onboarding.show() },
            quit: { NSApp.terminate(nil) }
        ))

        registerHotKeys()
        services = ServiceProvider { [weak self] text in self?.ask.open(prefill: text) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        // Language/helper changes rebuild the hover card's view.
        model.settings.$primaryHelper.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.hover.refreshView() }
        }.store(in: &subs)
        model.settings.$targetLanguage.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.hover.refreshView() }
        }.store(in: &subs)

        updateBadge()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBadge() }
        }
        // The model forwards changes from whichever bank is current (it's replaced on language switch).
        model.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &subs)

        warmUp()
        if !model.settings.hasOnboarded {
            onboarding.show()
        }
        if model.settings.reminderEnabled { scheduleReminder() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.bank.flush()
        model?.journey.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        journey.show(.today)
        return true
    }

    // MARK: Setup

    private func registerHotKeys() {
        let hk = HotKeyCenter.shared
        hk.register(Shortcuts.ask) { [weak self] in self?.ask.toggle() }
        hk.register(Shortcuts.lens) { [weak self] in self?.lens.toggle() }
        hk.register(Shortcuts.sprinkles) { [weak self] in self?.sprinkles.toggle() }
        hk.register(Shortcuts.journey) { [weak self] in self?.journey.show(.today) }
        hk.register(Shortcuts.selection) { [weak self] in self?.translateSelection() }
    }

    private func translateSelection() {
        Task {
            let text = await Task.detached { AXReader.selectedText() }.value
            if let text {
                ask.open(prefill: text)
            } else {
                ask.open(prefill: nil)
                if !AXReader.isTrusted { model.permissions.requestAccessibility() }
            }
        }
    }

    /// The first OCR call can take many seconds while Vision loads its model; do it now, in the background.
    private func warmUp() {
        Task.detached(priority: .background) { TextRecognizer.warmUp() }
        let pairs = model.settings.helpers.map { ($0, model.target) } + [(model.target, model.settings.primaryHelper)]
        let translator = model.translator
        Task.detached(priority: .background) { await translator.warmUp(pairs: pairs) }
    }

    private func updateBadge() {
        statusItem.updateBadge(due: model.bank.dueCount(newLimit: model.settings.dailyNewCards))
    }

    // MARK: Reminder

    func scheduleReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["lupe.daily"])
        guard model.settings.reminderEnabled else { return }
        let hour = model.settings.reminderHour, minute = model.settings.reminderMinute
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Fünf Minuten Deutsch?"
            content.body = Self.reminderLines.randomElement() ?? "Your words are waiting."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
            center.add(UNNotificationRequest(identifier: "lupe.daily", content: content, trigger: trigger))
        }
    }

    nonisolated static let reminderLines = [
        "Your words are waiting. A short review keeps the streak alive 🔥",
        "Quick review before Feierabend? ⌃⌥J",
        "The words you met this week want to say hallo again.",
        "Five minutes now saves an hour of re-learning later.",
    ]
}

/// "Translate with Lupe" in every app's right-click → Services menu. Needs no permissions.
final class ServiceProvider: NSObject {
    private let handler: @MainActor (String) -> Void

    init(handler: @escaping @MainActor (String) -> Void) {
        self.handler = handler
    }

    @objc func translateService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        let h = handler
        Task { @MainActor in h(text) }
    }
}
