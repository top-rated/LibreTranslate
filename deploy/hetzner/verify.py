"""verify.py -- check LibreTranslate from OUTSIDE the server, the way each
caller calls it, and compare it with the old instance.

    python3 verify.py [new base URL] [old base URL]
    (defaults: https://lt.makehybrid.com  http://65.108.253.194:5000)

The server workflow's `verify` runs this on a GitHub runner, so every request
crosses the internet, DNS and HTTPS like a caller's does. It checks:

  - the hostname resolves and serves HTTPS
  - /languages: the same languages as the old instance
  - /frontend/settings: keys and limits as on the old instance
  - Top Voice (server/visibility-engine.ts): POST <url>/detect, JSON
    {q, api_key}, within its 5 s timeout
  - makehybrid.com (api/src/grants/language.ts): POST <base>/detect, JSON
    {q} or {q, api_key}, within its 4 s timeout
  - Top Voice's i18n script: POST <url>/translate, JSON
    {q, source, target, format: "text", api_key}, within 30 s
  - /detect answers for the same texts on the new and the old instance

The key sent is a made-up one: with keys off (as on the old instance) the
service ignores it. Each caller's REAL key is tried from inside that caller
(DEPLOY.md, "Switching a caller"). Nothing here prints a secret.

Exit 1 on anything a caller would notice: an error, a missing language, a
changed setting, a timeout. Differing /detect answers are listed (and fail
the run when more than a few differ), so they can be looked at before a
caller is switched.
"""
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

NEW = (sys.argv[1] if len(sys.argv) > 1 else "https://lt.makehybrid.com").rstrip("/")
OLD = (sys.argv[2] if len(sys.argv) > 2 else "http://65.108.253.194:5000").rstrip("/")
FAKE_KEY = "verify-not-a-real-key"

# Texts like the ones Top Voice classifies (LinkedIn posts), in the languages
# its detector has returned over the last 30 days, plus short and mixed ones.
SAMPLES = [
    "Excited to share that our team just closed the biggest deal of the quarter. Thank you to everyone who made it happen!",
    "Estou muito feliz em anunciar que comecei um novo cargo como gerente de produto na empresa.",
    "Je suis ravi d'annoncer que je rejoins une nouvelle équipe pour développer des solutions durables.",
    "Ich freue mich, euch mitteilen zu können, dass ich eine neue Position als Teamleiter angetreten habe.",
    "Estoy encantado de compartir que nuestro equipo ha lanzado un nuevo producto este mes.",
    "Sono felice di annunciare che ho iniziato un nuovo lavoro come responsabile marketing.",
    "Ik ben trots om te delen dat ons team de prijs voor beste innovatie heeft gewonnen.",
    "Saya senang mengumumkan bahwa saya telah bergabung dengan tim baru sebagai analis data.",
    "Yeni bir pozisyona başladığımı paylaşmaktan mutluluk duyuyorum, herkese teşekkürler.",
    "Estic molt content d'anunciar que he començat una nova feina com a dissenyador.",
    "Z radością informuję, że rozpocząłem nową pracę jako kierownik projektu.",
    "يسعدني أن أعلن أنني بدأت وظيفة جديدة كمدير للمشاريع في الشركة.",
    "Sunt bucuros să anunț că am început un nou rol de inginer software.",
    "Jeg er glad for at kunne fortælle, at jeg er startet i et nyt job som udvikler.",
    "S radostí oznamuji, že jsem nastoupil na novou pozici vedoucího týmu.",
    "Tôi rất vui được thông báo rằng tôi đã bắt đầu công việc mới tại công ty.",
    "新しい会社でプロダクトマネージャーとして働き始めたことをお知らせします。",
    "Örömmel jelentem be, hogy új munkahelyen kezdtem el dolgozni fejlesztőként.",
    "Είμαι χαρούμενος που ανακοινώνω ότι ξεκίνησα μια νέα δουλειά ως μηχανικός.",
    "मुझे यह बताते हुए खुशी हो रही है कि मैंने एक नई नौकरी शुरू की है।",
    "S radosťou oznamujem, že som nastúpil na novú pozíciu vedúceho tímu.",
    "Olen iloinen voidessani kertoa, että aloitin uudessa työssä kehittäjänä.",
    "Jag är glad att berätta att jag har börjat ett nytt jobb som utvecklare.",
    "আমি আনন্দের সাথে জানাচ্ছি যে আমি একটি নতুন চাকরি শুরু করেছি।",
    "Радий повідомити, що я розпочав нову роботу на посаді керівника проєкту.",
    "Jam i lumtur të njoftoj se kam filluar një punë të re si menaxher.",
    "خوشحالم اعلام کنم که کار جدیدی را به عنوان مدیر پروژه شروع کرده‌ام.",
    "אני שמח לבשר שהתחלתי לעבוד בתפקיד חדש כמנהל מוצר.",
    "Mul on hea meel teatada, et alustasin uuel töökohal arendajana.",
    "Радвам се да споделя, че започнах нова работа като ръководител на проекти.",
    "Рад сообщить, что я начал новую работу в должности руководителя проекта.",
    "새로운 회사에서 프로덕트 매니저로 일을 시작하게 되어 기쁩니다.",
    "ผมยินดีที่จะแจ้งว่าผมได้เริ่มงานใหม่ในตำแหน่งผู้จัดการโครงการ",
    "مجھے یہ بتاتے ہوئے خوشی ہو رہی ہے کہ میں نے ایک نئی نوکری شروع کی ہے۔",
    "Masaya kong ibalita na nagsimula na ako sa bagong trabaho bilang tagapamahala.",
    "Džiaugiuosi galėdamas pranešti, kad pradėjau naują darbą kaip projektų vadovas.",
    "Z veseljem sporočam, da sem začel novo službo kot vodja projektov.",
    "Nina furaha kutangaza kwamba nimeanza kazi mpya kama meneja wa mradi.",
    "Priecājos paziņot, ka esmu sācis jaunu darbu kā projektu vadītājs.",
    "我很高兴地宣布,我已经开始担任新公司的产品经理。",
    "Thanks!",
    "Great post 👏",
    "https://example.com/article?id=42",
    "Congrats @Maria on the new role! Bem-vinda à equipa.",
]


