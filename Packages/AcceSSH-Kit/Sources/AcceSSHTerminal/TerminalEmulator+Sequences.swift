import Foundation
import AcceSSHShellIntegration

// Escape, CSI, OSC and DCS dispatch.
extension TerminalEmulator {
    private static func byte(_ character: Unicode.Scalar) -> UInt8 { UInt8(character.value) }

    // MARK: - ESC

    func vtESC(intermediates: [UInt8], final: UInt8) {
        if intermediates.isEmpty {
            switch final {
            case Self.byte("7"): saveCursor()
            case Self.byte("8"): restoreCursor()
            case Self.byte("D"): commitCursorLine(); index()
            case Self.byte("E"): commitCursorLine(); index(); cursor.column = 0
            case Self.byte("H"): tabStops[cursor.column] = true
            case Self.byte("M"): reverseIndex()
            case Self.byte("c"): fullReset()
            case Self.byte("="): modes.applicationKeypad = true
            case Self.byte(">"): modes.applicationKeypad = false
            default: break  // ST (ESC \) and unsupported single shifts are no-ops.
            }
            return
        }
        guard intermediates.count == 1 else { return }
        let charset: CharacterSet94? = switch final {
        case Self.byte("0"): .decSpecialGraphics
        case Self.byte("B"): .ascii
        case Self.byte("A"): .unitedKingdom
        default: nil
        }
        switch intermediates[0] {
        case Self.byte("("): if let charset { cursor.g0 = charset }
        case Self.byte(")"): if let charset { cursor.g1 = charset }
        case Self.byte("#"):
            if final == Self.byte("8") {  // DECALN: fill the screen with E
                let cell = TerminalCell(character: "E")
                for row in 0..<rows {
                    screens[active].lines[row] = TerminalLine(cells: Array(repeating: cell, count: columns))
                }
                markAllRowsChanged()
            }
        default:
            break
        }
    }

    // MARK: - CSI

