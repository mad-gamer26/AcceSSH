import Foundation
import Testing
@testable import AcceSSHTerminal
import AcceSSHCore

@Suite("Terminal emulator")
struct EmulatorTests {
    func makeTerminal(columns: Int = 20, rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(columns: columns, rows: rows, scrollbackLimit: 100)
    }

    @Test func printsTextAndWrapsLongLines() {
        let terminal = makeTerminal(columns: 10, rows: 3)
        terminal.feed("hello world, wrapped")
        #expect(terminal.screenLine(0).text == "hello worl")
        #expect(terminal.screenLine(0).isWrapped)
        #expect(terminal.screenLine(1).text == "d, wrapped")
        #expect(terminal.logicalLineText(atAbsoluteRow: 0) == "hello world, wrapped")
    }

    @Test func carriageReturnOverwritesAndCommitsFinalText() {
        let terminal = makeTerminal()
        let update = terminal.feed("10%\r50%\r100%\r\n")
        #expect(update.committedLines.map(\.text) == ["100%"])
    }

    @Test func cursorPositioningAndErase() {
        let terminal = makeTerminal()
        terminal.feed("abcdef\u{1B}[1;3H\u{1B}[K")
        #expect(terminal.screenLine(0).text == "ab")
        terminal.feed("\u{1B}[3;5HX")
        #expect(terminal.screenLine(2).text == "    X")
        #expect(terminal.cursorScreenPosition == (2, 5))
    }

    @Test func sgrColorsAndAttributes() {
        let terminal = makeTerminal()
        terminal.feed("\u{1B}[1;31mA\u{1B}[38;5;200mB\u{1B}[38;2;1;2;3mC\u{1B}[48:2::9:8:7mD\u{1B}[0mE")
        let cells = terminal.screenLine(0).cells
        #expect(cells[0].attributes.flags.contains(.bold))
        #expect(cells[0].attributes.foreground == .indexed(1))
        #expect(cells[1].attributes.foreground == .indexed(200))
        #expect(cells[2].attributes.foreground == .rgb(red: 1, green: 2, blue: 3))
        #expect(cells[3].attributes.background == .rgb(red: 9, green: 8, blue: 7))
        #expect(cells[4].attributes == .default)
    }

    @Test func wideCharactersOccupyTwoCells() {
        let terminal = makeTerminal()
        terminal.feed("a中b")
        let line = terminal.screenLine(0)
        #expect(line.cells[1].width == 2)
        #expect(line.cells[2].width == 0)
        #expect(line.text == "a中b")
        #expect(terminal.cursorScreenPosition.column == 4)
    }

    @Test func combiningMarksAndEmojiSequencesJoinOneCell() {
        let terminal = makeTerminal()
        terminal.feed("e\u{0301}x")
        #expect(terminal.screenLine(0).text == "éx")
        #expect(terminal.cursorScreenPosition.column == 2)

        terminal.feed("\r\n👍🏽!")
        #expect(terminal.screenLine(1).text == "👍🏽!")
        #expect(terminal.cursorScreenPosition.column == 3)
    }

    @Test func alternateScreenPreservesPrimary() {
        let terminal = makeTerminal()
        terminal.feed("shell line")
        let enter = terminal.feed("\u{1B}[?1049h\u{1B}[Hfull screen app")
        #expect(enter.events.contains(.alternateScreenChanged(isActive: true)))
        #expect(terminal.isAlternateScreenActive)
        #expect(terminal.screenLine(0).text == "full screen app")
        terminal.feed("\u{1B}[?1049l")
        #expect(!terminal.isAlternateScreenActive)
        #expect(terminal.screenLine(0).text == "shell line")
        #expect(terminal.cursorScreenPosition.column == 10)
    }

    @Test func scrollbackKeepsAbsoluteRowNumbers() {
        let terminal = makeTerminal(columns: 10, rows: 3)
        for index in 0..<6 { terminal.feed("line \(index)\r\n") }
        #expect(terminal.scrollbackCount == 4)
        #expect(terminal.line(atAbsoluteRow: 0)?.text == "line 0")
        #expect(terminal.line(atAbsoluteRow: 5)?.text == "line 5")
        terminal.clearScrollback()
        #expect(terminal.line(atAbsoluteRow: 0) == nil)
        #expect(terminal.line(atAbsoluteRow: 5)?.text == "line 5")
    }

    @Test func scrollRegionDoesNotFeedScrollback() {
        let terminal = makeTerminal(columns: 10, rows: 5)
        terminal.feed("top\u{1B}[2;4r\u{1B}[4;1Ha\r\nb\r\nc\r\nd")
        #expect(terminal.scrollbackCount == 0)
        #expect(terminal.screenLine(0).text == "top")
        #expect(terminal.screenLine(3).text == "d")
    }

    @Test func eraseDisplayMovesContentIntoScrollback() {
        let terminal = makeTerminal(columns: 10, rows: 3)
        terminal.feed("one\r\ntwo\u{1B}[H\u{1B}[2J")
        #expect(terminal.visibleText().isEmpty)
        #expect(terminal.fullText().hasPrefix("one\ntwo"))
    }

