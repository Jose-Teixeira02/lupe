#!/bin/zsh
# Records the product tour to demo/Lupe-demo.mp4 (1920×1080, about 90 s).
#
# Private by construction: Lupe runs with a throwaway demo profile and records only its own windows
# plus the demo document in TextEdit (no menu bar, Dock, notifications or other apps).
# The tour moves the real cursor, so it starts once the Mac has been idle for 15 s, hides other apps
# while it runs (and shows them again), and throws the take away if you touch the mouse or keyboard.
#
# Before running, in TextEdit: Edit › Spelling and Grammar › uncheck "Check Spelling While Typing",
# and Format › Text › hide the ruler (both are per window, so do it after the script opens the document).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Lupe
DOC="$PWD/demo/Project Alpine.rtf"
osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
open -a TextEdit "$DOC"
sleep 2
# Centre the document in the recorded 16:9 area.
read -r _ _ W H <<< "$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | tr -d ',')"
X=$(( (W - 900) / 2 )); Y=$(( (H - 756) / 2 + 13 ))
osascript -e "tell application \"TextEdit\" to set bounds of front window to {$X, $Y, $((X + 900)), $((Y + 520))}"
open -a TextEdit
echo "Recording starts when the Mac has been idle for 15 s. Hands off until it says done."
.build/out/Products/Debug/Lupe --demo-video "$PWD/demo/Lupe-demo.mp4"