    func vtCSI(_ csi: CSISequence) {
        if let marker = csi.privateMarker {
            switch marker {
            case Self.byte("?"): privateCSI(csi)
            case Self.byte(">"): secondaryCSI(csi)
            default: break
            }
            return
        }
        if !csi.intermediates.isEmpty {
            intermediateCSI(csi)
            return
        }
        switch csi.final {
        case Self.byte("@"): insertBlankCharacters(csi.count(0))
        case Self.byte("A"):
            let top = cursor.row >= scrollTop ? scrollTop : 0
            moveCursor(row: max(cursor.row - csi.count(0), top), column: cursor.column)
        case Self.byte("B"), Self.byte("e"):
            let bottom = cursor.row <= scrollBottom ? scrollBottom : rows - 1
            moveCursor(row: min(cursor.row + csi.count(0), bottom), column: cursor.column)
        case Self.byte("C"), Self.byte("a"): moveCursor(row: cursor.row, column: cursor.column + csi.count(0))
        case Self.byte("D"): moveCursor(row: cursor.row, column: cursor.column - csi.count(0))
        case Self.byte("E"): moveCursor(row: min(cursor.row + csi.count(0), scrollBottom), column: 0)
        case Self.byte("F"): moveCursor(row: max(cursor.row - csi.count(0), scrollTop), column: 0)
        case Self.byte("G"), Self.byte("`"): moveCursor(row: cursor.row, column: csi.count(0) - 1)
        case Self.byte("H"), Self.byte("f"): setCursorPosition(row: csi.count(0), column: csi.count(1))
        case Self.byte("I"): tabForward(csi.count(0))
        case Self.byte("J"): eraseDisplay(mode: csi.value(0, default: 0))
        case Self.byte("K"): eraseLine(mode: csi.value(0, default: 0))
        case Self.byte("L"): insertLines(csi.count(0))
        case Self.byte("M"): deleteLines(csi.count(0))
        case Self.byte("P"): deleteCharacters(csi.count(0))
        case Self.byte("S"): scrollUp(csi.count(0))
        case Self.byte("T"): if csi.parameters.count <= 1 { scrollDown(csi.count(0)) }
        case Self.byte("X"): eraseCharacters(csi.count(0))
        case Self.byte("Z"): tabBackward(csi.count(0))
        case Self.byte("b"):
            if let scalar = lastPrintedScalar {
                for _ in 0..<min(csi.count(0), columns * rows) { vtPrint(scalar) }
            }
        case Self.byte("c"):
            if csi.value(0, default: 0) == 0 { respond("\u{1B}[?62;22c") }  // VT220 with ANSI color
        case Self.byte("d"):
            let row = csi.count(0) - 1 + (modes.originMode ? scrollTop : 0)
            moveCursor(row: row, column: cursor.column)
        case Self.byte("g"):
            switch csi.value(0, default: 0) {
            case 0: tabStops[cursor.column] = false
            case 3: tabStops = Array(repeating: false, count: columns)
            default: break
            }
        case Self.byte("h"), Self.byte("l"):
            let enable = csi.final == Self.byte("h")
            for parameter in csi.parameters {
                switch parameter.first ?? -1 {
                case 4: modes.insertMode = enable
                case 20: modes.newLineMode = enable
                default: break
                }
            }
        case Self.byte("m"): applySGR(csi.parameters)
        case Self.byte("n"):
            switch csi.value(0, default: 0) {
            case 5: respond("\u{1B}[0n")
            case 6: respond("\u{1B}[\(reportedCursorRow);\(cursor.column + 1)R")
            default: break
            }
        case Self.byte("r"):
            let top = csi.count(0) - 1
            let bottom = (csi.value(1, default: rows) == 0 ? rows : csi.value(1, default: rows)) - 1
            if top < bottom, bottom < rows {
                scrollTop = top
                scrollBottom = bottom
                setCursorPosition(row: 1, column: 1)
            }
        case Self.byte("s"): saveCursor()
        case Self.byte("u"): restoreCursor()
        case Self.byte("t"):
            if csi.value(0, default: 0) == 18 { respond("\u{1B}[8;\(rows);\(columns)t") }
        default:
            break
        }
    }

    private var reportedCursorRow: Int {
        modes.originMode ? cursor.row - scrollTop + 1 : cursor.row + 1
    }

    private func privateCSI(_ csi: CSISequence) {
        switch csi.final {
        case Self.byte("h"), Self.byte("l"):
            let enable = csi.final == Self.byte("h")
            for parameter in csi.parameters { setPrivateMode(parameter.first ?? -1, enable) }
        case Self.byte("n"):
            if csi.value(0, default: 0) == 6 { respond("\u{1B}[?\(reportedCursorRow);\(cursor.column + 1)R") }
        case Self.byte("p") where csi.intermediates == [Self.byte("$")]:
            // DECRQM: report whether a private mode is set (1), reset (2) or unknown (0).
            let mode = csi.value(0, default: 0)
            let state = privateModeState(mode).map { $0 ? 1 : 2 } ?? 0
            respond("\u{1B}[?\(mode);\(state)$y")
        default:
            break
        }
    }

    private func secondaryCSI(_ csi: CSISequence) {
        switch csi.final {
        case Self.byte("c"):
            respond("\u{1B}[>1;10;0c")
        case Self.byte("q"):
            // XTVERSION
            respond("\u{1B}P>|AcceSSH(1.0)\u{1B}\\")
        default:
            break
        }
    }

    private func intermediateCSI(_ csi: CSISequence) {
        switch (csi.intermediates, csi.final) {
        case ([Self.byte(" ")], Self.byte("q")):
            let style = CursorStyleRequest(rawValue: csi.value(0, default: 0)) ?? .default
            modes.cursorStyle = style
            update.events.append(.cursorStyleChanged(style))
        case ([Self.byte("!")], Self.byte("p")):
            softReset()
        case ([Self.byte("$")], Self.byte("p")):
            let mode = csi.value(0, default: 0)
            let state: Int = switch mode {
            case 4: modes.insertMode ? 1 : 2
            case 20: modes.newLineMode ? 1 : 2
            default: 0
            }
            respond("\u{1B}[\(mode);\(state)$y")
        default:
            break
        }
    }

