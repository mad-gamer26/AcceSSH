import UIKit
import AcceSSHCore
import AcceSSHTerminal
import AcceSSHAccessibility

/// Scrollable terminal: draws the emulator's lines and exposes them to VoiceOver.
///
/// Rendering and accessibility both read the emulator model. Visual rows are drawn by
/// ``TerminalCanvasView``; VoiceOver sees one ``TerminalLineElement`` per logical line
/// (soft-wrapped rows joined), created lazily, so 10,000 lines of scrollback cost nothing
/// until VoiceOver visits them.
final class TerminalView: UIScrollView {
    let terminal: TerminalEmulator
    weak var session: TerminalSession?
    private let canvas = TerminalCanvasView()
    private(set) var font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private(set) var cellWidth: CGFloat = 8
    private(set) var lineHeight: CGFloat = 17
    let padding: CGFloat = 6
    var onGridSizeChange: ((Int, Int) -> Void)?
    /// Performs a key action (set by the view controller), used by VoiceOver gestures.
    var onKeyAction: ((KeyAction) -> Void)?
    private var lastGrid = (columns: 0, rows: 0)
    private var followsOutput = true

    // Accessibility caches, rebuilt lazily after updates.
    private var lineRangesDirty = true
    private var cachedLineRanges: [ClosedRange<Int>] = []
    private var elementCache: [Int: TerminalLineElement] = [:]

    init(terminal: TerminalEmulator) {
        self.terminal = terminal
        super.init(frame: .zero)
        canvas.terminalView = self
        canvas.isAccessibilityElement = false
        addSubview(canvas)
        alwaysBounceVertical = true
        keyboardDismissMode = .none
        isAccessibilityElement = false
        accessibilityLabel = "Terminal"
        accessibilityContainerType = .semanticGroup
        updateFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: TerminalView, _) in
            view.updateFont()
            view.canvas.setNeedsDisplay()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(contrastChanged),
                                               name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func contrastChanged() { canvas.setNeedsDisplay() }

    /// Appearance and accessibility settings from the session's profiles.
    var appearance = AppearanceSettings() {
        didSet { if appearance != oldValue { updateFont(); canvas.setNeedsDisplay() } }
    }
    var accessibilitySettings = AcceSSHCore.AccessibilitySettings() {
        didSet { if accessibilitySettings != oldValue { updateFont(); canvas.setNeedsDisplay() } }
    }
    var themes: [TerminalTheme] = TerminalTheme.builtIn {
        didSet { canvas.setNeedsDisplay() }
    }

    private func updateFont() {
        let base = CGFloat(min(max(appearance.fontSize, 8), 48))
        let size = appearance.followsSystemTextSize
            ? UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traitCollection)
            : base
        var weight: UIFont.Weight = switch appearance.fontWeight {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        if accessibilitySettings.boldTerminalText { weight = .bold }
        if appearance.fontName == AppearanceSettings().fontName {
            font = UIFont.monospacedSystemFont(ofSize: min(size, 64), weight: weight)
        } else {
            font = UIFont(name: appearance.fontName, size: min(size, 64)) ?? UIFont.monospacedSystemFont(ofSize: min(size, 64), weight: weight)
        }
        cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width + CGFloat(appearance.characterSpacing)
        lineHeight = ceil(font.lineHeight * CGFloat(min(max(appearance.lineSpacing, 0.8), 2)))
        lastGrid = (0, 0)
        setNeedsLayout()
    }

    var isDarkAppearance: Bool {
        appearance.followsSystemAppearance ? traitCollection.userInterfaceStyle == .dark : true
    }

    var theme: TerminalTheme {
        let dark = isDarkAppearance
        let wantsHighContrast = accessibilitySettings.forceHighContrast
            || (accessibilitySettings.followSystemIncreaseContrast && UIAccessibility.isDarkerSystemColorsEnabled)
        if wantsHighContrast { return dark ? .highContrastDark : .highContrastLight }
        let id = appearance.followsSystemAppearance ? (dark ? appearance.darkThemeID : appearance.lightThemeID) : appearance.darkThemeID
        return themes.first { $0.id == id } ?? (dark ? .classicDark : .classicLight)
    }

    // MARK: - Geometry

    var isAlternate: Bool { terminal.isAlternateScreenActive }
    var firstRow: Int { isAlternate ? 0 : terminal.firstAvailableRow }
    var rowCount: Int { isAlternate ? terminal.rows : terminal.endRow - terminal.firstAvailableRow }

    /// Line at a display index (0 = oldest line shown).
    func line(atDisplayRow index: Int) -> TerminalLine? {
        isAlternate ? terminal.screenLine(index) : terminal.line(atAbsoluteRow: firstRow + index)
    }

