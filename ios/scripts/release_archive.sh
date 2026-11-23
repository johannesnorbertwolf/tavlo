#!/usr/bin/env bash
# Archive Tavlo for the App Store, and with --upload send it to App Store Connect
# (it then appears in TestFlight after Apple's processing, ~15–30 min).
#
#   bash ios/scripts/release_archive.sh            # archive + export a signed .ipa (no upload)
#   bash ios/scripts/release_archive.sh --upload   # archive + upload to App Store Connect
#
# Needs: the Apple Developer Program team signed in to Xcode (Settings → Accounts),
# the app record in App Store Connect (for --upload), xcodegen, and all four value
# models in TavliApp/TavliApp/Resources (gitignored; see setup.sh).
# Env: TAVLO_TEAM (team ID, default below), OUT (output dir, default ios/build/release).
set -euo pipefail

TEAM="${TAVLO_TEAM:-8XRKL83C4V}"
UPLOAD=false
ALLOW_DIRTY=false
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=true ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
    *) echo "usage: $0 [--upload] [--allow-dirty]"; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../TavliApp"
IOS="$(cd .. && pwd)"
OUT="${OUT:-$IOS/build/release}"

# 1. Every variant's computer player must be bundled: a missing model silently turns
#    that variant's AI into random moves.
for name in Plakoto PlakotoStandard Fevga Portes; do
  if [ ! -f "TavliApp/Resources/${name}Value.mlpackage/Manifest.json" ]; then
    echo "error: ${name}Value.mlpackage is missing from TavliApp/Resources — not releasing."
    exit 1
  fi
done

# 2. The build number is the commit count, so every upload from a newer commit is
#    higher (App Store Connect rejects a repeated or lower build number). A release
#    must match a commit: refuse uncommitted changes unless --allow-dirty.
if [ "$ALLOW_DIRTY" != true ] && [ -n "$(git status --porcelain -- "$IOS")" ]; then
  echo "error: uncommitted changes under ios/ — commit first (or pass --allow-dirty for a test archive)."
  exit 1
fi
BUILD="$(git rev-list --count HEAD)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
echo "→ Tavlo $VERSION ($BUILD), team $TEAM, commit $(git rev-parse --short HEAD)"

# 3. Archive.
xcodegen generate --quiet
ARCHIVE="$OUT/Tavlo-$VERSION-$BUILD.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild -project TavliApp.xcodeproj -scheme TavliApp -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates -quiet archive

APP="$ARCHIVE/Products/Applications/TavliApp.app"
MODELS="$(find "$APP" -maxdepth 1 -name '*.mlmodelc' | wc -l | tr -d ' ')"
if [ "$MODELS" != 4 ]; then
  echo "error: the archived app has $MODELS compiled models, expected 4."
  exit 1
fi

# 4. Export (signed .ipa) or upload.
DEST=export
[ "$UPLOAD" = true ] && DEST=upload
PLIST="$OUT/ExportOptions.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$PLIST" \
  -exportPath "$OUT/export-$BUILD" -allowProvisioningUpdates -quiet

if [ "$UPLOAD" = true ]; then
  echo "✓ Uploaded Tavlo $VERSION ($BUILD). It shows up in App Store Connect → TestFlight after processing."
else
  echo "✓ Exported $OUT/export-$BUILD/TavliApp.ipa (not uploaded; pass --upload to send it)."
fi
