#!/bin/zsh
# Buduje wersję release i kopiuje DupliKAT.app do dist/ (gotowe do uruchomienia; ad-hoc podpis).
cd "$(dirname "$0")"
CONFIG=release ./build-app.sh > /dev/null || exit 1
rm -rf dist && mkdir -p dist
cp -R ~/Library/Caches/DubelBuild/DupliKAT.app dist/
echo "gotowe: $(pwd)/dist/DupliKAT.app"
