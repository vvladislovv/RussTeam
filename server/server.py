#!/usr/bin/env python3
"""
RussTeam — камера хранения для обмена изменениями между двумя Roblox Studio.

Хранит только то, чем участники обменялись за последнее время. Проектов целиком
здесь нет. Данные лежат в обычных файлах, по одному на канал.
"""

import collections
import hmac
import json
import os
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "0.0.0.0"
PORT = int(os.environ.get("RUSSTEAM_PORT", "8770"))
DATA_DIR = os.environ.get("RUSSTEAM_DATA", "/opt/russteam/data")
KEYS_FILE = os.environ.get("RUSSTEAM_KEYS", "/opt/russteam/keys.txt")

MAX_BODY      = 32 * 1024 * 1024  # предел на один запрос; крупное плагин шлёт порциями
MAX_EVENTS    = 50000             # событий в одной отправке
MAX_PULL_BYTES = 4 * 1024 * 1024  # сколько отдаём за один приём; остаток — следующим
MIN_VERSION   = (3, 0)            # плагины старее в канал не пускаем: они шлют
                                  # пачки без родословной, применить их нельзя
KICK_TIMEOUT  = 300               # сколько держим отключённого за дверью, секунд
RATE_WINDOW   = 60                # окно подсчёта частоты, секунды
RATE_LIMIT    = 300               # запросов с одного адреса за окно
# Пачки НЕ выбрасываются по количеству: пока хоть один участник их не забрал,
# они лежат. Иначе работа за день пропадёт, пока напарник в отпуске.
MAX_BATCHES   = 20000             # предохранитель от бесконечного роста
MAX_FEED_BYTES = 512 * 1024 * 1024   # полгигабайта на ленту одного автора
KEEP_MIN      = 20                # столько последних держим всегда
ROSTER_TTL    = 3600              # молчащих больше часа убираем из переклички:
                                  # иначе в списке висят призраки от старых версий
CHANNEL_TTL   = 30 * 24 * 3600    # канал без движения месяц — удаляем файл

_lock = threading.Lock()
_channel_re = re.compile(r"^[A-Za-z0-9_-]{4,64}$")
_cache = {}          # канал -> данные в памяти
_dirty = set()       # какие каналы ждут записи на диск
_hits = collections.defaultdict(collections.deque)   # адрес -> когда обращался
_keys = set()        # разрешённые ключи доступа
_last_deny = {}      # когда последний раз ругались на адрес


