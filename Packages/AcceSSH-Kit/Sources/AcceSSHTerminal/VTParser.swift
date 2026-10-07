import Foundation

/// A parsed control sequence (`CSI … final`).
public struct CSISequence: Equatable, Sendable {
    /// Parameters; each entry is `[value, subparameters...]` (colon-separated sub-parameters,
    /// as used by `38:2::r:g:b`). A missing value is `-1`.
    public var parameters: [[Int]]
    /// `?`, `>`, `<` or `=` when present.
    public var privateMarker: UInt8?
    public var intermediates: [UInt8]
    public var final: UInt8

    /// The first value of parameter `index`, or `defaultValue` when absent.
    public func value(_ index: Int, default defaultValue: Int) -> Int {
        guard index < parameters.count, let first = parameters[index].first, first >= 0 else { return defaultValue }
        return first
    }

    /// Like ``value(_:default:)`` but treats 0 as the default, as cursor-movement sequences do.
    public func count(_ index: Int, default defaultValue: Int = 1) -> Int {
        let raw = value(index, default: defaultValue)
        return raw == 0 ? defaultValue : raw
    }
}

/// Receives actions from ``VTParser``.
protocol VTParserHandler: AnyObject {
    func vtPrint(_ scalar: Unicode.Scalar)
    func vtExecute(_ control: UInt8)
    func vtCSI(_ sequence: CSISequence)
    func vtESC(intermediates: [UInt8], final: UInt8)
    func vtOSC(_ payload: [UInt8])
    func vtDCS(parameters: [[Int]], intermediates: [UInt8], final: UInt8, data: [UInt8])
}

