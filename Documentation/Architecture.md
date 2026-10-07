# AcceSSH — Technical Architecture

AcceSSH is an SSH client for iPhone and iPad built around accessible terminal interaction. It is deliberately iOS and iPadOS only: on the Mac, Terminal.app already covers this need. VoiceOver support has the same priority as SSH protocol correctness. This document is the design of record. Phase status is listed in §13.

Naming: **AcceSSH** is the only user-facing name. **AcceSSH** is used for the repository, paths and remote-side identifiers (`LC_TERMINAL=AcceSSH`, `~/.accessh/`). **AcceSSH** is used only where Swift or Xcode forbid hyphens (module and type names).

---

## 1. Product architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ App (SwiftUI scenes; UIKit where it serves better)                       │
│  Shared UI: host list, host editor, settings, SFTP browser, history, find │
│  iOS/iPadOS: TerminalView (UIView) + UIAccessibility line elements       │
├──────────────────────────────────────────────────────────────────────────┤
│ App services (main actor or session actors)                              │
│  SessionManager · HostStore · SettingsStore · KnownHostsStore            │
│  CredentialManager · KeyManager · FeedbackCenter (Sound/Haptic/Bell)     │
│  SpeechCoordinator (posts VoiceOver announcements)                       │
├──────────────────────────────────────────────────────────────────────────┤
│ AcceSSH-Transport (Phase 2)        │ AcceSSH-Kit (Phase 1, done)   │
│  SSHConnection actor (libssh2)        │  AcceSSHCore: models           │
│  Shell channel · SFTP · forwarding    │  AcceSSHTerminal: emulator +   │
│  Host-key + auth callbacks            │    semantic model                │
│                                       │  AcceSSHShellIntegration       │
│                                       │  AcceSSHAccessibility: policy  │
└──────────────────────────────────────────────────────────────────────────┘
```

Data flow for one session:

```
socket → libssh2 → SSHConnection (actor) → bytes
      → TerminalSession (actor) → TerminalEmulator.feed() → TerminalUpdate
           ├→ responses (DSR, DA, OSC 11 …) → back to SSH channel
           ├→ TerminalScreenSnapshot → renderer (main actor)
           ├→ semantic events → SpeechCoordinator / FeedbackCenter
           └→ OutputSpeechScheduler → SpeechUtterance → VoiceOver
