#!/bin/sh
# Builds Diskz.app into ~/Applications and signs it with the "diskz-dev" certificate
# (create that once with scripts/make-signing-cert.sh).
set -eu
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Diskz.app"
ID=com.github.tillg.diskz

swift build -c release --product DiskzApp
BIN="$(swift build -c release --show-bin-path)/DiskzApp"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Diskz"
cp Resources/AppIcon.icns Resources/MenuIcon.png "Resources/MenuIcon@2x.png" \
    Resources/MenuIconTemplate.png "Resources/MenuIconTemplate@2x.png" "$APP/Contents/Resources/"   # from logo.svg, see scripts/make-icon.sh
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleName</key><string>Diskz</string>
    <key>CFBundleExecutable</key><string>Diskz</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign diskz-dev --identifier "$ID" "$APP"
echo "built $APP"
