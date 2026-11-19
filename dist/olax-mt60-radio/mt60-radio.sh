#!/system/bin/sh
# Bridge live Android radio measurements to the local OpenWrt rpcd.
set -eu
umask 077
if [ "$(id -u)" != 0 ] || [ "$(getprop ro.product.device)" != t60_extchg_k62 ]; then
    echo 'The MT60 radio companion requires root on t60_extchg_k62.' >&2
    exit 1
fi

D=/data/local/mt60-openwrt
CHROOT_TMP=$D/rootfs/tmp
APP_DIR=/data/user/0/local.mt60.panel
APP_TMP=$APP_DIR/files/rootfs/tmp
PIDFILE=$D/mt60-radio.pid
DEX=/data/local/tmp/5gm-mt60-radio.dex

running() {
    [ -s "$PIDFILE" ] || return 1
    read -r pid < "$PIDFILE"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null &&
        tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$D/mt60-radio.sh"
}

guest_exec() {
    base=$1; shift
    case "$base" in
        "$CHROOT_TMP") "$@" ;;
        "$APP_TMP")
            uid=$(stat -c '%u' "$APP_DIR") || return 1
            case "$uid" in ''|*[!0-9]*) return 1 ;; esac
            [ "$uid" -ge 10000 ] || return 1
            /system/xbin/su "$uid" "$@"
            ;;
        *) return 1 ;;
    esac
}

publish() (
    base=$1
    name=$2
    [ -d "$base" ] || return 0
    printf '%s\n' "$line" | guest_exec "$base" /system/bin/sh -c '
        umask 077
        dir=$1/mt60-radio
        mkdir -m 700 "$dir" 2>/dev/null || true
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
        chmod 700 "$dir" || exit 1
        file=$(mktemp "$dir/metrics.XXXXXX") || exit 1
        cat > "$file" && mv -f "$file" "$dir/$2"
    ' sh "$base" "$name"
)

band_requests() {
    while :; do
        for base in "$CHROOT_TMP" "$APP_TMP"; do
            [ -f "$base/mt60-radio/bands.request" ] || continue
            request=$(guest_exec "$base" /system/bin/sh -c '
                dir=$1/mt60-radio
                [ ! -L "$dir" ] && cd "$dir" || exit 1
                mv -f bands.request bands.pending 2>/dev/null || exit 1
                [ ! -L bands.pending ] && [ -f bands.pending ] && head -c 256 bands.pending
                rm -f bands.pending
            ' sh "$base") || continue
            [ -n "$request" ] || continue
            line=$(/system/bin/timeout 12 /system/xbin/su 2000 /system/bin/sh -c '
                CLASSPATH=$1; export CLASSPATH
                exec /system/bin/app_process /system/bin RadioSnapshot bands "$2"
            ' sh "$DEX" "$request") || continue
            publish "$base" bands.reply || true
        done
        sleep 1
    done
}

case ${1:-start} in
start)
    running && exit 0
    if [ ! -r "$DEX" ] || [ ! -x /system/xbin/su ]; then
        echo 'The MT60 radio companion requires the DEX and stock su.' >&2
        exit 1
    fi
    if [ ! -d "$CHROOT_TMP" ] && [ ! -d "$APP_TMP" ]; then
        echo 'Start the native OpenWrt guest first.' >&2
        exit 1
    fi
    setsid "$D/mt60-radio.sh" collect </dev/null >"$D/mt60-radio.log" 2>&1 &
    ;;
stop)
    if running; then kill -TERM "-$pid" 2>/dev/null || true; fi
    rm -f "$PIDFILE" "$CHROOT_TMP/mt60-radio/metrics.json"
    ;;
collect)
    mkdir -p /acct/mt60-radio
    printf '%s\n' "$$" > /acct/mt60-radio/cgroup.procs
    printf '%s\n' "$$" > "$PIDFILE"
    trap 'rm -f "$PIDFILE"' EXIT
    trap 'exit' TERM INT
    band_requests &
    while :; do
        /system/xbin/su 2000 /system/bin/sh -c \
            "CLASSPATH=$DEX exec /system/bin/app_process /system/bin RadioSnapshot poll" |
        while IFS= read -r line; do
            publish "$CHROOT_TMP" metrics.json || true
            publish "$APP_TMP" metrics.json || true
        done
        sleep 6
    done
    ;;
*) exit 2 ;;
esac
