#!/usr/bin/env bash
#
# Build the app for a device WITHOUT code signing and wrap it into an unsigned
# `olcos-ios-unsigned.ipa` for sideloading (AltStore / Sideloadly re-sign it
# with the end user's Apple ID). Single source of truth for the .ipa, used both
# locally and by .github/workflows/release.yml.
#
# Requires the full Xcode (the iOS SDK) and an existing App/Mobile.xcframework
# (run scripts/fetch-framework.sh or scripts/build-framework.sh first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# A failed prerequisite must not leave a stale asset that looks newly built.
IPA="$ROOT/olcos-ios-unsigned.ipa"
rm -f "$IPA"
if [ ! -d App/Mobile.xcframework ]; then
  echo "error: App/Mobile.xcframework is missing — run scripts/fetch-framework.sh or scripts/build-framework.sh first" >&2
  exit 1
fi

# Never package an existing output after a failed build. Keep Xcode's native
# project/scheme/product names and bundle IDs, but brand the distributed asset.
mkdir -p build/logs
# Always regenerate: project.yml, not an old .xcodeproj, owns the version.
xcodegen generate --spec project.yml

echo "note: building olcrtc-ios for device (Release, unsigned) ..."
xcodebuild \
  -quiet -showBuildTimingSummary \
  -jobs 2 \
  -project olcrtc-ios.xcodeproj \
  -scheme olcrtc-ios \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  -resultBundlePath "build/device-$(date +%s)-$$.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee build/logs/device-build.log

APP="build/device/Build/Products/Release-iphoneos/olcrtc-ios.app"
if [ ! -d "$APP" ]; then
  echo "error: build did not produce $APP" >&2
  exit 1
fi

# #vpn: the tunnel appex must ship inside the app bundle — if the olcrtc-tunnel
# target fell out of the build, the IPA would sideload proxy-only, silently.
APPEX="$APP/PlugIns/olcrtc-tunnel.appex"
if [ ! -d "$APPEX" ]; then
  echo "error: tunnel extension missing from app bundle ($APPEX)" >&2
  exit 1
fi

python3 scripts/cut-release.py --check-bundle "$APP"

# An .ipa is just a zip with a Payload/ folder containing the .app.
# Use a fresh staging folder, never delete a caller's existing Payload/.
STAGE="$(mktemp -d "$ROOT/build/ipa.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qr "$STAGE/unsigned.ipa" Payload)
unzip -tq "$STAGE/unsigned.ipa"
mv "$STAGE/unsigned.ipa" "$IPA"

echo "done:  $IPA (unsigned; packaging alone does not run XCTest)"
