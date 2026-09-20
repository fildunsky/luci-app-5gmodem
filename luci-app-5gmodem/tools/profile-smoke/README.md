# profile-smoke: modem profiles without hardware

Runs every `modem/{usb,pci}/*` metric profile and every `modemband/*` profile under the host `busybox sh` with a fake `sms_tool`; nothing reaches a real port. Not packaged (luci.mk installs only `root/` and `htdocs/`).

- Run: `tools/profile-smoke/run.sh` (all, ~2 min) or `run.sh [-v] [-k] [-m "ok err"] [-t modem|band] 0e8d7127 413c81d7`. Exit code is non-zero on any FAIL; `-k` keeps the work dir with stdout/stderr/vars/command log of every run.
- Modes: `ok` (fixtures or a bare OK), `err` (ERROR), `cme` (+CME ERROR), `empty`, `hollow` (`+PFX: ,,,,`), `junk` and `alpha` (synthetic garbage fields).
- FAIL means: no marker after `. profile` (the whole poll would die), a shell error on stderr (arithmetic, not found, unknown operand, syntax error, bad number...), stdout noise from a metric profile, garbage or a raw CR in `get*` output on an error reply, a value that differs from `expect.*`. In `junk`/`alpha` only fatal-class errors count.
- Fixtures: `fixtures/<profile>/<scenario>/<CMD>.txt` holds a live reply (lines starting with `##` are comments, name the source post there); `expect.modem` / `expect.band` hold `VAR=value` or `getbands=...` lines; optional `init` presets framework variables (`MODE_NUM=13`). File name = command upper-cased without `AT`, `?` -> `_GET`, `=?` -> `_TEST`, `=` -> `_SET_`, other symbols -> `_`; a miss is logged as `MISS` in the command log.
- Framework functions are extracted from `5gmodem.sh` / `bands.sh` by name, `lib.sh` is sourced whole; `/usr/share/5gmodem`, `/tmp/`, `/var/lock/` are rewritten into the work dir.
- Host busybox runs applets without looking at PATH, so `logger`, `sleep`, `flock`, `pgrep`, `killall`, `ifup`, `wget`... are overridden as shell functions in `prelude.sh` (otherwise they hit the host: syslog, real sleeps). `mmcli`, `qmicli`, `uqmi`, `uci`, `ubus`, `gcom` are PATH stubs in `stubs/`.
- Every profile run is wrapped in `ulimit -v 1500000` and `timeout 60` with stdin from `/dev/null`: a runaway pipeline must die instead of eating host memory. Keep both when adding new launch points.
- Not covered: HiLink scripts (need HTTP), the Compal branches behind `is_compal`, anything that needs a stateful modem.
