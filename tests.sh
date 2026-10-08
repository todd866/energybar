#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

CC="${CC:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="build"
mkdir -p "$BUILD_DIR"

COMMON=(-fobjc-arc -O0 -g -Wall -Wextra -Werror
    -isysroot "$SDKROOT" -mmacosx-version-min=13.0 -ISources)

run_foundation() {
    local name="$1"
    shift
    "$CC" "${COMMON[@]}" "$@" -framework Foundation -o "$BUILD_DIR/$name"
    "$BUILD_DIR/$name"
}

run_foundation test_pure Sources/pure.m Tests/test_pure.m
run_foundation test_v11 Sources/pure.m Sources/parse.m Sources/store.m Tests/test_v11.m
run_foundation test_ui Sources/store.m Tests/test_ui.m
run_foundation test_soc Sources/pure.m Sources/store.m Sources/soc.m Tests/test_soc.m
run_foundation test_vehicle Sources/pure.m Sources/store.m Sources/soc.m Sources/vehicle.m Tests/test_vehicle.m
run_foundation test_config Sources/config.m Sources/store.m Sources/tariff.m Tests/test_config.m
run_foundation test_tariff Sources/store.m Sources/tariff.m Tests/test_tariff.m
run_foundation test_parse_hardening Sources/parse.m Tests/test_parse_hardening.m
run_foundation test_status_glyph Sources/pure.m Tests/test_status_glyph.m
run_foundation test_fixture Sources/parse.m Sources/fixture.m Tests/test_fixture.m
run_foundation test_sessions Sources/sessions.m Tests/test_sessions.m
run_foundation test_fronius_archive Sources/fronius_archive.m Tests/test_fronius_archive.m

"$CC" "${COMMON[@]}" \
    Sources/pure.m Sources/parse.m Sources/store.m Sources/tariff.m Sources/soc.m Sources/chart.m \
    Sources/tiles.m Sources/popover.m Sources/vehicle.m Tests/test_render.m \
    -framework Cocoa -o "$BUILD_DIR/test_render"
RENDER_ARGS=()
if [[ -n "${1:-}" ]]; then RENDER_ARGS+=("$1"); fi
if [[ "${ENERGYBAR_SKIP_PIXEL_SNAPSHOTS:-0}" == "1" ]]; then
    RENDER_ARGS+=(--skip-pixel-snapshots)
fi
"$BUILD_DIR/test_render" "${RENDER_ARGS[@]}" -NSViewLayoutAssertions YES

if [[ "${ENERGYBAR_SANITIZERS:-0}" == "1" ]]; then
    SAN=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    "$CC" "${COMMON[@]}" "${SAN[@]}" \
        Sources/pure.m Sources/parse.m Sources/store.m Tests/test_v11.m \
        -framework Foundation -o "$BUILD_DIR/test_v11_sanitized"
    "$BUILD_DIR/test_v11_sanitized"
    "$CC" "${COMMON[@]}" "${SAN[@]}" \
        Sources/pure.m Sources/store.m Sources/soc.m Sources/vehicle.m Tests/test_vehicle.m \
        -framework Foundation -o "$BUILD_DIR/test_vehicle_sanitized"
    "$BUILD_DIR/test_vehicle_sanitized"
    "$CC" "${COMMON[@]}" "${SAN[@]}" \
        Sources/sessions.m Tests/test_sessions.m \
        -framework Foundation -o "$BUILD_DIR/test_sessions_sanitized"
    "$BUILD_DIR/test_sessions_sanitized"
    "$CC" "${COMMON[@]}" "${SAN[@]}" \
        Sources/fronius_archive.m Tests/test_fronius_archive.m \
        -framework Foundation -o "$BUILD_DIR/test_fronius_archive_sanitized"
    "$BUILD_DIR/test_fronius_archive_sanitized"
    "$CC" "${COMMON[@]}" "${SAN[@]}" \
        Sources/store.m Sources/tariff.m Tests/test_tariff.m \
        -framework Foundation -o "$BUILD_DIR/test_tariff_sanitized"
    "$BUILD_DIR/test_tariff_sanitized"
fi

echo "tests ok"
