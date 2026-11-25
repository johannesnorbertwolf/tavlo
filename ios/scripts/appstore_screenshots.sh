#!/usr/bin/env bash
# App Store screenshots (#184): builds the app (Debug, for the simulator) once, then for
# every locale and device launches it straight into each scene via the DEBUG-only
# `-screenshot*` launch arguments (ios/TavliApp/TavliApp/Views/ScreenshotScenes.swift) and
# saves a PNG with `xcrun simctl io <udid> screenshot`.
#
# Usage:
#   ios/scripts/appstore_screenshots.sh [-o OUTDIR] [-l "en el de nl"] [-d "iphone ipad"] [--no-build]
#
#   -o OUTDIR    where to write (default: design/app-store/screenshots)
#   -l LOCALES   space-separated subset of: en de nl el fa (default: en el de nl; fa is not
#                listed on the App Store for now, see docs/app-store/listing.md)
#   -d DEVICES   space-separated subset of: iphone ipad (default: both)
#   --no-build   reuse the last build in $DERIVED_DATA
#
# Output: OUTDIR/<locale>/<device>/NN-name.png, e.g. OUTDIR/en/iphone/01-play.png, plus
# OUTDIR/<locale>/iphone-medium/ for every iPhone shot.
#
# Devices (override the UDIDs with IPHONE_UDID / IPAD_UDID):
#   iphone        = iPhone 17 Pro Max simulator -> 1320 x 2868 portrait, App Store Connect's
#                   "iPhone with Dynamic Island (large display)"
#   iphone-medium = the iphone shots scaled to 1206 x 2622 (same aspect within 0.1%), the
#                   **required** "iPhone with Dynamic Island (medium display)" size (2026)
#   ipad          = iPad Pro 13-inch (M5) simulator -> 2064 x 2752 portrait, "13-inch display"
#
# Per locale each simulator gets that language + region as its system setting (so the
# status bar and the iPad's date read natively) and is rebooted; the iPad is switched to
# "Full Screen Apps" (no window grip / app name in the status bar). The status bar shows
# 9:41 on Tue 13 Jan 2026, full battery and full bars. Everything is restored at the end
# (language/region/multitasking take effect on the next boot). The scenes, in order:
#   01-play      a mid-game Plakoto position vs the computer, your turn, dice rolled
#   02-review    the post-game review on your worst move (yours amber vs best blue + graph)
#   03-drill     the drill's solution on another mistake (your move amber vs best blue)
#   04-handicap  the handicap builder sheet with a preset handicap
#   05-dark      the game in dark appearance, a later position
#   06-newgame   the new-game sheet (Plakoto · Standard · Portes · Fevga, levels)
#
# Needs the four Core ML models in ios/TavliApp/TavliApp/Resources (gitignored) and an
# up-to-date TavliApp.xcodeproj (`xcodegen generate` in ios/TavliApp). PNGs are squeezed
# with pngquant when installed, else re-encoded losslessly with Pillow when available.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="$ROOT/design/app-store/screenshots"
LOCALES="en el de nl"
DEVICES="iphone ipad"
BUILD=1
IPHONE_UDID="${IPHONE_UDID:-5065195B-B000-40D6-8E99-F14EDDFA0991}"
IPAD_UDID="${IPAD_UDID:-5DD9979A-94BA-4A1C-8E47-323E3E433441}"
DERIVED_DATA="${DERIVED_DATA:-${TMPDIR:-/tmp}/tavtav-screenshots-dd}"
BUNDLE_ID="com.plakoto.TavliApp"
SETTLE="${SETTLE:-6}"   # seconds between launch and capture

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -l) LOCALES="$2"; shift 2 ;;
    -d) DEVICES="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Scenes: "NN-name|launch arguments". Positions come from the fixture
# (ScreenshotFixture.swift): 01/05 use gamePly / darkGamePly, 02 your worst move, 03
# the drill's last card (another of your mistakes).
SCENES=(
  "01-play|-screenshotGame -settings.appearance light"
  "02-review|-screenshotReview -settings.appearance light"
  "03-drill|-screenshotDrill -screenshotDrillSolution -settings.appearance light"
  "04-handicap|-screenshotHandicap -settings.appearance light"
  "05-dark|-screenshotGame -settings.appearance dark"
  "06-newgame|-screenshotNewGame -settings.appearance light"
)

udid_for() { case "$1" in iphone) echo "$IPHONE_UDID" ;; ipad) echo "$IPAD_UDID" ;; *) echo "unknown device $1" >&2; exit 2 ;; esac; }
region_for() { case "$1" in en) echo en_US ;; de) echo de_DE ;; nl) echo nl_NL ;; el) echo el_GR ;; fa) echo fa_IR ;; *) echo "unknown locale $1" >&2; exit 2 ;; esac; }

# ── Build once ──────────────────────────────────────────────────────────────────────
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/TavliApp.app"
if [ "$BUILD" = 1 ]; then
  echo "Building TavliApp (Debug, simulator)…"
  mkdir -p "$DERIVED_DATA"
  if ! xcodebuild -project "$ROOT/ios/TavliApp/TavliApp.xcodeproj" -scheme TavliApp \
      -configuration Debug -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build > "$DERIVED_DATA/build.log" 2>&1; then
    grep -E "error:" "$DERIVED_DATA/build.log" | head -20 >&2
    echo "build failed (log: $DERIVED_DATA/build.log)" >&2
    exit 1
  fi
