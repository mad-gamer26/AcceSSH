#!/bin/sh
# Builds CLibSSH2.xcframework (libssh2 + OpenSSL, static) for iOS devices, the iOS
# simulator and macOS, and places it where AcceSSH-Transport expects it.
#
# Sources are pinned by version/commit and verified by SHA-256 before building.
# libssh2 is built from a pinned main-branch commit because security fixes made in 2026
# (for example CVE-2026-7598 and several SFTP and transport fixes) are not in a tagged
# release yet. Update LIBSSH2_COMMIT and LIBSSH2_SHA256 together.
#
# Usage: Scripts/build-libssh2.sh [--clean]
set -eu

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBSSH2_COMMIT=232c9516fff9758427eb79861b51a6e3fde56d6d
LIBSSH2_SHA256=9c338a91c555b24cca99d9ff5ed2df6670846988646322aaa0d2a00db57a74ef

IOS_MIN=18.0
MACOS_MIN=15.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/Vendor/build"
SRC="$WORK/src"
OUTPUT="$ROOT/Packages/AcceSSH-Transport/Vendor/CLibSSH2.xcframework"
JOBS=$(sysctl -n hw.ncpu)

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$WORK/platforms" "$OUTPUT"
fi
mkdir -p "$SRC"

fetch() {  # url file sha256
    if [ ! -f "$SRC/$2" ]; then
        echo "Downloading $2"
        curl -fsSL -o "$SRC/$2.partial" "$1"
        mv "$SRC/$2.partial" "$SRC/$2"
    fi
    actual=$(shasum -a 256 "$SRC/$2" | cut -d' ' -f1)
    if [ "$actual" != "$3" ]; then
        echo "Checksum mismatch for $2: expected $3, got $actual" >&2
        exit 1
    fi
}

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
SHORT_COMMIT=$(printf '%s' "$LIBSSH2_COMMIT" | cut -c1-10)
fetch "https://github.com/libssh2/libssh2/archive/$SHORT_COMMIT.tar.gz" "libssh2-$SHORT_COMMIT.tar.gz" "$LIBSSH2_SHA256"

# build_platform <name> <openssl-target> <sdk> <cmake-system> <min-flag>
build_platform() {
    name=$1 openssl_target=$2 sdk=$3 system=$4 min_flag=$5
    prefix="$WORK/platforms/$name"
    if [ -f "$prefix/lib/libCLibSSH2.a" ]; then
        echo "== $name already built"
        return
    fi
    echo "== Building for $name"
    rm -rf "$prefix" "$WORK/tmp-$name"
    mkdir -p "$prefix" "$WORK/tmp-$name"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)

    # OpenSSL
    tar -xzf "$SRC/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK/tmp-$name"
    (
        cd "$WORK/tmp-$name/openssl-$OPENSSL_VERSION"
        CC="$(xcrun --sdk "$sdk" --find clang)" CFLAGS="$min_flag -isysroot $sysroot" \
            ./Configure "$openssl_target" no-shared no-tests no-apps no-docs no-ui-console no-dso no-engine \
            --prefix="$prefix" --libdir=lib >/dev/null
        make -j"$JOBS" build_libs >/dev/null
        make install_dev >/dev/null 2>&1
    )

    # libssh2
    tar -xzf "$SRC/libssh2-$SHORT_COMMIT.tar.gz" -C "$WORK/tmp-$name"
    cmake -S "$WORK/tmp-$name/libssh2-$LIBSSH2_COMMIT" -B "$WORK/tmp-$name/libssh2-build" \
        -DCMAKE_SYSTEM_NAME="$system" \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$(printf '%s' "$min_flag" | sed 's/.*=//')" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCRYPTO_BACKEND=OpenSSL \
        -DOPENSSL_ROOT_DIR="$prefix" \
        -DOPENSSL_INCLUDE_DIR="$prefix/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$prefix/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$prefix/lib/libssl.a" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DENABLE_ZLIB_COMPRESSION=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DLIBSSH2_NO_DEPRECATED=OFF >/dev/null
    cmake --build "$WORK/tmp-$name/libssh2-build" --parallel "$JOBS" >/dev/null
    cmake --install "$WORK/tmp-$name/libssh2-build" >/dev/null

    # One static library per platform, so the xcframework is a single binary.
    libtool -static -o "$prefix/lib/libCLibSSH2.a" \
        "$prefix/lib/libssh2.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a" 2>/dev/null
    rm -rf "$WORK/tmp-$name"
}

build_platform ios-arm64 ios64-xcrun iphoneos iOS "-mios-version-min=$IOS_MIN"
build_platform ios-simulator-arm64 iossimulator-arm64-xcrun iphonesimulator iOS "-mios-simulator-version-min=$IOS_MIN"
build_platform macos-arm64 darwin64-arm64-cc macosx Darwin "-mmacosx-version-min=$MACOS_MIN"

# Headers with a module map so Swift can `import CLibSSH2`.
HEADERS="$WORK/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$WORK/platforms/macos-arm64/include/libssh2.h" "$WORK/platforms/macos-arm64/include/libssh2_sftp.h" \
    "$WORK/platforms/macos-arm64/include/libssh2_publickey.h" "$HEADERS/"
cat > "$HEADERS/CLibSSH2.h" <<'EOF'
#include "libssh2.h"
#include "libssh2_sftp.h"
#include "libssh2_publickey.h"
EOF
cat > "$HEADERS/module.modulemap" <<'EOF'
module CLibSSH2 {
    header "CLibSSH2.h"
    link "z"
    export *
}
EOF

rm -rf "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
xcodebuild -create-xcframework \
    -library "$WORK/platforms/ios-arm64/lib/libCLibSSH2.a" -headers "$HEADERS" \
    -library "$WORK/platforms/ios-simulator-arm64/lib/libCLibSSH2.a" -headers "$HEADERS" \
    -library "$WORK/platforms/macos-arm64/lib/libCLibSSH2.a" -headers "$HEADERS" \
    -output "$OUTPUT" >/dev/null

cat > "$(dirname "$OUTPUT")/VERSIONS.txt" <<EOF
OpenSSL $OPENSSL_VERSION (sha256 $OPENSSL_SHA256)
libssh2 $LIBSSH2_COMMIT (sha256 $LIBSSH2_SHA256)
Built $(date -u +%Y-%m-%dT%H:%M:%SZ) for iOS $IOS_MIN+ (device, simulator arm64) and macOS $MACOS_MIN+ (arm64)
EOF
echo "Created $OUTPUT"
