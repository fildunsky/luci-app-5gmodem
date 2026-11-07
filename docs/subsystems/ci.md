# CI and releases

`.github/workflows/build.yml` builds and publishes releases; `build-cached.yml` is a manual experiment with a cached SDK; `sdk-cache.yml` keeps the SDK tarball warm.

## One build per package format

`luci-app-5gmodem` is `PKGARCH:=all`, so one build per package format fits every device. A 24.10 SDK produces the `.ipk` (that branch still uses opkg), a 25.12 SDK produces the `.apk`. The x86_64 SDK is only the builder.

In the matrix, `sdk` is the tag of the `openwrt/sdk` image and must exist (it becomes the image name); `label` and `slug` are only the job name and the artifact name.

## Independent MediaTek helper packages

`5gmodem-mtk-at` has its own version and is distributed from
`dist/5gmodem-mtk-at/5gmodem-mtk-at.apk` and `.ipk` on master. It is not
built, attached or required by normal app releases. Do not add helper download
instructions to README files or mention unchanged helper packages in release notes.
The app offers the download and installation instructions only for matching MTK
hardware when the executable helper is missing.

`build-mtk.yml` runs on master changes to the package or its build inputs, and
can also be dispatched manually. `mtk-dist.py check` compares a SHA-256 fingerprint
of all tracked package files (including executable bits), the helper workflow,
shared build/fetch scripts and the checker itself, plus checksums of both stored
packages. Unchanged inputs and packages skip the build. A source/build change or
a missing/corrupt package requires rebuilding both formats. Changes only under
`dist` do not trigger a build; dispatch the workflow to validate or repair them.

The helper job compiles static ARMv7 and AArch64 clients with
`build-usock.sh`, then packages them with the 25.12.5 APK and 24.10.8 IPK SDKs.
`STRIP` is disabled because the clients run on the MediaTek device rather than
the SDK target. Only after both builds succeed does the store job commit both
packages and `manifest.json` together. It rebases on current master and verifies
the fingerprint again before pushing, so a newer source change cannot receive
stale packages. Update the package version/release when its installed contents
change. The initial stored version 1.2-r1 comes from the published v3.9.24 assets;
their SHA-256 digests were verified against GitHub's release metadata.

`fast-build.sh` builds only the package arguments supplied by the caller; its
default is `luci-app-5gmodem`. SDK tarballs are cached by their published checksum
in both workflows.

## Preparing a release

Bump `PKG_VERSION` in `luci-app-5gmodem/Makefile` and keep `PKG_RELEASE=1` for a new version. Update the shared LuCI module `API` values and `fresh.check()` version together so cached pages reload their dependencies. Run the relevant behavior checks, JavaScript/shell syntax checks, translation checks and embedded icon validation before committing.

Use an English release body and attach separate UTF-8 translations named `notes-ru.txt`, `notes-id.txt`, `notes-ja.txt`, `notes-vi.txt`, `notes-zh_Hans.txt` and `notes-zh_Hant.txt` to the draft. These names match `update.sh check <language>`; each translated file must fit its 8192-byte limit. Create the draft with notes and translations before pushing the `v<version>` tag. The workflow reuses that draft and publishes it only after both package formats are ready. Do not update README install links before the packages have been published.

After pushing the release tag, report that the release has been handed off to CI and finish the task. Do not wait for builds, poll their status, or monitor publication unless the user explicitly asks. CI builds the packages, publishes the release and updates README links automatically on the server.

## Release flow without a 404 window

On a `v*` tag each build attaches its packages to a **draft** release with `gh release upload`. Not `softprops/action-gh-release`: it publishes a reused draft after upload, so the first matrix job would make the release public while the other format is still building. If the draft does not exist yet, the job creates an empty one; `|| gh release view` covers the other job having just created it.

The `publish` job runs after both builds, checks that every asset the READMEs and the in-app updater point at is attached, and only then publishes the release (`--latest`) and runs `.github/scripts/readme-links.sh <version> <pkg_release>`, which rewrites the install links in all six READMEs, checks that each URL answers 200 and commits. Until publish, `releases/latest` keeps serving the previous complete release. A failed build leaves the draft unpublished.

Bumping the README links in the release commit by hand used to leave a 15-20 minute window in which the install command returned 404; that is why the links are moved by CI.

## Stable asset names

Translation packages get their version from `luci.mk` (a commit hash), so the file name changes every release and cannot be linked from the README. CI renames them to `luci-i18n-5gmodem-<lang>.apk/.ipk`; the version stays inside the package metadata. Copies under both names used to be attached side by side, which doubled the assets and confused users.

## Failure logs

When the build fails, the job prints the compile log of the first failing package: the top-level `Error 2` says nothing.

## Cached SDK experiment (`build-cached.yml`)

The package itself is scripts, but the SDK builds its dependencies, including the heavy ModemManager stack (glib2, gio, libmm-glib); `openwrt/gh-action-sdk` caches nothing, so every run spends 14-18 minutes on them. The experiment unpacks the SDK tarball on the runner (a container cannot be cached: mounting a volume over `/builder/staging_dir` hides the toolchain) and caches `staging_dir`, `build_dir` and `dl`. The SDK tarball is cached separately because it never changes for a version. The key includes the SDK version and the hash of the package Makefile; `restore-keys` falls back to the previous cache of the same SDK version.
