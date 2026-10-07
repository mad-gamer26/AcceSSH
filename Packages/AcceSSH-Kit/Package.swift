// swift-tools-version: 6.0
//
// AcceSSH-Kit: the platform-independent engine of AcceSSH.
//
// Everything in this package compiles for iOS, iPadOS and macOS and contains no UIKit or
// AppKit code. Platform UI lives in the app targets; this package holds the models, the
// terminal emulator, the semantic terminal model, the shell-integration protocol and the
// accessibility policy logic that both the renderer and VoiceOver layer consume.

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "AcceSSH-Kit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "AcceSSHCore", targets: ["AcceSSHCore"]),
        .library(name: "AcceSSHShellIntegration", targets: ["AcceSSHShellIntegration"]),
        .library(name: "AcceSSHTerminal", targets: ["AcceSSHTerminal"]),
        .library(name: "AcceSSHAccessibility", targets: ["AcceSSHAccessibility"]),
    ],
    targets: [
        // Codable models shared by every layer: hosts, profiles, settings, feedback events.
        .target(
            name: "AcceSSHCore",
            swiftSettings: strictConcurrency
        ),
        // The versioned, accessibility-focused shell-integration protocol, its decoder,
        // the bash/zsh/fish scripts, and the transparent rc-file installer.
        .target(
            name: "AcceSSHShellIntegration",
            resources: [.copy("Scripts")],
            swiftSettings: strictConcurrency
        ),
        // VT/xterm terminal emulator plus the semantic terminal model.
        .target(
            name: "AcceSSHTerminal",
            dependencies: ["AcceSSHCore", "AcceSSHShellIntegration"],
            swiftSettings: strictConcurrency
        ),
        // Platform-independent accessibility policy: speech scheduling, semantic navigation,
        // screen description, highlight detection and announcement composition.
        .target(
            name: "AcceSSHAccessibility",
            dependencies: ["AcceSSHCore", "AcceSSHTerminal", "AcceSSHShellIntegration"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "AcceSSHCoreTests",
            dependencies: ["AcceSSHCore"]
        ),
        .testTarget(
            name: "AcceSSHShellIntegrationTests",
            dependencies: ["AcceSSHShellIntegration"]
        ),
        .testTarget(
            name: "AcceSSHTerminalTests",
            dependencies: ["AcceSSHTerminal", "AcceSSHShellIntegration", "AcceSSHCore", "AcceSSHAccessibility"]
        ),
        .testTarget(
            name: "AcceSSHAccessibilityTests",
            dependencies: ["AcceSSHAccessibility", "AcceSSHTerminal", "AcceSSHCore"]
        ),
    ]
)
