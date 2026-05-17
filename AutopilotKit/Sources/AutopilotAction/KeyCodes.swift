import AutopilotCore
import CoreGraphics

/// Maps key names to macOS virtual key codes for synthesized key events.
enum KeyCodes {
    private static let table: [String: CGKeyCode] = [
        // Editing and whitespace
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "del": 0x33,
        "forwarddelete": 0x75,
        "escape": 0x35, "esc": 0x35,

        // Arrows
        "left": 0x7B, "leftarrow": 0x7B, "arrowleft": 0x7B,
        "right": 0x7C, "rightarrow": 0x7C, "arrowright": 0x7C,
        "down": 0x7D, "downarrow": 0x7D, "arrowdown": 0x7D,
        "up": 0x7E, "uparrow": 0x7E, "arrowup": 0x7E,

        // Navigation
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,

        // Function keys
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,

        // Letters and digits
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
        "k": 0x28, "n": 0x2D, "m": 0x2E
    ]

    /// The virtual key code for a key name, if known.
    ///
    /// Matching is lenient: letter case and any spaces, hyphens, or
    /// underscores are ignored, so "Page Up", "page-up", and "pageup" all
    /// resolve to the same key.
    static func code(for keyName: String) -> CGKeyCode? {
        table[normalize(keyName)]
    }

    /// Lower-case `keyName` and drop spacing characters so spelling variants
    /// collapse onto one canonical table key.
    private static func normalize(_ keyName: String) -> String {
        String(keyName.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" })
    }
}

extension CGEventFlags {
    /// Build event flags from the agent's modifier set.
    init(modifiers: [KeyPress.Modifier]) {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .function: flags.insert(.maskSecondaryFn)
            }
        }
        self = flags
    }
}
