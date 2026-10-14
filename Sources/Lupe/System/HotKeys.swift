import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon's RegisterEventHotKey. Needs no permissions.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    struct Shortcut: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32

        static let controlOption = UInt32(controlKey | optionKey)

        /// "⌃⌥D"
        var display: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + (Self.keyNames[keyCode] ?? "?")
        }

        static let keyNames: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_S): "S",
            UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_J): "J", UInt32(kVK_Space): "Space",
        ]
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// Returns false if another app already owns the shortcut.
    @discardableResult
    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C555045), id: id) // 'LUPE'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The app's default shortcuts. ⌃⌥ avoids clashing with ⌥ characters on the Portuguese layout.
enum Shortcuts {
    static let ask = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: HotKeyCenter.Shortcut.controlOption)
    static let lens = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: HotKeyCenter.Shortcut.controlOption)
    static let selection = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: HotKeyCenter.Shortcut.controlOption)
    static let sprinkles = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_I), modifiers: HotKeyCenter.Shortcut.controlOption)
    static let journey = HotKeyCenter.Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: HotKeyCenter.Shortcut.controlOption)
}
