#!/bin/bash
# Remove Tuck. Quitting it slides every hidden icon back into view.
set -uo pipefail

osascript -e 'quit app "Tuck"' 2>/dev/null
sleep 1
pkill -x Tuck 2>/dev/null

rm -rf "${HOME}/Applications/Tuck.app" /Applications/Tuck.app
defaults delete local.tuck 2>/dev/null
tccutil reset Accessibility local.tuck >/dev/null 2>&1

echo "Tuck is gone. Your icons are free to fight over the notch again."
echo "(If you made a signing cert, remove 'Tuck Local Signing' in Keychain Access.)"
