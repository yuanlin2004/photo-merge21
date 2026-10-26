#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)"
fi
APP="$PWD/dist/Photo Merge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/photo-merge" "$APP/Contents/MacOS/photo-merge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>photo-merge</string>
<key>CFBundleIdentifier</key><string>com.yuanlin2004.photomerge</string>
<key>CFBundleName</key><string>Photo Merge</string>
<key>CFBundleDisplayName</key><string>Photo Merge</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Photo</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.image</string></array>
</dict></array>
</dict></plist>
PLIST
cp Resources/Icons/PhotoMerge.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
cp "$BIN/photo-merge" dist/photo-merge
printf 'Built %s\n' "$APP"
FLIP="$PWD/dist/Photo Flip.app"
mkdir -p "$FLIP/Contents/MacOS" "$FLIP/Contents/Resources"
cp "$BIN/photo-flip" "$FLIP/Contents/MacOS/photo-flip"
sed -e 's/photo-merge/photo-flip/g' -e 's/photomerge/photoflip/g' -e 's/Photo Merge/Photo Flip/g' -e 's/public.image/public.png/g' "$APP/Contents/Info.plist" > "$FLIP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$FLIP/Contents/Info.plist"
cp Resources/Icons/PhotoFlip.icns "$FLIP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$FLIP"
cp "$BIN/photo-flip" dist/photo-flip
printf 'Built %s\n' "$FLIP"