keystrokes → KeyboardProfile → TerminalInputEncoder → SSH channel
```

The emulator is the single source of truth. The renderer and the accessibility layer both read the emulator's model. Neither reads the other. Accessibility never scrapes pixels or a rendered text layer.

## 2. Repository and Xcode project structure

```
AcceSSH/                          ~/Documents/Code/AcceSSH
├── README.md
├── project.yml                      XcodeGen spec that generates AcceSSH.xcodeproj (Phase 3)
├── AcceSSH.xcodeproj             generated; not edited by hand
├── Apps/                            (Phase 3+)
│   ├── Shared/                      App entry (AcceSSHApp), scenes, SwiftUI screens shared by all platforms
│   │   ├── Hosts/                   host list, groups, favorites, recents, host editor
│   │   ├── Session/                 session container, tabs, toolbar, find, history
│   │   ├── Settings/                one view per settings category
│   │   ├── SFTP/                    file browser and transfers
│   │   └── Services/                SessionManager, stores, FeedbackCenter, SpeechCoordinator
│   ├── iOS/                         UIKit terminal view, UIAccessibility elements, key commands, Info.plist
├── Packages/
│   ├── AcceSSH-Kit/              platform-independent engine (this phase)
│   │   ├── Sources/AcceSSHCore/            Codable models: hosts, profiles, settings, feedback, keys
│   │   ├── Sources/AcceSSHShellIntegration/ protocol decoder, bash/zsh/fish scripts, installer
│   │   ├── Sources/AcceSSHTerminal/        VT parser, emulator, semantic model, input encoder
│   │   ├── Sources/AcceSSHAccessibility/   speech scheduling, navigation, screen analysis
│   │   └── Tests/                            unit tests and PTY end-to-end tests
│   └── AcceSSH-Transport/        SSH/SFTP/forwarding over libssh2 (Phase 2)
├── Vendor/                          libssh2 + OpenSSL xcframeworks built by Scripts/ with pinned checksums
├── Documentation/
│   ├── Architecture.md              this document
│   ├── Developer/                   subsystem documents
│   └── User/                        accessibility-first user guide
├── Scripts/                         test runner, vendor builds, project generation
└── UITests/                         XCUITest + accessibility audits (Phase 4+)
```

**Why Swift packages for the engine.** Everything that can be tested without a device lives in `AcceSSH-Kit`, which has no UIKit imports. The packages also compile for macOS, but only so the test suites run directly on the development Mac; there is no Mac app. `swift test` runs in seconds and verifies the emulator, semantic model, protocol and accessibility policy on every change. The same code builds for iOS, verified with `xcodebuild -destination generic/platform=iOS`.

**Why XcodeGen.** A YAML project spec makes diffs readable and avoids `.pbxproj` merge conflicts. XcodeGen is already installed (`/opt/homebrew/bin/xcodegen`). The generated project is the one people open.

## 3. SSH library evaluation and choice

| | SwiftNIO SSH | Citadel | **libssh2** | libssh | NMSSH / Shout / SwiftSH |
|---|---|---|---|---|---|
| Maintenance | Apple, active (0.14, July 2026) | small team, active | curl project, active; security releases in 2026 | active | unmaintained |
| License | Apache 2.0 | MIT | BSD-3 | **LGPL 2.1** | MIT |
| Crypto backend | swift-crypto / BoringSSL | NIO SSH + extras | OpenSSL 3 / mbedTLS / WinCNG | OpenSSL / libgcrypt | libssh2 |
| Language / concurrency | Swift, NIO event loops (async bridges) | Swift async | C; we wrap it in an actor | C | ObjC/Swift wrappers |
| RSA keys | no (design choice) | via own additions | yes, rsa-sha2-256/512 | yes | via libssh2 |
| Keyboard-interactive | not supported as of this review | no | yes | yes | partial |
| Encrypted OpenSSH keys | n/a | partial | yes (bcrypt-pbkdf) | yes | old versions |
| Compression | no | no | zlib | zlib | |
| SFTP | no | yes | yes | yes | yes |
| Forwarding (L/R) | primitives | direct/remote TCP | direct-tcpip, tcpip-forward | yes | partial |
| Agent forwarding | no | no | yes | yes | |
| Custom signing (Secure Enclave) | yes | yes | yes (`libssh2_userauth_publickey` sign callback) | limited | |
| Binary size | small (Swift) | small | libssh2 ~300 KB + OpenSSL ~3–4 MB | similar | |
| App Store | fine | fine | fine (BSD + Apache) | static linking LGPL is problematic | fine |

Accessibility implications: none directly. Indirectly, the library must surface **keyboard-interactive prompts as structured data** (name, instruction, prompts, echo flags) so AcceSSH can present them as accessible forms with secure fields. It must also give **typed errors** we can translate into understandable messages. libssh2 does both.

**Decision: libssh2 1.11.x with OpenSSL 3.x**, built as static xcframeworks by `Scripts/build-libssh2.sh` (Phase 2), pinned by version and SHA-256, and wrapped by `AcceSSH-Transport`:

- `SSHConnection` is an `actor` with a custom serial executor that owns one non-blocking libssh2 session and its socket. It drives I/O with `poll(2)`/`kqueue` and exposes `async` APIs: `connect`, `authenticate`, `openShell(term:size:env:)`, `sftp()`, `forwardLocal…`. libssh2 is never touched from two threads at once.
- Authentication supports password, keyboard-interactive (prompt callbacks become an `AsyncStream` of prompt requests answered by the UI), public key from memory (with passphrase), and **signing callbacks** for Secure Enclave P-256 keys and the in-app agent. Private keys never leave the Secure Enclave.
- Host-key verification happens after the handshake and before authentication. The key and its SHA-256 fingerprint go to `HostKeyVerifier` (§11). Nothing proceeds until the verdict is `trusted` or the person approves.
- Jump hosts: the inner session's transport is one end of a `socketpair` bridged to a `direct-tcpip` channel on the outer session.
- Dynamic forwarding: a local SOCKS5 listener (Network.framework) opens `direct-tcpip` channels.

Tradeoffs we accept: libssh2 is C, and 2026 brought several CVEs (for example CVE-2026-7598, an integer overflow, and an SFTP out-of-bounds fix). Mitigations: track upstream security releases, isolate libssh2 behind one actor, bounds-check every buffer we pass, and keep an `SSHTransport` protocol so a SwiftNIO SSH backend can be added if it gains keyboard-interactive and RSA support.

## 4. Terminal emulator strategy

AcceSSH uses its own emulator (`AcceSSHTerminal`) rather than embedding SwiftTerm or another engine. SwiftTerm is capable and MIT-licensed. But its model is built for drawing, while AcceSSH needs semantic structure (prompts, commands, output blocks, absolute positions that survive scrolling) designed into the model itself. Retrofitting that into a third-party engine would mean a permanent fork.

Implemented in Phase 1:

- **Parser:** a DEC ANSI state machine after Paul Williams' design, with incremental UTF-8 decoding. Parameters are bounded at 32 values, each clamped to 65535, and OSC/DCS strings are capped. C1 controls are ignored in UTF-8 mode.
- **xterm/VT220 behavior:** cursor movement, CUP with origin mode and scroll regions (DECSTBM), IND/RI/NEL, ICH/DCH/ECH/IL/DL, ED/EL with background-color erase, SU/SD, REP, tab stops (HTS/TBC/CHT/CBT), DECSC/DECRC, DEC Special Graphics, DECALN, RIS and DECSTR.
- **Modes:** DECCKM, DECKPAM, DECAWM, DECOM, IRM, LNM, DECTCEM, the alternate screen (47/1047/1048/1049), mouse modes (9/1000/1002/1003) and encodings (1005/1006/1015), focus reporting (1004), bracketed paste (2004), synchronized output (2026), DECSCUSR cursor styles, and DECRQM.
- **Reports:** DSR/CPR, primary and secondary DA, XTVERSION, window size (CSI 18 t), OSC 10/11 color queries, and minimal DECRQSS.
- **SGR:** bold, dim, italic, underline (single, double, curly), blink, inverse, hidden, strikethrough, overline, 16 colors, 256 colors and true color in both `;` and `:` forms.
- **Unicode:** wcwidth-compatible widths; wide characters as leading cell plus continuation; combining marks, ZWJ emoji sequences, skin tones and flags joined into one grapheme cell.
- **OSC:** titles (0/1/2), working directory (7, 1337), hyperlinks (8), notifications (9, 777), clipboard writes (52; queries are never answered), and shell integration (133/633/6973).
- **Scrollback:** absolute row numbering (see §5), batched trimming, and three separate clear operations (screen, scrollback, both). ED 2 on the primary screen moves content into scrollback, so output erased by `clear` stays reviewable.
- **Input encoding:** cursor/application modes, xterm modifier parameters, F1–F20, Control/Option combinations, and bracketed paste that strips embedded end markers.

Renderer (Phase 4): a `UIView` that draws from `TerminalScreenSnapshot` with Core Text, caching per-row glyph runs and redrawing only `changedRows`. Theme colors are resolved at draw time.

## 5. Semantic terminal architecture

Everything is addressed by **`TerminalPosition(row:column:)`**, where `row` counts every line ever written to the primary screen. Screen row 0 is absolute row `evictedLineCount + scrollback.count`. Scrolling, `clear`, Clear Screen, resizing and trimming all preserve absolute numbers, so a command record created an hour ago still points at the right text.

The model holds:

- **Cells and lines** (`TerminalCell`, `TerminalLine.isWrapped`): logical lines are wrapped rows joined.
- **Cursor, modes, title, working directory, hyperlinks**, and both screens.
- **`TerminalCommand` records**: `promptStart`, `inputStart`, `outputStart`, `outputEnd`, `commandLine` (reported by the shell or extracted from the screen), `exitStatus`, `workingDirectory`, timing, `phase` (prompt, input, running, finished) and `source` (`.shellIntegration` or `.heuristic`). `TerminalOutputBlock` is derived from them.
- **`ShellIntegrationState`**: not detected, marks only, active, newer protocol or disabled, plus version, capabilities, token verification, host and user.

Each `feed()` returns a `TerminalUpdate` containing:

- **committed lines**: logical lines completed by a line feed, carrying their semantic kind (prompt, command input, output or unknown). This is the authoritative new-output stream for speech. Carriage-return progress bars commit only their final text.
- the cursor line text and kind (prompt plus typed input)
- changed rows, events and responses.

Heuristics run only when no integration is present. `recordHeuristicPrompt()` and `noteHeuristicCommandSubmitted(commandLine:)` create `.heuristic` records, so semantic navigation works on any server, and shell integration simply makes it exact.

## 6. VoiceOver architecture

Principles:

1. Accessibility consumes the emulator model directly.
2. Two interaction modes exist: **typing** (focus on the command line, keys go to the remote side) and **reviewing** (a review position moves through history without moving the shell's cursor, like a screen reader's review cursor).
3. Automatic speech is a policy, not a side effect. The `OutputSpeechScheduler` decides, and a platform `SpeechCoordinator` posts.

**iOS and iPadOS** (Phase 4), based on public UIKit APIs:

- `TerminalView` is a container (`isAccessibilityElement = false`) whose `accessibilityElements` are custom `UIAccessibilityElement` subclasses created from the model. There is one element per logical line by default; the alternatives are per visual row or per output block (`TerminalElementGranularity`). Elements are virtualized: only a window around the viewport exists at a time.
- Each line element has the `.staticText` trait and its `accessibilityLabel` is the logical line text. Lines carry no spoken classification (such as "prompt", "command" or "error") and there are no custom rotors; VoiceOver's built-in Characters, Words and Lines navigation works on the label.
- `accessibilityCustomActions` on line elements: Copy Line, Read Command Output, Copy Command Output, Open Link (which speaks the real destination host first), and Select From Here.
- The **command-line element** adopts `UITextInput`, so VoiceOver treats it as a text field and gives standard typing echo and character/word editing feedback. In secret-input mode (password prompts, detected from prompts or `stty -echo`) its value is never exposed.
- Hardware keys: `UIKeyCommand` with `wantsPriorityOverSystemBehavior` for arrows, Escape, Tab and Control combinations; `pressesBegan` for everything else. Quick Nav (VoiceOver arrow-key navigation) intercepts arrow keys while it is on. This cannot be detected or overridden, so the user guide documents toggling it with Left+Right Arrow, and the toolbar and custom actions provide arrow keys as an alternative.
- Announcements: `UIAccessibility.post(notification: .announcement, …)` with `NSAttributedString` keys `.accessibilitySpeechQueueAnnouncement` (queue rather than interrupt) and `.accessibilitySpeechAnnouncementPriority` (iOS 17+) mapped from `SpeechUtterance.Priority`. Screen changes use `.layoutChanged` sparingly.

**Platform-independent policy** (implemented in `AcceSSHAccessibility`):

- `OutputSpeechScheduler`:
  - reading modes: everything, new lines, prompts only, important only, manual
  - quiet-period coalescing plus a maximum latency
  - overflow strategies (last lines, first lines, summary) with a character cap
  - suppression of the typed command's echo
  - speaking of text the shell inserted that the person did not type (tab completion, history recall) and of deleted characters
  - holding synchronized-output frames until complete
  - pause and resume, with a "Read New Output" buffer
- `AlternateScreenMonitor`: for vim, htop and menus, speaks the newly highlighted item (inverse video or a distinct background), or the cursor line when it moves or changes. Changed-lines and off modes are also available.
- `HighlightDetector`, `ScreenDescriber` (Describe Screen), `SemanticNavigator` (previous/next prompt, command and error; last command; last command output), `ErrorLineClassifier`, `HeuristicPromptDetector` (including secret-prompt detection), `SpeechTextFilter` (box drawing, repeated rules, whitespace) and `AnnouncementComposer` ("Command failed with exit status 1.", "make was interrupted after 2 minutes", signals, durations).

Every `AppCommand` (Read New Output, Read Current Line, Read From Cursor, Read Last Command, Read Last Command Output, Copy Last Command Output, Jump to Previous/Next Prompt, Command or Error, Repeat Last Announcement, Pause Automatic Speech, Speak Cursor Position, Describe Screen, and the three Clear commands) is reachable from four places: a menu command or keyboard shortcut, a VoiceOver custom action, the toolbar, and the command palette.

## 7. Accessibility-focused shell-integration protocol

Full specification: [Developer/ShellIntegrationProtocol.md](Developer/ShellIntegrationProtocol.md).

- **In-band:** OSC escape sequences on the existing PTY. No second service, no port.
- **Marks** use the de facto standard OSC 133 (A/B/C/D). These are also understood from other terminals' integrations (VS Code's OSC 633 and fish 4's built-in marks), so AcceSSH benefits even without its own script.
- **AcceSSH metadata** uses OSC 6973 with percent-encoded `key=value` fields: `hello` (protocol version, script version, shell, capabilities, host, user, token), `command` (exact command line, withheld for hidden commands), `cwd`, `host`, `user`, `title` and `notify` (an accessible `accessh_notify` function for scripts). Unknown events and keys are ignored, so the protocol is versioned and backward compatible.
- **Trust:** AcceSSH sends a random per-session token in `LC_ACCESSH_TOKEN`. A `hello` echoing it is verified. Marks from unverified sources are still used for navigation, which is harmless, but are labeled.
- **Opt-in installation:** scripts for bash (3.2+, with bash-preexec cooperation), zsh and fish are installed only with approval. `ShellIntegrationInstaller` produces a plan listing every file with full before/after content and a VoiceOver-friendly summary. Startup-file edits are confined to one block between `# >>> AcceSSH shell integration >>>` markers, which can be updated or removed exactly. A damaged block is refused, not guessed at. "Activate on connect" sources the script for one session without touching any startup file.

