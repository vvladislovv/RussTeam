<div align="center">

<img src="assets/russteam_logo.png" width="120" alt="RussTeam">

# RussTeam

**Move changes between separate Roblox Studio projects**

Different accounts, different places, different cities — one shared channel.

[![version](https://img.shields.io/badge/version-5.3-3a7ae0)](https://github.com/vvladislovv/RussTeam/releases)
[![plugin](https://img.shields.io/badge/Roblox-plugin-d63e3e)](https://create.roblox.com/store/asset/97875424740318/RussTeam)
[![license](https://img.shields.io/badge/license-MIT-66a060)](LICENSE)

[![Download plugin](https://img.shields.io/badge/⬇_Download_plugin-RussTeam.rbxm-3a7ae0?style=for-the-badge)](https://github.com/vvladislovv/RussTeam/releases/latest/download/RussTeam.rbxm)

[How it works](#how-it-works) · [Install](#download-and-run) · [Architecture](docs/ARCHITECTURE.en.md) · [Bug postmortem](docs/%D0%98%D0%A1%D0%A2%D0%9E%D0%A0%D0%98%D0%AF_%D0%9E%D0%A8%D0%98%D0%91%D0%9E%D0%9A.md) · **[Русский](README.md)**

</div>

---

## Why

Roblox only supports collaboration inside a **single** place. If you and a teammate work
on **separate projects** and want to hand parts, models and scripts to each other, there
is no built-in way.

RussTeam does it. You work in your place, your teammate in theirs, and changes travel
between you through a small relay server.

```
   Studio #1                  server                  Studio #2
  ┌──────────┐    push      ┌──────────┐    pull     ┌──────────┐
  │ project A│ ──────────>  │ channel  │ ─────────>  │ project B│
  │          │ <──────────  │          │ <─────────  │          │
  └──────────┘    pull      └──────────┘    push     └──────────┘
```

The server exists because **you are rarely online at the same time**. It holds changes
while the other side is away: work at night, your teammate picks it up in the morning.

## What transfers

| Transfers | Does not transfer |
|---|---|
| Parts, models, folders: position, rotation, size | **Union / Negate** — the shape lives on Roblox servers |
| Meshes with textures, render and collision fidelity | **Terrain** — voxels don't fit the exchange |
| Materials, colors, transparency, reflectance, physics | **Private assets** — a link travels, not the file |
| Welds and constraints: `WeldConstraint`, `Motor6D` | `Camera`, `Animator` — the engine creates those |
| GUIs: `ScreenGui`, `SurfaceGui`, `BillboardGui` | |
| Decals, particles, lights, sound, lighting effects | |
| Scripts of every kind, Value objects | |
| Characters, rigs, clothing, `StarterPlayerScripts` | |

## Download and run

### 1. Install the plugin

**From the Roblox Store** — [plugin page](https://create.roblox.com/store/asset/97875424740318/RussTeam),
one click, updates arrive automatically.

**As a file** — grab [`RussTeam.rbxm`](https://github.com/vvladislovv/RussTeam/releases/latest/download/RussTeam.rbxm) from the latest release, drop it into the Studio plugins
folder (*Plugins* tab → **Plugins Folder** button) and restart Studio.

> On Windows closing the window is enough. On macOS you need **Cmd+Q** — the close button
> does not quit the app.

### 2. Run the server

Any machine with Python 3 reachable from the internet. No domain or certificate needed:
Studio is fine with plain `http://`.

```bash
scp server/server.py root@YOUR_SERVER:/opt/russteam/server.py
ssh root@YOUR_SERVER
mkdir -p /opt/russteam/data
python3 /opt/russteam/server.py
```

On first start the server generates an access key and prints it:

```
создан ключ доступа: rt_XXXXXXXXXXXXXXXXXXXXXXXXXXXX
RussTeam слушает 0.0.0.0:8770, данные в /opt/russteam/data
```

To keep it running, install it as a service — see [docs/DEPLOY.md](docs/DEPLOY.md).

### 3. Connect

Open the panel with the **RussTeam** button and fill three fields once:

| Field | Value |
|---|---|
| Server address | `http://YOUR_ADDRESS:8770` |
| Access key | the `rt_...` string from the server console |
| Channel | any shared code, e.g. `TEAM-4821` |

Hit **Подключиться** (Connect). The bar turns green and the toolbar icon lights up.

Send the same three lines to your teammate. **The key and the channel are passwords** —
share them privately.

## How it works

Every 12 seconds the plugin compares the project against the snapshot it saw last time and
sends **only the difference**: what was added, changed, removed. The whole project never
travels.

Receiving works the same way: the server returns everything you have not seen yet and the
plugin applies it. One exchange is one request.

Objects are identified by a hidden attribute that travels with the object, so renaming or
moving something to another folder does not create a duplicate.

Details in [docs/ARCHITECTURE.en.md](docs/ARCHITECTURE.en.md).

## Features

**Live mode** — the exchange runs on its own every 12 seconds. Turn it off with
the button at the bottom of the panel.

**Send whole project** — uploads everything. Before sending, the plugin clears
its own earlier batches from the server so stale data cannot resurface.

**Request whole project** — asks your teammate for everything; their plugin
responds on its own.

**Staged application** — large snapshots are applied 200 objects at a time,
with a progress bar and a warning not to touch the project meanwhile.

**Nothing destructive happens silently.** These always stop and wait for you:

| What | When it asks |
|---|---|
| Receiving a whole project | always, with the object count |
| A big batch | over 400 changes at once |
| Receiving deletions | over 50 deletions at once |
| **Sending** your own deletions | over 50 — trouble stays where it happened |

Every confirmation has a reject button.

**Who is in the channel** — who is around, who is editing right now, and **which
plugin version each one runs**. Mismatched versions are the most common reason
changes don't arrive. There is a button to kick a participant.

**Paused during playtests** — while Play is pressed nothing is exchanged.

**One copy per Studio** — if the plugin is installed twice, the redundant copy
disables itself.

**Service actions** (under "Показать подробности"): sync now, remove duplicates,
repair empty meshes, remove what the teammate doesn't have. All with a preview
and two presses.

## Limits

Measured on a live Studio:

| What | How much |
|---|---|
| One change | ~180 bytes |
| Studio sends per request | 3.5 MB ≈ 20 000 changes in 0.66 s |
| Send chunk | 8000 changes |
| Apply slice | 200 objects |
| Verified on | **30 000 objects — zero loss, 3.3 s** |
| Project walk | 100 000 objects |
| One participant's feed | 512 MB ≈ 3 000 000 changes |
| Server capacity | 400 concurrent users, zero errors |

Class coverage: **110**. On a real 2543-object project, 2526 are transferred —
**99.3%**. The rest cannot be moved at all: `UnionOperation`, `Terrain`,
`Camera`, and engine-created objects.

## Troubleshooting

| What you see | What it means |
|---|---|
| No button in the toolbar | Studio was not fully restarted. On macOS use `Cmd+Q` |
| `сервер не принял ключ доступа` | The key was not copied in full. Copy, don't retype |
| `сервер недоступен` | Missing `http://` or the `:8770` port in the address |
| `по этому адресу отвечает не RussTeam` | The address points at a different program |
| `слишком частые запросы` | Over 300 requests per minute from one address. Wait a minute |
| A mesh arrives as a white block | The mesh asset is private. Share it or use a public one |
| `идёт запуск игры, обмен на паузе` | Stop Play — no exchange happens during a playtest |
| Nothing arrives | Make sure both sides typed the channel **identically** |
| `attempt to index nil with 'CreateToolbar'` | A copy of the plugin was left as a Script inside the place. Delete it from the tree |
| "принято 0" every 12 seconds | Something is waiting for confirmation — check the buttons at the bottom |
| Thousands of deletions arrived | **Do not confirm.** Your teammate's project is damaged; have them accept your full snapshot |
| Participants show different versions | Update everyone: the server rejects versions below 3.0 |

Errors go to **View → Output** as warnings. For a verbose trace set
`Config.VERBOSE = true`.

## For developers

```
plugin/               plugin sources
  init.server.lua     wires the parts together
  Config.lua          limits, classes, properties
  Serialize.lua       properties to JSON and back
  Tree.lua            project walk and snapshot diff
  Apply.lua           applying incoming changes
  Net.lua             talking to the server
  Panel.lua           the Studio panel
server/server.py      relay server
docs/                 architecture and deployment
```

Build with [Rojo](https://rojo.space):

```bash
rojo build -o RussTeam.rbxm     # file for the plugins folder
./check.sh                       # syntax, broken links, calls that don't exist
```

## Author

**vvladislovv**

[![GitHub](https://img.shields.io/badge/GitHub-vvladislovv-181717?logo=github)](https://github.com/vvladislovv)
[![Telegram](https://img.shields.io/badge/Telegram-dislov__freelance-2AABEE?logo=telegram)](https://t.me/dislov_freelance)
[![Roblox](https://img.shields.io/badge/Roblox-profile-d63e3e?logo=roblox)](https://www.roblox.com/users/707163568/profile)

Found a bug or have an idea — [open an issue](https://github.com/vvladislovv/RussTeam/issues).

## License

[MIT](LICENSE) — do what you want, no warranty.
