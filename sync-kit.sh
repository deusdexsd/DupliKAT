#!/bin/zsh
# Odświeża kopię MidniteUIKit w Vendor/ z projektu źródłowego (../MidniteUIKit), jeśli jest obok.
cd "$(dirname "$0")"
[ -d ../MidniteUIKit ] || { echo "Brak ../MidniteUIKit — nic do zrobienia"; exit 0; }
rsync -a --delete --exclude .build --exclude .swiftpm ../MidniteUIKit/ Vendor/MidniteUIKit/
echo "MidniteUIKit zsynchronizowany"
