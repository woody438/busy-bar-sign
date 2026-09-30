#!/usr/bin/env bash
# Builds the platform-independent parts of the app (engine, fonts, raster,
# geometry) and checks them: LED-for-LED parity with the simulator, pixel
# alignment on common displays, and frame time.
#
#   Checks/run.sh                 # uses swiftc and node from PATH
#   SWIFTC=/path/to/swiftc Checks/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTC="${SWIFTC:-swiftc}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
B=Sources/Bar

echo "== parity with the simulator"
"$SWIFTC" -O $B/BarEngine.swift $B/PixelFonts.swift $B/FontData.swift Checks/parity/main.swift -o "$OUT/parity"
"$OUT/parity" "$OUT/swift.bin" >/dev/null
node simulator/tools/parity.js "$OUT/swift.bin" | tail -1

echo; echo "== geometry"
"$SWIFTC" -O $B/BarGeometry.swift Checks/geometry/main.swift -o "$OUT/geometry"
"$OUT/geometry" | tail -1

echo; echo "== frame time"
"$SWIFTC" -O $B/BarEngine.swift $B/PixelFonts.swift $B/FontData.swift $B/LEDRaster.swift Checks/raster/main.swift -o "$OUT/raster"
"$OUT/raster"
