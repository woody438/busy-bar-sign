#!/usr/bin/env bash
# Builds the platform-independent parts of the app and checks them:
# LED-for-LED parity with the simulator, pixel alignment on common displays,
# frame time, the call detector's decisions on a scripted afternoon, the
# status rules, the local web server's request handling, and the Stream
# Deck plugin end to end.
#
#   Checks/run.sh                 # uses swiftc, node and npm from PATH
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

echo; echo "== call detection (runs a scripted 40 seconds in real time)"
LINK=()
if ! printf 'import Combine\n' | "$SWIFTC" -typecheck - >/dev/null 2>&1; then
  # no Combine here (Linux): build the two-name stand-in as a module
  "$SWIFTC" -parse-as-library -emit-library -emit-module -module-name Combine \
    Checks/detector/CombineStandIn.swift -o "$OUT/libCombine.so" -emit-module-path "$OUT/Combine.swiftmodule"
  LINK=(-I "$OUT" -L "$OUT" -lCombine)
  export LD_LIBRARY_PATH="$OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# (the ${LINK[@]+...} form: macOS's bash 3.2 treats an empty array as unset)
"$SWIFTC" ${LINK[@]+"${LINK[@]}"} Sources/CallDetector.swift Sources/StatusRules.swift Checks/detector/FakeProbes.swift Checks/detector/main.swift -o "$OUT/detector"
"$OUT/detector" | tail -1

echo; echo "== status rules (calendar, mic, controls)"
node simulator/tools/rules-check.js
node simulator/tools/rules-cases.js "$OUT/rules.json" >/dev/null
"$SWIFTC" -O Sources/StatusRules.swift Checks/rules/main.swift -o "$OUT/rules"
"$OUT/rules" "$OUT/rules.json"

echo; echo "== local API (what the Stream Deck plugin talks to)"
"$SWIFTC" Sources/LocalAPI.swift Checks/http/main.swift -o "$OUT/http"
"$OUT/http"

echo; echo "== Stream Deck plugin (key drawing, and a fake Stream Deck and app)"
(cd streamdeck && npm ci --silent && npm test)

echo; echo "all checks passed"
