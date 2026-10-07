import UIKit
import AcceSSHCore
import AcceSSHTerminal

/// Modifiers latched by the accessory bar's Control and Option buttons; applied to the next key.
@MainActor
final class ModifierLatch {
    private(set) var modifiers: KeyModifiers = []
    var onChange: (() -> Void)?

    func toggle(_ modifier: KeyModifiers) {
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        onChange?()
    }

    /// Returns the latched modifiers and clears them.
    func consume() -> KeyModifiers {
        let current = modifiers
        if !current.isEmpty {
            modifiers = []
            onChange?()
        }
        return current
    }
}

/// Hardware-keyboard commands shared by both input views.
@MainActor
enum TerminalKeyCommands {
    static func make(action: Selector, includeArrows: Bool) -> [UIKeyCommand] {
        var commands: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags = [], title: String? = nil) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            if let title { command.discoverabilityTitle = title }
            commands.append(command)
        }
        if includeArrows {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
                for flags: UIKeyModifierFlags in [[], .shift, .alternate, .control, [.shift, .control], [.shift, .alternate]] {
                    add(input, flags)
                }
            }
            for input in [UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown, "\t"] {
                add(input)
            }
            add("\t", .shift)
            let functionKeys = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                                UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
            for key in functionKeys { add(key) }
        }
        add(UIKeyCommand.inputEscape)
        for scalar in "abcdefghijklmnopqrstuvwxyz[]\\/" { add(String(scalar), .control) }
        return commands
    }

    /// Converts a key command into a terminal chord.
    static func chord(for command: UIKeyCommand) -> KeyChord? {
        guard let input = command.input else { return nil }
        var modifiers: KeyModifiers = []
        if command.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if command.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if command.modifierFlags.contains(.control) { modifiers.insert(.control) }
        let key: TerminalKey
        switch input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case UIKeyCommand.inputLeftArrow: key = .left
        case UIKeyCommand.inputRightArrow: key = .right
        case UIKeyCommand.inputHome: key = .home
        case UIKeyCommand.inputEnd: key = .end
        case UIKeyCommand.inputPageUp: key = .pageUp
        case UIKeyCommand.inputPageDown: key = .pageDown
        case UIKeyCommand.inputEscape: key = .escape
        case "\t": key = .tab
        case UIKeyCommand.f1: key = .function(1)
        case UIKeyCommand.f2: key = .function(2)
        case UIKeyCommand.f3: key = .function(3)
        case UIKeyCommand.f4: key = .function(4)
        case UIKeyCommand.f5: key = .function(5)
        case UIKeyCommand.f6: key = .function(6)
        case UIKeyCommand.f7: key = .function(7)
        case UIKeyCommand.f8: key = .function(8)
        case UIKeyCommand.f9: key = .function(9)
        case UIKeyCommand.f10: key = .function(10)
        case UIKeyCommand.f11: key = .function(11)
        case UIKeyCommand.f12: key = .function(12)
        default: key = .text(input)
        }
        return KeyChord(key, modifiers: modifiers)
    }
}

/// Direct-keys input: every keystroke goes to the server immediately.
final class DirectKeyInputView: UIView, UIKeyInput {
    weak var session: TerminalSession?
    let latch: ModifierLatch
    private var accessoryView: UIView?

    init(latch: ModifierLatch) {
        self.latch = latch
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = "Terminal keys"
        accessibilityHint = "Double-tap to type. Each key goes straight to the server."
        backgroundColor = .secondarySystemBackground
        let label = UILabel()
        label.text = "Direct keys: typing goes straight to the server"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(activate)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAccessory(_ view: UIView) { accessoryView = view }
    override var inputAccessoryView: UIView? { accessoryView }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func activate() { becomeFirstResponder() }

    override func accessibilityActivate() -> Bool {
        becomeFirstResponder()
    }

    override var accessibilityValue: String? {
        get {
            guard let terminal = session?.terminal else { return nil }
            let line = terminal.isAlternateScreenActive
                ? terminal.screenLine(terminal.cursorScreenPosition.row).text
                : terminal.logicalLineText(atAbsoluteRow: terminal.cursorPosition.row)
            return line.isEmpty ? nil : line
        }
        set {}
    }

    // UITextInputTraits: the terminal needs exactly what was typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var inlinePredictionType: UITextInlinePredictionType = .no

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let session else { return }
        let modifiers = latch.consume()
        if text == "\n" {
            session.send(KeyChord(.enter, modifiers: modifiers))
        } else if !modifiers.isEmpty, text.count == 1 {
            session.send(KeyChord(.text(text), modifiers: modifiers))
        } else {
            session.send(text: text)
        }
    }

    func deleteBackward() {
        session?.send(KeyChord(.backspace, modifiers: latch.consume()))
    }

