#!/bin/zsh
# Build Energybar.app — Glancebar-style, no Xcode project.
set -euo pipefail
cd "${0:A:h}"

CC="${CC:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="build"
OUTPUT_APP="$BUILD_DIR/Energybar.app"
mkdir -p "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.energybar-build.XXXXXX")"
APP="$STAGING_DIR/Energybar.app"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

./tests.sh
plutil -lint Info.plist >/dev/null

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CC" \
    -fobjc-arc \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min=13.0 \
    -arch arm64 \
    -ISources \
    Sources/config.m Sources/tariff.m Sources/fixture.m Sources/pure.m Sources/parse.m Sources/store.m Sources/sessions.m Sources/fronius_archive.m Sources/soc.m Sources/chart.m Sources/tiles.m Sources/popover.m Sources/vehicle.m Sources/main.m \
    -framework Cocoa \
    -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Energybar"
install -m 0644 Info.plist "$APP/Contents/Info.plist"

# Sign: prefer ENERGYBAR_CODESIGN_IDENTITY, else ad-hoc
if [[ -n "${ENERGYBAR_CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$ENERGYBAR_CODESIGN_IDENTITY" --options runtime "$APP"
elif [[ "${ENERGYBAR_ADHOC:-0}" == "1" ]]; then
    codesign --force --sign - "$APP"
else
    ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/{print $2; exit}') || true
    if [[ -n "$ID" ]]; then
        codesign --force --sign "$ID" --options runtime "$APP"
    else
        echo "No Developer ID identity found. Set ENERGYBAR_ADHOC=1 for an explicit local-only build." >&2
        exit 1
    fi
fi

EXPECTED_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
ACTUAL_VERSION="$($APP/Contents/MacOS/Energybar --version)"
[[ "$ACTUAL_VERSION" == "Energybar $EXPECTED_VERSION" ]] || {
    echo "version mismatch: plist=$EXPECTED_VERSION executable=$ACTUAL_VERSION" >&2
    exit 1
}
codesign --verify --deep --strict "$APP"
BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Energybar")"
[[ "$BUILT_ARCHS" == "arm64" ]] || {
    echo "expected Apple-silicon-only arm64 build (built: $BUILT_ARCHS)" >&2
    exit 1
}
"$APP/Contents/MacOS/Energybar" --help >/dev/null

rm -rf "$OUTPUT_APP"
mv "$APP" "$OUTPUT_APP"
echo "Built $OUTPUT_APP"
echo "Verified version $EXPECTED_VERSION, signature, arm64 architecture, and native CLI smoke test"
echo "Install: quit the running Energybar, replace /Applications/Energybar.app, then reopen it"
