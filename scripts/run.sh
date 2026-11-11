#!/bin/zsh
# Build ZenNotch and (re)launch it, no Xcode window needed.
# Usage: ./scripts/run.sh            # Debug build
#        ./scripts/run.sh release    # Release build
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="Debug"
[[ "${1:-}" == "release" ]] && CONFIG="Release"

# Use full Xcode's toolchain even if xcode-select still points at CommandLineTools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

PROJECT="boringNotch.xcodeproj"
SCHEME="boringNotch"

echo "▸ Building ($CONFIG)…"
# Shares Xcode's DerivedData, so builds here and in Xcode reuse the same cache.
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
      -destination 'platform=macOS' -allowProvisioningUpdates build \
      > /tmp/zennotch-build.log 2>&1; then
  grep -E "error:" /tmp/zennotch-build.log | sed "s|$PWD/||" | sort -u
  echo "✗ Build failed. Full log: /tmp/zennotch-build.log"
  exit 1
fi

PRODUCTS_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS_DIR/Boring Notch.app"

# Quit the running copy so the new build takes over.
pkill -x "Boring Notch" 2>/dev/null && sleep 0.5 || true

echo "▸ Launching $APP"
open "$APP"
echo "✓ Running"
