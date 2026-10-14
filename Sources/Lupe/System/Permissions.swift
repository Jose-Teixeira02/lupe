import AppKit
import ApplicationServices
import LupeCore
import Combine
import CoreGraphics

/// Screen Recording (for reading pixels) and Accessibility (for exact text and selections).
/// Lupe never changes these itself; it explains why and opens the right System Settings pane.
@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let sr = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        let changed = sr != screenRecording || ax != accessibility || !wroteStatus
        if sr != screenRecording { screenRecording = sr }
        if ax != accessibility { accessibility = ax }
        if changed { writeStatus() }
    }

    private var wroteStatus = false

    /// `status.json` in the data folder, so the permission state can be checked from a terminal.
    private func writeStatus() {
        wroteStatus = true
        let info: [String: Any] = [
            "screenRecording": screenRecording, "accessibility": accessibility,
            "version": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev",
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: LupePaths.appSupport.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    /// Shows the system prompt once; afterwards macOS only allows toggling it in System Settings.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings(anchor: "Privacy_ScreenCapture")
        }
        refresh()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings(anchor: "Privacy_Accessibility")
        }
        refresh()
    }

    func openSettings(anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}
