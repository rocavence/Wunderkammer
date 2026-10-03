import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts via Carbon's RegisterEventHotKey: works in every
/// app without Accessibility permission, and doesn't activate Wunderkammer.
@MainActor
final class GlobalHotkeys {
    struct Shortcut: Equatable {
        var keyCode: Int
        var modifiers: NSEvent.ModifierFlags

        /// ⌃⌥⇧⌘ order, then the key.
        var display: String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + Self.keyName(keyCode)
        }

        static func keyName(_ code: Int) -> String {
            var names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←",
                                        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Escape: "⎋",
                                        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
                                        kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
            let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            for (i, k) in fkeys.enumerated() { names[k] = "F\(i + 1)" }
            if let n = names[code] { return n }
            // Ask the keyboard layout what the key types.
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            data.withUnsafeBytes { ptr in
                _ = UCKeyTranslate(ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code), UInt16(kUCKeyActionDisplay),
                                   0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            }
            let typed = String(utf16CodeUnits: chars, count: length)
            // Control characters aren't something to show.
            guard typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), !typed.isEmpty else { return "?" }
            return typed.uppercased()
        }

        /// Stored as "keyCode:modifierRawValue".
        var stored: String { "\(keyCode):\(modifiers.intersection([.command, .shift, .option, .control]).rawValue)" }

        init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.command, .shift, .option, .control])
        }

        init?(stored: String) {
            let parts = stored.split(separator: ":").compactMap { UInt(String($0)) }
            guard parts.count == 2 else { return nil }
            self.init(keyCode: Int(parts[0]), modifiers: NSEvent.ModifierFlags(rawValue: parts[1]))
        }

        var carbonModifiers: UInt32 {
            var m: UInt32 = 0
            if modifiers.contains(.command) { m |= UInt32(cmdKey) }
            if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
            if modifiers.contains(.option) { m |= UInt32(optionKey) }
            if modifiers.contains(.control) { m |= UInt32(controlKey) }
            return m
        }
    }

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x574B_4D52 // 'WKMR'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Returns false when another app already holds the combination.
    @discardableResult
    func register(_ shortcut: Shortcut, _ handler: @escaping @MainActor () -> Void) -> Bool {
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        handlers = [:]
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }
}

private let hotkeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var id = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
    let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
    let key = id.id
    Task { @MainActor in hotkeys.fire(key) }
    return noErr
}
