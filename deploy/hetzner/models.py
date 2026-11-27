"""models.py -- install the translation models LT_LOAD_ONLY names, and only the
missing ones, into the models volume. deploy.sh runs it inside the image,
before a container is started or replaced, so the running LibreTranslate keeps
answering while models download:

    docker compose run --rm --no-deps -T --entrypoint ./venv/bin/python \
        libretranslate - < models.py

Unlike LibreTranslate's own boot (which downloads only when fewer than two
models are installed, and gives up silently half way), this finishes a
partial set, never updates a model that is already installed (a deploy must
not change translations nobody asked to change), and exits non-zero when a
language would be missing.
"""
import os
import sys

from argostranslate import package

import libretranslate.language as lang

codes = [c.strip() for c in os.environ.get("LT_LOAD_ONLY", "").split(",") if c.strip()]
if not codes:
    sys.exit("LT_LOAD_ONLY is empty; set the language codes in .env.")
want = set(lang.iso2model(codes))

print(f"Languages wanted: {len(want)}", flush=True)
installed = {(p.from_code, p.to_code) for p in package.get_installed_packages()}
print(f"Models already installed: {len(installed)}", flush=True)

package.update_package_index()
available = [p for p in package.get_available_packages() if p.from_code in want and p.to_code in want]
offered = {c for p in available for c in (p.from_code, p.to_code)}
if want - offered:
    sys.exit("No model offers: " + ",".join(sorted(want - offered)) + ". Nothing was installed.")

todo = [p for p in available if (p.from_code, p.to_code) not in installed]
print(f"Models to download: {len(todo)} of {len(available)}", flush=True)
for i, p in enumerate(todo, 1):
    print(f"  [{i}/{len(todo)}] {p.from_code} -> {p.to_code} ({p.package_version})", flush=True)
    p.install()

have = {c for p in package.get_installed_packages() for c in (p.from_code, p.to_code)}
missing = want - have
if missing:
    sys.exit("Still missing after the download: " + ",".join(sorted(missing)))
print(f"All {len(want)} languages are installed ({len(package.get_installed_packages())} models).", flush=True)
