#!/bin/zsh
# Uruchomienie deweloperskie: osobne ustawienia i pamięć (~/Library/Caches/DubelDev), prawdziwe dane nietknięte.
#   ./dev-run.sh                 zwykły start
#   ./dev-run.sh --shots <demo>  skany na folderze demo (tylko odczyt) + zrzuty okien do ~/Library/Caches/DubelDev/shots
cd "$(dirname "$0")"
DEV=~/Library/Caches/DubelDev
APP=~/Library/Caches/DubelBuild/DupliKAT.app
./build-app.sh > /dev/null || exit 1
export DUBEL_DATA_DIR="$DEV/data" DUBEL_DEFAULTS_SUITE=dubel-dev
if [[ "$1" == "--shots" ]]; then
  defaults delete dubel-dev 2>/dev/null; rm -rf "$DEV/data" "$DEV/shots"
  export DUBEL_SHOTS="$DEV/shots" DUBEL_DEMO_ROOT="$2" DUBEL_DEMO_FCP="${3:-$HOME/Movies}"
fi
exec $APP/Contents/MacOS/Dubel
