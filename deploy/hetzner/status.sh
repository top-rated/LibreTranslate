#!/usr/bin/env bash
# status.sh -- LibreTranslate's health on this server. Changes nothing.
#
# Container, image and restarts; whether it answers /languages, /detect and
# /translate on 127.0.0.1:5200; memory against its cap; the models volume and
# free disk; whether the hostname is served; and the neighbours' state (Top
# Voice's and FOMO's containers), so one look says nothing else was harmed.
# Settings are listed by name with their values, except anything that looks
# like a key, secret or token. Exit 1 when LibreTranslate is not answering.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PORT=5200
SERVICE=libretranslate
envval() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1; }
post() { curl -sS -m 30 -H 'content-type: application/json' -d "$2" "http://127.0.0.1:$PORT$1"; }

echo "== LibreTranslate"
cid="$(docker compose ps -q "$SERVICE" 2>/dev/null | head -n 1)"
if [[ -z "$cid" ]]; then
  echo "  not running (no container in the 'libretranslate' compose project)"
else
  docker inspect -f '  container: {{.Name}}  {{.Config.Image}}  {{.State.Status}}  health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}  started={{.State.StartedAt}}  restarts={{.RestartCount}}  oom-killed={{.State.OOMKilled}}' "$cid"
  docker stats --no-stream --format '  memory: {{.MemUsage}} ({{.MemPerc}})   cpu: {{.CPUPerc}}' "$cid" < /dev/null
fi
echo "  checkout: $(git -C .. log -1 --format='%h %s' 2>/dev/null)  (LibreTranslate $(cat ../../VERSION 2>/dev/null))"

echo "== Settings (.env)"
grep -E '^[A-Z_][A-Z0-9_]*=' .env 2>/dev/null \
  | sed -E 's/^([A-Z0-9_]*(KEY|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*)=.*/\1=(set, not shown)/; s/^(LT_LOAD_ONLY)=(.*)$/\1=(\2)/' \
  | sed 's/^/  /'

echo "== Answering on 127.0.0.1:$PORT"
ok=1
langs="$(curl -sS -m 15 "http://127.0.0.1:$PORT/languages" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null)" || langs=""
want="$(envval LT_LOAD_ONLY | tr ',' '\n' | grep -c .)"
if [[ "$langs" == "$want" ]]; then echo "  /languages: $langs (all of LT_LOAD_ONLY)"; else echo "  /languages: ${langs:-NO ANSWER} (want $want)"; ok=0; fi
d="$(post /detect '{"q":"Bonjour tout le monde, comment allez-vous ?"}' 2>&1)"
echo "  /detect:    $d" | head -c 300; echo
grep -q '"language"' <<<"$d" || ok=0
t0=$(date +%s%N)
t="$(post /translate '{"q":"Good morning, the meeting starts at ten.","source":"en","target":"fr","format":"text"}' 2>&1)"
echo "  /translate: $t ($(( ($(date +%s%N) - t0) / 1000000 )) ms)" | head -c 300; echo
grep -q '"translatedText"' <<<"$t" || ok=0

echo "== Disk"
mp="$(docker volume inspect -f '{{.Mountpoint}}' libretranslate_models 2>/dev/null)"
[[ -n "$mp" ]] && echo "  models volume: $(du -sh "$mp" 2>/dev/null | cut -f1)"
echo "  images: $(docker images libretranslate-app --format '{{.Tag}} ({{.Size}})' | tr '\n' ' ')"
df -h / | awk 'NR==2 { print "  server disk: " $4 " free of " $2 }'
free -m | awk 'NR==2 { print "  server memory: " $7 " MB available of " $2 }'

echo "== Hostname (Top Voice's Caddy)"
if [[ -f /opt/caddy-sites/libretranslate.caddy ]]; then
  python3 -I sites-filter.py lt.caddy /opt/caddy-sites/libretranslate.caddy 2>&1 >/dev/null
  grep -qE '^[^#[:space:]].*\{' /opt/caddy-sites/libretranslate.caddy && echo "  installed: yes" || echo "  installed: the file has no site yet (DNS)"
else
  echo "  not installed (/opt/caddy-sites/libretranslate.caddy is missing)"
fi
[[ -f /etc/cron.d/libretranslate-sites ]] && echo "  cron: on" || echo "  cron: off"
tail -n 3 /var/log/libretranslate-sites.log 2>/dev/null | sed 's/^/  log: /'

echo "== Neighbours on this server"
docker ps --format '  {{.Names}}  {{.Status}}' | grep -E 'top-voice|fomo' || echo "  (none found)"

(( ok )) || { echo; echo "LibreTranslate is NOT answering as it should (above)."; exit 1; }
