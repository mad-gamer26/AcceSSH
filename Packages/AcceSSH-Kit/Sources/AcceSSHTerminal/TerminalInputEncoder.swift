import Foundation
import AcceSSHCore

/// Encodes keys and pastes into the bytes an xterm-compatible application expects.
public struct TerminalInputEncoder: Sendable {
    public var optionSendsEscape: Bool
    public var backspaceSendsDelete: Bool

    public init(optionSendsEscape: Bool = true, backspaceSendsDelete: Bool = true) {
        self.optionSendsEscape = optionSendsEscape
        self.backspaceSendsDelete = backspaceSendsDelete
    }

    /// Bytes for a key chord under the terminal's current modes. Returns an empty array for
    /// chords with no terminal meaning (for example Command shortcuts).
    public func encode(_ chord: KeyChord, modes: TerminalModes) -> [UInt8] {
        let modifiers = chord.modifiers.subtracting(.command)
        // xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
        var modifierParameter = 1
        if modifiers.contains(.shift) { modifierParameter += 1 }
        if modifiers.contains(.option) { modifierParameter += 2 }
        if modifiers.contains(.control) { modifierParameter += 4 }
        let hasModifiers = modifierParameter > 1

        func csi(_ text: String) -> [UInt8] { [0x1B, 0x5B] + Array(text.utf8) }
        func cursorKey(_ final: Character) -> [UInt8] {
            if hasModifiers { return csi("1;\(modifierParameter)\(final)") }
            return modes.applicationCursorKeys ? [0x1B, 0x4F] + Array(String(final).utf8) : csi(String(final))
        }
        func tilde(_ number: Int) -> [UInt8] {
            hasModifiers ? csi("\(number);\(modifierParameter)~") : csi("\(number)~")
        }

        switch chord.key {
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right: return cursorKey("C")
        case .left: return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case let .function(number):
            switch number {
            case 1...4:
                let final = ["P", "Q", "R", "S"][number - 1]
                return hasModifiers ? csi("1;\(modifierParameter)\(final)") : [0x1B, 0x4F] + Array(final.utf8)
            case 5...20:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34]
                return tilde(codes[number - 5])
            default:
                return []
            }
        case .escape:
            return modifiers.contains(.option) && optionSendsEscape ? [0x1B, 0x1B] : [0x1B]
        case .tab:
            return modifiers.contains(.shift) ? csi("Z") : [0x09]
        case .enter:
            let base: [UInt8] = modes.newLineMode ? [0x0D, 0x0A] : [0x0D]
            return modifiers.contains(.option) && optionSendsEscape ? [0x1B] + base : base
        case .backspace:
            var bytes: [UInt8] = modifiers.contains(.control) ? [0x08] : (backspaceSendsDelete ? [0x7F] : [0x08])
            if modifiers.contains(.option) && optionSendsEscape { bytes.insert(0x1B, at: 0) }
            return bytes
        case let .text(text):
            var bytes: [UInt8]
            if modifiers.contains(.control), let control = Self.controlByte(for: text) {
                bytes = [control]
            } else {
                bytes = Array(text.utf8)
            }
            if modifiers.contains(.option) && optionSendsEscape && !bytes.isEmpty { bytes.insert(0x1B, at: 0) }
            return bytes
        }
    }

    /// The C0 control byte for Control plus a character, following xterm.
    public static func controlByte(for text: String) -> UInt8? {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch value {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return value - UInt8(ascii: "a") + 1
        case UInt8(ascii: "@")...UInt8(ascii: "_"): return value - UInt8(ascii: "@")
        case UInt8(ascii: " "), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "7"), UInt8(ascii: "/"), UInt8(ascii: "-"): return 0x1F
        case UInt8(ascii: "8"), UInt8(ascii: "?"): return 0x7F
        default: return nil
        }
    }

    /// Bytes for pasted text. Newlines become carriage returns (what a typed Return sends).
    /// With bracketed paste, the text is wrapped in `ESC[200~`/`ESC[201~` and any embedded
    /// end marker is removed so pasted text cannot break out and run as typed commands.
    public func encodePaste(_ text: String, bracketed: Bool) -> [UInt8] {
        var cleaned = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if bracketed {
            cleaned = cleaned.replacingOccurrences(of: "\u{1B}[201~", with: "").replacingOccurrences(of: "\u{1B}[200~", with: "")
            return Array("\u{1B}[200~".utf8) + Array(cleaned.utf8) + Array("\u{1B}[201~".utf8)
        }
        return Array(cleaned.utf8)
    }

    /// Bytes for a focus change when the application requested focus reporting (mode 1004).
    public static func focusReport(focused: Bool, modes: TerminalModes) -> [UInt8] {
        guard modes.focusReporting else { return [] }
        return Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }
}
