#!/bin/bash
set -eu
VER="$1"
TGT="${2:-x86/64}"
OUT="$3"
P="releases/$VER/targets/$TGT"
HOSTS="https://downloads.openwrt.org https://mirror-01.infra.openwrt.org https://mirror-02.infra.openwrt.org https://mirror-03.infra.openwrt.org https://archive.openwrt.org"
SUMS=""
for h in $HOSTS; do
	SUMS=$(curl -fsSL --retry 2 -m 60 "$h/$P/sha256sums") && break
done
[ -n "$SUMS" ] || { echo "::error::no sha256sums for $VER"; exit 1; }
LINE=$(printf '%s\n' "$SUMS" | grep -E '\*?openwrt-sdk-.*\.tar\.(zst|xz)$' | head -1)
SUM=${LINE%% *}
FILE=${LINE##*[ *]}
echo "sdk_file=$FILE" >> "$GITHUB_OUTPUT"
echo "sdk_sum=$SUM" >> "$GITHUB_OUTPUT"
mkdir -p "$OUT"
if [ -f "$OUT/sdk.tar" ] && echo "$SUM  $OUT/sdk.tar" | sha256sum -c --quiet; then
	echo "cached SDK $FILE is valid"
	exit 0
fi
[ "${CHECK_ONLY:-0}" = 1 ] && exit 0
for h in $HOSTS; do
	echo "trying $h"
	rm -f "$OUT/sdk.tar"
	if curl -fL --retry 2 --speed-limit 500000 --speed-time 30 -m 1500 -o "$OUT/sdk.tar" "$h/$P/$FILE" \
	   && echo "$SUM  $OUT/sdk.tar" | sha256sum -c --quiet; then
		echo "downloaded $FILE from $h"
		exit 0
	fi
done
echo "::error::could not download $FILE from any mirror"
exit 1
