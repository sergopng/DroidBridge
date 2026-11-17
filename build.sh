#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mode="${1:-}"
if [[ -n "$mode" && "$mode" != "--dmg" ]]; then
  echo "Usage: ./build.sh [--dmg]" >&2
  exit 2
fi
for command in curl python3 xcrun make patch shasum; do
  command -v "$command" >/dev/null
done
xcrun --show-sdk-path >/dev/null
mkdir -p build/downloads extras build/mtp-sources image
download() {
  local name="$1" url="$2" digest="$3" file="build/downloads/$1"
  if [[ ! -f "$file" ]]; then
    curl --fail --location --retry 2 "$url" -o "$file.part"
    mv "$file.part" "$file"
  fi
  if ! printf '%s  %s\n' "$digest" "$file" | shasum -a 256 -c -; then
    rm -f "$file"
    printf 'Checksum mismatch: %s\n' "$name" >&2
    exit 1
  fi
}
google=https://dl.google.com/android/repository
scrcpy=https://github.com/Genymobile/scrcpy/releases/download/v5.0.1
download libusb.tar.bz2 https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2 5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
download libmtp.tar.gz https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.22/libmtp-1.1.22.tar.gz c3fcf411aea9cb9643590cbc9df99fa5fe30adcac695024442973d76fa5f87bc
download platform-tools.zip "$google/platform-tools_r37.0.1-darwin.zip" ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d
download scrcpy-arm64.tgz "$scrcpy/scrcpy-macos-aarch64-v5.0.1.tar.gz" 33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b
download scrcpy-x86_64.tgz "$scrcpy/scrcpy-macos-x86_64-v5.0.1.tar.gz" 31a5467a9e907f162b093267cbbab1276b15c6e709c2ea8159566a8d165beb50

if [[ ! -f libusb-1.0.29/configure ]]; then tar -xjf build/downloads/libusb.tar.bz2; fi
if [[ ! -f libmtp-1.1.22/.droidbridge-patched ]]; then
  tar -xzf build/downloads/libmtp.tar.gz
  patch -p1 < third-party/macOS.patch
  touch libmtp-1.1.22/.droidbridge-patched
fi
unzip -oq build/downloads/platform-tools.zip
tar -xzf build/downloads/scrcpy-arm64.tgz -C extras
tar -xzf build/downloads/scrcpy-x86_64.tgz -C extras

if [[ -n "${DROIDBRIDGE_HELPER_APK:-}" ]]; then
  test -f "$DROIDBRIDGE_HELPER_APK"
  mkdir -p extras/helper
  cp "$DROIDBRIDGE_HELPER_APK" extras/helper/DroidBridgeHelper.apk
else
  download build-tools.zip "$google/build-tools_r35.0.1_macosx.zip" c01e4b763da96ae5ef67e8bdf2abc94fb6cb3e73a42209581feb6a7019a51b9c
  download android-platform.zip "$google/platform-35_r02.zip" 0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0
  unzip -oq build/downloads/build-tools.zip -d extras
  unzip -oq build/downloads/android-platform.zip -d extras
  ./build-helper.sh
fi

./build-libs.sh arm64 x86_64 > build/native.log 2>&1 || { tail -60 build/native.log >&2; exit 1; }
cp build/downloads/{libmtp.tar.gz,libusb.tar.bz2} build/mtp-sources/
cp build-libs.sh third-party/macOS.patch third-party/MTP-BUILD.txt build/mtp-sources/
(cd build/mtp-sources && zip -q ../MTP-Library-Sources.zip ./*)
cp docs/installation.ru.txt image/Установка.txt
./build-app.sh
if [[ "$mode" == "--dmg" ]]; then
  version="$(plutil -extract CFBundleShortVersionString raw src/Info.plist)"
  hdiutil create -ov -volname "DroidBridge $version" -srcfolder image -format UDZO "build/DroidBridge-$version.dmg"
fi
