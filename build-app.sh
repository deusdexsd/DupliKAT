#!/bin/zsh
# Buduje DupliKAT (kod: Dubel) i pakuje w .app poza iCloudem (~/Library/Caches), z ad-hoc podpisem.
set -e
cd "$(dirname "$0")"
BUILD=~/Library/Caches/DubelBuild
CONFIG=${CONFIG:-debug}
# UNIVERSAL=1 → jedna aplikacja dla Apple Silicon i Intela (do DMG).
ARCHS=(); [ -n "$UNIVERSAL" ] && ARCHS=(--arch arm64 --arch x86_64)
if ! swift build -c $CONFIG --scratch-path $BUILD --product Dubel $ARCHS > /tmp/dubel-build.log 2>&1; then grep -E "error" /tmp/dubel-build.log | head -20; echo "BUDOWANIE NIEUDANE (nie pakuję starej wersji)"; exit 1; fi
BIN=$BUILD/$CONFIG/Dubel
[ -n "$UNIVERSAL" ] && BIN=$BUILD/out/Products/${(C)CONFIG}/Dubel
APP=$BUILD/DupliKAT.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp "$BIN" $APP/Contents/MacOS/Dubel
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp Resources/Icons/*.png $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.midnitemedia.dubel</string>
<key>CFBundleName</key><string>DupliKAT</string>
<key>CFBundleDisplayName</key><string>DupliKAT</string>
<key>CFBundleExecutable</key><string>Dubel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>100</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>pl</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>DupliKAT przegląda wskazane dyski zewnętrzne, żeby znaleźć duplikaty. Niczego nie zmienia bez Twojego potwierdzenia.</string>
<key>NSAppleEventsUsageDescription</key><string>DupliKAT odczytuje zaznaczenie w Finderze, żeby sprawdzić wybrany folder albo kartę (skrót albo przycisk Stream Deck).</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.midnitemedia.dubel</string><key>CFBundleURLSchemes</key><array><string>duplikat</string></array></dict></array>
<key>NSDesktopFolderUsageDescription</key><string>DupliKAT przegląda wskazane foldery, żeby znaleźć duplikaty.</string>
<key>NSDocumentsFolderUsageDescription</key><string>DupliKAT przegląda wskazane foldery, żeby znaleźć duplikaty.</string>
<key>NSDownloadsFolderUsageDescription</key><string>DupliKAT przegląda wskazane foldery, żeby znaleźć duplikaty.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
echo "APP: $APP"
