# Развёртывание сервера

**Требуется:** любая машина с Python 3, доступная из интернета. Ни базы данных,
ни зависимостей, ни домена, ни сертификата — Studio работает по обычному `http://`.

## Установка

```bash
# 1. Папка и файл
ssh root@ВАШ_СЕРВЕР
mkdir -p /opt/russteam/data
exit
scp server/server.py root@ВАШ_СЕРВЕР:/opt/russteam/server.py

# 2. Служба, чтобы работало постоянно
ssh root@ВАШ_СЕРВЕР
cat > /etc/systemd/system/russteam.service <<'UNIT'
[Unit]
Description=RussTeam sync relay
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/russteam/server.py
Environment=RUSSTEAM_PORT=8770
Environment=RUSSTEAM_DATA=/opt/russteam/data
WorkingDirectory=/opt/russteam
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/opt/russteam

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now russteam

# 3. Открыть порт
ufw allow 8770/tcp comment 'russteam'

# 4. Проверить
curl http://127.0.0.1:8770/health
```

Ответ должен быть таким:

```json
{"ok": true, "service": "russteam", "time": 1787749543}
```

## Ключи доступа

При первом запуске сервер создаёт ключ сам и печатает его в журнал:

```bash
journalctl -u russteam | grep "создан ключ"
cat /opt/russteam/keys.txt
```

Ключей может быть сколько угодно — по одному в строке. Файл перечитывается **раз в минуту**,
перезапуск не нужен.

```bash
# добавить ключ для нового человека
echo "rt_НОВЫЙКЛЮЧ" >> /opt/russteam/keys.txt

# отозвать доступ — просто убрать строку
```

Ключи генерируются без символов, которые путаются глазами: нет `l`, `1`, `I`, `O`, `0`.

## Настройки через переменные окружения

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `RUSSTEAM_PORT` | `8770` | порт |
| `RUSSTEAM_DATA` | `/opt/russteam/data` | где лежат каналы |
| `RUSSTEAM_KEYS` | `/opt/russteam/keys.txt` | файл ключей |

## Обслуживание

```bash
# состояние
systemctl status russteam

# только ошибки — обычные запросы не пишутся
journalctl -u russteam | grep -E "ошибка|отказ|сбой|потеря"

# сколько занимают данные
du -sh /opt/russteam/data/

# что в канале
python3 -c "
import json
d = json.load(open('/opt/russteam/data/ВАШ_КАНАЛ.json'))
print('участников:', len(d['roster']))
for u, r in d['roster'].items():
    print(' ', r.get('name'), 'вер.', r.get('ver'))
print('лент:', len(d['feeds']))
"
```

## Резервная копия

Данные — обычные файлы, копируются как есть:

```bash
tar czf russteam-$(date +%F).tar.gz /opt/russteam/data /opt/russteam/keys.txt
```

Терять их не страшно: это только очередь необменянных изменений, сами проекты
лежат у вас в Studio.

## Обновление

```bash
scp server/server.py root@ВАШ_СЕРВЕР:/opt/russteam/server.py
ssh root@ВАШ_СЕРВЕР systemctl restart russteam
```

Сервер понимает и новый единый обмен, и старый раздельный, поэтому участники со старой
версией плагина продолжат работать.