    private func privateModeState(_ mode: Int) -> Bool? {
        switch mode {
        case 1: modes.applicationCursorKeys
        case 5: modes.reverseVideo
        case 6: modes.originMode
        case 7: modes.autoWrap
        case 12: modes.cursorBlinking
        case 25: modes.cursorVisible
        case 47, 1047, 1049: isAlternateScreenActive
        case 1000: modes.mouseTracking == .normal
        case 1002: modes.mouseTracking == .buttonEvent
        case 1003: modes.mouseTracking == .anyEvent
        case 1004: modes.focusReporting
        case 1006: modes.mouseEncoding == .sgr
        case 1007: modes.alternateScroll
        case 2004: modes.bracketedPaste
        case 2026: modes.synchronizedOutput
        default: nil
        }
    }

    private func setPrivateMode(_ mode: Int, _ enable: Bool) {
        switch mode {
        case 1:
            if modes.applicationCursorKeys != enable {
                modes.applicationCursorKeys = enable
                update.events.append(.applicationCursorKeysChanged(enable))
            }
        case 5:
            modes.reverseVideo = enable
            markAllRowsChanged()
        case 6:
            modes.originMode = enable
            setCursorPosition(row: 1, column: 1)
        case 7: modes.autoWrap = enable
        case 9: modes.mouseTracking = enable ? .x10 : .off
        case 12: modes.cursorBlinking = enable
        case 25: modes.cursorVisible = enable
        case 47: setAlternateScreen(enable, clear: false)
        case 1047:
            if !enable, isAlternateScreenActive {
                for row in 0..<rows { screens[active].lines[row] = TerminalLine(columns: columns) }
            }
            setAlternateScreen(enable, clear: false)
        case 1048: enable ? saveCursor() : restoreCursor()
        case 1049:
            if enable {
                guard !isAlternateScreenActive else { return }
                saveCursor()
                setAlternateScreen(true, clear: true)
            } else {
                guard isAlternateScreenActive else { return }
                setAlternateScreen(false, clear: false)
                restoreCursor()
            }
        case 1000: modes.mouseTracking = enable ? .normal : .off
        case 1002: modes.mouseTracking = enable ? .buttonEvent : .off
        case 1003: modes.mouseTracking = enable ? .anyEvent : .off
        case 1004: modes.focusReporting = enable
        case 1005: modes.mouseEncoding = enable ? .utf8 : .legacy
        case 1006: modes.mouseEncoding = enable ? .sgr : .legacy
        case 1015: modes.mouseEncoding = enable ? .urxvt : .legacy
        case 1007: modes.alternateScroll = enable
        case 2004: modes.bracketedPaste = enable
        case 2026:
            if modes.synchronizedOutput != enable {
                modes.synchronizedOutput = enable
                update.events.append(.synchronizedOutputChanged(enable))
            }
        default:
            break
        }
    }

    // MARK: - SGR

