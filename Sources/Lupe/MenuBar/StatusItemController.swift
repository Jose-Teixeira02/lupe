import AppKit
import SwiftUI

/// The menu-bar icon and its popover.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel, actions: MenuActions) {
        self.model = model
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "character.magnify", accessibilityDescription: "Lupe")
                ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Lupe")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        var wrapped = actions
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        wrapped.openAsk = { close(); actions.openAsk() }
        wrapped.openLens = { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { actions.openLens() } }
        wrapped.openJourney = { s in close(); actions.openJourney(s) }
        wrapped.openSettings = { close(); actions.openSettings() }
        wrapped.openOnboarding = { close(); actions.openOnboarding() }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuView(model: model, actions: wrapped))
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.permissions.refresh()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Shows the number of due cards next to the icon (only when there are some).
    func updateBadge(due: Int) {
        item.button?.title = due > 0 ? " \(due)" : ""
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }
}