## 8. Data models

All models are in `AcceSSHCore`, are `Codable`, `Hashable` and `Sendable`, and contain no secrets:

| Model | File |
|---|---|
| `Host`, `HostGroup`, `EnvironmentVariable`, `ConnectionOptions`, `ReconnectPolicy`, `HostProfileReferences`, `ShellIntegrationPreference` | Models/Host.swift |
| `AuthenticationConfiguration`, `SSHKey`, `SSHKeyAlgorithm`, `KnownHost`, `HostKeyVerifier`, `PortForward` | Models/Security.swift |
| `TerminalSettings`, `CommandHistorySettings`, `SessionLogSettings`, `SessionConnectionState`, `SessionDescriptor` | Models/Terminal.swift |
| `AppearanceSettings`, `TerminalTheme` (WCAG-checked high-contrast presets), `RGBColor` | Models/Appearance.swift |
| `AccessibilitySettings`, `VoiceOverSettings`, `AnnouncementCategory`, `CursorAnnouncementSettings` | Models/Accessibility.swift |
| `FeedbackEvent`, `SoundProfile`, `HapticProfile`, `BellProfile`, `ToneSpec`, `HapticPattern`, `QuietHours` | Models/Feedback.swift |
| `KeyboardProfile`, `ToolbarProfile`, `ToolbarItem`, `KeyAction`, `KeyChord`, `AppCommand` | Models/Keyboard.swift |
| `ProfileLibrary`, `ResolvedProfiles`, `ConnectionProfileExport` | Models/Profiles.swift |

