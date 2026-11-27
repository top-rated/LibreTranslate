#!/usr/bin/env bash
# github-deploy.sh -- the GitHub Actions side of running LibreTranslate on
# top-voice-1. The owner's steps are in DEPLOY.md.
#
#   github-deploy.sh ready      is this repository set up to reach the server?
#   github-deploy.sh deploy     get COMMIT onto the server and deploy it
#   github-deploy.sh server     ACTION on the server: status, logs, restart,
#                               stop (take it off: hostname, then container;
#                               the models and keys volumes are kept), start
#   github-deploy.sh summary    always: the plain-English summary of a run
#
# Before APP_SSH_KEY exists this does nothing: `ready` is false and every
# workflow stops there, green.
#
# Every server-side script is UPLOADED and then run with stdin from /dev/null,
# never piped into `bash -s` (a docker command inside would read the rest of
# the script as its input).
#
# Environment: APP_SSH_KEY (required), APP_HOST (the workflows default it to
# top-voice-1's address), APP_SSH_HOST_KEY (optional, pins the host key),
# COMMIT, CLONE_URL, GIT_TOKEN (the run's own short-lived token, so the server
# can fetch this repository), ACTION, GITHUB_STEP_SUMMARY.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HOST="${APP_HOST:-46.224.170.196}"
STATE_DIR="${RUNNER_TEMP:-/tmp}/libretranslate-deploy"
STATE="$STATE_DIR/state"
SSH_DIR="$STATE_DIR/ssh"
REMOTE_DIR=/opt/libretranslate/deploy/hetzner

say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
remember() { mkdir -p "$STATE_DIR"; printf '%s=%q\n' "$1" "$2" >> "$STATE"; }
recall() { [[ -f "$STATE" ]] && source "$STATE"; return 0; }

cmd_ready() {
  if [[ -z "${APP_SSH_KEY:-}" ]]; then
    remember NOT_READY "the repository secret APP_SSH_KEY is not set"
    echo "ready=false"
    say "Not reaching the server: APP_SSH_KEY is not set. DEPLOY.md, 'Setting up', says how."
    return 0
  fi
  echo "ready=true"
}

setup_ssh() {
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  printf '%s\n' "$APP_SSH_KEY" > "$SSH_DIR/id"; chmod 600 "$SSH_DIR/id"
  if [[ -n "${APP_SSH_HOST_KEY:-}" ]]; then
    printf '%s\n' "$APP_SSH_HOST_KEY" > "$SSH_DIR/known_hosts"; STRICT=yes
  else
    ssh-keyscan -T 10 "$APP_HOST" > "$SSH_DIR/known_hosts" 2>/dev/null \
      || die "No SSH answer from $APP_HOST. Is the server up, and port 22 open?"
    STRICT=accept-new
  fi
  chmod 600 "$SSH_DIR/known_hosts"
}

ssh_to() {
  ssh -i "$SSH_DIR/id" \
      -o "UserKnownHostsFile=$SSH_DIR/known_hosts" -o "StrictHostKeyChecking=$STRICT" \
      -o ConnectTimeout=30 -o BatchMode=yes -o LogLevel=ERROR -o ServerAliveInterval=30 \
      "root@$APP_HOST" "$@"
}

# Upload a script and run it with stdin from /dev/null; its exit code comes back.
run_remote() { # SCRIPT ARGS...
  local script="$1"; shift
  local name; name="/root/.libretranslate-$(basename "$script" .sh)-$$.sh"
  ssh_to "umask 077 && cat > $name" < "$script"
  local q="" a
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  ssh_to "bash $name$q < /dev/null; rc=\$?; rm -f $name; exit \$rc"
}

