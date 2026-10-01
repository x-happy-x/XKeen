#!/bin/sh
# Standalone recovery. Does not depend on the installed XKeen modules or Mihomo API.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
BASE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${HOMENET_ROOT:-/}
ROOT=${ROOT%/}
OPT="$ROOT/opt"
PATH="$OPT/bin:$OPT/sbin:$PATH"
SERVICE="$OPT/etc/init.d/S05xkeen"
[ -f "$BASE/before.tar" ] && [ -f "$BASE/paths.txt" ] || { echo 'Backup is incomplete' >&2; exit 1; }
(cd "$BASE" && sha256sum -c before.sha256) >/dev/null
case "${1:-}" in
  --check) tar -tf "$BASE/before.tar" >/dev/null; echo 'Backup checksum and archive OK'; exit 0 ;;
  --apply) ;;
  *) echo "Usage: $0 --check | --apply" >&2; exit 2 ;;
esac
mkdir "$BASE/restore.lock" 2>/dev/null || { echo 'Rollback already running' >&2; exit 1; }
trap 'rmdir "$BASE/restore.lock" 2>/dev/null || true' EXIT
# Retain failed runtime evidence privately before restoring the known good state.
# Diagnostic capture must never prevent recovery if disk space is exhausted.
failed_state="$BASE/failed-state-$(date +%s)-$$.tar"
(cd "${ROOT:-/}" && tar -cf "$failed_state" opt/etc/mihomo/config.yaml opt/etc/mihomo/profiles opt/etc/init.d/S05xkeen) 2>"$BASE/failed-state.log" || true
[ ! -x "$SERVICE" ] || "$SERVICE" stop >"$BASE/rollback-stop.log" 2>&1 || true
# A damaged new service must not prevent recovery: use the known previous service too.
tar -xOf "$BASE/before.tar" opt/etc/init.d/S05xkeen > "$BASE/restore-service.sh"
sh "$BASE/restore-service.sh" stop >>"$BASE/rollback-stop.log" 2>&1 || true
# Last resort applies only to the exact managed executable, never every proxy process.
for pid in $(pidof mihomo 2>/dev/null || true); do
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
  case "$exe" in "$OPT/sbin/mihomo"|"$OPT/sbin/mihomo (deleted)")
    kill "$pid" 2>/dev/null || true
    sleep 2
    [ ! -e "/proc/$pid/exe" ] || kill -9 "$pid" 2>/dev/null || true
  ;; esac
done
# cache.db is captured only after the writer has stopped.
[ ! -f "$OPT/etc/mihomo/cache.db" ] || tar -rf "$failed_state" -C "${ROOT:-/}" opt/etc/mihomo/cache.db 2>>"$BASE/failed-state.log" || true
# Atomic replacement is also safe if an old executable still has an open mapping.
[ ! -f "$OPT/sbin/mihomo" ] || mv "$OPT/sbin/mihomo" "$BASE/failed-mihomo-$(date +%s)-$$"
# Move only the two replaceable trees aside; old files must not mix with new ones.
failed_ui=''
for rel in sbin/.xkeen etc/mihomo/zash; do
  if [ -d "$OPT/$rel" ]; then
    destination="$BASE/failed-$(basename "$rel")-$(date +%s)-$$"
    mv "$OPT/$rel" "$destination"
    [ "$rel" != etc/mihomo/zash ] || failed_ui="$destination"
  fi
done
tar -xf "$BASE/before.tar" -C "${ROOT:-/}"
# Cached HTML can still request the newer content-hashed assets after rollback.
# Keep both immutable asset sets while restoring the previous entry point.
if [ -n "$failed_ui" ] && [ -d "$failed_ui/assets" ]; then
  mkdir -p "$OPT/etc/mihomo/zash/assets"
  cp -a "$failed_ui/assets/." "$OPT/etc/mihomo/zash/assets/"
fi
sync
"$SERVICE" start manual >"$BASE/rollback-start.log" 2>&1
: > "$BASE/rolled-back"
echo "Previous files restored. Service started. Backup: $BASE"
