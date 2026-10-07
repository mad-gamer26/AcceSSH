# AcceSSH

An SSH client for iPhone and iPad, designed around accessible terminal interaction. VoiceOver support is treated with the same priority as SSH protocol correctness: output is read as it arrives without ever interrupting, Direct Keys mode speaks every character and cursor move, and every behavior can be customized.

> **Status:** early and in active development. It connects, authenticates (keys, passwords, keyboard-interactive), runs an accessible terminal, and installs optional shell integration. SFTP, port forwarding, multiple sessions and more are on the roadmap in [Documentation/Architecture.md](Documentation/Architecture.md).

## Highlights

- Real SSH via libssh2 and OpenSSL, running over Network.framework; host-key verification with spoken fingerprints; Ed25519 and ECDSA key generation, with optional Face ID protection.
- A VT220/xterm terminal emulator whose model drives both the screen and VoiceOver: one accessibility element per line, never one giant text blob.
- Speech built for terminals: batched output, typed-echo suppression or full character echo, cursor-movement announcements, highlighted-menu-item detection in full-screen programs, announcements that never interrupt.
- Line Editing (a native text field) and Direct Keys input, a customizable key bar, three-finger swipes that send arrow keys, hardware keyboard support.
- Optional shell integration for bash, zsh and fish, installed only after you review every changed line, so AcceSSH knows exactly where each command and its output begin and end, and announces failures with their exit status.

## Building

Requirements: macOS with Xcode 27 or later (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and CMake (`brew install cmake`).

```sh
git clone https://github.com/mad-gamer26/AcceSSH.git
cd AcceSSH
Scripts/build-libssh2.sh       # downloads, verifies and builds libssh2 + OpenSSL (about a minute)
Scripts/generate-project.sh    # regenerates AcceSSH.xcodeproj from project.yml
open AcceSSH.xcodeproj         # choose the AcceSSH-iOS scheme and your device
```

To run it on your own device, change the signing team in Xcode (or `DEVELOPMENT_TEAM` and the bundle identifier in `project.yml`).

## Testing

```sh
Scripts/test.sh                # engine tests, including real bash and zsh shell-integration runs
Scripts/test.sh --ios          # also compiles the engine for iOS
```

Tests against a live SSH server are skipped unless you point them at one:

```sh
cd Packages/AcceSSH-Transport
ACCESSH_TEST_HOST=example.com ACCESSH_TEST_USER=me ACCESSH_TEST_KEY=~/.ssh/id_ed25519 swift test
```

The UI tests (XCUITest, including Apple accessibility audits) take the same values prefixed with `TEST_RUNNER_`, for example `TEST_RUNNER_ACCESSH_TEST_HOST`. Pass `-collect-test-diagnostics never` to `xcodebuild test` to avoid a long wait after the tests finish.

## Repository layout

| Path | Contents |
|---|---|
| `Packages/AcceSSH-Kit` | Platform-independent engine: models, terminal emulator, semantic model, shell integration, speech and navigation logic |
| `Packages/AcceSSH-Transport` | SSH over libssh2 and OpenSSL, key generation, remote shell-integration management |
| `Apps/` | The iPhone and iPad app (`Shared/` for SwiftUI screens and services, `iOS/` for the UIKit terminal) |
| `UITests/` | XCUITest suites, including live-server and accessibility-audit tests |
| `Documentation/` | Architecture, the shell-integration protocol, and user guides |
| `Scripts/` | Build, project generation and test tooling |

## License

AcceSSH is released under the [MIT License](LICENSE). Bundled libraries keep their own licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
