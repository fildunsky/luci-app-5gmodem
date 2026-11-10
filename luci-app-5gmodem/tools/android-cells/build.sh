#!/bin/sh
set -eu
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${JAVA_HOME:?Set JAVA_HOME to a JDK directory}"
: "${R8_JAR:?Set R8_JAR to the official R8 jar}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/classes" "$WORK/dex"
"$JAVA_HOME/bin/javac" --release 8 -Xlint:-options -d "$WORK/classes" "$SRC/stubs/android/telephony/TelephonyManager.java" "$SRC/CellProbe.java"
"$JAVA_HOME/bin/jar" cf "$WORK/stubs.jar" -C "$WORK/classes" android
"$JAVA_HOME/bin/java" -cp "$R8_JAR" com.android.tools.r8.D8 --classpath "$WORK/stubs.jar" --min-api 31 --release --output "$WORK/dex" "$WORK"/classes/CellProbe*.class
cp "$WORK/dex/classes.dex" "$SRC/../../root/usr/share/5gmodem/android-cells.dex"
