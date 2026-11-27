#!/usr/bin/env bash
# bootstrap.sh -- get this repository onto the server and deploy a commit.
#
#   bootstrap.sh <commit> <clone URL>
#
# github-deploy.sh uploads and runs this on top-voice-1 for every deploy. It
# is safe to run again and again:
#   - clones the repository to /opt/libretranslate the first time (with the
#     deploy run's short-lived token, read from a root-only file)
#   - checks out the commit, so the deploy.sh that runs is the commit's own
#   - writes deploy/hetzner/.env from .env.example the first time (the
#     settings: languages, memory cap; no secret is needed while API keys
#     are off), and adds any setting .env.example has gained since
#   - installs the cron that serves the hostname once its DNS points here
#   - runs deploy.sh <commit>
set -euo pipefail
umask 077

commit="${1:?usage: bootstrap.sh <commit> <clone URL>}"
url="${2:?usage: bootstrap.sh <commit> <clone URL>}"
DIR=/opt/libretranslate
TOKEN_FILE=/root/.libretranslate-git-token

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

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

command -v docker >/dev/null || die "docker is not installed on this server."
command -v git >/dev/null || die "git is not installed on this server."

if [[ ! -d "$DIR/.git" ]]; then
  say "First deploy: cloning into $DIR"
  git_auth clone --quiet "$url" "$DIR"
fi
# The repository may have moved (top-rated -> makehybrid): follow it.
git -C "$DIR" remote set-url origin "$url"
git_auth -C "$DIR" fetch --quiet origin || echo "    (could not fetch; using what $DIR already has)"
if git -C "$DIR" rev-parse --verify --quiet "origin/$commit^{commit}" >/dev/null; then
  ref="origin/$commit"
else
  ref="$commit"
fi
git -C "$DIR" checkout --quiet --detach "$ref" || die "no such commit in $DIR: $commit"

cd "$DIR/deploy/hetzner"
if [[ ! -f .env ]]; then
  say "Writing the first .env from .env.example"
  grep -E '^[A-Z_][A-Z0-9_]*=' .env.example > .env
  chmod 600 .env
else
  while IFS= read -r line; do
    key="${line%%=*}"
    grep -q "^$key=" .env || { printf '%s\n' "$line" >> .env; echo "    $key added to .env (from .env.example)"; }
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' .env.example)
fi

cat > /etc/cron.d/libretranslate-sites <<EOF
# LibreTranslate's hostname: served once its DNS points at this server
# (deploy/hetzner/sites.sh in $DIR). Removed by: sites.sh --remove
* * * * * root bash $DIR/deploy/hetzner/sites.sh --cron >> /var/log/libretranslate-sites.log 2>&1
EOF
chmod 644 /etc/cron.d/libretranslate-sites

exec bash ./deploy.sh "$commit"