cmd_deploy() {
  setup_ssh
  local commit="${COMMIT:-main}"
  remember MODE deploy; remember COMMIT "$commit"
  [[ -n "${CLONE_URL:-}" ]] || die "CLONE_URL is empty."
  if [[ -n "${GIT_TOKEN:-}" ]]; then
    printf '%s\n' "$GIT_TOKEN" | ssh_to "umask 077 && cat > /root/.libretranslate-git-token" \
      || die "Could not reach $APP_HOST over SSH. Check that APP_SSH_KEY is the private half of a key the server's root accepts."
  fi
  say "Deploying $commit on $APP_HOST"
  set +e
  run_remote "$HERE/bootstrap.sh" "$commit" "$CLONE_URL"
  local code=$?
  set -e
  ssh_to "rm -f /root/.libretranslate-git-token" >/dev/null 2>&1 || true
  remember CODE "$code"
  case "$code" in
    0) say "Deployed." ;;
    1) die "Not deployed: the new container did not answer (deploy.sh put the previous one back if there was one), or a step before it failed. The log above says which." ;;
    3) die "LibreTranslate is deployed and answering, but its hostname is not served: the shared Caddy is not ready for it, or refused lt.caddy and kept the previous configuration. The log above says which." ;;
    255) die "Could not reach $APP_HOST over SSH. Check APP_SSH_KEY and that port 22 is open." ;;
    *) die "The deploy failed (exit $code); its output is above." ;;
  esac
}

cmd_server() {
  setup_ssh
  local action="${ACTION:-status}"
  remember MODE "$action"
  local remote
  case "$action" in
    status) remote="bash status.sh" ;;
    logs) remote="docker compose logs --no-color --tail 200 libretranslate" ;;
    restart) remote="docker compose restart libretranslate && sleep 20 && bash status.sh" ;;
    stop) remote="bash sites.sh --remove; docker compose stop libretranslate && echo 'Stopped. The models and keys volumes are kept; start (or a deploy) brings it back.'" ;;
    start) remote="docker compose up -d libretranslate && bash sites.sh && sleep 30 && bash status.sh" ;;
    *) die "action is status, logs, restart, stop or start." ;;
  esac
  ssh_to "test -d $REMOTE_DIR" || die "LibreTranslate has not been deployed to $APP_HOST yet (no $REMOTE_DIR)."
  set +e
  ssh_to "cd $REMOTE_DIR && { $remote; } < /dev/null"
  local code=$?
  set -e
  remember CODE "$code"
  [[ "$code" == 0 ]] || die "'$action' failed on $APP_HOST (exit $code); its output is above."
}

cmd_summary() {
  recall
  local out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  {
    printf '## LibreTranslate on top-voice-1: %s\n\n' "${MODE:-run}"
    if [[ -n "${NOT_READY:-}" ]]; then
      printf '**Nothing done.** %s. `deploy/hetzner/DEPLOY.md` has the steps.\n' "$NOT_READY"
    elif [[ "${MODE:-}" == deploy ]]; then
      case "${CODE:-}" in
        0) printf '**Deployed** `%s`. The log ends with the language count, a `/detect` answer and the memory in use.\n' "${COMMIT:-main}" ;;
        3) printf '**Deployed `%s`, but the hostname is not served.** LibreTranslate answers on the server; the shared Caddy is not ready for it or refused `lt.caddy`. The log says which.\n' "${COMMIT:-main}" ;;
        1) printf '**Not deployed.** `%s` did not answer, or a step before the swap failed. Whatever was running was left (or put back) as it was.\n' "${COMMIT:-main}" ;;
        *) printf '**Failed** before `%s` was deployed. The log says where.\n' "${COMMIT:-main}" ;;
      esac
    elif [[ "${CODE:-1}" == 0 ]]; then
      printf 'Done. The log has the details; no secret is ever printed.\n'
    else
      printf 'Did not finish, or LibreTranslate is not answering as it should. The log says where.\n'
    fi
  } >> "$out"
}

case "${1:-}" in
  ready) cmd_ready ;;
  deploy) cmd_deploy ;;
  server) cmd_server ;;
  summary) cmd_summary ;;
  *) die "usage: github-deploy.sh ready|deploy|server|summary" ;;
esac
