import AppKit
import LupeCore
import SwiftUI

/// One label drawn on the overlay.
struct SprinkleLabel: Identifiable, Equatable {
    var id: String
    var text: String
    var gloss: String
    var gender: Gender?
    var pos: PartOfSpeech
    /// Word rectangle in the overlay's SwiftUI coordinates (top-left origin).
    var wordRect: CGRect
    var mode: SprinkleCandidate.Mode
    /// True when the page under the label is dark.
    var darkBackground: Bool
    var placement: Placement = .above

    enum Placement: Equatable { case above, below, cover }

    /// Chooses where the tag goes: above if there's room, else below, else over the word.
    static func placement(style: SprinkleStyle, spaceAbove: CGFloat, spaceBelow: CGFloat) -> Placement {
        switch style {
        case .above: return .above
        case .replace: return .cover
        case .auto:
            if spaceAbove >= 14 { return .above }
            if spaceBelow >= 14 { return .below }
            return .cover
        }
    }
}

@MainActor
final class SprinkleOverlayState: ObservableObject {
    @Published var labels: [SprinkleLabel] = []
    @Published var expanded: String?
    @Published var style: SprinkleStyle = .above
    @Published var visible = true
}

/// Transparent, click-through window covering one screen.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SprinkleOverlayView: View {
    @ObservedObject var state: SprinkleOverlayState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if state.visible {
                ForEach(state.labels) { label in
                    SprinkleTag(label: label, style: state.style, expanded: state.expanded == label.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.labels)
        .animation(.easeOut(duration: 0.15), value: state.expanded)
        .animation(.easeOut(duration: 0.12), value: state.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// The tag itself: "der Tisch" above "table", tinted by gender, with a thin underline on the original word.
struct SprinkleTag: View {
    var label: SprinkleLabel
    var style: SprinkleStyle
    var expanded: Bool

    private var color: Color { Theme.color(for: label.pos, gender: label.gender) }

    var body: some View {
        let r = label.wordRect
        let placement = expanded && label.placement == .cover ? .above : label.placement
        ZStack(alignment: .topLeading) {
            if placement != .cover {
                // Underline linking the tag to the word.
                Capsule()
                    .fill(color.opacity(0.65))
                    .frame(width: max(r.width, 6), height: 2)
                    .position(x: r.midX, y: placement == .above ? r.maxY + 1.5 : r.minY - 1.5)
                tag
                    .fixedSize()
                    .position(x: r.midX, y: placement == .above ? r.minY - tagHeight / 2 - 1 : r.maxY + tagHeight / 2 + 1)
            } else {
                // Cover the word with the German.
                Text(label.text)
                    .font(.system(size: max(9, min(r.height * 0.72, 18)), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .frame(minWidth: r.width + 4, minHeight: r.height + 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.94)))
                    .fixedSize()
                    .position(x: r.midX, y: r.midY)
            }
        }
    }

    private var tagHeight: CGFloat { expanded ? 18 : 15 }

    private var tag: some View {
        HStack(spacing: 4) {
            Text(label.text)
                .font(.system(size: expanded ? 12 : 10.5, weight: .semibold, design: .rounded))
            if expanded, !label.gloss.isEmpty {
                Text("· \(label.gloss)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: tagHeight)
        .background(Capsule().fill(color.opacity(label.darkBackground ? 0.85 : 0.92)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(label.darkBackground ? 0.25 : 0), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
