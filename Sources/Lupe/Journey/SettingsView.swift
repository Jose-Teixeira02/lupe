import AppKit
import LupeCore
import SwiftUI

/// Holds the API key while it's typed (SwiftUI's @State needs Xcode's macro plugins).
@MainActor
final class KeyDraft: ObservableObject {
    @Published var text = ""
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LupeSettings
    @ObservedObject var permissions: Permissions
    @StateObject private var keyDraft = KeyDraft()
    var reminderChanged: () -> Void

    var body: some View {
        Form {
            Section("Languages") {
                Picker("I'm learning", selection: $settings.targetLanguage) {
                    ForEach(LupePaths.availablePacks(), id: \.code) { p in
                        Text("\(p.flag) \(p.nativeName)").tag(p.code)
                    }
                }
                Picker("Explain things in", selection: $settings.primaryHelper) {
                    Text("🇬🇧 English").tag("en")
                    Text("🇵🇹 Português").tag("pt")
                }
                Picker("My level when I started", selection: $settings.placementLevel) {
                    Text("Just starting").tag("none")
                    Text("A1 · basics").tag("A1")
                    Text("A2 · everyday").tag("A2")
                    Text("B1 · independent").tag("B1")
                    Text("B2 · fluent-ish").tag("B2")
                }
                LabeledContent("On-device translation") {
                    Text(model.translationStatus == "installed" ? "Ready ✓" :
                            model.translationStatus == "supported" ? "Language pack not downloaded" : "Checking…")
                        .foregroundStyle(model.translationStatus == "installed" ? Theme.success : Theme.warm)
                }
                if model.translationStatus == "supported" {
                    Button("Download languages in System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                }
                LabeledContent("Voice") { Text(Speech.shared.voiceDescription(for: model.lexicon.info.speechLanguage)) }
                if !Speech.shared.voiceDescription(for: model.lexicon.info.speechLanguage).contains("premium")
                    && !Speech.shared.voiceDescription(for: model.lexicon.info.speechLanguage).contains("enhanced") {
                    Text("Tip: for a more natural German voice, download an Enhanced or Premium German voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("Slower speech for practice", isOn: $settings.slowSpeech)
            }

            Section {
                Toggle("Hover lens", isOn: $settings.hoverEnabled)
                Picker("Hold this key", selection: $settings.hoverModifier) {
                    ForEach(HoverModifier.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Rest time before lookup") {
                    HStack {
                        Slider(value: $settings.hoverDwellMs, in: 60...600, step: 20).frame(width: 180)
                        Text("\(Int(settings.hoverDwellMs)) ms").font(.system(size: 11, design: .monospaced)).frame(width: 56)
                    }
                }
                Toggle("Add looked-up words to my deck automatically", isOn: $settings.autoSaveLookups)
                Toggle("Pronounce words when they appear", isOn: $settings.speakOnLookup)
                Toggle("Prefer exact text from apps (Accessibility)", isOn: $settings.preferAccessibilityText)
            } header: {
                Text("Hover lens")
            } footer: {
                Text("⌃ is the default because ⌥ is used to type characters like @ and [ on the Portuguese keyboard.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sprinkles", isOn: $settings.sprinklesEnabled)
                Stepper("At most \(settings.sprinkleBudget) tags per screen", value: $settings.sprinkleBudget, in: 1...15)
                Picker("Style", selection: $settings.sprinkleStyle) {
                    ForEach(SprinkleStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("German tags on English & Portuguese text", isOn: $settings.sprinkleTeach)
                Toggle("Meanings over hard words in German text", isOn: $settings.sprinkleAssistGerman)
                LabeledContent("Check the screen every") {
                    HStack {
                        Slider(value: $settings.sprinkleIntervalSec, in: 0.8...5, step: 0.1).frame(width: 180)
                        Text(String(format: "%.1f s", settings.sprinkleIntervalSec)).font(.system(size: 11, design: .monospaced)).frame(width: 56)
                    }
                }
                excludedApps
            } header: {
                Text("Sprinkles")
            } footer: {
                Text("Tags favour words you're learning, then the next most useful words for your level. Words you know never get a tag.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Picker("Explanations and grammar checks by", selection: $settings.tutorProvider) {
                    Text("Apple Intelligence (on-device, free)").tag("device")
                    Text("Claude (your API key)").tag("claude")
                }
                if settings.tutorProvider == "claude" {
                    if model.hasClaudeKey {
                        LabeledContent("API key") {
                            HStack {
                                Text("Stored in your Keychain ✓").foregroundStyle(Theme.success)
                                Button("Remove") { model.removeClaudeKey() }
                            }
                        }
                    } else {
                        HStack {
                            SecureField("Anthropic API key (sk-ant-…)", text: $keyDraft.text)
                            Button("Save") {
                                model.saveClaudeKey(keyDraft.text)
                                keyDraft.text = ""
                            }
                            .disabled(keyDraft.text.isEmpty)
                        }
                    }
                }
            } header: {
                Text("AI explanations")
            } footer: {
                Text(settings.tutorProvider == "claude"
                     ? "Only the sentence you ask about is sent to Anthropic when you press Explain or ⌘K check. Translation, reading and speech stay on this Mac. Uses \(ClaudeTutor.model); your Anthropic account is billed per request."
                     : "On-device AI is free and private, and good at fixing sentences. Its explanations are sometimes wrong, so Lupe labels them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Daily practice") {
                Stepper("Daily goal: \(model.journey.dailyGoalXP) XP", value: Binding(get: { model.journey.dailyGoalXP }, set: { model.journey.dailyGoalXP = $0 }), in: 10...300, step: 10)
                Stepper("New cards per session: \(settings.dailyNewCards)", value: $settings.dailyNewCards, in: 0...50)
                Toggle("Daily reminder", isOn: Binding(get: { settings.reminderEnabled }, set: { settings.reminderEnabled = $0; reminderChanged() }))
                if settings.reminderEnabled {
                    DatePicker("Remind me at", selection: Binding(get: {
                        Calendar.current.date(from: DateComponents(hour: settings.reminderHour, minute: settings.reminderMinute)) ?? Date()
                    }, set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        settings.reminderHour = c.hour ?? 19
                        settings.reminderMinute = c.minute ?? 0
                        reminderChanged()
                    }), displayedComponents: .hourAndMinute)
                }
            }

            Section {
                permissionRow("Screen Recording", granted: permissions.screenRecording,
                              why: "Read words under the mouse in any app, Sprinkles and Lens.") { permissions.requestScreenRecording() }
                permissionRow("Accessibility", granted: permissions.accessibility,
                              why: "Exact text in native apps and translating your selection (⌃⌥S).") { permissions.requestAccessibility() }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Everything runs on this Mac: text recognition, translation, speech and AI notes. Nothing on your screen is sent anywhere.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Stored in") {
                    Button(LupePaths.appSupport.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.open(LupePaths.appSupport)
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Language packs") {
                    Button("Open packs folder") {
                        let dir = LupePaths.appSupport.appendingPathComponent("packs")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var excludedApps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Never read these apps").font(.system(size: 12))
            Text(settings.excludedApps.map(Self.appName).joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Exclude the app I used last") {
                if let id = NSWorkspace.shared.runningApplications.first(where: {
                    $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.isActive == false
                })?.bundleIdentifier, !settings.excludedApps.contains(id) {
                    settings.excludedApps.append(id)
                }
            }
            .buttonStyle(.link).font(.system(size: 11))
        }
    }

    /// "Bitwarden" for com.bitwarden.desktop when installed, else a readable part of the bundle id.
    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let parts = bundleID.split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[parts.count - 2].capitalized : bundleID
    }

    private func permissionRow(_ name: String, granted: Bool, why: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? Theme.success : Theme.warm)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("How Lupe works").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Four layers, from quiet to on-demand. Everything feeds one deck that reminds you of words just before you'd forget them.")
                    .foregroundStyle(.secondary)
                item("character.magnify", "Ask bar", Shortcuts.ask.display,
                     "Type English or Portuguese to get German, with every word broken down by gender. Type German to see its meaning and get it checked. ⏎ copies the German.")
                item("hand.point.up.left", "Hover lens", "hold ⌃",
                     "Hold Control and rest the mouse on any word, in any app. You get the German with gender, plural or verb forms, and the whole sentence translated. Looked-up words are saved with the sentence you found them in.")
                item("sparkles", "Sprinkles", Shortcuts.sprinkles.display,
                     "A handful of German tags over English or Portuguese words on screen, chosen from what you're learning. Over German text, tags show meanings for hard words. Rest the mouse on a tag to see more.")
                item("text.viewfinder", "Lens", Shortcuts.lens.display,
                     "Translates every block of text on the screen in place, like Google Lens. Hover a block to listen, copy or save it. Esc closes.")
                item("text.cursor", "Translate selection", Shortcuts.selection.display,
                     "Select text in any app and press the shortcut (needs Accessibility). Without it, right-click → Services → Translate with Lupe.")
                item("map", "Journey", Shortcuts.journey.display,
                     "Daily review, streaks, your words and your path from A1 to C1.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Colours").font(.system(size: 16, weight: .semibold, design: .rounded))
                    HStack(spacing: 14) {
                        GenderedWord(display: "der Tisch", gender: .masculine, pos: .noun, size: 16)
                        GenderedWord(display: "die Tür", gender: .feminine, pos: .noun, size: 16)
                        GenderedWord(display: "das Fenster", gender: .neuter, pos: .noun, size: 16)
                        GenderedWord(display: "die Leute", gender: .plural, pos: .noun, size: 16)
                    }
                    HStack(spacing: 14) {
                        Tag(text: "der", color: Theme.der); Tag(text: "die", color: Theme.die)
                        Tag(text: "das", color: Theme.das); Tag(text: "plural", color: Theme.plural)
                        Tag(text: "verb", color: Theme.color(for: .verb, gender: nil))
                        Tag(text: "adjective", color: Theme.color(for: .adjective, gender: nil))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Privacy").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Text recognition (Vision), translation (Apple Translation), speech and AI notes (Apple Intelligence) all run on this Mac. Lupe never uploads screenshots or text. Your deck lives in ~/Library/Application Support/Lupe as plain JSON.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a language").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Packs are plain text: one word per line (lemma | part of speech | gender | forms | English | Portuguese | level). Drop a folder with pack.json and *.tsv into the packs folder (Settings → Data) and pick it under Languages.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
        }
    }

    private func item(_ symbol: String, _ title: String, _ keys: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                    KeyHint(keys: keys)
                }
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
