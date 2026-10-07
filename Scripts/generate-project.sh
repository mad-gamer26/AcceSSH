#!/bin/sh
# Regenerates AcceSSH.xcodeproj from project.yml.
set -eu
cd "$(dirname "$0")/.."
[ -d Packages/AcceSSH-Transport/Vendor/CLibSSH2.xcframework ] || Scripts/build-libssh2.sh
xcodegen generate --spec project.yml