Engine models: `TerminalCommand`, `TerminalOutputBlock` and `TerminalEvent` in `AcceSSHTerminal`; `ShellIntegrationState` and `ShellIntegrationCapabilities` in `AcceSSHShellIntegration`.

## 9. UI navigation architecture

- **iPad:** a `NavigationSplitView` with a sidebar (Favorites, Recents, Groups, All Hosts) and a detail area holding the active session. Multiple windows (scenes) and Stage Manager are supported, and a session switcher appears as a picker in the toolbar.
- **iPhone:** a `NavigationStack` (hosts → session). Sessions are switched from a session list, and the terminal is full screen with the accessory toolbar above the keyboard.
- **Sheets:** host editor, host-key confirmation (blocking), keyboard-interactive prompts, find, command history, shell-integration plan review, SFTP and paste confirmation.
- **Settings categories:** General, Hosts, Terminal, Appearance, Accessibility, VoiceOver, Keyboard, Toolbar, Sounds, Haptics, Bell, Notifications, SSH, Shell Integration, Security, SFTP, Advanced.
- **Focus order:** the session status (host, connection state) comes first, then the terminal lines, then the command line, then the toolbar. After connecting, focus moves to the command line.

## 10. Sound, haptic and bell architecture

- `FeedbackCenter` (main actor) receives a `FeedbackEvent` and its context (session, foreground or background). It consults the resolved `SoundProfile`, `HapticProfile` and `BellProfile` and `VoiceOverSettings.enabledAnnouncements`. Each channel is independent, and the defaults are quiet.
- `SoundManager`:
  - `ToneSpec` is synthesized with `AVAudioEngine` and `AVAudioSourceNode` (sine, triangle, square, two-note).
  - Files play through `AVAudioPlayer`.
  - On iOS the audio session is `.ambient` with mixing, so cues never stop the person's audio or duck VoiceOver.
