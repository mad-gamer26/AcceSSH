// swift-tools-version: 6.0
//
// AcceSSH-Transport: SSH, SFTP and port forwarding for AcceSSH, built on libssh2 and
// OpenSSL. The binary is produced by Scripts/build-libssh2.sh from pinned, checksummed
// sources; run that script once before building this package.

import PackageDescription

let package = Package(
    name: "AcceSSH-Transport",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "AcceSSHTransport", targets: ["AcceSSHTransport"]),
    ],
    dependencies: [
        .package(path: "../AcceSSH-Kit"),
    ],
    targets: [
        .binaryTarget(name: "CLibSSH2", path: "Vendor/CLibSSH2.xcframework"),
        .target(
            name: "AcceSSHTransport",
            dependencies: [
                "CLibSSH2",
                .product(name: "AcceSSHCore", package: "AcceSSH-Kit"),
                .product(name: "AcceSSHShellIntegration", package: "AcceSSH-Kit"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "AcceSSHTransportTests",
            dependencies: [
                "AcceSSHTransport",
                .product(name: "AcceSSHCore", package: "AcceSSH-Kit"),
                .product(name: "AcceSSHTerminal", package: "AcceSSH-Kit"),
                .product(name: "AcceSSHAccessibility", package: "AcceSSH-Kit"),
                .product(name: "AcceSSHShellIntegration", package: "AcceSSH-Kit"),
            ]
        ),
    ]
)
