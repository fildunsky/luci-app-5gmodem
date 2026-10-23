#!/bin/sh
set -e
cd "$(dirname "$0")"
CC=${CC:-arm-linux-gnueabihf-gcc}
mkdir -p files
$CC -static -Os -s -o files/usock-armv7 src/usock.c
file files/usock-armv7 2>/dev/null || true