def call(method, url, body=None, timeout=30):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json", "user-agent": "libretranslate-verify"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    except Exception as e:  # timeout, refused, TLS
        return None, f"{type(e).__name__}: {e}", time.monotonic() - t0
    ms = time.monotonic() - t0
    try:
        return status, json.loads(raw), ms
    except ValueError:
        return status, raw[:200].decode(errors="replace"), ms


failures = []
warnings = []


def fail(msg):
    failures.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


host = urllib.parse.urlparse(NEW).hostname
print(f"== {NEW}  (compared with {OLD})")
try:
    addrs = sorted({a[4][0] for a in socket.getaddrinfo(host, 443)})
    ok(f"{host} resolves to {', '.join(addrs)}")
except OSError as e:
    fail(f"{host} does not resolve: {e}")
    print("\nStopping: nothing can reach it without DNS.")
    sys.exit(1)

old_up = call("GET", OLD + "/languages", timeout=15)[0] == 200
if not old_up:
    print(f"  note  the old instance ({OLD}) is not answering; comparisons are skipped")

print("== /languages")
s, new_langs, ms = call("GET", NEW + "/languages")
if s != 200 or not isinstance(new_langs, list):
    fail(f"/languages answered {s}: {new_langs}")
    new_codes = set()
else:
    new_codes = {l["code"] for l in new_langs}
    ok(f"{len(new_codes)} languages over HTTPS ({ms * 1000:.0f} ms)")
    if old_up:
        old_codes = {l["code"] for l in call("GET", OLD + "/languages")[1]}
        if new_codes == old_codes:
            ok("exactly the old instance's languages")
        else:
            fail(f"languages differ from the old instance: missing {sorted(old_codes - new_codes)}, extra {sorted(new_codes - old_codes)}")

print("== /frontend/settings (keys and limits)")
keys = ("apiKeys", "keyRequired", "charLimit")
s, new_set, _ = call("GET", NEW + "/frontend/settings")
if s != 200 or not isinstance(new_set, dict):
    fail(f"/frontend/settings answered {s}")
