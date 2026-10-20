#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/CodexQuotaBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
typeset -a architectures
case "${1:-}" in
  --universal) architectures=(arm64 x86_64) ;;
  "") architectures=("$(uname -m)") ;;
  *) print -u2 "Usage: ./build.sh [--universal]"; exit 2 ;;
esac
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
for architecture in "${architectures[@]}"; do
  xcrun swiftc -O -target "${architecture}-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement \
    Sources/main.swift -o "$BUILD_DIR/CodexQuotaBar-$architecture"
done
if (( ${#architectures[@]} > 1 )); then
  xcrun lipo -create "$BUILD_DIR"/CodexQuotaBar-* -output "$APP/Contents/MacOS/CodexQuotaBar"
else
  cp "$BUILD_DIR/CodexQuotaBar-${architectures[1]}" "$APP/Contents/MacOS/CodexQuotaBar"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexQuotaBar</string>
<key>CFBundleIdentifier</key><string>local.codex.quota-bar</string>
<key>CFBundleName</key><string>CodexQuotaBar</string>
<key>CFBundleDisplayName</key><string>Codex 额度</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