/// A DEC ANSI-compatible escape sequence parser (after Paul Williams' state machine at
/// vt100.net), with incremental UTF-8 decoding in the ground state.
///
/// Every input byte is consumed exactly once and the parser never allocates per printable
/// character. Hostile input is bounded: at most 32 parameters, values clamp at 65535 and
/// OSC/DCS strings are truncated at fixed limits.
struct VTParser {
    enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case stringIgnore
    }

    static let maximumParameters = 32
    static let maximumOSCLength = 65_536
    static let maximumDCSLength = 65_536

    private(set) var state: State = .ground
    private var intermediates: [UInt8] = []
    private var parameters: [[Int]] = []
    private var currentParameter: [Int] = []
    private var currentValue = -1
    private var hasParameterContent = false
    private var privateMarker: UInt8?
    private var stringBuffer: [UInt8] = []
    private var dcsFinal: UInt8 = 0

    // UTF-8 decoding state.
    private var utf8Remaining = 0
    private var utf8Scalar: UInt32 = 0
    private var utf8Minimum: UInt32 = 0

    var isLatin1 = false

    mutating func advance(_ byte: UInt8, handler: some VTParserHandler) {
        // "Anywhere" transitions.
        switch byte {
        case 0x18, 0x1A:
            flushIncompleteUTF8(handler)
            if state == .dcsPassthrough || state == .oscString { stringBuffer.removeAll(keepingCapacity: true) }
            handler.vtExecute(byte)
            state = .ground
            return
        case 0x1B:
            flushIncompleteUTF8(handler)
            switch state {
            case .oscString: handler.vtOSC(stringBuffer)
            case .dcsPassthrough: handler.vtDCS(parameters: parameters, intermediates: intermediates, final: dcsFinal, data: stringBuffer)
            default: break
            }
            enterEscape()
            return
        default:
            break
        }

        switch state {
        case .ground:
            ground(byte, handler)

        case .escape:
            switch byte {
            case 0x00...0x17, 0x19, 0x1C...0x1F: handler.vtExecute(byte)
            case 0x20...0x2F: intermediates.append(byte); state = .escapeIntermediate
            case UInt8(ascii: "["): clearSequence(); state = .csiEntry
            case UInt8(ascii: "]"): stringBuffer.removeAll(keepingCapacity: true); state = .oscString
            case UInt8(ascii: "P"): clearSequence(); stringBuffer.removeAll(keepingCapacity: true); state = .dcsEntry
            case UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): state = .stringIgnore
            case 0x30...0x7E: handler.vtESC(intermediates: intermediates, final: byte); state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch byte {
            case 0x00...0x17, 0x19, 0x1C...0x1F: handler.vtExecute(byte)
            case 0x20...0x2F: if intermediates.count < 4 { intermediates.append(byte) }
            case 0x30...0x7E: handler.vtESC(intermediates: intermediates, final: byte); state = .ground
            default: break
            }

        case .csiEntry, .csiParam:
            switch byte {
            case 0x00...0x17, 0x19, 0x1C...0x1F: handler.vtExecute(byte)
            case 0x30...0x39, UInt8(ascii: ";"), UInt8(ascii: ":"): parameterByte(byte); state = .csiParam
            case 0x3C...0x3F:
                if state == .csiEntry { privateMarker = byte; state = .csiParam } else { state = .csiIgnore }
            case 0x20...0x2F: intermediates.append(byte); state = .csiIntermediate
            case 0x40...0x7E: dispatchCSI(byte, handler)
            default: break
            }

        case .csiIntermediate:
            switch byte {
            case 0x00...0x17, 0x19, 0x1C...0x1F: handler.vtExecute(byte)
            case 0x20...0x2F: if intermediates.count < 4 { intermediates.append(byte) }
            case 0x30...0x3F: state = .csiIgnore
            case 0x40...0x7E: dispatchCSI(byte, handler)
            default: break
            }

        case .csiIgnore:
            switch byte {
            case 0x00...0x17, 0x19, 0x1C...0x1F: handler.vtExecute(byte)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            switch byte {
            case 0x07:
                handler.vtOSC(stringBuffer)
                stringBuffer.removeAll(keepingCapacity: true)
                state = .ground
            case 0x00...0x06, 0x08...0x1F:
                break
            default:
                if stringBuffer.count < Self.maximumOSCLength { stringBuffer.append(byte) }
            }

        case .dcsEntry, .dcsParam:
            switch byte {
            case 0x30...0x39, UInt8(ascii: ";"), UInt8(ascii: ":"): parameterByte(byte); state = .dcsParam
            case 0x3C...0x3F:
                if state == .dcsEntry { privateMarker = byte; state = .dcsParam } else { state = .dcsIgnore }
            case 0x20...0x2F: intermediates.append(byte); state = .dcsIntermediate
            case 0x40...0x7E: finishParameters(); dcsFinal = byte; state = .dcsPassthrough
            default: break
            }

        case .dcsIntermediate:
            switch byte {
            case 0x20...0x2F: if intermediates.count < 4 { intermediates.append(byte) }
            case 0x30...0x3F: state = .dcsIgnore
            case 0x40...0x7E: finishParameters(); dcsFinal = byte; state = .dcsPassthrough
            default: break
            }

        case .dcsPassthrough:
            if byte != 0x7F, stringBuffer.count < Self.maximumDCSLength { stringBuffer.append(byte) }

        case .dcsIgnore, .stringIgnore:
            break
        }
    }

    // MARK: - Ground state and UTF-8

    private mutating func ground(_ byte: UInt8, _ handler: some VTParserHandler) {
        if utf8Remaining > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Scalar = (utf8Scalar << 6) | UInt32(byte & 0x3F)
                utf8Remaining -= 1
                if utf8Remaining == 0 {
                    let valid = utf8Scalar >= utf8Minimum && !(0xD800...0xDFFF).contains(utf8Scalar)
                    let scalar = valid ? Unicode.Scalar(utf8Scalar) : nil
                    emitPrintable(scalar ?? "\u{FFFD}", handler)
                }
                return
            }
            // Truncated sequence: replace it and reprocess this byte.
            utf8Remaining = 0
            handler.vtPrint("\u{FFFD}")
        }

        switch byte {
        case 0x00...0x1F:
            handler.vtExecute(byte)
        case 0x20...0x7E:
            handler.vtPrint(Unicode.Scalar(byte))
        case 0x7F:
            break
        default:
            if isLatin1 {
                emitPrintable(Unicode.Scalar(byte), handler)
                return
            }
            switch byte {
            case 0xC2...0xDF: utf8Remaining = 1; utf8Scalar = UInt32(byte & 0x1F); utf8Minimum = 0x80
            case 0xE0...0xEF: utf8Remaining = 2; utf8Scalar = UInt32(byte & 0x0F); utf8Minimum = 0x800
            case 0xF0...0xF4: utf8Remaining = 3; utf8Scalar = UInt32(byte & 0x07); utf8Minimum = 0x10000
            default: handler.vtPrint("\u{FFFD}")
            }
        }
    }

    private func emitPrintable(_ scalar: Unicode.Scalar, _ handler: some VTParserHandler) {
        // C1 controls arriving as UTF-8 (U+0080–U+009F) are ignored, as xterm does in UTF-8 mode.
        if (0x80...0x9F).contains(scalar.value) { return }
        handler.vtPrint(scalar)
    }

    private mutating func flushIncompleteUTF8(_ handler: some VTParserHandler) {
        if utf8Remaining > 0 {
            utf8Remaining = 0
            if state == .ground { handler.vtPrint("\u{FFFD}") }
        }
    }

    // MARK: - Parameters

    private mutating func enterEscape() {
        clearSequence()
        state = .escape
    }

    private mutating func clearSequence() {
        intermediates.removeAll(keepingCapacity: true)
        parameters.removeAll(keepingCapacity: true)
        currentParameter.removeAll(keepingCapacity: true)
        currentValue = -1
        hasParameterContent = false
        privateMarker = nil
    }

    private mutating func parameterByte(_ byte: UInt8) {
        hasParameterContent = true
        switch byte {
        case UInt8(ascii: ";"):
            currentParameter.append(currentValue)
            if parameters.count < Self.maximumParameters { parameters.append(currentParameter) }
            currentParameter.removeAll(keepingCapacity: true)
            currentValue = -1
        case UInt8(ascii: ":"):
            if currentParameter.count < 8 { currentParameter.append(currentValue) }
            currentValue = -1
        default:
            let digit = Int(byte - UInt8(ascii: "0"))
            currentValue = min((max(currentValue, 0) * 10) + digit, 65_535)
        }
    }

    private mutating func finishParameters() {
        if hasParameterContent {
            currentParameter.append(currentValue)
            if parameters.count < Self.maximumParameters { parameters.append(currentParameter) }
        }
        currentParameter.removeAll(keepingCapacity: true)
        currentValue = -1
        hasParameterContent = false
    }

    private mutating func dispatchCSI(_ final: UInt8, _ handler: some VTParserHandler) {
        finishParameters()
        handler.vtCSI(CSISequence(parameters: parameters, privateMarker: privateMarker, intermediates: intermediates, final: final))
        state = .ground
    }
}
