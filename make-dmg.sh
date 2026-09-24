#!/bin/zsh
# Buduje uniwersalną wersję (Apple Silicon + Intel) i pakuje ją do dist/DupliKAT.dmg.
# Podpis ad-hoc, bez notaryzacji: przy pierwszym otwarciu na innym Macu trzeba kliknąć prawym → Otwórz.
set -e
cd "$(dirname "$0")"
UNIVERSAL=1 CONFIG=release ./build-app.sh > /dev/null || exit 1
rm -rf dist && mkdir -p dist
STAGE=$(mktemp -d)
cp -R ~/Library/Caches/DubelBuild/DupliKAT.app "$STAGE/"
ln -s /Applications "$STAGE/Aplikacje"
hdiutil create -volname "DupliKAT" -srcfolder "$STAGE" -ov -format UDZO dist/DupliKAT.dmg > /dev/null
cp -R "$STAGE/DupliKAT.app" dist/
rm -rf "$STAGE"
echo "gotowe: $(pwd)/dist/DupliKAT.dmg"
