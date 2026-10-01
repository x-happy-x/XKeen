#!/bin/sh
# Input has already been downloaded from pinned fork releases and SHA-256 checked.
set -eu
PATH=/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin
ROOT=${HOMENET_ROOT:-/}
ROOT=${ROOT%/}
OPT="$ROOT/opt"
PATH="$OPT/bin:$OPT/sbin:$PATH"
STAGE=${1:?staging directory required}
BASE=${2:?backup directory required}
case "$STAGE" in "$OPT"/tmp/homenet-release-*) ;; *) echo 'Unsafe stage' >&2; exit 2;; esac
case "$BASE" in "$OPT"/backups/homenet-*) ;; *) echo 'Unsafe backup' >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || [ -n "$ROOT" ] || exit 1
[ ! -e "$BASE" ] || { echo 'Backup already exists' >&2; exit 1; }
SERVICE="$OPT/etc/init.d/S05xkeen"
CONFIG=$(readlink -f "$OPT/etc/mihomo/config.yaml")
case "$CONFIG" in "$OPT/etc/mihomo/"*) ;; *) echo 'Config target outside Mihomo' >&2; exit 1;; esac
mkdir "$OPT/tmp/homenet-deploy.lock" 2>/dev/null || { echo 'Deployment already running' >&2; exit 1; }
armed=0
stopped=0
cleanup() {
  rc=$?
  [ "$rc" = 0 ] || printf '%s\n' "$rc" > "$STAGE/failed"
  trap - EXIT INT TERM HUP
  if [ "$armed" = 1 ]; then
    sh "$BASE/rollback.sh" --apply >>"$BASE/rollback.log" 2>&1 || echo "ROLLBACK FAILED: $BASE/rollback.log" >&2
  elif [ "$stopped" = 1 ]; then
    "$SERVICE" start manual >>"$BASE/stop.log" 2>&1 || true
  fi
  rmdir "$OPT/tmp/homenet-deploy.lock" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
umask 077
mkdir -p "$BASE"
cp "$STAGE/rollback.sh" "$BASE/rollback.sh"
chmod 700 "$BASE/rollback.sh"
(cd "$STAGE" && sha256sum -c payload.sha256) >/dev/null
# NTFS tar writers do not preserve POSIX executable bits.
for tree in "$STAGE/xkeen" "$STAGE/zash"; do
  find "$tree" -type d -exec chmod 755 {} \;
  find "$tree" -type f -exec chmod 644 {} \;
done
chmod 755 "$STAGE/mihomo" "$STAGE/xkeen/xkeen" "$STAGE/S05xkeen"
chmod 600 "$STAGE/config.yaml"
sh -n "$STAGE/xkeen/xkeen"
sh -n "$STAGE/S05xkeen"
"$STAGE/mihomo" -v > "$BASE/new-version.txt"
"$STAGE/mihomo" -t -d "$OPT/etc/mihomo" -f "$STAGE/config.yaml" >"$BASE/validation.log" 2>&1
# Prepare the complete recovery list before interrupting the service.
# Exclude accumulated old backups, but include profiles, provider files and tsnet state.
(cd "${ROOT:-/}" && find opt/etc/mihomo -path opt/etc/mihomo/backup -prune -o -type f -print -o -type l -print) > "$BASE/paths.txt"
for rel in opt/sbin/mihomo opt/sbin/xkeen opt/sbin/.xkeen opt/etc/init.d/S05xkeen opt/etc/xkeen; do
  [ ! -e "$ROOT/$rel" ] || printf '%s\n' "$rel" >> "$BASE/paths.txt"
done
# stop removes generated NDM hooks; save their active contents first.
mkdir -p "$BASE/pre-stop/opt/etc/ndm"
for rel in opt/etc/ndm/netfilter.d/proxy.sh opt/etc/ndm/schedule.d/00-xkeen-hotspot-sync.sh; do
  if [ -f "$ROOT/$rel" ]; then
    mkdir -p "$BASE/pre-stop/$(dirname "$rel")"
    cp -p "$ROOT/$rel" "$BASE/pre-stop/$rel"
  fi
done
tar -cf "$BASE/before.tar" -C "$BASE/pre-stop" opt
# Files are snapshotted while stopped so BoltDB and embedded Tailscale state are consistent.
stopped=1
"$SERVICE" stop >"$BASE/stop.log" 2>&1 || exit 1
tar -rf "$BASE/before.tar" -C "${ROOT:-/}" -T "$BASE/paths.txt" || exit 1
(cd "$BASE" && sha256sum before.tar > before.sha256)
sh "$BASE/rollback.sh" --check >"$BASE/backup-check.log"
armed=1
# Start an independent watchdog before any replacement. The host must acknowledge success.
nohup sh -c 'sleep "$1"; [ -f "$2/confirmed" ] || [ -f "$2/rolled-back" ] || sh "$2/rollback.sh" --apply >>"$2/watchdog.log" 2>&1' sh "${HOMENET_CONFIRM_TIMEOUT:-600}" "$BASE" </dev/null >/dev/null 2>&1 &
echo "$!" > "$BASE/watchdog.pid"
cp -p "$STAGE/mihomo" "$OPT/sbin/mihomo.new"
chmod 755 "$OPT/sbin/mihomo.new"
mv "$OPT/sbin/mihomo.new" "$OPT/sbin/mihomo"
cp -p "$STAGE/xkeen/xkeen" "$OPT/sbin/xkeen.new"
chmod 755 "$OPT/sbin/xkeen.new"
mv "$OPT/sbin/xkeen.new" "$OPT/sbin/xkeen"
mv "$OPT/sbin/.xkeen" "$BASE/replaced-xkeen"
mv "$STAGE/xkeen/_xkeen" "$OPT/sbin/.xkeen"
mv "$OPT/etc/mihomo/zash" "$BASE/replaced-zash"
mv "$STAGE/zash" "$OPT/etc/mihomo/zash"
cp "$STAGE/S05xkeen" "$SERVICE.new"
chmod 755 "$SERVICE.new"
mv "$SERVICE.new" "$SERVICE"
# Replace the real profile, preserving config.yaml as a symlink.
cp "$STAGE/config.yaml" "$CONFIG.new"
chmod 600 "$CONFIG.new"
mv "$CONFIG.new" "$CONFIG"
sync
"$SERVICE" start manual >"$BASE/start.log" 2>&1
expected=$(cat "$STAGE/version.txt")
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  version=$(curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:9090/version 2>/dev/null | jq -r .version) || version=''
  if [ "$version" = "$expected" ] && curl --noproxy '*' -fsS --max-time 3 http://127.0.0.1:9090/ui/ >/dev/null; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || { echo 'New core/UI health check failed' >&2; exit 1; }
# If the old setup passed a proxied GET, require the new setup to pass it too.
if [ -s "$STAGE/network-check-url" ]; then
  url=$(cat "$STAGE/network-check-url")
  curl -x http://127.0.0.1:1080 --noproxy '' -fsSL --connect-timeout 8 --max-time 30 "$url" -o /dev/null
fi
# Keep recovery armed while checking the same destinations that worked before.
# This loop runs on the router even when the host loses its connection.
verify_seconds=0
[ ! -f "$STAGE/verify-seconds" ] || verify_seconds=$(cat "$STAGE/verify-seconds")
case "$verify_seconds" in ''|*[!0-9]*) exit 1;; esac
[ "$verify_seconds" -le 1200 ] || exit 1
deadline=$(($(date +%s) + verify_seconds))
failures=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  healthy=1
  while read -r expected_status url; do
    [ -n "$url" ] || continue
    status=$(curl -x http://127.0.0.1:1080 --noproxy '' -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || status=000
    [ "$status" = "$expected_status" ] || healthy=0
    printf '%s %s %s\n' "$(date +%s)" "$status" "$url" >> "$BASE/connectivity.log"
  done < "$STAGE/network-checks"
  if [ "$healthy" = 1 ]; then failures=0; else failures=$((failures + 1)); fi
  [ "$failures" -lt 2 ] || { echo 'Connectivity regressed; restoring previous installation' >&2; exit 1; }
  sleep "${HOMENET_PROBE_INTERVAL:-20}"
done
armed=0
stopped=0
: > "$BASE/ready"
echo "READY $BASE; host acknowledgement required within ${HOMENET_CONFIRM_TIMEOUT:-600}s"
