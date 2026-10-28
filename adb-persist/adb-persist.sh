#!/bin/bash
#
# adb-persist.sh — keep network ADB alive across factory reset.
# Unified script, model-independent (works via onboot.sh anchors).
# Tested targets: Station Lite 2, Station Mini 2
# (Buildroot, quasar 3.21, rooted, ADB markers already in use).
# Version 1.1.0.
#
# install:   backup -> patch onboot.sh (+12 lines) -> install rootkeeper
#            etalon into /system -> verify on-device -> remount ro
# verify:    read-only checks that the patch is in place and ADB is up
# uninstall: restore stock onboot.sh from a backup dir, remove the etalon
#
# Usage:
#   ./adb-persist.sh install   [--device IP:PORT] [--reboot] [--dry-run] [--force]
#   ./adb-persist.sh verify    [--device IP:PORT]
#   ./adb-persist.sh uninstall [--device IP:PORT] [--reboot] [--backup-dir DIR]
#
# Requirements on host: bash, adb, patch.

set -u

VERSION="1.1.0"
DEFAULT_DEVICE="192.168.1.x:5555"
ONBOOT_PATH="/system/vendor/quasar/onboot.sh"
ETALON_PATH="/system/vendor/quasar/rootkeeper.sh.persist"
KEEPER_PATH="/data/quasar/rootkeeper.sh"
MARKER1="/data/quasar/activate_adb_quasmodrom"
MARKER2="/data/quasar/activate_network_adb"
STAGING="/data/quasar/transfer-staging"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="$SCRIPT_DIR/backups"

DEVICE="$DEFAULT_DEVICE"
DO_REBOOT=0
DRY_RUN=0
FORCE=0
BACKUP_DIR=""

# All human output goes to stderr; stdout is reserved for captured values.
log() { printf '%s\n' "[adb-persist] $*" >&2; }
die() { printf '%s\n' "[adb-persist] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool missing on host: $1"; }

adb_sh() { adb -s "$DEVICE" shell "$1"; }

