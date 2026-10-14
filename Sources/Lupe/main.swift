import AppKit

// `Lupe --snapshot <dir>` renders the main screens to PNG files (used to check the design without a display).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        Snapshots.render(to: dir)
    }
    exit(0)
}

// `Lupe --icon <file.png>` renders the 1024 px app icon (used by scripts/build-app.sh).
if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        Snapshots.renderIcon(to: url)
    }
    exit(0)
}

// One Lupe at a time: two copies would fight over the shortcuts and overwrite each other's deck.
// A second launch (another copy of the app, or opening it twice) hands over to the running one and quits.
if let id = Bundle.main.bundleIdentifier,
   let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    if let url = running.bundleURL {
        // Opening the running copy's bundle sends it a "reopen", which shows its main window.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
