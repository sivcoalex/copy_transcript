#!/bin/zsh
# Builds Diktafon.app and (with --install) copies it to /Applications.
set -euo pipefail
cd "${0:A:h}"

WHISPER=vendor/whisper.cpp
BUILD=build
APP="$BUILD/Diktafon.app"

if [[ ! -d "$WHISPER" ]]; then
  git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp.git "$WHISPER"
fi

if [[ ! -f "$WHISPER/build/src/libwhisper.a" ]]; then
  cmake -S "$WHISPER" -B "$WHISPER/build" -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  cmake --build "$WHISPER/build" -j8 --config Release
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -L "$WHISPER/build/src" -L "$WHISPER/build/ggml/src" \
  -L "$WHISPER/build/ggml/src/ggml-metal" -L "$WHISPER/build/ggml/src/ggml-blas" \
  -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lc++ \
  -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
  Sources/*.swift -o "$APP/Contents/MacOS/Diktafon"

cp Info.plist "$APP/Contents/Info.plist"

if [[ ! -f "$BUILD/AppIcon.icns" ]]; then
  swift tools/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Diktafon 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Diktafon.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Diktafon.app"
fi
