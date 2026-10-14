import AppKit
import LupeCore
import SwiftUI

/// Visual language: calm surfaces, one warm accent, and the classic learner colours for gender
/// (der = blue, die = red, das = green, plural = amber).
enum Theme {
    static let accent = Color(red: 0.20, green: 0.42, blue: 0.95)
    static let warm = Color(red: 0.98, green: 0.55, blue: 0.20)
    static let streak = Color(red: 1.0, green: 0.48, blue: 0.16)
    static let success = Color(red: 0.16, green: 0.66, blue: 0.42)

    static let der = Color(red: 0.16, green: 0.45, blue: 0.95)
    static let die = Color(red: 0.89, green: 0.24, blue: 0.33)
    static let das = Color(red: 0.13, green: 0.62, blue: 0.38)
    static let plural = Color(red: 0.90, green: 0.58, blue: 0.10)
    static let neutral = Color(red: 0.42, green: 0.40, blue: 0.62)

    static func color(for gender: Gender?) -> Color {
        switch gender {
        case .masculine?: der
        case .feminine?: die
        case .neuter?: das
        case .plural?: plural
        case nil: neutral
        }
    }

    static func nsColor(for gender: Gender?) -> NSColor {
        NSColor(color(for: gender))
    }

    static func color(for pos: PartOfSpeech?, gender: Gender?) -> Color {
        if pos == .noun || gender != nil { return color(for: gender) }
        switch pos {
        case .verb?: return Color(red: 0.55, green: 0.33, blue: 0.85)
        case .adjective?, .adverb?: return Color(red: 0.10, green: 0.55, blue: 0.65)
        default: return neutral
        }
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "en": "English"
        case "pt": "Português"
        case "de": "Deutsch"
        case "nb": "Norsk"
        default: Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }

    static func flag(_ code: String) -> String {
        switch code {
        case "en": "🇬🇧"
        case "pt": "🇵🇹"
        case "de": "🇩🇪"
        case "nb": "🇳🇴"
        default: "🏳️"
        }
    }
}

/// "der Tisch" with the article tinted by gender.
struct GenderedWord: View {
    var display: String
    var gender: Gender?
    var pos: PartOfSpeech?
    var size: CGFloat = 22
    var weight: Font.Weight = .semibold

    var body: some View {
        let parts = display.split(separator: " ", maxSplits: 1).map(String.init)
        let color = Theme.color(for: pos, gender: gender)
        Group {
            if parts.count == 2, ["der", "die", "das"].contains(parts[0]) {
                (Text(parts[0] + " ").foregroundStyle(color.opacity(0.9)).font(.system(size: size * 0.78, weight: .medium, design: .rounded))
                    + Text(parts[1]).foregroundStyle(.primary).font(.system(size: size, weight: weight, design: .rounded)))
            } else {
                Text(display).font(.system(size: size, weight: weight, design: .rounded))
            }
        }
        .lineLimit(2)
        .minimumScaleFactor(0.6)
    }
}

/// Small rounded tag, e.g. "noun", "A1".
struct Tag: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

/// Keyboard shortcut hint, e.g. ⌃⌥D.
struct KeyHint: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.35)))
            .foregroundStyle(.secondary)
    }
}

/// NSVisualEffectView for SwiftUI backgrounds in floating panels.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Circular progress ring used for the daily goal.
struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 6
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