- `HapticManager`:
  - On iPhone, `CHHapticEngine.capabilitiesForHardware().supportsHaptics` gates Core Haptics custom patterns; otherwise it falls back to `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` / `UISelectionFeedbackGenerator`.
  - Most iPads have no haptic engine, so haptics are reported as unavailable and settings show this rather than pretending.
- `BellManager`: BEL → `BellProfile`, with throttling (repeated bells inside `throttleInterval` are dropped) and quiet hours. A visual flash becomes a border flash under Reduce Motion. A spoken phrase is a queued, low-priority announcement. Background bells post a `UNUserNotification` when allowed.

## 11. Security architecture

- **Secrets:**
  - Passwords and private keys are Keychain generic-password items with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synced by default. With "Require Face ID / Touch ID" they use a `SecAccessControl` with `.userPresence`.
  - Models hold only UUID references, and export strips them (`ConnectionProfileExport`).
- **Keys:**
  - Ed25519 and P-256/P-384 generation uses CryptoKit. RSA import is supported; generation is offered only for compatibility, at 3072+ bits.
  - Secure Enclave P-256 keys (`SecureEnclave.P256.Signing.PrivateKey`) sign through libssh2's sign callback and never leave the device.
  - Encrypted OpenSSH keys are decrypted in memory only, with the passphrase optionally kept in the Keychain.
