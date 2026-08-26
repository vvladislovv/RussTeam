# RussTeam architecture

**[Русская версия](ARCHITECTURE.md)**

## The pieces

```
┌─────────────────────────────┐         ┌─────────────────────────────┐
│        Studio #1            │         │        Studio #2            │
│  ┌───────────────────────┐  │         │  ┌───────────────────────┐  │
│  │  RussTeam plugin      │  │         │  │  RussTeam plugin      │  │
│  │  ┌─────────────────┐  │  │         │  │                       │  │
│  │  │ Tree: walk      │  │  │         │  │                       │  │
│  │  │ Serialize: JSON │  │  │         │  │                       │  │
│  │  │ Apply: incoming │  │  │         │  │                       │  │
│  │  │ Net: HTTP       │  │  │         │  │                       │  │
│  │  │ Panel: the UI   │  │  │         │  │                       │  │
│  │  └─────────────────┘  │  │         │  └───────────────────────┘  │
│  └──────────┬────────────┘  │         │  └──────────┬────────────┘  │
└─────────────┼───────────────┘         └─────────────┼───────────────┘
              │      POST /v1/sync                    │
              └───────────────┬───────────────────────┘
                              ▼
                  ┌───────────────────────┐
                  │   server.py           │
                  │   Python, no database,│
                  │   no dependencies     │
                  │                       │
                  │   data/CHANNEL.json   │
                  │   ├── feeds           │
                  │   └── roster          │
                  └───────────────────────┘
```

## Why a server is needed

Studio cannot reach another Studio: there is no address and no persistent connection.
More importantly, **you rarely work at the same time**. Something has to stay online,
accept changes and hold them until the other side shows up.

Three relays were tried:

| Relay | Why it failed |
|---|---|
| Roblox DataStore | Bound to a single place. You have separate places |
| Open Cloud | Roblox forbids sending API keys to its own endpoints from Luau |
| **Own server** | Works. No domain or certificate required |

## Plugin modules

### Config
Every limit, the list of transferable classes and their properties. The only file worth
opening to tune behaviour.

### Serialize
Roblox properties to JSON and back. Handles `Vector3`, `CFrame`, `Color3`, `UDim`,
`UDim2`, `Vector2`, `NumberRange`, `BrickColor`, `PhysicalProperties`, enums and
references to other instances.

Values carry an explicit tag:

```lua
CFrame.new(1, 2, 3)  →  { __t = "cf", d = {1, 2, 3, 1,0,0, 0,1,0, 0,0,1} }
```

The tag says what to rebuild on the other side. The `d` field is mandatory: a table with
a string key *and* numeric indices **does not survive JSON** — numeric keys turn into
strings.

### Tree
Walking the project and diffing snapshots.

A snapshot maps `id → record`. The id lives in a hidden `__vsid` attribute on the object
itself and **travels with it**. As a result:

- renaming is a modification, not "delete one, create another";
- dragging into another folder is also a modification;
- a duplicated object (`Ctrl+D`) gets a fresh id, because the walk spots the collision.

Each record carries a cheap hash of its properties, so diffing is hash comparison.

Skipped: characters (anything containing a `Humanoid`), helper objects named with a `__`
prefix, classes outside the list.

### Apply
Applying incoming changes. Order matters:

1. **Create** — several passes, because a parent may arrive in the same batch and not
   exist yet.
2. **Modify** — with conflict detection.
3. **References** — a separate pass once every target exists. Otherwise a weld would look
   for a part that is not there.
4. **Delete** — deepest first, otherwise the parent goes before its children.

Meshes are a special case. Writing `MeshId` is **forbidden**:

```
The current thread cannot write 'MeshId' (lacking capability NotAccessible)
```

So a mesh is built through `AssetService:CreateMeshPartAsync`, and render/collision
fidelity are passed **at creation time** — assigning them later does not stick. Built
meshes are cached: the first costs a round trip to Roblox, the rest are clones at 0.1 ms.

### Net
The only module that knows about HTTP. The access key travels in an `x-russteam-key`
header.

Roblox blocks such headers towards **its own** endpoints but allows them for third-party
hosts — which is what makes this design possible at all.

### Panel
The UI. It decides nothing: it receives state and reports clicks outwards.

## The exchange

A single request does everything — three times fewer round trips than separate calls.

```
POST /v1/sync
{
  "channel": "TEAM-4821",
  "me": "707163568",
  "name": "vlad",
  "since": { "3845084819": 17 },     ← how far I read each feed
  "events": [ ... ]                   ← my diff, optional
}
```

```
200 OK
{
  "n": 42,                            ← my batch number
  "batches": [ ... ],                 ← what I have not seen
  "roster": { ... },                  ← who is in the channel
  "more": false,                      ← are there batches left
  "dropped": 0                        ← unread batches that had to be discarded
}
```

## Server storage

One file per channel, two sections:

**Feeds** — one per participant. Everyone writes only to their own, so concurrent work
never collides.

**Roster** — when each person checked in, how much they have unsent, how far they have
read the other feeds.

A batch lives **until every active participant has fetched it**. Once fetched, the last 20
are kept as a cushion. Someone silent for over a week drops out of the roster and stops
holding back cleanup.

Data lives in memory and is flushed to disk once a second by a separate thread — otherwise
the file would be re-read on every request.

## Conflicts

Every change carries the fingerprint of the version its author started from. The receiver
compares three things: its current version, its own baseline and the incoming fingerprint.

If both sides edited from a common point, the change is **not applied** — it lands in the
conflict list with a choice. There is no automatic merge of two script versions; that is a
separate large problem.

## Limits and where they come from

| Limit | Value | Source |
|---|---|---|
| Send chunk | 8000 changes | Measured: 20 000 (3.5 MB) in 0.66 s, 60 000 (10.6 MB) times out |
| Request | 32 MB | Studio will not send more anyway |
| Pull response | 4 MB | The rest arrives on the next exchange |
| Participant feed | 512 MB | ≈ 3M changes, then the guard kicks in |
| Project walk | 8000 objects | Guard against huge places; the plugin warns on truncation |
| Rate | 300 requests/min per address | Flood protection |
| Big batch | 400 changes | Above that a human confirms |

## Known limitations

**Union and Negate.** The shape produced by a union lives on Roblox servers. Decomposing
an existing union back into source parts is impossible from code — there is no
`SeparateAsync`. `GeometryService:UnionAsync` can build a new one, but we have no source
parts to give it.

**Terrain.** Voxels weigh tens of megabytes and do not fit the exchange.

**Private assets.** An `rbxassetid://...` link travels, not the file. If the asset is not
shared, the other side sees nothing.

**Script merging.** Two versions of one file are never merged: a human picks one.
