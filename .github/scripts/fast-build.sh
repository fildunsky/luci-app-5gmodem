#!/bin/bash
set -ef

cd /builder
if [ -f /sdk/sdk.tar ]; then
	echo "::group::extract cached SDK"
	tar xf /sdk/sdk.tar --strip=1 --no-same-owner -C /builder
	echo "::endgroup::"
elif [ -f setup.sh ]; then
	bash setup.sh
fi

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default | grep -E '^src-git(-full)? (base|luci) ' > feeds.conf
echo "src-link modem /feed/" >> feeds.conf
echo "::group::feeds.conf"; cat feeds.conf; echo "::endgroup::"

echo "::group::feeds update"
./scripts/feeds update -a
echo "::endgroup::"

echo "::group::feeds install"
./scripts/feeds install -p modem -f luci-app-5gmodem 2>&1 | tail -40
echo "::endgroup::"

KEEP=" luci-app-5gmodem luci-base lua csstidy luasrcdiet ucode "
echo "::group::prune dependencies (only build-time tools stay)"
for d in package/feeds/*/*; do
	[ -L "$d" ] || continue
	case "$KEEP" in *" ${d##*/} "*) echo "keep $d" ;; *) rm -f "$d" ;; esac
done
rm -rf tmp
echo "::endgroup::"

echo "::group::defconfig"
make defconfig >/dev/null
grep -E "5gmodem|^CONFIG_ALL" .config || true
echo "::endgroup::"

make -j"$(nproc)" V=w package/luci-app-5gmodem/compile

mkdir -p /artifacts
find bin/ -type f \( -name '*5gmodem*.ipk' -o -name '*5gmodem*.apk' \) -exec cp -v {} /artifacts/ \;
