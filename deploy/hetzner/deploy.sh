#!/usr/bin/env bash
# deploy.sh -- build and run a commit of LibreTranslate on this server.
#
#   ./deploy.sh              deploy origin/main
#   ./deploy.sh <commit>     deploy that commit. A ROLLBACK is a deploy of an
#                            earlier commit; its image is reused when it is
#                            still on the server (the last three are kept)
#
# Run on the server (by hand, or by github-deploy.sh from the Actions tab). It:
#   1. fetches the commit into this checkout (/opt/libretranslate)
#   2. builds libretranslate-app:<commit> unless that image is already here
#      (whatever is running keeps answering)
#   3. installs any missing translation model into the models volume
#      (models.py), still while the running one answers; the first deploy
#      downloads them all, which takes a while
#   4. replaces the container and waits until it really answers: /languages
#      lists every language in LT_LOAD_ONLY, and /detect works
#   5. if it does not, puts the previous image back, and says so
#   6. hands the hostname to the shared Caddy (sites.sh: only once its DNS
#      points here, and only if the combined configuration validates;
#      exit 3: LibreTranslate is running, only the hostname was refused)
#   7. removes LibreTranslate images other than the running one and the two
#      before it
#
# Nothing here touches Top Voice's or FOMO's containers, volumes or files;
# the only shared things are the `edge` network and one file in
# /opt/caddy-sites.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077

PORT=5200
SERVICE=libretranslate
IMAGE=libretranslate-app
TOKEN_FILE="${LT_GIT_TOKEN_FILE:-/root/.libretranslate-git-token}"
EDGE_NETWORK=edge

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

envval() { sed -n "s/^$1=//p" .env | tail -n 1; }

set_env() {
  local tmp; tmp="$(mktemp .env.XXXXXX)"
  awk -v k="$1" -v v="$2" 'BEGIN { d = 0 } index($0, k "=") == 1 { if (!d) print k "=" v; d = 1; next } { print } END { if (!d) print k "=" v }' .env > "$tmp"
  chmod 600 "$tmp"; mv "$tmp" .env
}

# git with the deploy run's short-lived token, when there is one. The token is
# read from a root-only file by an askpass helper, never put on a command
# line or in the remote URL.
git_auth() {
  if [[ -s "$TOKEN_FILE" ]]; then
    local askpass rc=0
    askpass="$(mktemp)"
    printf '#!/bin/sh\ncase "$1" in Username*) echo x-access-token ;; *) cat %q ;; esac\n' "$TOKEN_FILE" > "$askpass"
    chmod 700 "$askpass"
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git "$@" || rc=$?
    rm -f "$askpass"
    return "$rc"
  fi
  GIT_TERMINAL_PROMPT=0 git "$@"
}

want_count() { envval LT_LOAD_ONLY | tr ',' '\n' | grep -c .; }

# Answering the way callers need it: every language listed, and /detect works.
answering() {
  local n
  n="$(curl -fsS -m 10 "http://127.0.0.1:$PORT/languages" 2>/dev/null \
    | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null)" || return 1
  [[ "$n" == "$(want_count)" ]] || return 1
  curl -fsS -m 10 -H 'content-type: application/json' \
    -d '{"q":"Hello everyone, how are you today?"}' \
    "http://127.0.0.1:$PORT/detect" 2>/dev/null | grep -q '"language"'
}

wait_answering() { # SECONDS
  local deadline=$(( SECONDS + $1 ))
  while (( SECONDS < deadline )); do
    answering && return 0
    sleep 5
  done
  return 1
}

prune_images() {
  local cur n=0 t
  cur="$(envval APP_IMAGE_TAG)"
  # `docker images` lists the newest first.
  for t in $(docker images "$IMAGE" --format '{{.Tag}}'); do
    [[ "$t" == "$cur" ]] && continue
    n=$((n + 1))
    (( n <= 2 )) && continue
    docker rmi "$IMAGE:$t" >/dev/null 2>&1 || true
  done
  docker image prune -f >/dev/null 2>&1 || true
}
free_gb() { df -BG --output=avail / | tail -n 1 | tr -dc 0-9; }

install_sites() { bash ./sites.sh; }

