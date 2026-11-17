#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${DROIDBRIDGE_MACOS_SDK:-$(xcrun --show-sdk-path)}"
if [[ -z "${DROIDBRIDGE_MACOS_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
app="$PWD/image/DroidBridge.app"
mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks}
mkdir -p bin AppIcon.iconset
build_arch() {
  local arch="$1"
  swiftc -O -sdk "$sdk" -target "$arch-apple-macos14.4" -swift-version 5 \
    -module-cache-path "$PWD/SwiftCache26" src/{App,Backend,Operations,Workspace,Transfers,FileFeatures,AndroidFeatures,Tools,Appearance,ScrcpySettings,Fastboot,ADBSession}.swift -o "bin/DroidBridge-$arch"
  clang -arch "$arch" -mmacosx-version-min=14.4 -O2 -Wall -Wextra \
    -I"vendor-$arch/include" src/mtp.c -L"vendor-$arch/lib" -lmtp \
    -Wl,-rpath,@executable_path/../Frameworks -o "bin/mtp-bridge-$arch"
}
build_arch arm64 > bin/arm64.log 2>&1 &
arm_pid=$!
build_arch x86_64 > bin/x86_64.log 2>&1 &
intel_pid=$!
build_failed=0
wait "$arm_pid" || { cat bin/arm64.log >&2; build_failed=1; }
wait "$intel_pid" || { cat bin/x86_64.log >&2; build_failed=1; }
if [[ "$build_failed" == 1 ]]; then exit 1; fi
for exec in DroidBridge mtp-bridge; do
  lipo -create "bin/$exec-arm64" "bin/$exec-x86_64" -output "$app/Contents/MacOS/$exec"
done
for lib in libmtp.dylib libusb-1.0.dylib; do
  lipo -create "vendor-arm64/lib/$lib" "vendor-x86_64/lib/$lib" -output "$app/Contents/Frameworks/$lib"
done
cp platform-tools/{adb,fastboot} "$app/Contents/MacOS/"
scrcpy_arm="extras/scrcpy-macos-aarch64-v5.0.1"
scrcpy_intel="extras/scrcpy-macos-x86_64-v5.0.1"
cmp "$scrcpy_arm/scrcpy-server" "$scrcpy_intel/scrcpy-server"
lipo -create "$scrcpy_arm/scrcpy" "$scrcpy_intel/scrcpy" -output "$app/Contents/MacOS/scrcpy"
mkdir -p "$app/Contents/Resources/scrcpy"
cp "$scrcpy_arm/"{scrcpy-server,scrcpy.png,disconnected.png} "$app/Contents/Resources/scrcpy/"
cp "$scrcpy_arm/LICENSE" "$app/Contents/Resources/scrcpy-LICENSE.txt"
cp extras/helper/DroidBridgeHelper.apk "$app/Contents/Resources/"
cp build/MTP-Library-Sources.zip "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/MacOS/scrcpy"
cp platform-tools/NOTICE.txt "$app/Contents/Resources/Android-Platform-Tools-NOTICE.txt"
cp libmtp-1.1.22/COPYING "$app/Contents/Resources/libmtp-LICENSE.txt"
cp libusb-1.0.29/COPYING "$app/Contents/Resources/libusb-LICENSE.txt"
cp src/Info.plist "$app/Contents/Info.plist"
swift -sdk "$sdk" -module-cache-path "$PWD/SwiftCache26" src/icon.swift "$PWD/bin/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" bin/icon.png --out "AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size*2))" "$((size*2))" bin/icon.png --out "AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
if ! /usr/bin/iconutil -c icns AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns" 2>bin/iconutil.log; then
python3 - "$app/Contents/Resources/AppIcon.icns" <<'PYICON'
from pathlib import Path
import struct
import sys
icons = {
    "icp4": "16x16", "icp5": "32x32", "icp6": "32x32@2x",
    "ic07": "128x128", "ic08": "256x256", "ic09": "512x512", "ic10": "512x512@2x",
    "ic11": "16x16@2x", "ic12": "32x32@2x", "ic13": "128x128@2x", "ic14": "256x256@2x",
}
chunks = bytearray()
for kind, size in icons.items():
    payload = (Path("AppIcon.iconset") / f"icon_{size}.png").read_bytes()
    chunks += kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload
Path(sys.argv[1]).write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
PYICON
fi
test -s "$app/Contents/Resources/AppIcon.icns"
for item in "$app/Contents/Frameworks/"*.dylib "$app/Contents/MacOS/mtp-bridge" "$app/Contents/MacOS/adb" "$app/Contents/MacOS/fastboot"; do
  codesign --force --sign - "$item"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ln -sfn /Applications image/Applications
