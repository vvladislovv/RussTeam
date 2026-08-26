# Текст для релиза v2.6

Скопировать в описание релиза на GitHub.
Прикрепить файл: `RussTeam.rbxm`

---

## RussTeam 2.6

Перенос деталей, моделей, мешей и скриптов между **разными** проектами Roblox Studio.
Разные аккаунты, разные карты — общий обмен через свой сервер.

### Как поставить

**Плагин** — скачай `RussTeam.rbxm` ниже, положи в папку плагинов Studio
(*Plugins* → **Plugins Folder**) и перезапусти Studio.
На Mac нужен `Cmd+Q`: крестик программу не закрывает.

**Сервер** — любая машина с Python 3, [инструкция](../docs/DEPLOY.md).
Домен и сертификат не нужны.

**Соединиться** — три поля в панели: адрес сервера, ключ доступа, общий код канала.
Один раз, дальше запомнится.

### Что в этой версии

**Меши приезжают целыми.** Оказалось, Roblox запрещает записывать `MeshId` —
поэтому раньше вместо меша появлялась белая заготовка. Теперь меш собирается через
`AssetService`, а точность отрисовки и столкновений задаётся при создании.
Сверил 22 свойства меша — совпали все.

**Обмен втрое быстрее.** Отметка, отправка и приём слились в один запрос.
Интервал 5 секунд вместо 30. Для двоих обмен занимает 2 миллисекунды.

**Настройки не теряются.** Запоминаются на каждое нажатие клавиши, а не при потере
фокуса, и до попытки подключения, а не после успеха. Адрес и канал дублируются
в проект, поэтому переживают переустановку плагина. Ключ там не хранится намеренно.

**Работа в офлайне доходит.** Сервер держит изменения, пока их не забрали **все**
участники. Проверено: 500 отправок, второй участник появился потом — получил все 500.

**Меньше мусора.** Персонажи и манекены больше не переносятся, во время нажатого Play
обмен стоит на паузе. Раньше каждый запуск игры отправлял напарнику руки-ноги манекенов.

**Код разложен на семь модулей** и документирован. Архитектура и README на русском
и английском.

### Пределы

| Что | Сколько |
|---|---|
| Studio отправляет за раз | 3,5 МБ ≈ 20 000 изменений за 0,66 с |
| Крупное режется на порции | по 8000, общий объём не ограничен |
| Лента участника | 512 МБ ≈ 3 000 000 изменений |
| Сервер держит | 400 человек одновременно без ошибок |

### Чего не умеет

**Union и Negate** — форма после объединения живёт на серверах Roblox, разобрать
готовый юнион из кода нельзя: метода не существует.

**Terrain** — воксели не помещаются в обмен.

**Приватные ассеты** — едет ссылка, а не файл. Не расшарен — у напарника пусто.

### Если что-то не работает

Таблица частых ошибок — в [README](../README.md#если-что-то-не-работает).
Ошибки плагин пишет в **View → Output** предупреждениями.

---

## English

Move parts, models, meshes and scripts between **separate** Roblox Studio projects.
Different accounts, different places — one shared channel through your own server.

**Install** — download `RussTeam.rbxm`, drop it into the Studio plugins folder
(*Plugins* → **Plugins Folder**), restart Studio. On macOS use `Cmd+Q`.

**Server** — any machine with Python 3, see [deployment guide](../docs/DEPLOY.md).
No domain or certificate needed.

### What's in this release

**Meshes arrive intact.** Roblox forbids writing `MeshId`, so meshes used to appear as
blank white blocks. They are now built through `AssetService`, with render and collision
fidelity applied at creation time. All 22 mesh properties verified to round-trip.

**Three times faster.** Check-in, push and pull merged into a single request.
Five-second interval instead of thirty. Two users exchange in 2 milliseconds.

**Settings persist.** Saved on every keystroke and before the connection attempt, not
after success. Address and channel are mirrored into the place file, surviving plugin
reinstalls. The key is deliberately not stored there.

**Offline work arrives.** The server holds changes until **every** participant has
fetched them. Verified: 500 pushes, second participant arrived later, got all 500.

**Less noise.** Characters and rigs are no longer transferred, and the exchange pauses
during playtests.

**Seven modules** instead of one file, with architecture docs in both languages.
