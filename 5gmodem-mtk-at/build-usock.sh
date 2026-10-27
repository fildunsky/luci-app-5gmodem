#!/bin/sh
set -e
cd "$(dirname "$0")"
CC=${CC:-arm-linux-gnueabihf-gcc}
CC64=${CC64:-aarch64-linux-gnu-gcc}
mkdir -p files
$CC -static -Os -s -o files/usock-armv7 src/usock.c
$CC64 -static -Os -s -o files/usock-aarch64 src/usock.c
file files/usock-armv7 files/usock-aarch64 2>/dev/null || true
