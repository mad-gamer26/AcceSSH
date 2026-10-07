#!/bin/sh
# Runs the AcceSSH-Kit test suite. Pass --ios to also compile the engine for iOS.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE="$ROOT/Packages/AcceSSH-Kit"

echo "== Checking shell-integration script syntax"
bash -n "$PACKAGE/Sources/AcceSSHShellIntegration/Scripts/accessh.bash"
zsh -n "$PACKAGE/Sources/AcceSSHShellIntegration/Scripts/accessh.zsh"
if command -v fish >/dev/null 2>&1; then
    fish --no-execute "$PACKAGE/Sources/AcceSSHShellIntegration/Scripts/accessh.fish"
else
    echo "   fish is not installed; skipping the fish syntax check"
fi

echo "== Running AcceSSH-Kit tests"
swift test --package-path "$PACKAGE"

if [ "${1:-}" = "--ios" ]; then
    echo "== Building AcceSSH-Kit for iOS"
    DERIVED=$(mktemp -d)
    trap 'rm -rf "$DERIVED"' EXIT
    (cd "$PACKAGE" && xcodebuild -scheme AcceSSH-Kit-Package -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED" -quiet build)
fi
