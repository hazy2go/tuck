#!/bin/bash
# Build Tuck.app (universal: Apple Silicon + Intel) into ~/Applications.
# Needs only the Xcode Command Line Tools: xcode-select --install
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${TUCK_DEST:-${HOME}/Applications}/Tuck.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>Tuck</string>
	<key>CFBundleDisplayName</key>     <string>Tuck</string>
	<key>CFBundleIdentifier</key>      <string>local.tuck</string>
	<key>CFBundleExecutable</key>      <string>Tuck</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key> <string>1.0.0</string>
	<key>CFBundleVersion</key>         <string>1</string>
	<key>LSMinimumSystemVersion</key>  <string>14.0</string>
	<!-- Menu bar only: no Dock icon, no app switcher entry. -->
	<key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

for arch in arm64 x86_64; do
	swiftc -O -parse-as-library \
		-target "$arch-apple-macos14.0" \
		-o "$TMP/Tuck-$arch" \
		"$SRC_DIR"/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Tuck" "$TMP"/Tuck-*

# Sign with the local cert from scripts/make-signing-cert.sh if present (keeps
# the Accessibility permission across rebuilds), otherwise ad-hoc.
codesign --force --sign "${TUCK_SIGN_ID:-Tuck Local Signing}" --identifier local.tuck "$APP" 2>/dev/null \
	|| codesign --force --sign - --identifier local.tuck "$APP"

echo "built: $APP"
