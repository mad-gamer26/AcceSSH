import UIKit
import SwiftUI
import AcceSSHCore
import AcceSSHTerminal
import AcceSSHAccessibility

/// Hosts the terminal view and the input row, keeping the input above the keyboard.
final class TerminalViewController: UIViewController {
    let session: TerminalSession
    private let terminalView: TerminalView
    private let latch = ModifierLatch()
    private lazy var lineField = CommandLineField(latch: latch)
    private lazy var keyInput = DirectKeyInputView(latch: latch)
    private lazy var accessoryBar = TerminalAccessoryBar(profile: session.profiles.toolbar, latch: latch)
    private var toolbarProfile: ToolbarProfile?
    private var mode: InputMode?
    private let inputRow = UIView()

    init(session: TerminalSession) {
        self.session = session
        terminalView = TerminalView(terminal: session.terminal)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        terminalView.session = session
        lineField.session = session
        keyInput.session = session
        lineField.setAccessory(accessoryBar)
        keyInput.setAccessory(accessoryBar)

        for subview in [terminalView, inputRow] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [lineField, keyInput] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            inputRow.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: inputRow.layoutMarginsGuide.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: inputRow.layoutMarginsGuide.trailingAnchor),
                subview.topAnchor.constraint(equalTo: inputRow.topAnchor, constant: 4),
                subview.bottomAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: -4),
            ])
        }
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: inputRow.topAnchor),
            inputRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            inputRow.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            inputRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])

        terminalView.onGridSizeChange = { [weak self] columns, rows in
            self?.session.resize(columns: columns, rows: rows)
        }
        session.onTerminalUpdate = { [weak self] update in
            self?.terminalView.terminalDidUpdate(update)
        }
        accessoryBar.onAction = { [weak self] action in self?.perform(action) }
        terminalView.onKeyAction = { [weak self] action in self?.perform(action) }
        // Focus order: terminal lines, then the input row.
        view.accessibilityElements = [terminalView, inputRow]
        apply(mode: session.effectiveInputMode, secret: session.isSecretInputActive)
        applySettings()
    }

    /// Applies the session's current appearance, accessibility and toolbar settings.
    func applySettings() {
        let profiles = session.profiles
        terminalView.appearance = profiles.appearance
        terminalView.accessibilitySettings = profiles.accessibility
        terminalView.themes = session.themes
        if toolbarProfile != profiles.toolbar {
            toolbarProfile = profiles.toolbar
            accessoryBar.rebuild(profile: profiles.toolbar)
        }
    }

    /// Shows the input view for the mode, keeping the keyboard up when switching.
    func apply(mode newMode: InputMode, secret: Bool) {
        lineField.setSecret(secret)
        guard newMode != mode else { return }
        let wasEditing = lineField.isFirstResponder || keyInput.isFirstResponder
        mode = newMode
        lineField.isHidden = newMode != .line
        keyInput.isHidden = newMode != .keys
        // An explicit element list ignores isHidden, so it must list only the active input;
        // otherwise VoiceOver could reach the hidden one.
        inputRow.accessibilityElements = [newMode == .line ? lineField : keyInput]
        if wasEditing {
            if newMode == .line { lineField.becomeFirstResponder() } else { keyInput.becomeFirstResponder() }
        }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    func focusInput() {
        if mode == .keys { keyInput.becomeFirstResponder() } else { lineField.becomeFirstResponder() }
    }

    private func perform(_ action: KeyAction) {
        switch action {
        case let .key(chord):
            if mode == .line { lineField.flushTypedText() }
            var chord = chord
            chord.modifiers.formUnion(latch.consume())
            session.send(chord)
        case let .text(text):
            session.send(text: text)
        case let .bytes(bytes):
            session.send(bytes: bytes)
        case let .command(command, pressReturn):
            session.send(text: command + (pressReturn ? "\r" : ""))
        case let .macro(actions, _):
            for action in actions { perform(action) }
        case let .app(command):
            session.perform(command)
        case .latchModifier:
            break
        }
    }
}

/// SwiftUI wrapper for the terminal screen.
struct TerminalScreen: UIViewControllerRepresentable {
    let session: TerminalSession
    let mode: InputMode
    let isSecret: Bool
    let profiles: ResolvedProfiles
    @Binding var navigationRequest: TerminalNavigationRequest?

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(session: session)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        controller.apply(mode: mode, secret: isSecret)
        controller.applySettings()
        if let request = navigationRequest {
            DispatchQueue.main.async { navigationRequest = nil }
            controller.handle(request)
        }
    }
}

/// Requests from SwiftUI that act on the terminal view.
enum TerminalNavigationRequest: Equatable {
    /// Moves focus to the command line (after connecting).
    case focusInput
}

extension TerminalViewController {
    func handle(_ request: TerminalNavigationRequest) {
        switch request {
        case .focusInput: focusInput()
        }
    }
}