else:
    mine = {k: new_set.get(k) for k in keys}
    if old_up:
        theirs = {k: call("GET", OLD + "/frontend/settings")[1].get(k) for k in keys}
        (ok if mine == theirs else fail)(f"{mine}" + ("" if mine == theirs else f" but the old instance has {theirs}"))
    else:
        ok(f"{mine}")

print("== Top Voice: POST <url>/detect {q, api_key}, 5 s timeout")
s, body, ms = call("POST", NEW + "/detect", {"q": SAMPLES[0], "api_key": FAKE_KEY}, timeout=5)
if s == 200 and isinstance(body, list) and body and body[0].get("language") == "en":
    ok(f"{body[0]} in {ms * 1000:.0f} ms")
else:
    fail(f"answered {s}: {body}")

print("== makehybrid.com: POST <base>/detect {q} and {q, api_key}, 4 s timeout")
for b in ({"q": SAMPLES[2]}, {"q": SAMPLES[2], "api_key": FAKE_KEY}):
    s, body, ms = call("POST", NEW.rstrip("/") + "/detect", b, timeout=4)
    label = "with a key" if "api_key" in b else "without a key"
    if s == 200 and isinstance(body, list) and body and body[0].get("language") == "fr":
        ok(f"{label}: {body[0]} in {ms * 1000:.0f} ms")
    else:
        fail(f"{label}: answered {s}: {body}")

print("== Top Voice's i18n script: POST <url>/translate {q, source, target, format, api_key}, 30 s timeout")
for target in ("fr", "de", "pt-BR", "zh-Hans"):
    if new_codes and target not in new_codes:
        continue
    s, body, ms = call("POST", NEW + "/translate", {"q": "Your campaign is ready. Open it to see the next post.", "source": "en", "target": target, "format": "text", "api_key": FAKE_KEY}, timeout=30)
    if s == 200 and isinstance(body, dict) and body.get("translatedText"):
        ok(f"en -> {target}: {body['translatedText'][:70]!r} in {ms:.1f} s")
    else:
        fail(f"en -> {target}: answered {s}: {str(body)[:160]}")

print("== Errors look the same as before")
s_new, b_new, _ = call("POST", NEW + "/detect", {"q": ""})
s_old, b_old, _ = call("POST", OLD + "/detect", {"q": ""}) if old_up else (s_new, b_new, 0)
(ok if s_new == s_old else fail)(f"empty q: {s_new} {b_new}" + ("" if s_new == s_old else f" (old instance: {s_old} {b_old})"))

print(f"== /detect on {len(SAMPLES)} texts, new vs old")
diff, times = [], []
for q in SAMPLES:
    s, n, ms = call("POST", NEW + "/detect", {"q": q, "api_key": FAKE_KEY}, timeout=10)
    times.append(ms)
    if s != 200 or not isinstance(n, list):
        fail(f"{q[:40]!r}: answered {s}: {n}")
        continue
    if not old_up:
        continue
    _, o, _ = call("POST", OLD + "/detect", {"q": q}, timeout=10)
    nl = n[0]["language"] if n else None
    ol = o[0]["language"] if isinstance(o, list) and o else None
    if nl != ol:
        diff.append((q, ol, nl))
times.sort()
print(f"  time: median {times[len(times) // 2] * 1000:.0f} ms, slowest {times[-1] * 1000:.0f} ms (callers give up at 4-5 s)")
if times[-1] > 4:
    fail("a /detect took longer than makehybrid.com's 4 s timeout")
if old_up:
    if not diff:
        ok(f"all {len(SAMPLES)} answers are the same language as the old instance's")
    for q, ol, nl in diff:
        print(f"  DIFF  old {ol!s:8} new {nl!s:8} {q[:60]!r}")
    if len(diff) > 3:
        fail(f"{len(diff)} of {len(SAMPLES)} /detect answers differ from the old instance")
    elif diff:
        warnings.append(f"{len(diff)} /detect answer(s) differ from the old instance (listed above)")

print()
for w in warnings:
    print(f"WARNING: {w}")
if failures:
    print(f"NOT READY: {len(failures)} check(s) failed (above).")
    sys.exit(1)
print("READY: every caller's request style works on the new address.")
