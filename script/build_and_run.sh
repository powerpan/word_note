#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="WordNote"
BUNDLE_ID="com.powerpan.WordNote"
MIN_SYSTEM_VERSION="14.0"
FIXTURE="${2:-populated}"
APPEARANCE="${3:-light}"
BUILD_FLAGS=(-Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors)

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  --ui-fixture|--ui-v2-fixture|--ui-v3-fixture)
    [[ "$FIXTURE" == "empty" || "$FIXTURE" == "populated" ]] || { echo "Invalid fixture" >&2; exit 2; }
    [[ "$APPEARANCE" == "light" || "$APPEARANCE" == "dark" ]] || { echo "Invalid appearance" >&2; exit 2; }
    QA_SESSION="${4:-$(uuidgen)}"
    [[ "$QA_SESSION" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || { echo "Invalid QA session UUID" >&2; exit 2; }
    APP_NAME="WordNoteQA"
    BUNDLE_ID="com.powerpan.WordNote.UITest"
    if [[ "$MODE" == "--ui-v2-fixture" ]]; then
      BUILD_FLAGS+=(--scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION)
    elif [[ "$MODE" == "--ui-v3-fixture" ]]; then
      BUILD_FLAGS+=(--scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION)
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--ui-fixture|--ui-v2-fixture|--ui-v3-fixture [empty|populated] [light|dark] [session-UUID]]" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_MASTER="$ROOT_DIR/Resources/AppIcon-1024.png"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
APP_ICON_GENERATOR="$ROOT_DIR/script/generate_app_icon.sh"
ICNS_GENERATOR="$ROOT_DIR/script/generate_icns.swift"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ ! -f "$APP_ICON_SOURCE"
      || "$APP_ICON_MASTER" -nt "$APP_ICON_SOURCE"
      || "$APP_ICON_GENERATOR" -nt "$APP_ICON_SOURCE"
      || "$ICNS_GENERATOR" -nt "$APP_ICON_SOURCE" ]]; then
  "$APP_ICON_GENERATOR" "$APP_ICON_MASTER"
fi

swift build "${BUILD_FLAGS[@]}"
BUILD_BINARY="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/WordNote"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

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
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --ui-fixture|--ui-v2-fixture|--ui-v3-fixture)
    echo "QA session: $QA_SESSION"
    /usr/bin/open -n "$APP_BUNDLE" --args --ui-fixture "$FIXTURE" --ui-appearance "$APPEARANCE" --ui-session "$QA_SESSION"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
