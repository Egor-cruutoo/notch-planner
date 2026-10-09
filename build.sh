#!/bin/bash
# Сборка «Островка» без Xcode-проекта — хватает Command Line Tools.
#   ./build.sh           — собрать build/Островок.app под этот Mac
#   ./build.sh run       — собрать и запустить
#   ./build.sh install   — собрать, положить в /Applications и запустить
#   ./build.sh test      — самопроверка (разбор строк, планировщик, импорт и т. д.)
#   ./build.sh release   — универсальная сборка (Apple Silicon + Intel) и build/Ostrovok.zip
set -euo pipefail
cd "$(dirname "$0")"

# Если установлены Command Line Tools — берём их (лицензию полного Xcode принимать не нужно).
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Нужен компилятор Swift. Установи Command Line Tools:  xcode-select --install" >&2
  exit 1
fi

APP="build/Островок.app"
BIN="$APP/Contents/MacOS/Ostrovok"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="14.0"
COMMON=(-O -swift-version 5 -sdk "$SDK")

case "${1:-}" in
  release) ARCHS=(arm64 x86_64) ;;
  *)       ARCHS=("$(uname -m)") ;;
esac

if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ Иконка"
  mkdir -p build/tmp
  swiftc "${COMMON[@]}" -target "$(uname -m)-apple-macos$MIN_OS" scripts/MakeIcon.swift -o build/tmp/MakeIcon
  rm -rf build/tmp/AppIcon.iconset
  build/tmp/MakeIcon build/tmp/AppIcon.iconset
  iconutil -c icns build/tmp/AppIcon.iconset -o Resources/AppIcon.icns
fi

echo "→ Компиляция (${ARCHS[*]})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tmp
SLICES=()
for arch in "${ARCHS[@]}"; do
  swiftc "${COMMON[@]}" -target "$arch-apple-macos$MIN_OS" Sources/*.swift -o "build/tmp/Ostrovok-$arch"
  SLICES+=("build/tmp/Ostrovok-$arch")
done
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$BIN"
else
  cp "${SLICES[0]}" "$BIN"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ $APP"

case "${1:-}" in
  run)
    pkill -x Ostrovok 2>/dev/null || true
    sleep 0.3
    open "$APP"
    ;;
  install)
    pkill -x Ostrovok 2>/dev/null || true
    sleep 0.3
    rm -rf "/Applications/Островок.app"
    cp -R "$APP" /Applications/
    open "/Applications/Островок.app"
    echo "✓ Установлено в /Applications/Островок.app"
    ;;
  test)
    "$BIN" --selftest
    ;;
  release)
    rm -f build/Ostrovok.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" build/Ostrovok.zip
    echo "✓ build/Ostrovok.zip"
    ;;
esac