    @Test func deviceStatusAndAttributesRespond() {
        let terminal = makeTerminal()
        terminal.feed("abc")
        let cpr = terminal.feed("\u{1B}[6n")
        #expect(String(decoding: cpr.responses, as: UTF8.self) == "\u{1B}[1;4R")
        let da = terminal.feed("\u{1B}[c")
        #expect(String(decoding: da.responses, as: UTF8.self) == "\u{1B}[?62;22c")
        let bg = terminal.feed("\u{1B}]11;?\u{07}")
        #expect(String(decoding: bg.responses, as: UTF8.self).hasPrefix("\u{1B}]11;rgb:"))
    }

    @Test func titleAndBellEvents() {
        let terminal = makeTerminal()
        let update = terminal.feed("\u{1B}]2;build\u{1B}\\\u{07}")
        #expect(update.events.contains(.titleChanged("build")))
        #expect(update.events.contains(.bell))
        #expect(terminal.title == "build")
    }

    @Test func decSpecialGraphicsLineDrawing() {
        let terminal = makeTerminal()
        terminal.feed("\u{1B}(0lqk\u{1B}(Bx")
        #expect(terminal.screenLine(0).text == "┌─┐x")
    }

    @Test func insertAndDeleteCharacters() {
        let terminal = makeTerminal()
        terminal.feed("abcdef\u{1B}[1;3H\u{1B}[2P")
        #expect(terminal.screenLine(0).text == "abef")
        terminal.feed("\u{1B}[2@XY")
        #expect(terminal.screenLine(0).text == "abXYef")
    }

    @Test func resizeKeepsCursorLineVisible() {
        let terminal = makeTerminal(columns: 10, rows: 4)
        terminal.feed("a\r\nb\r\nc\r\nd")
        terminal.resize(columns: 10, rows: 2)
        #expect(terminal.screenLine(1).text == "d")
        #expect(terminal.cursorScreenPosition.row == 1)
        terminal.resize(columns: 10, rows: 4)
        #expect(terminal.screenLine(0).text == "a")
        #expect(terminal.cursorScreenPosition.row == 3)
    }

    @Test func hyperlinksAreRecorded() throws {
        let terminal = makeTerminal()
        terminal.feed("\u{1B}]8;;https://example.com/docs\u{1B}\\link\u{1B}]8;;\u{1B}\\ plain")
        let cells = terminal.screenLine(0).cells
        let link = try #require(terminal.hyperlink(id: cells[0].hyperlinkID))
        #expect(link.uri == "https://example.com/docs")
        #expect(link.spokenDestination == "https link to example.com")
        #expect(cells[5].hyperlinkID == 0)
    }

    @Test func clipboardQueriesAreNeverAnswered() {
        let terminal = makeTerminal()
        let query = terminal.feed("\u{1B}]52;c;?\u{07}")
        #expect(query.responses.isEmpty)
        let write = terminal.feed("\u{1B}]52;c;aGVsbG8=\u{07}")
        #expect(write.events.contains(.clipboardWriteRequested("hello")))
    }

    @Test func malformedInputDoesNotCrash() {
        let terminal = makeTerminal()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let bytes = (0..<256).map { _ in UInt8.random(in: 0...255, using: &generator) }
            terminal.feed(bytes)
        }
        terminal.feed("\u{1B}[999999;999999H\u{1B}[999999Pok")
        #expect(terminal.cursorScreenPosition.row < terminal.rows)
    }

    @Test func searchFindsMatchesAcrossScrollback() throws {
        let terminal = makeTerminal(columns: 20, rows: 2)
        terminal.feed("alpha error\r\nbeta\r\ngamma ERROR here\r\n")
        let matches = try terminal.search("error")
        #expect(matches.map(\.row) == [0, 2])
        let sensitive = try terminal.search("ERROR", caseSensitive: true)
        #expect(sensitive.count == 1)
        let regex = try terminal.search("^g.*here$", regularExpression: true)
        #expect(regex.count == 1)
    }
}

@Suite("Input encoding")
struct InputEncoderTests {
    let encoder = TerminalInputEncoder()

    func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    @Test func arrowKeysFollowCursorKeyMode() {
        var modes = TerminalModes()
        #expect(string(encoder.encode(KeyChord(.up), modes: modes)) == "\u{1B}[A")
        modes.applicationCursorKeys = true
        #expect(string(encoder.encode(KeyChord(.up), modes: modes)) == "\u{1B}OA")
        #expect(string(encoder.encode(KeyChord(.left, modifiers: .control), modes: modes)) == "\u{1B}[1;5D")
    }

    @Test func controlAndOptionCombinations() {
        let modes = TerminalModes()
        #expect(encoder.encode(KeyChord(.text("c"), modifiers: .control), modes: modes) == [0x03])
        #expect(encoder.encode(KeyChord(.text("["), modifiers: .control), modes: modes) == [0x1B])
        #expect(encoder.encode(KeyChord(.text("b"), modifiers: .option), modes: modes) == [0x1B, 0x62])
        #expect(string(encoder.encode(KeyChord(.tab, modifiers: .shift), modes: modes)) == "\u{1B}[Z")
        #expect(string(encoder.encode(KeyChord(.function(5)), modes: modes)) == "\u{1B}[15~")
        #expect(string(encoder.encode(KeyChord(.function(1)), modes: modes)) == "\u{1B}OP")
    }

    @Test func bracketedPasteCannotEscape() {
        let bytes = encoder.encodePaste("ls\n\u{1B}[201~rm -rf /\n", bracketed: true)
        let text = string(bytes)
        #expect(text == "\u{1B}[200~ls\rrm -rf /\r\u{1B}[201~")
    }
}