# --- safety net: never leave / mounted rw ------------------------------------
REMOUNTED_RW=0
cleanup() {
    if [ "$REMOUNTED_RW" = "1" ]; then
        log "cleanup: restoring / to ro..."
        adb -s "$DEVICE" shell 'mount -o remount,ro /' >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

usage() {
    sed -n '2,20p' "$0"
    exit "${1:-0}"
}

# --- embedded patch (must stay byte-identical to lite/patches/) --------------
write_patch_file() {
    cat > "$1" <<'PATCH_EOF'
--- onboot.sh.orig
+++ onboot.sh
@@ -37,6 +37,19 @@
     chmod 777 /data/quasar
     chmod 777 /data/quasar/logs
 
+    # ADB-PERSIST v1: wipe стирает /data (маркеры + rootkeeper.sh),
+    # а /system переживает — восстанавливаем отсюда до 'check'.
+    # Идемпотентно: только mkdir/touch/cp, конфиги не затираем.
+    RK_SRC=/system/vendor/quasar/rootkeeper.sh.persist
+    RK_DST=/data/quasar/rootkeeper.sh
+    mkdir -p /data/quasar
+    touch /data/quasar/activate_adb_quasmodrom /data/quasar/activate_network_adb
+    if [ -f "$RK_SRC" ] && [ ! -x "$RK_DST" ]; then
+        cp -f "$RK_SRC" "$RK_DST"
+        chmod 755 "$RK_DST"
+    fi
+    unset RK_SRC RK_DST
+
     /system/vendor/quasar/yio_iptables_init.sh
 
     /system/vendor/quasar/set_monotonic_time.sh
PATCH_EOF
}

# --- common steps -------------------------------------------------------------
connect_device() {
    need adb
    log "connecting to $DEVICE..."
    adb connect "$DEVICE" >/dev/null 2>&1 || true
    [ "$(adb_sh 'echo OK' 2>/dev/null | tr -d '\r')" = "OK" ] \
        || die "device $DEVICE not reachable over ADB"
    log "device reachable"
}

check_pristine_onboot() {
    local marker_count
    marker_count="$(adb_sh "grep -c ADB-PERSIST $ONBOOT_PATH 2>/dev/null" | tr -d '\r')"
    if [ "$marker_count" != "0" ] && [ "$FORCE" != "1" ]; then
        die "patch already installed (ADB-PERSIST found). Use verify, or --force to reinstall."
    fi
    adb_sh "grep -q 'activate_adb.sh check' $ONBOOT_PATH" \
        || die "unexpected onboot.sh: no 'activate_adb.sh check' anchor. Aborting."
    log "onboot.sh anchor OK"
}

do_backup() {
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    log "backup dir: $BACKUP_DIR"
    adb -s "$DEVICE" pull "$ONBOOT_PATH" "$BACKUP_DIR/onboot.sh.orig" >/dev/null 2>&1 \
        || die "cannot pull $ONBOOT_PATH"
    adb -s "$DEVICE" pull /system/vendor/quasar/activate_adb.sh \
        "$BACKUP_DIR/activate_adb.sh" >/dev/null 2>&1 || true
    adb -s "$DEVICE" pull /system/vendor/quasar/launch.json \
        "$BACKUP_DIR/launch.json" >/dev/null 2>&1 || true
    if adb -s "$DEVICE" pull "$KEEPER_PATH" \
            "$BACKUP_DIR/rootkeeper.sh" >/dev/null 2>&1; then
        log "rootkeeper pulled (etalon available)"
        HAVE_KEEPER=1
    else
        log "WARNING: no live $KEEPER_PATH — markers-only install, no self-heal"
        HAVE_KEEPER=0
    fi
    md5sum "$BACKUP_DIR"/* | tee "$BACKUP_DIR/md5sums.txt" >/dev/null
    log "backup complete"
}

# Build patched onboot.sh from the pulled original. Prints path on stdout.
# NOTE: callers must use `out="$(build_patched)" || exit 1` — die() inside
# a command substitution only exits the subshell.
build_patched() {
    need patch
    local orig="$BACKUP_DIR/onboot.sh.orig"
    local new="$BACKUP_DIR/onboot.sh.new"
    local diff_file="$BACKUP_DIR/adb-persist.diff"
    [ -f "$orig" ] || die "original missing: $orig"
    if grep -q 'ADB-PERSIST' "$orig"; then
        # Reinstall: strip the previously installed block first.
        [ "$FORCE" = "1" ] || die "pulled onboot.sh already patched (use --force to reinstall)"
        awk '/    # ADB-PERSIST v1/ { skip=1; next }
             skip==1 && /    unset RK_SRC RK_DST/ { skip=2; next }
             skip==2 { skip=0; if (/^$/) next }
             !skip' "$orig" > "$BACKUP_DIR/onboot.sh.stripped"
        orig="$BACKUP_DIR/onboot.sh.stripped"
        grep -q 'ADB-PERSIST' "$orig" && die "strip failed: marker still present"
        grep -q 'activate_adb.sh check' "$orig" \
            || die "strip damaged onboot.sh: anchor lost"
        log "previous patch block stripped for reinstall"
    fi
    write_patch_file "$diff_file"
    cp "$orig" "$new"
    patch --forward --silent "$new" -i "$diff_file" >/dev/null 2>&1 \
        || die "patch does not apply cleanly to this onboot.sh (see $diff_file)"
    local added removed marked
    added="$(diff -u "$orig" "$new" | grep -c '^+' || true)"
    added=$((added - 1)) # minus '+++' header
    removed="$(diff -u "$orig" "$new" | grep -c '^-' || true)"
    removed=$((removed - 1)) # minus '---' header
    marked="$(grep -c 'ADB-PERSIST' "$new" || true)"
    [ "$added" = "13" ] && [ "$removed" = "0" ] && [ "$marked" = "1" ] \
        || die "patched file failed assertions (added=$added removed=$removed markers=$marked)"
    sh -n "$new" || die "patched onboot.sh failed shell syntax check"
    log "patched onboot.sh built and verified (+13/-0, sh -n OK)"
    printf '%s\n' "$new"
}

remount_rw() {
    adb_sh 'mount -o remount,rw /' >/dev/null 2>&1 \
        || die "remount rw failed"
    REMOUNTED_RW=1
    adb_sh 'mount | grep " / "' | grep -q '(rw' \
        || die "remount rw did not take effect"
    log "remounted / rw"
}

remount_ro() {
    adb_sh 'sync; mount -o remount,ro /' >/dev/null 2>&1 \
        || die "remount ro FAILED — run it manually: adb -s $DEVICE shell 'mount -o remount,ro /'"
    REMOUNTED_RW=0
    adb_sh 'mount | grep " / "' | grep -q '(ro' \
        || die "remount ro did not take effect"
    log "remounted / ro"
}

wait_for_device() {
    local i
    log "waiting for device to come back..."
    sleep 45
    for i in $(seq 1 12); do
        adb connect "$DEVICE" >/dev/null 2>&1 || true
        if [ "$(adb_sh 'echo OK' 2>/dev/null | tr -d '\r')" = "OK" ]; then
            log "device is back"
            return 0
        fi
        sleep 10
    done
    die "device did not come back within ~3 minutes"
}

# --- commands -----------------------------------------------------------------
cmd_verify() {
    local fail=0
    local marker_count etalon markers listen keeper mnt
    marker_count="$(adb_sh "grep -c ADB-PERSIST $ONBOOT_PATH 2>/dev/null" | tr -d '\r')"
    if [ "$marker_count" = "1" ]; then log "PASS: patch present in onboot.sh";
    else log "FAIL: patch NOT present in onboot.sh"; fail=1; fi
    etalon="$(adb_sh "test -f $ETALON_PATH && echo yes || echo no" | tr -d '\r')"
    if [ "$etalon" = "yes" ]; then log "PASS: etalon $ETALON_PATH present";
    else log "WARN: etalon missing (markers-only install?)"; fi
    markers="$(adb_sh "test -f $MARKER1 && test -f $MARKER2 && echo yes || echo no" | tr -d '\r')"
    if [ "$markers" = "yes" ]; then log "PASS: ADB markers present";
    else log "FAIL: ADB markers missing"; fail=1; fi
    listen="$(adb_sh 'netstat -tln 2>/dev/null | grep -c ":5555 "' | tr -d '\r')"
    if [ "$listen" != "0" ]; then log "PASS: adbd LISTEN :5555";
    else log "FAIL: nothing LISTENs on :5555"; fail=1; fi
    keeper="$(adb_sh 'ps | grep -c "[r]ootkeeper.sh"' | tr -d '\r')"
    if [ "$keeper" != "0" ]; then log "PASS: rootkeeper running";
    else log "WARN: rootkeeper not running"; fi
    mnt="$(adb_sh 'mount | grep " / "' | tr -d '\r')"
    case "$mnt" in
        *"(ro"*) log "PASS: / mounted ro" ;;
        *) log "WARN: / is NOT ro: $mnt" ;;
    esac
    [ "$fail" = "0" ] && log "VERIFY: OK" || die "VERIFY: FAILED"
}

cmd_install() {
    local new_file
    check_pristine_onboot
    do_backup
    new_file="$(build_patched)" || exit 1
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: backup + build OK, no writes performed. Backup: $BACKUP_DIR"
        return 0
    fi
    remount_rw
    adb -s "$DEVICE" shell "mkdir -p $STAGING" >/dev/null 2>&1 \
        || die "cannot create staging dir"
    adb -s "$DEVICE" push "$new_file" "$STAGING/onboot.sh.new" >/dev/null 2>&1 \
        || die "push of patched onboot.sh failed"
    adb -s "$DEVICE" push "$BACKUP_DIR/onboot.sh.orig" \
        "$STAGING/onboot.sh.orig-backup" >/dev/null 2>&1 \
        || die "push of orig backup failed"
    if [ "$HAVE_KEEPER" = "1" ]; then
        adb -s "$DEVICE" push "$BACKUP_DIR/rootkeeper.sh" \
            "$STAGING/rootkeeper.sh.persist" >/dev/null 2>&1 \
            || die "push of etalon failed"
    fi
    adb_sh "cp -f $STAGING/onboot.sh.new $ONBOOT_PATH && chmod 755 $ONBOOT_PATH" \
        >/dev/null 2>&1 || die "install of onboot.sh failed"
    if [ "$HAVE_KEEPER" = "1" ]; then
        adb_sh "cp -f $STAGING/rootkeeper.sh.persist $ETALON_PATH && chmod 644 $ETALON_PATH" \
            >/dev/null 2>&1 || die "install of etalon failed"
    fi
    adb_sh "sh -n $ONBOOT_PATH" >/dev/null 2>&1 \
        || die "INSTALLED onboot.sh failed on-device syntax check"
    log "on-device sh -n OK"
    local pulled="$BACKUP_DIR/onboot.sh.installed-check"
    adb -s "$DEVICE" pull "$ONBOOT_PATH" "$pulled" >/dev/null 2>&1 \
        || die "cannot pull back installed file for comparison"
    cmp -s "$new_file" "$pulled" \
        || die "installed file differs from verified build — investigate before reboot!"
    log "installed file matches verified build"
    remount_ro
    adb_sh "rm -rf $STAGING" >/dev/null 2>&1 || true
    log "staging cleaned"
    cmd_verify
    if [ "$DO_REBOOT" = "1" ]; then
        adb -s "$DEVICE" reboot >/dev/null 2>&1 || true
        wait_for_device
        cmd_verify
    fi
    log "INSTALL: done (v$VERSION)"
}

cmd_uninstall() {
    if [ -z "$BACKUP_DIR" ]; then
        BACKUP_DIR="$(ls -d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1)"
        [ -n "$BACKUP_DIR" ] || die "no backups found in $BACKUP_ROOT; pass --backup-dir"
        log "using latest backup: $BACKUP_DIR"
    fi
    local orig="$BACKUP_DIR/onboot.sh.orig"
    [ -f "$orig" ] || die "original not found: $orig"
    sh -n "$orig" || die "backup copy failed syntax check — refusing to install it"
    remount_rw
    adb -s "$DEVICE" shell "mkdir -p $STAGING" >/dev/null 2>&1 \
        || die "cannot create staging dir"
    adb -s "$DEVICE" push "$orig" "$STAGING/onboot.sh.stock" >/dev/null 2>&1 \
        || die "push of stock onboot.sh failed"
    adb_sh "cp -f $STAGING/onboot.sh.stock $ONBOOT_PATH && chmod 755 $ONBOOT_PATH && rm -f $ETALON_PATH" \
        >/dev/null 2>&1 || die "restore failed"
    adb_sh "sh -n $ONBOOT_PATH" >/dev/null 2>&1 \
        || die "restored onboot.sh failed on-device syntax check"
    remount_ro
    adb_sh "rm -rf $STAGING" >/dev/null 2>&1 || true
    log "UNINSTALL: stock onboot.sh restored, etalon removed."
    log "NOTE: ADB markers in /data were left alone, so ADB keeps working."
    log "To fully disable ADB, remove $MARKER1 $MARKER2 and reboot."
    if [ "$DO_REBOOT" = "1" ]; then
        adb -s "$DEVICE" reboot >/dev/null 2>&1 || true
        wait_for_device
    fi
}

# --- arg parsing ---------------------------------------------------------------
CMD="${1:-}"
[ -n "$CMD" ] || usage 1
shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --reboot) DO_REBOOT=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$CMD" in
    install) connect_device; cmd_install ;;
    verify) connect_device; cmd_verify ;;
    uninstall) connect_device; cmd_uninstall ;;
    *) usage 1 ;;
esac
