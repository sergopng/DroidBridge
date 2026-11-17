#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(/usr/libexec/java_home -v 17)" || { echo "Set JAVA_HOME to a JDK 17 installation." >&2; exit 1; }
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
sdk="$PWD/extras/android-35/android.jar"
tools="$PWD/extras/android-15"
build="$PWD/extras/helper"
rm -rf "$build/classes" "$build/dex"
mkdir -p "$build/classes" "$build/dex"
"$JAVA_HOME/bin/javac" -source 8 -target 8 -classpath "$sdk" -d "$build/classes" src/android/*.java
"$JAVA_HOME/bin/jar" cf "$build/classes.jar" -C "$build/classes" .
"$tools/d8" --min-api 23 --lib "$sdk" --output "$build/dex" "$build/classes.jar"
"$tools/aapt2" link -I "$sdk" --manifest src/android/AndroidManifest.xml --min-sdk-version 23 --target-sdk-version 35 --version-code 1 --version-name 1.0 -o "$build/base.apk"
(cd "$build/dex" && zip -q -j "$build/base.apk" classes.dex)
"$tools/zipalign" -f 4 "$build/base.apk" "$build/aligned.apk"
if [[ ! -f "$build/key.p12" ]]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -storetype PKCS12 -keystore "$build/key.p12" -storepass android -keypass android -alias droidbridge -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=DroidBridge"
fi
"$tools/apksigner" sign --ks "$build/key.p12" --ks-pass pass:android --out "$build/DroidBridgeHelper.apk" "$build/aligned.apk"
"$tools/apksigner" verify "$build/DroidBridgeHelper.apk"