    var cursorDisplayRow: Int {
        isAlternate ? terminal.cursorScreenPosition.row : terminal.cursorPosition.row - firstRow
    }

    func rectForDisplayRows(_ rows: ClosedRange<Int>) -> CGRect {
        CGRect(x: 0, y: padding + CGFloat(rows.lowerBound) * lineHeight,
               width: bounds.width, height: CGFloat(rows.count) * lineHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let usableWidth = bounds.width - padding * 2
        let usableHeight = bounds.height - padding * 2 - adjustedContentInset.top - adjustedContentInset.bottom
        let columns = max(20, Int(usableWidth / cellWidth))
        let rows = max(5, Int(usableHeight / lineHeight))
        if columns != lastGrid.columns || rows != lastGrid.rows {
            lastGrid = (columns, rows)
            onGridSizeChange?(columns, rows)
        }
        layoutCanvas()
    }

    private func layoutCanvas() {
        let height = max(bounds.height, padding * 2 + CGFloat(rowCount) * lineHeight)
        let size = CGSize(width: bounds.width, height: height)
        if canvas.frame.size != size {
            canvas.frame = CGRect(origin: .zero, size: size)
            contentSize = size
        }
    }

    private var isNearBottom: Bool {
        contentOffset.y + bounds.height - adjustedContentInset.bottom >= contentSize.height - lineHeight * 2
    }

    func scrollToBottom(animated: Bool = false) {
        let y = max(-adjustedContentInset.top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // MARK: - Updates

    func terminalDidUpdate(_ update: TerminalUpdate) {
        let wasAtBottom = isNearBottom || followsOutput
        layoutCanvas()
        if wasAtBottom { scrollToBottom() }
        canvas.setNeedsDisplay()
        lineRangesDirty = true
        if update.events.contains(where: { if case .alternateScreenChanged = $0 { true } else { false } }) {
            // No screen-change notification: it would interrupt VoiceOver.
            elementCache.removeAll()
        }
    }

    // MARK: - Accessibility container

    /// Display-row ranges of logical lines that VoiceOver can visit.
    private var lineRanges: [ClosedRange<Int>] {
        if lineRangesDirty {
            cachedLineRanges = computeLineRanges()
            lineRangesDirty = false
            // Keep element identity (and so VoiceOver focus) for lines that still start on the
            // same row, even if they grew by wrapping.
            let current = Dictionary(cachedLineRanges.map { ($0.lowerBound, $0) }, uniquingKeysWith: { first, _ in first })
            elementCache = elementCache.filter { current[$0.key] != nil }
            for (start, element) in elementCache { element.rows = current[start]! }
        }
        return cachedLineRanges
    }

    private func computeLineRanges() -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        let count = rowCount
        if isAlternate {
            for row in 0..<count where !(line(atDisplayRow: row)?.isBlank ?? true) || row == cursorDisplayRow {
                ranges.append(row...row)
            }
            return ranges
        }
        // Primary screen: logical lines up to the cursor's line; blank rows below it are omitted.
        let lastRow = min(count - 1, lastContentRow())
        var row = 0
        while row <= lastRow {
            var end = row
            while end < lastRow, line(atDisplayRow: end)?.isWrapped == true { end += 1 }
            ranges.append(row...end)
            row = end + 1
        }
        return ranges
    }

    private func lastContentRow() -> Int {
        var row = rowCount - 1
        let cursor = cursorDisplayRow
        while row > cursor, line(atDisplayRow: row)?.isBlank ?? true { row -= 1 }
        return row
    }

    override func accessibilityElementCount() -> Int { lineRanges.count }

    override func accessibilityElement(at index: Int) -> Any? {
        let ranges = lineRanges
        guard ranges.indices.contains(index) else { return nil }
        return element(for: ranges[index])
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard let element = element as? TerminalLineElement else { return NSNotFound }
        return lineRanges.firstIndex { $0.lowerBound == element.rows.lowerBound } ?? NSNotFound
    }

    private func element(for rows: ClosedRange<Int>) -> TerminalLineElement {
        if let cached = elementCache[rows.lowerBound], cached.rows == rows { return cached }
        let element = TerminalLineElement(terminalView: self, rows: rows)
        elementCache[rows.lowerBound] = element
        return element
    }

    func elementDidBecomeFocused(_ element: TerminalLineElement) {
        followsOutput = element.rows.upperBound >= cursorDisplayRow
        let rect = rectForDisplayRows(element.rows)
        if !bounds.contains(rect) { scrollRectToVisible(rect.insetBy(dx: 0, dy: -lineHeight), animated: false) }
    }

    /// Runs the action configured for a VoiceOver three-finger swipe. Returns false when the
    /// direction is set to scroll, so VoiceOver scrolls the terminal as usual.
    func handleThreeFingerSwipe(_ direction: UIAccessibilityScrollDirection) -> Bool {
        // VoiceOver reports vertical scrolls by content direction, the opposite of the finger:
        // a three-finger swipe up arrives as .down. Settings are by finger direction.
        let swipe: SwipeDirection
        switch direction {
        case .down: swipe = .up
        case .up: swipe = .down
        case .left: swipe = .left
        case .right: swipe = .right
        default: return false
        }
        guard let session, let action = session.profiles.keyboard.effectiveGestures.threeFingerSwipes[swipe],
              let onKeyAction else { return false }
        onKeyAction(action)
        return true
    }

    /// Text from the start of a display row to the end of the terminal content.
    func textFromLineToEnd(_ displayRow: Int) -> String {
        if isAlternate {
            let lines = (displayRow..<terminal.rows).map { terminal.screenLine($0).text }
            return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        return terminal.text(ofAbsoluteRows: (displayRow + firstRow)..<terminal.endRow).trimmingCharacters(in: .newlines)
    }

    /// Text for a line element.
    func text(for rows: ClosedRange<Int>) -> String {
        if isAlternate { return line(atDisplayRow: rows.lowerBound)?.text ?? "" }
        return terminal.text(ofAbsoluteRows: (rows.lowerBound + firstRow)..<(rows.upperBound + firstRow + 1))
    }
}

/// One logical line for VoiceOver.
final class TerminalLineElement: UIAccessibilityElement {
    var rows: ClosedRange<Int>
    private weak var terminalView: TerminalView?

    init(terminalView: TerminalView, rows: ClosedRange<Int>) {
        self.terminalView = terminalView
        self.rows = rows
        super.init(accessibilityContainer: terminalView)
        accessibilityTraits = .staticText
    }

    override var accessibilityLabel: String? {
        get {
            let text = terminalView?.text(for: rows) ?? ""
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? "Blank" : text
        }
        set {}
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { terminalView?.rectForDisplayRows(rows) ?? .zero }
        set {}
    }

    override func accessibilityElementDidBecomeFocused() {
        terminalView?.elementDidBecomeFocused(self)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        terminalView?.handleThreeFingerSwipe(direction) ?? false
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            [
                UIAccessibilityCustomAction(name: "Copy Screen") { [weak self] _ in
                    guard let view = self?.terminalView else { return false }
                    Clipboard.copy(view.terminal.visibleText())
                    view.session?.speech.say("Copied screen.")
                    return true
                },
                UIAccessibilityCustomAction(name: "Copy from This Line to End") { [weak self] _ in
                    guard let self, let view = self.terminalView else { return false }
                    Clipboard.copy(view.textFromLineToEnd(self.rows.lowerBound))
                    view.session?.speech.say("Copied to the end.")
                    return true
                },
            ]
        }
        set {}
    }
}

/// Draws the visible rows. Never consulted by accessibility.
final class TerminalCanvasView: UIView {
    weak var terminalView: TerminalView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let view = terminalView, let context = UIGraphicsGetCurrentContext() else { return }
        let theme = view.theme
        let reverse = view.terminal.modes.reverseVideo
        context.setFillColor(UIColor(theme.background).cgColor)
        context.fill(rect)

        let first = max(0, Int((rect.minY - view.padding) / view.lineHeight))
        let last = min(view.rowCount - 1, Int((rect.maxY - view.padding) / view.lineHeight))
        guard first <= last else { return }
        let cursorRow = view.cursorDisplayRow
        let cursorColumn = view.terminal.cursorScreenPosition.column
        let showCursor = view.terminal.modes.cursorVisible

        for row in first...last {
            guard let line = view.line(atDisplayRow: row) else { continue }
            let y = view.padding + CGFloat(row) * view.lineHeight
            drawLine(line, y: y, view: view, theme: theme, reverse: reverse, context: context)
            if showCursor, row == cursorRow {
                let x = view.padding + CGFloat(cursorColumn) * view.cellWidth
                let cell = CGRect(x: x, y: y, width: view.cellWidth, height: view.lineHeight)
                let enhanced = view.accessibilitySettings.enhancedCursorVisibility
                let cursorColor = UIColor(view.appearance.cursorColor ?? theme.cursor)
                context.setFillColor(cursorColor.cgColor)
                switch view.appearance.cursorShape {
                case .block:
                    context.fill(cell)
                case .underline:
                    let thickness: CGFloat = enhanced ? 4 : 2
                    context.fill(CGRect(x: cell.minX, y: cell.maxY - thickness, width: cell.width, height: thickness))
                case .bar:
                    context.fill(CGRect(x: cell.minX, y: cell.minY, width: enhanced ? 4 : 2, height: cell.height))
                }
                if enhanced {
                    // A contrasting outline keeps the cursor visible on any background color.
                    context.setStrokeColor(UIColor(theme.background).cgColor)
                    context.setLineWidth(1)
                    context.stroke(cell.insetBy(dx: -1, dy: -1))
                    context.setStrokeColor(cursorColor.cgColor)
                    context.stroke(cell.insetBy(dx: -2, dy: -2))
                }
                if view.appearance.cursorShape == .block, cursorColumn < line.cells.count {
                    let character = String(line.cells[cursorColumn].character)
                    (character as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                        .font: view.font, .foregroundColor: UIColor(theme.cursorText),
                    ])
                }
            }
        }
    }

