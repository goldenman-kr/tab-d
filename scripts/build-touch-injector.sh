#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
java="${TABD_JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
mkdir -p build/touch-injector/classes build/touch-injector/dex
"$java/bin/javac" --release 8 -cp "$sdk/platforms/android-36/android.jar" -d build/touch-injector/classes scripts/TabDTouch.java
"$java/bin/jar" cf build/touch-injector/classes.jar -C build/touch-injector/classes .
JAVA_HOME="$java" "$sdk/build-tools/35.0.0/d8" --lib "$sdk/platforms/android-36/android.jar" --output build/touch-injector/dex build/touch-injector/classes.jar
"$java/bin/jar" cf build/tabd-touch-input.jar -C build/touch-injector/dex classes.dex
echo 'Built shell-only multitouch fixture: build/tabd-touch-input.jar'