- **Host keys:**
  - Trust on first use, with an explicit confirmation sheet that speaks the key type and SHA-256 fingerprint.
  - A changed key, including an algorithm change, is a blocking warning (`HostKeyVerdict.changed`). It is never silently accepted, never "just this once" by default, and replacing the stored key requires a deliberate action.
  - Each hop of a jump-host chain is verified.
- **Secret input:**
  - Password prompts (detected heuristically, by keyboard-interactive echo flags, or by disabled echo) switch the command line to secure entry. Typed text is never exposed via accessibility values, never recorded in history or logs, and never spoken.
- **Logging:** `os.Logger` with `.private` interpolation for anything user-derived. Libraries' debug tracing is off in release builds.
- **Clipboard:**
  - Copies of terminal output can be local-only with an expiry (`UIPasteboard` options).
  - OSC 52 writes follow `RemoteClipboardPolicy` (default: ask). Clipboard reads are never answered.
- **Paste safety:** bracketed paste strips embedded end markers, and multiline or large pastes ask for confirmation.
- **Remote content:**
  - Titles and notifications are sanitized and capped.
  - OSC 8 link activation states the real destination host.
  - Integration payloads are size-limited.
  - Remote sequences can never execute local actions.
- **App lock:** optional `LAContext` gate on launch and resume. Sessions can be configured to disconnect when locked.
- **No automatic reconnect on launch** unless the host has `reconnectOnLaunch` set.

## 12. Testing strategy

1. **Engine unit tests** (`swift test`, 75 tests): parser and emulator behavior, semantic records, protocol decoding, installer plans, speech scheduling, navigation, models. Fuzz-style random input runs on every pass.
2. **End-to-end shell-integration tests**: the real bash (3.2, as shipped on the development Mac) and zsh scripts run on a PTY, and their output drives the emulator. They verify command text, exit statuses, output extraction, working directory and the hidden-command privacy rule.
3. **Conformance:** `vttest` and `esctest` runs against a local PTY harness (Phase 9), and recorded byte streams from vim, nano, tmux, screen, htop, top, less, man and dialog as golden-screen tests.
4. **SSH integration:**
   - A Docker OpenSSH server in CI with password, key (Ed25519, ECDSA, RSA, encrypted), keyboard-interactive (PAM), changed host keys, jump hosts, forwarding and SFTP.
   - Network-loss simulation with `pfctl` and Network Link Conditioner.