    func applySGR(_ parameters: [[Int]]) {
        if parameters.isEmpty {
            cursor.attributes = .default
            return
        }
        var attributes = cursor.attributes
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            let code = max(parameter.first ?? 0, 0)
            switch code {
            case 0: attributes = .default
            case 1: attributes.flags.insert(.bold)
            case 2: attributes.flags.insert(.dim)
            case 3: attributes.flags.insert(.italic)
            case 4:
                attributes.flags.subtract(TextAttributeFlags.anyUnderline)
                switch parameter.count > 1 ? parameter[1] : 1 {
                case 0: break
                case 2: attributes.flags.insert(.doubleUnderline)
                case 3: attributes.flags.insert(.curlyUnderline)
                default: attributes.flags.insert(.underline)
                }
            case 5, 6: attributes.flags.insert(.blink)
            case 7: attributes.flags.insert(.inverse)
            case 8: attributes.flags.insert(.hidden)
            case 9: attributes.flags.insert(.strikethrough)
            case 21: attributes.flags.subtract(TextAttributeFlags.anyUnderline); attributes.flags.insert(.doubleUnderline)
            case 22: attributes.flags.subtract([.bold, .dim])
            case 23: attributes.flags.remove(.italic)
            case 24: attributes.flags.subtract(TextAttributeFlags.anyUnderline)
            case 25: attributes.flags.remove(.blink)
            case 27: attributes.flags.remove(.inverse)
            case 28: attributes.flags.remove(.hidden)
            case 29: attributes.flags.remove(.strikethrough)
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 38:
                let (color, consumed) = Self.extendedColor(parameters, at: index)
                if let color { attributes.foreground = color }
                index += consumed
            case 39: attributes.foreground = .default
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 48:
                let (color, consumed) = Self.extendedColor(parameters, at: index)
                if let color { attributes.background = color }
                index += consumed
            case 49: attributes.background = .default
            case 53: attributes.flags.insert(.overline)
            case 55: attributes.flags.remove(.overline)
            case 58:
                // Underline color: parsed so its arguments are skipped, not rendered separately.
                index += Self.extendedColor(parameters, at: index).1
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            index += 1
        }
        cursor.attributes = attributes
    }

    /// Parses `38;5;n`, `38;2;r;g;b` and the colon forms `38:5:n`, `38:2::r:g:b`, `38:2:r:g:b`.
    /// Returns the color and how many extra top-level parameters were consumed.
    static func extendedColor(_ parameters: [[Int]], at index: Int) -> (TerminalColor?, Int) {
        func component(_ value: Int) -> UInt8 { UInt8(clamping: max(value, 0)) }
        let parameter = parameters[index]
        if parameter.count > 1 {
            switch parameter[1] {
            case 5 where parameter.count > 2:
                return (.indexed(component(parameter[2])), 0)
            case 2:
                let values: ArraySlice<Int>
                if parameter.count >= 6 { values = parameter[3...5] } else if parameter.count == 5 { values = parameter[2...4] } else { return (nil, 0) }
                let v = Array(values)
                return (.rgb(red: component(v[0]), green: component(v[1]), blue: component(v[2])), 0)
            default:
                return (nil, 0)
            }
        }
        guard index + 1 < parameters.count else { return (nil, 0) }
        switch parameters[index + 1].first ?? -1 {
        case 5:
            guard index + 2 < parameters.count else { return (nil, 1) }
            return (.indexed(component(parameters[index + 2].first ?? 0)), 2)
        case 2:
            guard index + 4 < parameters.count else { return (nil, parameters.count - index - 1) }
            return (.rgb(
                red: component(parameters[index + 2].first ?? 0),
                green: component(parameters[index + 3].first ?? 0),
                blue: component(parameters[index + 4].first ?? 0)
            ), 4)
        default:
            return (nil, 1)
        }
    }

    // MARK: - OSC

