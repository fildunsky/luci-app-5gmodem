# CI and releases

`.github/workflows/build.yml` builds and publishes releases; `build-cached.yml` is a manual experiment with a cached SDK; `sdk-cache.yml` keeps the SDK tarball warm.

## One build per package format

`luci-app-5gmodem` is `PKGARCH:=all`, so one build per package format fits every device. A 24.10 SDK produces the `.ipk` (that branch still uses opkg), a 25.12 SDK produces the `.apk`. The x86_64 SDK is only the builder.

In the matrix, `sdk` is the tag of the `openwrt/sdk` image and must exist (it becomes the image name); `label` and `slug` are only the job name and the artifact name.

`5gmodem-mtk-at` is also `noarch`: its static ARMv7 client runs on the MediaTek pocket router, not on the router. The runner builds it with Ubuntu's `gcc-arm-linux-gnueabihf` (`5gmodem-mtk-at/build-usock.sh`) before the SDK step; the package Makefile only installs `files/usock-armv7` and disables `STRIP`, because the SDK would run the target architecture's strip on an ARM binary.

## Release flow without a 404 window

On a `v*` tag each build attaches its packages to a **draft** release with `gh release upload`. Not `softprops/action-gh-release`: it publishes a reused draft after upload, so the first matrix job would make the release public while the other format is still building. If the draft does not exist yet, the job creates an empty one; `|| gh release view` covers the other job having just created it.

The `publish` job runs after both builds, checks that every asset the READMEs and the in-app updater point at is attached, and only then publishes the release (`--latest`) and runs `.github/scripts/readme-links.sh <version> <pkg_release>`, which rewrites the install links in all six READMEs, checks that each URL answers 200 and commits. Until publish, `releases/latest` keeps serving the previous complete release. A failed build leaves the draft unpublished.

Bumping the README links in the release commit by hand used to leave a 15-20 minute window in which the install command returned 404; that is why the links are moved by CI.

## Stable asset names

Translation packages get their version from `luci.mk` (a commit hash), so the file name changes every release and cannot be linked from the README. CI renames them to `luci-i18n-5gmodem-<lang>.apk/.ipk`; the version stays inside the package metadata. The same is done for `5gmodem-mtk-at.apk/.ipk`. Copies under both names used to be attached side by side, which doubled the assets and confused users.

## Failure logs

When the build fails, the job prints the compile log of the first failing package: the top-level `Error 2` says nothing.

## Cached SDK experiment (`build-cached.yml`)

The package itself is scripts, but the SDK builds its dependencies, including the heavy ModemManager stack (glib2, gio, libmm-glib); `openwrt/gh-action-sdk` caches nothing, so every run spends 14-18 minutes on them. The experiment unpacks the SDK tarball on the runner (a container cannot be cached: mounting a volume over `/builder/staging_dir` hides the toolchain) and caches `staging_dir`, `build_dir` and `dl`. The SDK tarball is cached separately because it never changes for a version. The key includes the SDK version and the hash of the package Makefile; `restore-keys` falls back to the previous cache of the same SDK version.
