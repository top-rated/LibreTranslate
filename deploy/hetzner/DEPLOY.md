# LibreTranslate on top-voice-1

LibreTranslate runs on **top-voice-1** (46.224.170.196), next to Top Voice and
FOMO Maldives, at **https://lt.makehybrid.com**. Callers use the same paths and
request bodies as before (`/detect`, `/translate`, `/languages`); only the
address changed from `http://65.108.253.194:5000`.

| | |
|---|---|
| Code | this fork, built from the commit you deploy (`docker/Dockerfile`) |
| On the server | `/opt/libretranslate`; settings in `deploy/hetzner/.env` |
| Compose project | `libretranslate` (its own; Top Voice's and FOMO's are untouched) |
| Volumes | `libretranslate_models` (the translation models), `libretranslate_db` (API keys) |
| Front door | Top Voice's Caddy, through `/opt/caddy-sites/libretranslate.caddy` (from `lt.caddy`) |
| On the server only | `127.0.0.1:5200` (no port is open to the internet) |
| Languages | the old instance's 50 (`LT_LOAD_ONLY`) |
| API keys | off, as on the old instance: a key sent is ignored |
| Limits | memory 4 GB, 3 CPUs (`LT_MEMORY`, `LT_CPUS` in `.env`) |

## The buttons (Actions tab)

- **Deploy LibreTranslate (top-voice-1)**: builds a commit and runs it. Only by
  hand; merging or syncing the fork deploys nothing. It ends by calling the
  new address from outside the way each caller does (`verify.py`).
- **LibreTranslate server (top-voice-1)**: `status`, `verify`, `compare` and
  `logs` change nothing. `compare` runs `verify`'s checks on the server itself,
  against `127.0.0.1:5200`, so it works before DNS does. Then `restart`,
  `stop` (type `top-voice-1`) and `start`.

## Setting up (once)

1. Repository secret **`APP_SSH_KEY`**: the same deploy key Top Voice and
   FOMO use (Settings → Secrets and variables → Actions).
2. Actions tab: enable workflows for this fork. Then disable **Build and
   Publish Docker Image**, which is upstream's and would fail here without
   their Docker Hub login.
3. DNS: `lt.makehybrid.com` A record → `46.224.170.196`, DNS only, no AAAA.

## How a deploy works

`deploy.sh` builds `libretranslate-app:<commit>` while the running container
keeps answering, installs any missing model into the models volume (the first
deploy downloads all of them, which takes a while), then swaps the container
and waits until `/languages` lists all 50 languages and `/detect` answers. If
it doesn't, the previous image goes back by itself. A swap interrupts callers
for about a minute. Top Voice and makehybrid.com treat a failed `/detect` as
"language unknown".

Settings: edit `deploy/hetzner/.env` on the server, then deploy the same
commit again; that applies them.

## Rollback

**To an earlier version.** Run **Deploy** with the earlier commit. The last
three images stay on the server and are reused, and the models are kept. On
the server:

```bash
cd /opt/libretranslate/deploy/hetzner && ./deploy.sh <commit>
```

**Callers back to the old instance**, while it is still running. Set each
caller's address back, then restart that caller:

- **Top Voice**: in `/opt/top-voice/deploy/hetzner/app/.env` on top-voice-1,
  set `LANG_DETECT_URL=http://65.108.253.194:5000/detect`, remove
  `TRANSLATE_URL`, then run `docker compose up -d app` there.
- **makehybrid.com**: in `/opt/makehybrid/deploy/hetzner/app/.env` on app-1,
  set `LANGUAGE_DETECT_URL=http://65.108.253.194:5000`, then run
  `docker compose up -d app` there.

Each `.env` keeps a dated copy from the switch (`.env.before-lt-*`).

**Take LibreTranslate off top-voice-1.** Run the server button with `stop`.
On the server, that is:

```bash
cd /opt/libretranslate/deploy/hetzner && bash sites.sh --remove && docker compose stop libretranslate
```

`sites.sh --remove` takes the hostname off the shared Caddy, keeps a copy of
it, and stops its cron. Top Voice's and FOMO's sites stay as they are. The
volumes are kept, so `start` or a deploy brings it all back.

**Remove it completely.** Do this only once nothing calls it:

```bash
cd /opt/libretranslate/deploy/hetzner && bash sites.sh --remove \
  && docker compose down -v && docker rmi $(docker images -q libretranslate-app) \
  && rm -rf /opt/libretranslate /var/log/libretranslate-sites.log
```

## API keys (later, separately)

Keys are off, as they were. Turning them on is its own change. First add
each caller's key, so no caller breaks. The key is read from a prompt, so it
never lands in the shell history:

```bash
cd /opt/libretranslate/deploy/hetzner
read -rs KEY && docker compose exec libretranslate ./venv/bin/ltmanage keys add 1000 --key "$KEY"; unset KEY
```

Then set `LT_API_KEYS=true` in `.env`, plus whichever of LibreTranslate's
`LT_REQUIRE_API_KEY_*` settings you want to enforce, and deploy again. Once
the `libretranslate_db` volume holds keys, back it up.