    func vtOSC(_ payload: [UInt8]) {
        let text = String(decoding: payload, as: UTF8.self)
        let separator = text.firstIndex(of: ";")
        guard let code = Int(separator.map { text[..<$0] } ?? text[...]) else { return }
        let argument = separator.map { text[text.index(after: $0)...] } ?? ""

        switch code {
        case 0, 2:
            setTitle(String(argument))
            if code == 0 { iconTitle = title }
        case 1:
            iconTitle = Self.sanitizedTitle(argument)
        case 7:
            if let path = Self.pathFromFileURL(argument) { applyShellIntegration(.workingDirectory(path), origin: .finalTerm) }
        case 8:
            setHyperlink(argument)
        case 9:
            // OSC 9;4;... is ConEmu progress, not a notification.
            if !argument.hasPrefix("4;"), !argument.isEmpty {
                update.events.append(.remoteNotification(title: nil, body: Self.sanitizedTitle(argument), urgency: .normal))
            }
        case 10, 11:
            if argument == "?" {
                let color = code == 10 ? reportedForeground : reportedBackground
                func hex(_ value: UInt8) -> String { String(format: "%02x%02x", value, value) }
                respond("\u{1B}]\(code);rgb:\(hex(color.red))/\(hex(color.green))/\(hex(color.blue))\u{1B}\\")
            }
        case 52:
            // `c;<base64>` writes the clipboard. Queries (`?`) are never answered: reading the
            // clipboard from a remote host would leak local data.
            let parts = argument.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] != "?", let data = Data(base64Encoded: String(parts[1])),
               let string = String(data: data, encoding: .utf8) {
                update.events.append(.clipboardWriteRequested(string))
            }
        case 777:
            let parts = argument.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.first == "notify", parts.count >= 2 {
                let body = parts.count == 3 ? String(parts[2]) : ""
                update.events.append(.remoteNotification(
                    title: Self.sanitizedTitle(parts[1]), body: Self.sanitizedTitle(body), urgency: .normal
                ))
            }
        case 1337:
            if argument.hasPrefix("CurrentDir=") {
                applyShellIntegration(.workingDirectory(String(argument.dropFirst("CurrentDir=".count))), origin: .finalTerm)
            }
        default:
            if let (message, origin) = ShellIntegrationDecoder.decode(oscCode: code, payload: argument) {
                applyShellIntegration(message, origin: origin)
            }
        }
    }

    func setTitle<S: StringProtocol>(_ newTitle: S) {
        let sanitized = Self.sanitizedTitle(newTitle)
        guard sanitized != title else { return }
        title = sanitized
        update.events.append(.titleChanged(sanitized))
    }

    /// Strips control characters and caps length, so a hostile title cannot inject
    /// sequences into UI strings or flood VoiceOver.
    static func sanitizedTitle<S: StringProtocol>(_ text: S) -> String {
        var result = String(text.unicodeScalars.filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }.map(Character.init))
        if result.count > 512 { result = String(result.prefix(512)) }
        return result
    }

    static func pathFromFileURL<S: StringProtocol>(_ text: S) -> String? {
        guard text.hasPrefix("file://") else { return nil }
        let rest = text.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return ShellIntegrationCoding.percentDecode(rest[slash...])
    }

    private func setHyperlink(_ argument: Substring) {
        let parts = argument.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let uri = String(parts[1])
        guard !uri.isEmpty else {
            cursor.hyperlinkID = 0
            return
        }
        guard uri.utf8.count <= 4_096 else { return }
        var identifier: String?
        for option in parts[0].split(separator: ":") where option.hasPrefix("id=") {
            identifier = String(option.dropFirst(3))
        }
        let key = "\(identifier ?? "")\u{0}\(uri)"
        if let existing = hyperlinkIDs[key] {
            cursor.hyperlinkID = existing
            return
        }
        guard hyperlinks.count < 65_536 else { return }
        let id = nextHyperlinkID
        nextHyperlinkID += 1
        hyperlinks[id] = TerminalHyperlink(uri: uri, identifier: identifier)
        hyperlinkIDs[key] = id
        cursor.hyperlinkID = id
    }

    // MARK: - DCS

    func vtDCS(parameters: [[Int]], intermediates: [UInt8], final: UInt8, data: [UInt8]) {
        // DECRQSS (`DCS $ q <setting> ST`): answer "invalid" for everything except SGR and
        // DECSTBM, which some programs query to save and restore state.
        guard intermediates == [Self.byte("$")], final == Self.byte("q") else { return }
        let setting = String(decoding: data, as: UTF8.self)
        switch setting {
        case "r": respond("\u{1B}P1$r\(scrollTop + 1);\(scrollBottom + 1)r\u{1B}\\")
        case "m": respond("\u{1B}P1$r0m\u{1B}\\")
        default: respond("\u{1B}P0$r\u{1B}\\")
        }
    }

    func respond(_ text: String) {
        update.responses.append(contentsOf: Array(text.utf8))
    }
}
