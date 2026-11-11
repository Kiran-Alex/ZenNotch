#!/bin/zsh
# Dev aid: build, launch, and have the app render only its open notch to a PNG.
# Usage: ./scripts/snap-notch.sh [output.png] [page]   (page: home | insights)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/zennotch-notch.png}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -allowProvisioningUpdates build > /tmp/zennotch-build.log 2>&1 \
  || { grep -E "error:" /tmp/zennotch-build.log | sort -u; exit 1; }

PRODUCTS_DIR=$(xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS_DIR/Boring Notch.app"

TMPDIR_APP="$HOME/Library/Containers/site.kiranalex.zennotch/Data/tmp"
mkdir -p "$TMPDIR_APP"
rm -f "$TMPDIR_APP/notch-snapshot.png"
printf '%s' "${2:-home}" > "$TMPDIR_APP/debug-snapshot"

pkill -x "Boring Notch" 2>/dev/null && sleep 0.5 || true
open "$APP"

# The app renders only its notch window (nothing else on screen) and closes it again.
for _ in {1..20}; do
  [[ -f "$TMPDIR_APP/notch-snapshot.png" ]] && break
  sleep 0.5
done
[[ -f "$TMPDIR_APP/notch-snapshot.png" ]] || { echo "no snapshot produced"; exit 1; }
cp "$TMPDIR_APP/notch-snapshot.png" "$OUT"
echo "$OUT"
