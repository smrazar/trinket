#!/bin/bash
# Builds trinket.app: release binary, icon, Info.plist, bundled ffmpeg, and an ad-hoc signature.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="trinket"
BINARY_NAME="Trinket"
BUNDLE_ID="com.local.trinket"
# Bump +0.1 for a normal round of changes, +1.0 for a major one. See docs/CHANGELOG.md.
VERSION="1.1"
APP="build/${APP_NAME}.app"

echo "==> Building release binary"
# A release build embeds the absolute path of every source and object file — in the DWARF debug
# info, and in the linker's debug map. Without these flags the builder's home directory ends up
# inside every published binary, about a hundred times over.
#
# `strings` does not show them: Apple's strings only dumps __TEXT on a Mach-O and never reads
# __DWARF. Check the built bundle with `python3 ~/Developer/scan-personal-data.py build/trinket.app`.
#
# All three flags are needed — `-Xswiftc` never reaches clang, so C dependencies keep their paths
# without the `-Xcc` one.
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
    -Xcc -ffile-prefix-map="$PWD=." -Xlinker -oso_prefix -Xlinker "$PWD/"

echo "==> Running self-checks"
# A check the build ignores is a check that stops being true. The build fails on a failure.
".build/release/${BINARY_NAME}" --self-check

# The checks use `UserDefaults(suiteName:)`, and a suite is a plist under ~/Library/Preferences
# that the owning process cannot always delete — unlinking a live one just means cfprefsd writes it
# back on exit. Clearing here, after the check process is gone, is the belt to that braces. 366 of
# these had accumulated before anybody looked in there.
rm -f "$HOME/Library/Preferences/trinket.check."*.plist "$HOME/Library/Preferences/trinket.probe.plist" 2>/dev/null || true

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/${BINARY_NAME}" "$APP/Contents/MacOS/${BINARY_NAME}"

echo "==> Rendering the icon"
# Rasterises every size from the vector source and writes the .icns chunks directly.
# `iconutil` is deliberately not used: it rejects every iconset on this machine with
# "Invalid Iconset", including ones it produced itself from a known-good .icns.
swift Tools/make-icon.swift Assets/icon.svg "$APP/Contents/Resources/AppIcon.icns"
# Shipped alongside so the self-check can prove it still carries explicit width/height — with only
# a viewBox an SVG decodes to a zero-size NSImage and every thumbnail comes out blank.
cp Assets/icon.svg "$APP/Contents/Resources/icon.svg"

# The vendored ffmpeg, when present. Committed as a tarball and extracted at package time rather
# than kept expanded in the repo. GPL-3-or-later; Resources/ffmpeg-BUILD.txt records the exact
# upstream build so the corresponding-source offer is answerable.
FFMPEG_TARBALL=$(ls Resources/ffmpeg-*-macos-arm64.tar.xz 2>/dev/null | head -1 || true)
if [[ -n "$FFMPEG_TARBALL" ]]; then
  echo "==> Bundling ffmpeg"
  mkdir -p "$APP/Contents/Resources/bin"
  tar -xJf "$FFMPEG_TARBALL" -C "$APP/Contents/Resources/bin"
  chmod +x "$APP/Contents/Resources/bin/ffmpeg"
  # Ad-hoc sign the extracted binary or macOS refuses to launch it.
  codesign --force --sign - "$APP/Contents/Resources/bin/ffmpeg"
  cp Resources/ffmpeg-BUILD.txt "$APP/Contents/Resources/" 2>/dev/null || true
else
  echo "==> No ffmpeg tarball in Resources/ — audio and video stay unavailable (see docs/STATUS.md)"
fi

echo "==> Writing Info.plist"
# Written by the script rather than kept as a file, so version and bundle id have one source each.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${BINARY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later</string>
    <!-- The app restores nothing, so macOS Resume must not either: it is a second restorer
         working from worse information, and brings back windows nobody opened. -->
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.image</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
                <string>public.text</string>
                <string>public.rtf</string>
                <string>public.html</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Signing"
# Ad-hoc. There is no paid Developer ID, so there is no notarisation — see
# ~/Developer/publishing-to-github.md for what that means for a download.
codesign --force --deep --sign - "$APP"

echo "==> Built ${APP} (${VERSION})"
