#!/usr/bin/env bash
# sites.sh -- serve LibreTranslate's hostname once its DNS points at this server.
#
#   ./sites.sh          install, and say which names are served / waiting
#   ./sites.sh --cron   the same, silent unless something changed
#                       (every minute, from /etc/cron.d/libretranslate-sites)
#   ./sites.sh --remove take the hostname off the shared Caddy (a rollback),
#                       and stop the cron that would put it back; the next
#                       deploy.sh puts both back
#
# lt.caddy lists the names. sites-filter.py keeps the site blocks whose DNS
# points here, and this installs the result as
# /opt/caddy-sites/libretranslate.caddy in the shared Caddy (Top Voice's) --
# but only if that whole configuration still validates; otherwise the
# previous file goes back and nothing is reloaded. Top Voice's and FOMO's own
# site files are never touched.
#
# Exit: 0 served as wanted (a name may still be waiting for DNS), 1 not
# installed (the shared Caddy is not ready, or refused the file).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

SITES_DIR="${CADDY_SITES_DIR:-/opt/caddy-sites}"
EDGE_PROJECT="${EDGE_PROJECT:-top-voice}"
NAME=libretranslate.caddy
DST="$SITES_DIR/$NAME"
mode="${1:-}"
quiet=0; [[ "$mode" == --cron ]] && quiet=1

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
say() { (( quiet )) || printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

exec 8> /run/lock/libretranslate-sites.lock 2>/dev/null || exec 8> /tmp/libretranslate-sites.lock
flock -w 120 8 || { warn "another sites.sh is still running."; exit 1; }

caddy="$(docker ps -q --filter "label=com.docker.compose.project=$EDGE_PROJECT" --filter "label=com.docker.compose.service=caddy" | head -n 1)"
if [[ -z "$caddy" ]]; then
  (( quiet )) && exit 0
  warn "no running Caddy from the '$EDGE_PROJECT' project on this server, so LibreTranslate's hostname is not served. LibreTranslate itself answers on 127.0.0.1:5200."
  exit 1
fi
if ! docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$caddy" | grep -qx /etc/caddy/sites; then
  (( quiet )) && exit 0
  warn "Top Voice's Caddy does not import a sites folder, so LibreTranslate's hostname is not served. LibreTranslate itself answers on 127.0.0.1:5200."
  exit 1
fi

validate() { docker exec "$caddy" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; }
reload() { docker exec "$caddy" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; }

if [[ "$mode" == --remove ]]; then
  rm -f /etc/cron.d/libretranslate-sites
  [[ -f "$DST" ]] || { say "LibreTranslate's hostname is not installed; nothing to remove."; exit 0; }
  mv -f "$DST" "$SITES_DIR/.$NAME.removed"
  if validate && reload; then
    log "Removed $DST from the shared Caddy (kept as $SITES_DIR/.$NAME.removed)."
    exit 0
  fi
  mv -f "$SITES_DIR/.$NAME.removed" "$DST"
  reload || true
  log "Could not reload Caddy without $NAME, so it was put back." >&2
  exit 1
fi

mkdir -p "$SITES_DIR"; chmod 755 "$SITES_DIR"
want="$(mktemp)"; report="$(mktemp)"
trap 'rm -f "$want" "$report"' EXIT
python3 -I sites-filter.py lt.caddy "$DST" > "$want" 2> "$report"

if [[ -f "$DST" ]] && cmp -s "$want" "$DST"; then
  say "LibreTranslate's hostname (unchanged):"; (( quiet )) || cat "$report"
  exit 0
fi

had=0
[[ -f "$DST" ]] && { cp -p "$DST" "$SITES_DIR/.$NAME.prev"; had=1; }
install -m 0644 "$want" "$SITES_DIR/.$NAME.new"
mv -f "$SITES_DIR/.$NAME.new" "$DST"
put_back() {
  if (( had )); then mv -f "$SITES_DIR/.$NAME.prev" "$DST"; else rm -f "$DST"; fi
}
if ! validate; then
  put_back
  log "$NAME REFUSED: the shared Caddy configuration does not validate with it; the previous one was put back. See why: copy lt.caddy's block to $DST and run: docker exec $caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" >&2
  exit 1
fi
if ! reload; then
  put_back
  reload || true
  log "$NAME REFUSED: Caddy would not reload with it; the previous one was put back." >&2
  exit 1
fi
rm -f "$SITES_DIR/.$NAME.prev"
log "Caddy reloaded. LibreTranslate's hostname:"
cat "$report"