report() {
  echo "    languages: $(curl -fsS -m 10 "http://127.0.0.1:$PORT/languages" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')"
  echo "    /detect:   $(curl -fsS -m 10 -H 'content-type: application/json' -d '{"q":"Bonjour tout le monde, comment allez-vous ?"}' "http://127.0.0.1:$PORT/detect")"
  docker stats --no-stream --format '    memory:    {{.MemUsage}}' "$(docker compose ps -q "$SERVICE" | head -n 1)" < /dev/null || true
}

[[ -f .env ]] || die "no .env here: bootstrap.sh writes the first one (or copy .env.example to .env)."
[[ -n "$(envval LT_LOAD_ONLY)" ]] || die "LT_LOAD_ONLY is not set in .env; it lists the languages to serve (.env.example)."
docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1 \
  || die "the shared '$EDGE_NETWORK' network is not on this server (Top Voice's compose file creates it). Nothing was changed."

repo="$(git rev-parse --show-toplevel)"
want="${1:-main}"

say "Fetching origin"
git_auth -C "$repo" fetch --quiet origin \
  || warn "could not fetch from GitHub; deploying from what this checkout already has."
# A bare branch name means the freshly fetched REMOTE ref; a SHA passes through.
if git -C "$repo" rev-parse --verify --quiet "origin/$want^{commit}" >/dev/null; then
  want="origin/$want"
fi
sha="$(git -C "$repo" rev-parse --verify "$want^{commit}")" || die "no such commit: $want"
tag="${sha:0:12}"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]] \
  || die "the checkout in $repo has local changes; deploy only what is committed."
git -C "$repo" checkout --quiet --detach "$sha"
echo "    $tag $(git -C "$repo" log -1 --format=%s "$sha")"
echo "    LibreTranslate $(cat "$repo/VERSION" 2>/dev/null || echo '?')"

prev="$(envval APP_IMAGE_TAG)"
if [[ "$prev" == "$tag" ]] && [[ -n "$(docker compose ps -q "$SERVICE")" ]] && answering; then
  # Same commit: but the settings in .env may have changed. Compose recreates
  # the container only when its configuration differs from the running one.
  say "$tag is already running; making sure it runs with the current settings"
  docker compose up -d "$SERVICE"
  wait_answering 600 || die "$tag did not come back on the current settings; see: docker compose logs $SERVICE"
  report
  install_sites || exit 3
  exit 0
fi

if (( $(free_gb) < 20 )); then
  say "Only $(free_gb) GB free: removing old LibreTranslate images and build cache first"
  prune_images
  docker builder prune -f --filter until=24h >/dev/null 2>&1 || true
  (( $(free_gb) >= 15 )) || die "only $(free_gb) GB free on the server; not building, because a full disk would stop Top Voice's and FOMO's databases too."
fi

if docker image inspect "$IMAGE:$tag" >/dev/null 2>&1; then
  say "Reusing $IMAGE:$tag (already built on this server)"
else
  say "Building $IMAGE:$tag (anything running keeps answering)"
  APP_IMAGE_TAG="$tag" docker compose build "$SERVICE"
fi

say "Installing any missing translation models (anything running keeps answering)"
APP_IMAGE_TAG="$tag" timeout 7200 docker compose run --rm --no-deps -T \
  --entrypoint ./venv/bin/python "$SERVICE" - < models.py \
  || die "the models step did not finish, so $tag was NOT started and ${prev:+$prev }is still what runs. Its output is above; running deploy.sh again carries on where it stopped."

say "Starting $tag"
set_env APP_IMAGE_TAG "$tag"
docker compose up -d "$SERVICE"
if wait_answering 600; then
  sites_ok=1
  install_sites || sites_ok=0
  say "Deployed $tag.${prev:+ The previous image was $prev.}"
  report
  prune_images
  (( sites_ok )) || exit 3
  exit 0
fi

docker compose logs --tail 60 "$SERVICE" >&2 || true
if [[ -n "$prev" ]] && docker image inspect "$IMAGE:$prev" >/dev/null 2>&1; then
  say "Not answering: putting $prev back"
  set_env APP_IMAGE_TAG "$prev"
  docker compose up -d "$SERVICE"
  wait_answering 600 || die "$prev is not answering either (log above)."
  say "Back on $prev. $tag is not deployed; see its log above."
  exit 1
fi
die "$tag is not answering, and there is no previous image to go back to (log above)."
