#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/音频切换.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.derived-data/mac"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/音频切换.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/YinPinQieHuan"
PROCESS_NAME="YinPinQieHuan"
BUNDLE_ID="com.mankeipun.yinpinqiehuan"

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "音频切换" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  SWIFT_STRICT_CONCURRENCY=complete \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
