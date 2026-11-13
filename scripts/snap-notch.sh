#!/bin/zsh
# Dev aid: build, launch, and have the app render only its open notch to a PNG.
# Usage: ./scripts/snap-notch.sh [output.png] [page]   (page: home | insights[:week|month|quarter|year|all] | slide0.4)
# Page "alert" (or "alert:heads") shows the closed notch with a sample task alert card.
# Prefix the page with "mock " (e.g. "mock home") to render fixture data instead of your own,
# for README screenshots. Mock data is in memory only and is never saved.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/zennotch-notch.png}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -destination 'platform=macOS' -allowProvisioningUpdates build > /tmp/zennotch-build.log 2>&1 \
  || { grep -E "error:" /tmp/zennotch-build.log | sort -u; exit 1; }

PRODUCTS_DIR=$(xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
PRODUCT=$(xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration ${CONFIG:-Debug} \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *PRODUCT_NAME /{print $2; exit}')
APP="$PRODUCTS_DIR/$PRODUCT.app"

TMPDIR_APP="$HOME/Library/Containers/site.kiranalex.zennotch/Data/tmp"
mkdir -p "$TMPDIR_APP"
rm -f "$TMPDIR_APP/notch-snapshot.png"
printf '%s' "${2:-home}" > "$TMPDIR_APP/debug-snapshot"

pkill -x "$PRODUCT" 2>/dev/null || true
pkill -x "Boring Notch" 2>/dev/null || true   # a copy left over from before the rename
sleep 0.5
open "$APP"

# The app renders only its notch window (nothing else on screen) and closes it again.
for _ in {1..20}; do
  [[ -f "$TMPDIR_APP/notch-snapshot.png" ]] && break
  sleep 0.5
done
[[ -f "$TMPDIR_APP/notch-snapshot.png" ]] || { echo "no snapshot produced"; exit 1; }
cp "$TMPDIR_APP/notch-snapshot.png" "$OUT"
echo "$OUT"
