#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
sdk="$(xcrun --show-sdk-path)"
for arch in "$@"; do
  prefix="$base/vendor-$arch"
  export CC="clang -arch $arch" CXX="clang++ -arch $arch"
  export MACOSX_DEPLOYMENT_TARGET=13.0 SDKROOT="$sdk"
  unset CPPFLAGS LDFLAGS LIBUSB_CFLAGS LIBUSB_LIBS
  host=()
  native="$(uname -m)"
  if [[ "$arch" != "$native" ]]; then
    build_host="$native"
    if [[ "$native" == arm64 ]]; then build_host=aarch64; fi
    target_host="$arch"
    if [[ "$arch" == arm64 ]]; then target_host=aarch64; fi
    host=(--build="$build_host-apple-darwin" --host="$target_host-apple-darwin")
  fi
  mkdir -p "$base/usb-$arch" "$base/mtp-$arch"
  cd "$base/usb-$arch"
  "$base/libusb-1.0.29/configure" ${host[@]+"${host[@]}"} --prefix="$prefix" --disable-static --enable-shared --disable-udev
  sed -i '' 's/^#define HAVE_PIPE2 1/\/\* #undef HAVE_PIPE2 \*\//' config.h
  make -C libusb -j6 core.lo descriptor.lo hotplug.lo io.lo strerror.lo sync.lo os/darwin_usb.lo os/events_posix.lo os/threads_posix.lo
  mkdir -p "$prefix/lib" "$prefix/include/libusb-1.0"
  clang -arch "$arch" -dynamiclib -install_name @rpath/libusb-1.0.dylib -framework IOKit -framework CoreFoundation -framework Security libusb/.libs/{core,descriptor,hotplug,io,strerror,sync}.o libusb/os/.libs/{darwin_usb,events_posix,threads_posix}.o -o "$prefix/lib/libusb-1.0.dylib"
  cp "$base/libusb-1.0.29/libusb/libusb.h" "$prefix/include/libusb-1.0/"
  cd "$base/mtp-$arch"
  export LIBUSB_CFLAGS="-I$prefix/include/libusb-1.0" LIBUSB_LIBS="-L$prefix/lib -lusb-1.0"
  export CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib"
  "$base/libmtp-1.1.22/configure" ${host[@]+"${host[@]}"} --prefix="$prefix" --disable-static --enable-shared --disable-mtpz --disable-examples --disable-doxygen --disable-udev
  make -C src -j6 libmtp_la-{libmtp,unicode,util,playlist-spl,ptp,libusb1-glue}.lo
  clang -arch "$arch" -dynamiclib -install_name @rpath/libmtp.dylib src/.libs/libmtp_la-{libmtp,unicode,util,playlist-spl,ptp,libusb1-glue}.o -L"$prefix/lib" -lusb-1.0 -liconv -o "$prefix/lib/libmtp.dylib"
  cp src/libmtp.h "$prefix/include/"
done
