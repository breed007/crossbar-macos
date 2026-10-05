#!/usr/bin/env bash
#
# screenshots.sh — regenerate the README screenshots from the real UI, with sample data.
#
# Builds an ad-hoc-signed Debug app into build/screens (demo mode needs no helper, so
# nothing is installed in /Applications). For each view and appearance it launches
# the app in demo mode (sample services and addresses, never this Mac's), finds that
# process's window by PID, captures the composited screen region around it over a
# GitHub-colored backdrop, and quits the demo. Capturing the region rather than the
# single window keeps the popover's material: a single-window capture flattens it
# (Switchback's light menu came out flat gray). The backdrop covers the whole
# screen, so nothing else on screen can end up in an image.
#
# Needs Screen Recording permission for whatever runs it (macOS asks once).
#
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=build/screens
APP="$OUT_DIR/Build/Products/Debug/Crossbar.app"
BIN="$APP/Contents/MacOS/Crossbar"
FINDER="$OUT_DIR/window-for-pid"
OUT="docs/screenshots"
mkdir -p "$OUT_DIR" "$OUT"

xcodegen generate >/dev/null
if ! xcodebuild -project Crossbar.xcodeproj -scheme Crossbar -configuration Debug \
    -derivedDataPath "$OUT_DIR" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_DEBUG_DYLIB=NO build >"$OUT_DIR/build.log" 2>&1; then
  grep -E "error:" "$OUT_DIR/build.log" || tail -20 "$OUT_DIR/build.log"
  echo "BUILD FAILED (full log: $OUT_DIR/build.log)"
  exit 1
fi

# Tiny helper: print "x y width height" (points, top-left origin) of the highest window
# a PID owns, skipping the capture backdrop, the menu-bar status item (short), and
# invisible windows.
if [ ! -x "$FINDER" ] || [ "$0" -nt "$FINDER" ]; then
  cat > "$OUT_DIR/window-for-pid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
let candidates = windows.filter { w in
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
          (w[kCGWindowName as String] as? String) != "CrossbarDemoBackdrop",
          let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
          (bounds["Height"] ?? 0) > 50, (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0 else { return false }
    return true
}
let best = candidates.max { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) }
guard let b = best?[kCGWindowBounds as String] as? [String: CGFloat] else { exit(1) }
print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!))
SWIFT
  swiftc -O "$OUT_DIR/window-for-pid.swift" -o "$FINDER"
fi

for view in popover warning settings; do
  for look in light dark; do
    "$BIN" --demo "$view" "$look" >"$OUT_DIR/demo-$view-$look.log" 2>&1 &
    pid=$!
    # Wait until the window's bounds read the same twice in a row (up to ~8 s). The
    # first sighting isn't always the final size: the popover animates open, and a
    # dialog can be on screen mid-layout. A single re-read after a fixed pause can
    # still catch it moving.
    bounds=""; prev=""
    for _ in $(seq 1 40); do
      sleep 0.2
      bounds=$("$FINDER" "$pid" 2>/dev/null) || bounds=""
      [ -n "$bounds" ] && [ "$bounds" = "$prev" ] && break
      prev="$bounds"
    done
    sleep 0.8                         # let it finish drawing
    if [ -n "$bounds" ]; then
      # The composited region, with room for the shadow. The backdrop covers the menu
      # bar too, so the margin above the popover is backdrop, not menu bar.
      read -r x y w h <<< "$bounds"
      top=$([ "$view" = popover ] && echo 12 || echo 24)
      x=$(( x - 32 )); y=$(( y - top )); w=$(( w + 64 )); h=$(( h + top + 48 ))
      screencapture -x -R "$x,$y,$w,$h" "$OUT/$view-$look.png"
      echo "captured $OUT/$view-$look.png"
    else
      echo "FAILED: no window for $view ($look)"
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
done
