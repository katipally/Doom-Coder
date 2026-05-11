import AppKit
import Carbon.HIToolbox

// Global hotkey registration using Carbon Events (RegisterEventHotKey).
//
// We use Carbon because NSEvent.addGlobalMonitorForEvents swallows key
// events for everyone else but does NOT suppress the original keystroke
// — Carbon hotkeys do. Carbon hotkeys work without Accessibility
// permission (unlike CGEventTap), which matches Spotlight behavior.
//
// Default shortcut: ⌥ Space (option + space). User-rebindable via
// Settings → Keyboard; persisted in UserDefaults.
@Observable
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    /// True if the most recent registration failed (typically because another
    /// app already owns this shortcut). UI reads this to surface a banner.
    private(set) var conflictDetected: Bool = false

    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private static let signature: OSType = 0x44434844 // 'DCHD'
    @ObservationIgnored private static let hotKeyID: UInt32 = 1
    @ObservationIgnored private var onTrigger: (@MainActor () -> Void)?

    private init() {}

    struct Shortcut: Codable, Equatable {
        /// Carbon virtual keycode (e.g. kVK_Space = 49).
        var keyCode: UInt32
        /// Cocoa-style modifier flags stripped to Carbon (option/cmd/shift/ctrl).
        var carbonModifiers: UInt32

        static let defaultShortcut = Shortcut(
            keyCode: UInt32(kVK_Space),
            carbonModifiers: UInt32(optionKey) // ⌥ Space
        )

        var descriptionForUI: String {
            var parts: [String] = []
            if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
            if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("⌥") }
            if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("⇧") }
            if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("⌘") }
            parts.append(keyCodeDisplay(keyCode))
            return parts.joined()
        }

        private func keyCodeDisplay(_ code: UInt32) -> String {
            switch Int(code) {
            case kVK_Space:         return "Space"
            case kVK_Return:        return "Return"
            case kVK_Escape:        return "Esc"
            case kVK_Tab:           return "Tab"
            // Carbon keycodes are physical key positions, not ASCII order.
            case kVK_ANSI_A: return "A"
            case kVK_ANSI_B: return "B"
            case kVK_ANSI_C: return "C"
            case kVK_ANSI_D: return "D"
            case kVK_ANSI_E: return "E"
            case kVK_ANSI_F: return "F"
            case kVK_ANSI_G: return "G"
            case kVK_ANSI_H: return "H"
            case kVK_ANSI_I: return "I"
            case kVK_ANSI_J: return "J"
            case kVK_ANSI_K: return "K"
            case kVK_ANSI_L: return "L"
            case kVK_ANSI_M: return "M"
            case kVK_ANSI_N: return "N"
            case kVK_ANSI_O: return "O"
            case kVK_ANSI_P: return "P"
            case kVK_ANSI_Q: return "Q"
            case kVK_ANSI_R: return "R"
            case kVK_ANSI_S: return "S"
            case kVK_ANSI_T: return "T"
            case kVK_ANSI_U: return "U"
            case kVK_ANSI_V: return "V"
            case kVK_ANSI_W: return "W"
            case kVK_ANSI_X: return "X"
            case kVK_ANSI_Y: return "Y"
            case kVK_ANSI_Z: return "Z"
            default:
                return "Key(\(code))"
            }
        }
    }

    // MARK: - Persistence

    private static let defaultsKey = "com.doomcoder.globalHotkey.v1"

    var current: Shortcut {
        get {
            if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
               let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) {
                return decoded
            }
            return .defaultShortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
            reregister()
        }
    }

    // MARK: - Registration

    func register(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
        reregister()
    }

    func reregister() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr, hkID.signature == GlobalHotkey.signature {
                    DispatchQueue.main.async {
                        GlobalHotkey.shared.fire()
                    }
                }
                return noErr
            },
            1, &eventType, nil, &handler
        )

        let hkID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let s = current
        let status = RegisterEventHotKey(
            s.keyCode,
            s.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("DoomCoder: RegisterEventHotKey failed with status \(status)")
            conflictDetected = true
        } else {
            conflictDetected = false
        }
        _ = hkID
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = handler {
            RemoveEventHandler(h)
            handler = nil
        }
    }

    @MainActor
    fileprivate func fire() {
        onTrigger?()
    }
}
