import LupeCore
import SwiftUI

struct MenuActions {
    var openAsk: () -> Void = {}
    var openLens: () -> Void = {}
    var openJourney: (JourneySection) -> Void = { _ in }
    var toggleSprinkles: () -> Void = {}
    var pauseSprinkles: () -> Void = {}
    var openSettings: () -> Void = {}
    var openOnboarding: () -> Void = {}
    var quit: () -> Void = {}
}

/// The menu-bar popover: today's progress, the review button, mode toggles and the word of the day.
struct MenuView: View {
    @ObservedObject var model: AppModel
    var actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            reviewButton
            toggles
            Divider()
            quickActions
            if let w = model.wordOfTheDay { wordOfTheDay(w) }
            permissionWarnings
            if !model.lastActivity.isEmpty {
                Text(model.lastActivity).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                ProgressRing(progress: model.journey.goalProgress, lineWidth: 5, color: Theme.accent)
                    .frame(width: 42, height: 42)
                Text("\(model.journey.today.xp)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.greeting).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(goalText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 0) {
                Text("🔥").font(.system(size: 18))
                    .saturation(model.journey.streak > 0 ? 1 : 0)
                Text("\(model.journey.streak)").font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(model.journey.streak > 0 ? Theme.streak : .secondary)
            }
            .help("Day streak")
        }
    }

    private var goalText: String {
        let today = model.journey.today
        if model.journey.goalProgress >= 1 { return "Daily goal reached. Toll gemacht!" }
        return "\(today.xp) / \(model.journey.dailyGoalXP) XP today · \(today.lookups) lookups"
    }

    private var reviewButton: some View {
        let due = model.bank.dueCount(newLimit: model.settings.dailyNewCards)
        return Button { actions.openJourney(.review) } label: {
            HStack {
                Image(systemName: due > 0 ? "rectangle.stack.fill" : "checkmark.seal.fill")
                Text(due > 0 ? "Review · \(due) due" : "All caught up").fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).opacity(0.7)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(due > 0 ? Theme.accent : Color.primary.opacity(0.06)))
            .foregroundStyle(due > 0 ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.settings.hoverEnabled }, set: { model.settings.hoverEnabled = $0 })) {
                HStack {
                    Text("Hover lens")
                    Text("hold \(model.settings.hoverModifier.label.components(separatedBy: " ").first ?? "⌃")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle(isOn: Binding(get: { model.settings.sprinklesEnabled }, set: { _ in actions.toggleSprinkles() })) {
                    HStack {
                        Text("Sprinkles")
                        Text("German tags on screen").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if model.settings.sprinklesEnabled {
                    if let until = model.sprinklesPausedUntil, until > Date() {
                        Text("paused").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Button("Pause 1h", action: actions.pauseSprinkles).buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 13))
    }

    private var quickActions: some View {
        VStack(spacing: 2) {
            row("character.magnify", "Ask: how do I say…?", Shortcuts.ask.display, action: actions.openAsk)
            row("text.viewfinder", "Translate this screen", Shortcuts.lens.display, action: actions.openLens)
            row("map", "Open your Journey", Shortcuts.journey.display) { actions.openJourney(.today) }
        }
    }

    private func row(_ symbol: String, _ title: String, _ keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13))
                Spacer()
                KeyHint(keys: keys)
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func wordOfTheDay(_ e: LexEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WORD OF THE DAY").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).tracking(0.8)
            HStack(alignment: .firstTextBaseline) {
                GenderedWord(display: model.lexicon.display(e), gender: e.gender, pos: e.pos, size: 18)
                Spacer()
                Button { model.speak(e.lemma) } label: { Image(systemName: "speaker.wave.2.fill") }.buttonStyle(.borderless)
                Button { model.addWordOfTheDay() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless).help("Add to your deck")
            }
            Text(e.glossList(model.settings.primaryHelper, limit: 3))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !e.forms.isEmpty {
                Text(model.lexicon.grammarLine(e)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.color(for: e.pos, gender: e.gender).opacity(0.07)))
    }

    @ViewBuilder
    private var permissionWarnings: some View {
        if !model.permissions.screenRecording || !model.permissions.accessibility {
            VStack(alignment: .leading, spacing: 6) {
                if !model.permissions.screenRecording {
                    warning("Screen Recording is off: hover in all apps, Sprinkles and Lens need it.", button: "Allow") {
                        model.permissions.requestScreenRecording()
                    }
                }
                if !model.permissions.accessibility {
                    warning("Accessibility is off: exact text and ⌃⌥S selection need it.", button: "Allow") {
                        model.permissions.requestAccessibility()
                    }
                }
            }
        }
    }

    private func warning(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warm)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: actions.openSettings).buttonStyle(.borderless)
            Button("Tour", action: actions.openOnboarding).buttonStyle(.borderless)
            Spacer()
            Text("\(model.lexicon.info.flag) \(model.bank.cards.count) words").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Quit", action: actions.quit).buttonStyle(.borderless)
        }
        .font(.system(size: 12))
    }
}