5. **UI and accessibility automation:** XCUITest with `XCUIApplication.performAccessibilityAudit()` on every screen, plus assertions on element labels, values and custom actions for the terminal elements and rotors.
   - Live tests (`UITests/iOS/ConnectionUITests.swift`) connect to a real server configured through `TEST_RUNNER_ACCESSH_TEST_*` variables. They read command output back through the accessibility tree, which is the tree VoiceOver uses.
   - `SettingsUITests` audits every settings screen. Two kinds of report are ignored, each with its reason documented in the test:
     - contrast on system navigation-bar buttons drawn on glass;
     - Dynamic Type warnings on standard Form controls, disproved by the largest-text-size screenshot test.
   - Every other issue fails the build. These audits led to:
     - explicit labels on text fields that have an example placeholder;
     - full-contrast section headers, footers and an accent colour;
     - `ChoicePicker` in place of system pickers, whose values are drawn in light grey;
     - stacked layouts for long values.
6. **Manual VoiceOver testing**, required before each release, on iPhone and iPad (with and without a hardware keyboard). It covers every scenario in the product brief: first launch through SFTP and multiple sessions, including fast output, full-screen apps, the bell, sounds and haptics, toolbar customization, shell integration enabled, disabled, upgraded and incompatible, and exit-status reporting. The scripts live in `Documentation/Developer/Testing.md` (Phase 3). Testers use the real VoiceOver interaction model: gestures, rotor and keyboard commands, Braille display spot checks, and Large Text at the largest accessibility size.
7. **Accessibility acceptance criteria per screen.** Every screen must meet all ten:
   1. every control is reachable
   2. every control has a meaningful name
   3. state is perceivable without sight
   4. focus order is logical
   5. every essential action can be done without sight
   6. important changes are announced
   7. dynamic terminal content is navigable
   8. there are no gesture-only or keyboard-only actions
   9. no information is conveyed by color alone
   10. the screen works at accessibility text sizes

   Labels alone do not count as passing.

## 13. Phased implementation roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Repository, architecture, core models, terminal emulator, semantic model, shell-integration protocol, scripts and installer, platform-independent accessibility policy, tests | **Done** |
| 2 | AcceSSH-Transport: libssh2 + OpenSSL xcframeworks (pinned, checksummed), session thread over Network.framework, password / key / keyboard-interactive auth, host-key verification, PTY shell, exec, keepalive, error translation, Ed25519 and ECDSA P-256 key generation | **Done** (jump hosts, forwarding and SFTP move to phases 6–7) |
| 3 | iOS app shell: AcceSSH.xcodeproj, host list and editor, key import, Keychain storage, host-key and sign-in prompts, sessions | **Done for iOS** |
| 4 | iOS terminal view and VoiceOver layer: line elements, custom actions, speech coordinator, line-editing and direct-keys input, hardware keyboard, key bar | **Done for iOS** (find, selection, macOS next) |
| 4b | Settings: VoiceOver and speech, announcements, appearance, terminal, keyboard, key bar editor, bell (synthesized tones, haptics, quiet hours), SSH keys (generate, import, Face ID protection), trusted host keys | **Done** |
| 5 | Sounds and haptics for every event, notifications | Bell done; per-event sounds next |
| 6 | Shell-integration UI over SFTP; SFTP browser | |
| 7 | Port forwarding (L/R/SOCKS), jump hosts, agent | |
| 8 | Command history browser, find, selection, export, session logs, app lock, multiple sessions UI | |
| 9 | Resize reflow, conformance suites, performance, documentation completion | |

### Known gaps after Phase 1

- **Reflow on resize:** narrowing the window truncates on-screen rows, and scrollback rows keep their original width. Reflow is scheduled for Phase 9. Logical-line reading is unaffected.
- **Mouse event encoding:** mouse modes are tracked, but turning pointer events into bytes arrives with the views in Phase 4.
- **Untested fish script:** the fish integration script has not been run, because fish is not installed on the development Mac. bash and zsh are verified end to end.
- **zsh partial-line mark:** when a command's output does not end in a newline, zsh's `PROMPT_SP` marker (`%`) appears in that output on screen and therefore in extracted output text.
- **Encodings:** only UTF-8 and Latin-1 are supported.