    private func drawLine(_ line: TerminalLine, y: CGFloat, view: TerminalView, theme: TerminalTheme, reverse: Bool, context: CGContext) {
        var column = 0
        let cells = line.cells
        while column < cells.count {
            let cell = cells[column]
            if cell.width == 0 { column += 1; continue }
            // Group narrow cells with identical attributes into one run.
            var end = column + 1
            if cell.width == 1 {
                while end < cells.count, cells[end].width == 1, cells[end].attributes == cell.attributes,
                      cells[end].hyperlinkID == cell.hyperlinkID { end += 1 }
            }
            let span = cell.width == 2 ? 2 : end - column
            var foreground = color(cell.attributes.foreground, theme: theme, isForeground: true, bold: cell.attributes.flags.contains(.bold))
            var background = color(cell.attributes.background, theme: theme, isForeground: false, bold: false)
            if cell.attributes.flags.contains(.inverse) != reverse { swap(&foreground, &background) }
            let x = view.padding + CGFloat(column) * view.cellWidth
            let runRect = CGRect(x: x, y: y, width: CGFloat(span) * view.cellWidth, height: view.lineHeight)
            if background != theme.background {
                context.setFillColor(UIColor(background).cgColor)
                context.fill(runRect)
            }
            let text = String(cells[column..<(cell.width == 2 ? column + 1 : end)].map(\.character))
            if text.contains(where: { $0 != " " }) && !cell.attributes.flags.contains(.hidden) {
                var attributes: [NSAttributedString.Key: Any] = [.font: font(for: cell.attributes, view: view)]
                let dimOpacity = max(view.appearance.dimOpacity, 0.55)
                let ink = UIColor(foreground).withAlphaComponent(cell.attributes.flags.contains(.dim) ? dimOpacity : 1)
                attributes[.foregroundColor] = cell.hyperlinkID != 0 ? UIColor(theme.hyperlink) : ink
                if view.appearance.characterSpacing != 0 { attributes[.kern] = view.appearance.characterSpacing }
                if cell.attributes.flags.contains(.underline) || cell.attributes.flags.contains(.doubleUnderline)
                    || cell.attributes.flags.contains(.curlyUnderline)
                    || (cell.hyperlinkID != 0 && view.appearance.underlineHyperlinks) {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                } else if view.accessibilitySettings.differentiateWithoutColor, cell.attributes.foreground != .default {
                    // Mark colored text so its meaning doesn't depend on color alone.
                    attributes[.underlineStyle] = NSUnderlineStyle.single.union(.patternDot).rawValue
                }
                if cell.attributes.flags.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            }
            column += cell.width == 2 ? 2 : end - column
        }
    }

    private func font(for attributes: CellAttributes, view: TerminalView) -> UIFont {
        let bold = attributes.flags.contains(.bold)
        let italic = attributes.flags.contains(.italic)
        guard bold || italic else { return view.font }
        var font = UIFont.monospacedSystemFont(ofSize: view.font.pointSize, weight: bold ? .bold : .regular)
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        return font
    }

    private func color(_ color: TerminalColor, theme: TerminalTheme, isForeground: Bool, bold: Bool) -> RGBColor {
        switch color {
        case .default: return isForeground ? theme.foreground : theme.background
        case let .indexed(index): return theme.color(forIndex: bold && index < 8 && isForeground ? index : index)
        case let .rgb(red, green, blue): return RGBColor(red: red, green: green, blue: blue)
        }
    }
}

extension UIColor {
    convenience init(_ color: RGBColor) {
        self.init(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }
}