    override var keyCommands: [UIKeyCommand]? {
        TerminalKeyCommands.make(action: #selector(handleKeyCommand(_:)), includeArrows: true)
    }

    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        guard let chord = TerminalKeyCommands.chord(for: command) else { return }
        var latched = chord
        latched.modifiers.formUnion(latch.consume())
        session?.send(latched)
    }
}

/// Line-editing input: a native text field with full VoiceOver editing. Return sends the line;
/// Tab sends what's typed plus Tab so the shell can complete it.
final class CommandLineField: UITextField, UITextFieldDelegate {
    weak var session: TerminalSession?
    let latch: ModifierLatch
    private var historyIndex: Int?
    private var accessory: UIView?

    init(latch: ModifierLatch) {
        self.latch = latch
        super.init(frame: .zero)
        delegate = self
        borderStyle = .roundedRect
        font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        adjustsFontForContentSizeCategory = true
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        returnKeyType = .send
        clearButtonMode = .whileEditing
        setSecret(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAccessory(_ view: UIView) { accessory = view }
    override var inputAccessoryView: UIView? {
        get { accessory }
        set { accessory = newValue }
    }

    /// Switches to a secure field for password prompts; the text is never shown or spoken.
    func setSecret(_ secret: Bool) {
        guard isSecureTextEntry != secret || placeholder == nil else { return }
        isSecureTextEntry = secret
        placeholder = secret ? "Password" : "Command"
        accessibilityLabel = secret ? "Password" : "Command"
        accessibilityHint = secret
            ? "The server is asking for a password. It is sent when you press Return and is never saved."
            : "Type a command and press Return to send it. Tab sends what you typed and asks the shell to complete it."
        if secret { text = "" }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        session?.submitLine(text ?? "")
        text = ""
        historyIndex = nil
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // A latched Control or Option applies to the next typed key and is sent immediately.
        let modifiers = latch.modifiers
        if !modifiers.isEmpty, string.count == 1 {
            _ = latch.consume()
            flushTypedText()
            session?.send(KeyChord(.text(string), modifiers: modifiers))
            return false
        }
        return true
    }

    /// Sends anything typed so far without Return (used before Tab and control keys).
    func flushTypedText() {
        guard let typed = text, !typed.isEmpty else { return }
        session?.send(text: typed)
        text = ""
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = TerminalKeyCommands.make(action: #selector(handleKeyCommand(_:)), includeArrows: false)
        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t"] {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(handleKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc func handleKeyCommand(_ command: UIKeyCommand) {
        guard let session, let chord = TerminalKeyCommands.chord(for: command) else { return }
        switch (chord.key, chord.modifiers.isEmpty) {
        case (.up, true): recallHistory(older: true)
        case (.down, true): recallHistory(older: false)
        case (.tab, _):
            flushTypedText()
            session.send(chord)
        default:
            flushTypedText()
            session.send(chord)
        }
    }

    private func recallHistory(older: Bool) {
        guard let history = session?.history, !history.isEmpty else {
            Announcer.announce("No command history.")
            return
        }
        var index = historyIndex ?? history.count
        index = older ? max(0, index - 1) : min(history.count, index + 1)
        historyIndex = index
        text = index < history.count ? history[index] : ""
        Announcer.announce((text ?? "").isEmpty ? "Empty" : text ?? "")
    }
}

/// The key bar above the software keyboard, built from the toolbar profile.
final class TerminalAccessoryBar: UIInputView {
    private let latch: ModifierLatch
    private var latchButtons: [(UIButton, KeyModifiers)] = []
    private var stack: UIStackView?
    var onAction: ((KeyAction) -> Void)?

    /// Replaces the buttons with those of a toolbar profile.
    func rebuild(profile: ToolbarProfile) {
        guard let stack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        latchButtons.removeAll()
        for item in profile.items {
            stack.addArrangedSubview(makeButton(item))
        }
        updateLatchButtons()
    }

    init(profile: ToolbarProfile, latch: ModifierLatch) {
        self.latch = latch
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        self.stack = stack
        rebuild(profile: profile)
        latch.onChange = { [weak self] in self?.updateLatchButtons() }
        accessibilityLabel = "Terminal keys"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeButton(_ item: ToolbarItem) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .medium
        if let symbol = item.symbolName {
            configuration.image = UIImage(systemName: symbol)
        } else {
            configuration.title = item.title
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = item.accessibilityLabel
        button.accessibilityHint = item.accessibilityHint
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if case let .latchModifier(modifier) = item.action {
                self.latch.toggle(modifier)
            } else {
                self.onAction?(item.action)
            }
        }, for: .touchUpInside)
        if case let .latchModifier(modifier) = item.action {
            latchButtons.append((button, modifier))
        }
        return button
    }

    private func updateLatchButtons() {
        for (button, modifier) in latchButtons {
            let on = latch.modifiers.contains(modifier)
            button.isSelected = on
            button.configuration?.baseBackgroundColor = on ? .tintColor : nil
            button.configuration?.baseForegroundColor = on ? .white : nil
            button.accessibilityValue = on ? "On" : "Off"
        }
    }
}