def load_keys():
    """Ключи доступа: по одному в строке. Пустой файл — сервер закрыт для всех."""
    keys = set()
    try:
        with open(KEYS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    keys.add(line)
    except FileNotFoundError:
        pass
    return keys


def key_ok(given):
    """Сравнение без утечки по времени: не даём подбирать ключ по скорости ответа."""
    if not given:
        return False
    for known in _keys:
        if hmac.compare_digest(given, known):
            return True
    return False


def rate_ok(ip):
    """Не больше RATE_LIMIT запросов с адреса за окно.
    Обращения с самой машины не считаем: это обслуживание и проверки."""
    if ip in ("127.0.0.1", "::1", "localhost"):
        return True
    now = time.time()
    q = _hits[ip]
    while q and now - q[0] > RATE_WINDOW:
        q.popleft()
    if len(q) >= RATE_LIMIT:
        return False
    q.append(now)
    return True


def version_ok(ver):
    """Версия плагина не ниже минимальной. Неизвестную считаем старой."""
    try:
        major, minor = str(ver).split(".")[:2]
        return (int(major), int(minor)) >= MIN_VERSION
    except (ValueError, AttributeError):
        return False


def channel_path(channel):
    return os.path.join(DATA_DIR, channel + ".json")


def load(channel):
    """Читаем из памяти; с диска — только при первом обращении."""
    cached = _cache.get(channel)
    if cached is not None:
        return cached
    try:
        with open(channel_path(channel), "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, ValueError):
        data = {"feeds": {}, "roster": {}, "touched": time.time()}
    _cache[channel] = data
    return data


def save(channel, data):
    """Помечаем канал изменённым. На диск скидывает отдельный поток."""
    data["touched"] = time.time()
    _cache[channel] = data
    _dirty.add(channel)


def flush_to_disk():
    """Пишем изменённые каналы на диск. Вызывается под общим замком."""
    for channel in list(_dirty):
        data = _cache.get(channel)
        if data is None:
            _dirty.discard(channel)
            continue
        tmp = channel_path(channel) + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
            os.replace(tmp, channel_path(channel))
            _dirty.discard(channel)
        except OSError:
            pass


def prune_roster(roster, feeds=None):
    """Убираем молчащих. Их ленты уходят вместе с ними: держать чужое
    прошлое опасно — оно всплывёт у того, кто подключится позже."""
    now = time.time()
    for uid in list(roster.keys()):
        rec = roster.get(uid) or {}
        if now - float(rec.get("at", 0)) > ROSTER_TTL:
            del roster[uid]
            if feeds is not None:
                feeds.pop(uid, None)


def min_ack(author, roster, me):
    """До какого номера ленту author'а забрали ВСЕ живые участники.
    Если хоть кто-то ещё не видел пачку — она остаётся лежать."""
    seen = []
    for uid, rec in roster.items():
        if uid == author or not isinstance(rec, dict):
            continue
        since = rec.get("since")
        seen.append(int((since or {}).get(author, 0) or 0))
    if not seen:
        return 0          # кроме автора никого — держим всё
    return min(seen)


def trim_feed(feed, acked=0, report=None):
    """Выбрасываем только то, что забрали все. Остальное — предохранители.
    Если пришлось выбросить непрочитанное, пишем это в report."""
    # 1. забранное всеми
    if acked > 0 and len(feed) > KEEP_MIN:
        keep_from = 0
        for i, b in enumerate(feed):
            if int(b.get("n", 0)) > acked:
                keep_from = i
                break
        else:
            keep_from = max(0, len(feed) - KEEP_MIN)
        keep_from = min(keep_from, max(0, len(feed) - KEEP_MIN))
        if keep_from > 0:
            del feed[:keep_from]

    # 2. предохранитель по количеству
    dropped = 0
    while len(feed) > MAX_BATCHES:
        if int(feed[0].get("n", 0)) > acked:
            dropped += 1
        feed.pop(0)

    # 3. предохранитель по объёму
    while len(feed) > KEEP_MIN:
        size = len(json.dumps(feed, ensure_ascii=False).encode("utf-8"))
        if size <= MAX_FEED_BYTES:
            break
        if int(feed[0].get("n", 0)) > acked:
            dropped += 1
        feed.pop(0)

    if dropped and report is not None:
        report["dropped"] = report.get("dropped", 0) + dropped
        print(f"[потеря] выброшено {dropped} непрочитанных пачек: не хватило места",
              flush=True)
    return feed


def sweep_old_channels():
    """Раз в сутки убираем каналы, которыми давно не пользовались."""
    now = time.time()
    try:
        for name in os.listdir(DATA_DIR):
            if not name.endswith(".json"):
                continue
            path = os.path.join(DATA_DIR, name)
            try:
                if now - os.path.getmtime(path) > CHANNEL_TTL:
                    os.remove(path)
            except OSError:
                pass
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "RussTeam/1.0"
    protocol_version = "HTTP/1.1"

    def handle_one_request(self):
        self._body_read = False
        """Любая непойманная ошибка должна стать честным ответом 500,
        а не обрывом соединения: клиент иначе видит ConnectionClosed
        и не понимает, что произошло."""
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as exc:
            import traceback
            print(f"[сбой] {self.client_ip()} {self.requestline!r}: "
                  f"{type(exc).__name__}: {exc}", flush=True)
            traceback.print_exc()
            try:
                self.reply(500, {"ok": False, "error": f"внутренняя ошибка: {type(exc).__name__}"})
            except Exception:
                pass
            self.close_connection = True

    # --- вспомогательное ---

    def log_message(self, fmt, *args):
        # Журнал только для разбора поломок: обычные запросы и отказы по
        # ключу не пишем, иначе за сутки набегают гигабайты.
        try:
            line = fmt % args
        except Exception:
            line = str(fmt)
        if " 500 " in line or " 400 " in line:
            print(f"[ошибка] {self.client_ip()} {line}", flush=True)

    def log_error(self, fmt, *args):
        try:
            line = fmt % args
        except Exception:
            line = str(fmt)
        print(f"[ошибка] {self.client_ip()} строка запроса: "
              f"{getattr(self, 'requestline', '?')!r} -> {line}", flush=True)

    def reply(self, code, payload, close=True):
        # Соединение всегда закрываем после ответа. Roblox переиспользует
        # keep-alive непредсказуемо и падает с ConnectionClosed — дешевле
        # открывать новое соединение на каждый запрос.
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        try:
            self.wfile.flush()
        except OSError:
            pass

    def fail(self, code, text):
        # Тело надо дочитать, иначе его остаток попадёт в следующий запрос
        # по тому же соединению. Но если оно УЖЕ прочитано, читать нечего:
        # попытка приводит к зависанию до таймаута.
        if not self.close_connection and not getattr(self, "_body_read", False):
            self.drain_body()
        self.close_connection = True
        self.reply(code, {"ok": False, "error": text}, close=True)

    def drain_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        remaining = min(length, MAX_BODY + 1)
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)

    def read_json(self):
        self._body_read = True
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return None, "пустой запрос"
        if length > MAX_BODY:
            # Дочитывать многомегабайтное тело бессмысленно: отвечаем сразу
            # и закрываем. Клиент получит внятный отказ вместо обрыва.
            self.close_connection = True
            return None, (f"запрос {length // 1048576} МБ, предел "
                          f"{MAX_BODY // 1048576} МБ — отправляй порциями")
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8")), None
        except (ValueError, UnicodeDecodeError):
            return None, "не разобрал JSON"

    @staticmethod
    def check_channel(channel):
        if not channel or not _channel_re.match(str(channel)):
            return "код канала должен быть от 4 до 64 символов: буквы, цифры, дефис, подчёркивание"
        return None

    # --- маршруты ---

    def client_ip(self):
        return self.client_address[0] if self.client_address else "?"

    def guard(self):
        """Общая проверка перед любым делом: частота и ключ доступа."""
        with _lock:
            allowed = rate_ok(self.client_ip())
        if not allowed:
            self.fail(429, "слишком часто, подожди немного")
            return False
        given = self.headers.get("x-russteam-key") or ""
        if not key_ok(given):
            # Пишем не чаще раза в минуту с адреса: иначе цикл переподключений
            # заливает журнал одинаковыми строками.
            ip = self.client_ip()
            now = time.time()
            with _lock:
                last = _last_deny.get(ip, 0)
                if now - last > 60:
                    _last_deny[ip] = now
                    shown = (given[:6] + "…" + given[-4:]) if len(given) > 12 else (given or "пусто")
                    print(f"[отказ] {ip} ключ={shown} длина={len(given)}", flush=True)
            self.fail(401, "неверный ключ доступа")
            return False
        return True

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        one = lambda k: (q.get(k) or [""])[0]

        # Проверка живости открыта: по ней плагин понимает, что адрес верный.
        if url.path == "/health":
            return self.reply(200, {"ok": True, "service": "russteam", "time": int(time.time())})

        if not self.guard():
            return

        if url.path == "/v1/pull":
            channel, me = one("channel"), one("me")
            err = self.check_channel(channel)
            if err:
                return self.fail(400, err)
            since = {}
            raw_since = one("since")
            if raw_since:
                try:
                    parsed = json.loads(raw_since)
                except ValueError:
                    parsed = None
                # Пустая таблица в Luau кодируется как [], а не {} — принимаем оба.
                if isinstance(parsed, dict):
                    since = parsed
            with _lock:
                data = load(channel)
                roster = data.get("roster", {})
                prune_roster(roster)

                # Собираем в предсказуемом порядке: по автору, потом по номеру.
                # Так остаток догрузится следующим запросом без пропусков.
                pending = []
                for author, feed in sorted((data.get("feeds") or {}).items()):
                    if author == me:
                        continue
                    seen = int(since.get(author, 0) or 0)
                    for batch in sorted(feed, key=lambda b: int(b.get("n", 0))):
                        if int(batch.get("n", 0)) > seen:
                            pending.append((author, batch))

                out, budget, more = [], 0, False
                for author, batch in pending:
                    piece = {
                        "author": author,
                        "authorName": (roster.get(author) or {}).get("name", author),
                        "n": batch.get("n"),
                        "at": batch.get("at"),
                        "events": batch.get("events", []),
                    }
                    size = len(json.dumps(piece, ensure_ascii=False).encode("utf-8"))
                    if out and budget + size > MAX_PULL_BYTES:
                        more = True
                        break
                    out.append(piece)
                    budget += size
                save(channel, data)
            return self.reply(200, {"ok": True, "batches": out, "roster": roster, "more": more})

        if url.path == "/v1/roster":
            channel = one("channel")
            err = self.check_channel(channel)
            if err:
                return self.fail(400, err)
            with _lock:
                data = load(channel)
                roster = data.get("roster", {})
                prune_roster(roster)
                save(channel, data)
            return self.reply(200, {"ok": True, "roster": roster})

        return self.fail(404, "нет такого адреса")

    def do_POST(self):
        if not self.guard():
            return
        url = urlparse(self.path)
        payload, err = self.read_json()
        if err:
            return self.fail(400, err)

        channel = payload.get("channel")
        bad = self.check_channel(channel)
        if bad:
            return self.fail(400, bad)

        me = str(payload.get("me") or "")
        name = str(payload.get("name") or me)[:64]
        if not me:
            return self.fail(400, "не указан участник")

        if url.path == "/v1/hello":
            with _lock:
                data = load(channel)
                roster = data.setdefault("roster", {})
                roster[me] = {
                    "name": name,
                    "at": int(time.time()),
                    "pending": int(payload.get("pending") or 0),
                    "place": str(payload.get("place") or ""),
                    "ver": str(payload.get("ver") or "?"),
                    "auto": bool(payload.get("auto")),
                    "edit": bool(payload.get("edit", True)),
                }
                prune_roster(roster)
                save(channel, data)
            return self.reply(200, {"ok": True, "roster": roster})

        if url.path == "/v1/reset":
            # Убрать старые пачки, чтобы они не всплыли задним числом.
            # Нумерация НЕ сбрасывается: иначе у получателей курсор окажется
            # больше нового номера, и свежий снимок будет молча пропущен.
            scope = str(payload.get("scope") or "mine")
            with _lock:
                data = load(channel)
                feeds = data.setdefault("feeds", {})
                seq = data.setdefault("seq", {})
                cleared = 0
                targets = list(feeds.keys()) if scope == "all" else [me]
                for author in targets:
                    batches = feeds.get(author) or []
                    if batches:
                        last = max(int(b.get("n", 0)) for b in batches)
                        seq[author] = max(int(seq.get(author, 0)), last)
                        cleared += len(batches)
                    feeds[author] = []
                save(channel, data)
            print(f"[очистка] {name} убрал {cleared} пачек ({scope}) в канале {channel}",
                  flush=True)
            return self.reply(200, {"ok": True, "cleared": cleared})

        if url.path == "/v1/request-full":
            # Просьба к остальным прислать проект целиком. Живёт 5 минут:
            # дольше держать бессмысленно, а забытая просьба будет мешать.
            with _lock:
                data = load(channel)
                data["fullRequest"] = {"by": me, "name": name, "at": int(time.time())}
                save(channel, data)
            return self.reply(200, {"ok": True})

        if url.path == "/v1/kick":
            # Отключить участника из канала. Его лента остаётся: в ней могут
            # быть изменения, нужные остальным.
            target = str(payload.get("target") or "")
            if not target:
                return self.fail(400, "не указан, кого отключать")
            with _lock:
                data = load(channel)
                roster = data.setdefault("roster", {})
                name = (roster.get(target) or {}).get("name", target)
                roster.pop(target, None)
                kicked = data.setdefault("kicked", {})
                kicked[target] = int(time.time())
                # подчищаем просроченные запреты
                now = int(time.time())
                for uid in list(kicked.keys()):
                    if now - int(kicked[uid]) > KICK_TIMEOUT:
                        del kicked[uid]
                save(channel, data)
            print(f"[отключён] {name} ({target}) из канала {channel}", flush=True)
            return self.reply(200, {"ok": True, "kicked": name})

        if url.path == "/v1/leave":
            # Человек ушёл сам. Убираем его из переклички сразу, а не через час:
            # напарник должен видеть правду, а не призрака.
            with _lock:
                data = load(channel)
                roster = data.setdefault("roster", {})
                existed = roster.pop(me, None) is not None
                # Лента остаётся: в ней могут лежать изменения, которых
                # остальные ещё не забрали.
                save(channel, data)
            return self.reply(200, {"ok": True, "left": existed})

        if url.path == "/v1/sync":
            # Старые версии в канал не пускаем: их пачки применить невозможно,
            # а в перекличке они висят призраками.
            if not version_ok(payload.get("ver")):
                return self.fail(426, "версия плагина устарела — обнови до "
                                      f"{MIN_VERSION[0]}.{MIN_VERSION[1]} или новее")

            with _lock:
                data = load(channel)
                kicked = data.get("kicked") or {}
                when = kicked.get(me)
            if when and (int(time.time()) - int(when)) < KICK_TIMEOUT:
                return self.fail(403, "тебя отключили от канала")

            # Всё за один заход: отметиться, отдать своё, забрать чужое.
            # Втрое меньше запросов и втрое меньше задержка.
            events = payload.get("events")
            since = payload.get("since")
            if not isinstance(since, dict):
                since = {}

            with _lock:
                data = load(channel)
                feeds = data.setdefault("feeds", {})
                roster = data.setdefault("roster", {})

                sent_n = None
                if isinstance(events, list) and events:
                    if len(events) > MAX_EVENTS:
                        return self.fail(400, f"слишком много изменений за раз: {len(events)}")
                    feed = feeds.setdefault(me, [])
                    seq = data.setdefault("seq", {})
                    highest = max([int(b.get("n", 0)) for b in feed] or [0])
                    sent_n = max(highest, int(seq.get(me, 0))) + 1
                    seq[me] = sent_n
                    batch = {"n": sent_n, "at": int(time.time()),
                             "author": name, "events": events}
                    # Словарь родословных идёт вместе с пачкой: события
                    # ссылаются на него, чтобы не повторять одно и то же.
                    ancs = payload.get("ancs")
                    if isinstance(ancs, dict) and ancs:
                        batch["ancs"] = ancs
                    # Метка «часть полного снимка»: получатель приберётся
                    # только когда соберёт все части.
                    full = payload.get("full")
                    if isinstance(full, dict) and full.get("id"):
                        batch["full"] = full
                    feed.append(batch)
                    feeds[me] = trim_feed(feed, min_ack(me, roster, me))

                roster[me] = {
                    "name": name,
                    "at": int(time.time()),
                    "pending": 0 if sent_n else int(payload.get("pending") or 0),
                    "place": str(payload.get("place") or ""),
                    "ver": str(payload.get("ver") or "?"),
                    "auto": bool(payload.get("auto")),
                    "edit": bool(payload.get("edit", True)),
                    # До чего этот участник дочитал каждую ленту. По этому
                    # полю решаем, что уже можно выбросить.
                    "since": {str(k): int(v or 0) for k, v in since.items()},
                }
                prune_roster(roster, feeds)

                # Чистим только забранное всеми
                report = {}
                for a, f in list(feeds.items()):
                    feeds[a] = trim_feed(f, min_ack(a, roster, me), report)

                pending = []
                for author, feed in sorted(feeds.items()):
                    if author == me:
                        continue
                    # Лента участника, которого уже нет в перекличке, — это
                    # прошлое: закрытое место, старая версия, ушедший человек.
                    # Отдавать её новичкам нельзя: она вернёт удалённое
                    # и наплодит вторые копии.
                    if author not in roster:
                        continue
                    seen = int(since.get(author, 0) or 0)
                    for batch in sorted(feed, key=lambda b: int(b.get("n", 0))):
                        if int(batch.get("n", 0)) > seen:
                            pending.append((author, batch))

                out, budget, more = [], 0, False
                for author, batch in pending:
                    piece = {
                        "author": author,
                        "authorName": (roster.get(author) or {}).get("name", author),
                        "n": batch.get("n"),
                        "at": batch.get("at"),
                        "events": batch.get("events", []),
                    }
                    if batch.get("ancs"):
                        piece["ancs"] = batch["ancs"]
                    if batch.get("full"):
                        piece["full"] = batch["full"]
                    size = len(json.dumps(piece, ensure_ascii=False).encode("utf-8"))
                    if out and budget + size > MAX_PULL_BYTES:
                        more = True
                        break
                    out.append(piece)
                    budget += size

                save(channel, data)

                # Просьба прислать проект целиком — если она не наша и свежая
                req = data.get("fullRequest")
                ask = None
                if isinstance(req, dict) and req.get("by") != me:
                    if int(time.time()) - int(req.get("at", 0)) < 300:
                        ask = {"by": req.get("by"), "name": req.get("name"),
                               "at": req.get("at")}

            return self.reply(200, {"ok": True, "n": sent_n, "batches": out,
                                    "roster": roster, "more": more,
                                    "fullRequest": ask,
                                    "dropped": report.get("dropped", 0)})

        if url.path == "/v1/push":
            events = payload.get("events")
            if not isinstance(events, list):
                return self.fail(400, "нет списка изменений")
            if len(events) > MAX_EVENTS:
                return self.fail(400, f"слишком много изменений за раз: {len(events)}, предел {MAX_EVENTS}")
            with _lock:
                data = load(channel)
                feeds = data.setdefault("feeds", {})
                feed = feeds.setdefault(me, [])
                n = max([int(b.get("n", 0)) for b in feed] or [0]) + 1
                feed.append({
                    "n": n,
                    "at": int(time.time()),
                    "author": name,
                    "events": events,
                })
                feeds[me] = trim_feed(feed, min_ack(me, data.get("roster", {}), me))
                roster = data.setdefault("roster", {})
                roster[me] = {
                    "name": name,
                    "at": int(time.time()),
                    "pending": 0,
                    "place": str(payload.get("place") or ""),
                }
                prune_roster(roster)
                save(channel, data)
            return self.reply(200, {"ok": True, "n": n, "count": len(events)})

        return self.fail(404, "нет такого адреса")

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PUT(self):
        self.do_POST()

    def do_PATCH(self):
        self.do_POST()

    def do_OPTIONS(self):
        self.reply(200, {"ok": True, "methods": ["GET", "POST"]})

    def do_DELETE(self):
        self.fail(405, "этот метод не используется")

    def do_TRACE(self):
        self.fail(405, "этот метод не используется")

    def send_error(self, code, message=None, explain=None):
        """Заменяем HTML-страницу Python на понятный JSON."""
        try:
            self.drain_body()
            self.close_connection = True
            self.reply(code, {"ok": False,
                              "error": f"{message or 'ошибка'} (код {code})"}, close=True)
        except Exception:
            pass


def janitor():
    """Раз в секунду сохраняем накопленное, раз в сутки чистим старьё."""
    ticks = 0
    while True:
        time.sleep(1)
        ticks += 1
        with _lock:
            flush_to_disk()
            if ticks % 60 == 0:
                globals()["_keys"] = load_keys() or globals()["_keys"]
            if ticks % 86400 == 0:
                _cache.clear()
                sweep_old_channels()


class Server(ThreadingHTTPServer):
    # По умолчанию очередь входящих — 5 соединений, и всплеск обрывается.
    request_queue_size = 256
    daemon_threads = True
    allow_reuse_address = True


def main():
    global _keys
    os.makedirs(DATA_DIR, exist_ok=True)
    _keys = load_keys()
    if not _keys:
        # Первый запуск: делаем ключ сами, чтобы сервер не остался открытым.
        # Без символов, которые путают глазами: l, 1, I, 0, O, дефис в конце.
        alphabet = "abcdefghijkmnpqrstuvwxyzACDEFGHJKLMNPQRSTUVWXYZ23456789"
        new_key = "rt_" + "".join(secrets.choice(alphabet) for _ in range(28))
        with open(KEYS_FILE, "w", encoding="utf-8") as f:
            f.write("# Ключи доступа RussTeam, по одному в строке\n")
            f.write(new_key + "\n")
        os.chmod(KEYS_FILE, 0o600)
        _keys = {new_key}
        print("создан ключ доступа:", new_key, flush=True)
    threading.Thread(target=janitor, daemon=True).start()
    srv = Server((HOST, PORT), Handler)
    print(f"RussTeam слушает {HOST}:{PORT}, данные в {DATA_DIR}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
