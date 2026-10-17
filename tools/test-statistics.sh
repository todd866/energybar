#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build
cc="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
"$cc" -fobjc-arc -O0 -g -Wall -Wextra -Werror -isysroot "$sdk" \
  -mmacosx-version-min=13.0 -ISources Sources/store.m Sources/fronius_archive.m \
  Sources/statistics.m Tests/test_statistics.m -framework Foundation -o build/test_statistics
build/test_statistics
"$cc" -fobjc-arc -fsyntax-only -Wall -Wextra -Werror -isysroot "$sdk" \
  -mmacosx-version-min=13.0 -ISources Sources/statistics_view.m Sources/main.m
"$cc" -fobjc-arc -O0 -g -Wall -Wextra -Werror -isysroot "$sdk" \
  -mmacosx-version-min=13.0 -ISources Sources/store.m Sources/fronius_archive.m \
  Sources/statistics.m Sources/statistics_view.m Sources/chart.m Sources/forecast.m \
  Sources/charge_estimate.m Sources/pure.m Tests/test_statistics_view.m \
  -framework Cocoa -o build/test_statistics_view
build/test_statistics_view
