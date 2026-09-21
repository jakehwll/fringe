#!/usr/bin/env bash
#
# Assembles Fringe.app by hand: compile with SwiftPM, then lay out the bundle
# that Xcode would otherwise produce, and ad-hoc sign it.
#
#   CONFIGURATION=debug ./Scripts/build-app.sh   # faster, unoptimised build
#   UNIVERSAL=1        ./Scripts/build-app.sh    # arm64 + x86_64 binary
#
set -euo pipefail

APP_NAME="Fringe"
CONFIGURATION="${CONFIGURATION:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT/build"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

BUILD_FLAGS=(--package-path "$ROOT" -c "$CONFIGURATION" --disable-sandbox)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
	BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

echo "==> Building $APP_NAME ($CONFIGURATION)"
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_BUNDLE"
plutil -lint "$ROOT/Bundle/Info.plist" >/dev/null
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Bundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' >"$APP_BUNDLE/Contents/PkgInfo"

if [[ -f "$ROOT/Bundle/AppIcon.icns" ]]; then
	cp "$ROOT/Bundle/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> Copying example widgets"
mkdir -p "$APP_BUNDLE/Contents/Resources/Examples"
# `notch-api.js` is editor typings, not a widget.
shopt -s nullglob
for script in "$ROOT/Examples/"*.js; do
	[[ "$(basename "$script")" == "notch-api.js" ]] && continue
	cp "$script" "$APP_BUNDLE/Contents/Resources/Examples/"
done

# The MediaRemote adapter is loaded by /usr/bin/perl rather than linked into
# the app, so it is built separately as a plain dylib. Perl's DynaLoader loads
# the Mach-O directly, which is why a bare binary in a .framework directory is
# enough — no bundle structure required.
echo "==> Building MediaRemote adapter"
ADAPTER_DIR="$APP_BUNDLE/Contents/Resources/MediaRemoteAdapter.framework"
mkdir -p "$ADAPTER_DIR"
clang -dynamiclib -fobjc-arc -O2 \
	-framework Foundation \
	-o "$ADAPTER_DIR/MediaRemoteAdapter" \
	"$ROOT/Adapter/MediaRemoteAdapter.m"
cp "$ROOT/Adapter/mediaremote-adapter.pl" "$APP_BUNDLE/Contents/Resources/"
chmod +x "$APP_BUNDLE/Contents/Resources/mediaremote-adapter.pl"
codesign --force --sign - "$ADAPTER_DIR/MediaRemoteAdapter"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP_BUNDLE"
# Nudge LaunchServices so it re-reads the bundle instead of a stale copy.
touch "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