fi
[ -d "$APP" ] || { echo "no build at $APP" >&2; exit 1; }

# ── Simulator helpers ───────────────────────────────────────────────────────────────
boot() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" >/dev/null
}

# 9:41 local time on a fixed date (the iPad status bar shows the date too). simctl wants
# an ISO string in UTC; the simulator shows it in the Mac's time zone.
STATUS_TIME="$(date -u -r "$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-01-13 09:41:00' +%s)" '+%Y-%m-%dT%H:%M:%S.000Z')"
clean_status_bar() {
  xcrun simctl status_bar "$1" override --time "$STATUS_TIME" --batteryState charged \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3 --wifiMode active --cellularMode active \
    --dataNetwork wifi --operatorName ''
}

# Set the simulator's system language + region, then reboot so SpringBoard (status bar)
# and the app both pick it up.
set_locale() {
  local udid="$1" lang="$2" region="$3"
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$lang"
  xcrun simctl spawn "$udid" defaults write -g AppleLocale "$region"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  boot "$udid"
}

# The simulators' own language/region, saved before and restored after (plain files:
# macOS ships bash 3.2, which has no associative arrays).
STATE_DIR="$(mktemp -d)"
save_locale() {
  local udid="$1"
  xcrun simctl spawn "$udid" defaults read -g AppleLocale > "$STATE_DIR/$udid.locale" 2>/dev/null \
    || echo en_US > "$STATE_DIR/$udid.locale"
  xcrun simctl spawn "$udid" defaults read -g AppleLanguages 2>/dev/null | tr -d '()",' | xargs \
    > "$STATE_DIR/$udid.langs" || echo en-US > "$STATE_DIR/$udid.langs"
  xcrun simctl spawn "$udid" defaults read com.apple.springboard SBMedusaMultitaskingEnabled \
    > "$STATE_DIR/$udid.medusa" 2>/dev/null || rm -f "$STATE_DIR/$udid.medusa"
  # iPadOS 26+ "Windowed Apps" draws a resize grip and the app name in the status bar:
  # switch to "Full Screen Apps" (a no-op on the iPhone).
  xcrun simctl spawn "$udid" defaults write com.apple.springboard SBMedusaMultitaskingEnabled -bool NO
}
restore_locale() {
  local udid="$1"
  [ -f "$STATE_DIR/$udid.locale" ] || return 0
  # shellcheck disable=SC2046
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array $(cat "$STATE_DIR/$udid.langs")
  xcrun simctl spawn "$udid" defaults write -g AppleLocale "$(cat "$STATE_DIR/$udid.locale")"
  if [ -f "$STATE_DIR/$udid.medusa" ]; then
    xcrun simctl spawn "$udid" defaults write com.apple.springboard SBMedusaMultitaskingEnabled \
      -bool "$(cat "$STATE_DIR/$udid.medusa")"
  else
    xcrun simctl spawn "$udid" defaults delete com.apple.springboard SBMedusaMultitaskingEnabled 2>/dev/null || true
  fi
  xcrun simctl status_bar "$udid" clear || true
}

capture() {
  local udid="$1" out="$2"; shift 2
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  # shellcheck disable=SC2068
  xcrun simctl launch "$udid" "$BUNDLE_ID" $@ >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot --type=png "$out" >/dev/null 2>&1
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
}

# Shrink a PNG: pngquant (lossy, visually identical) when installed, else a lossless
# re-encode with Pillow when available (~35% smaller), else leave it as captured.
squeeze() {
  if command -v pngquant >/dev/null; then
    pngquant --force --skip-if-larger --quality 85-98 --output "$1" "$1" || true
  elif python3 -c 'import PIL' 2>/dev/null; then
    python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGB").save(sys.argv[1], optimize=True)' "$1"
  fi
}

# ── Run ─────────────────────────────────────────────────────────────────────────────
for device in $DEVICES; do
  udid="$(udid_for "$device")"
  boot "$udid"
  save_locale "$udid"
done
trap 'for d in $DEVICES; do restore_locale "$(udid_for "$d")"; done; rm -rf "$STATE_DIR"' EXIT

for device in $DEVICES; do
  udid="$(udid_for "$device")"
  for locale in $LOCALES; do
    region="$(region_for "$locale")"
    echo "── $locale / $device"
    set_locale "$udid" "$locale" "$region"
    xcrun simctl install "$udid" "$APP"
    clean_status_bar "$udid"
    dir="$OUTDIR/$locale/$device"
    mkdir -p "$dir"
    for scene in "${SCENES[@]}"; do
      name="${scene%%|*}"
      args="${scene#*|}"
      capture "$udid" "$dir/$name.png" $args -AppleLanguages "($locale)" -AppleLocale "$region"
      squeeze "$dir/$name.png"
      size="$(sips -g pixelWidth -g pixelHeight "$dir/$name.png" | awk '/pixel/{print $2}' | xargs | tr ' ' 'x')"
      echo "   $name.png  $size"
      if [ "$device" = iphone ]; then
        # App Store Connect requires the medium-display size: scale the large shot down.
        mkdir -p "$OUTDIR/$locale/iphone-medium"
        sips -z 2622 1206 "$dir/$name.png" --out "$OUTDIR/$locale/iphone-medium/$name.png" >/dev/null
        squeeze "$OUTDIR/$locale/iphone-medium/$name.png"
        echo "   iphone-medium/$name.png  1206x2622"
      fi
    done
  done
done
echo "Done: $OUTDIR"
