# DONT WAKE THE SQUISHY!

A "Don't Wake the Brainrots"-style Roblox game. A field of sleeping collectable
**squishies** sits in the middle of the map, patrolled by two **giant squishies**.
Sneak in, grab one (rarer = more income but a heavier carry slowdown), and get it
back to your plot without waking a giant — they notice you from further away when
you're carrying, and a slap flings you and makes you drop it. Squishies placed on
your plot earn money on their collect pads.

Source of truth is this repo; Studio is the viewport. The architecture contract
lives in **[DESIGN.md](DESIGN.md)** — if code disagrees with it, the code is wrong.

## Layout

| Path | Syncs into Studio as |
| --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |
| `Assets/SquishyMeshes.rbxm` | `ReplicatedStorage.SquishyMeshes` |
| `Assets/MainUi.rbxm` | `StarterGui.MainUi` |
| `Assets/<name>/` | Raw `.obj`/`.mtl`/texture source for the meshes |
| `place/` | The saved `.rbxl` place file |
| `tools/` | Lune scripts that regenerate the `.rbxm` assets |

Everything the game needs is in the repo: `rojo build` produces a playable place
from a clean clone, with no manual imports.

## The squishies

The roster (38 squishies across Common → Mythical) is **ported from the Squishy
Clicker game** — its `src/shared/Squishies.luau` is the canon for names, colours,
rarities and shapes. Here they live in [`src/shared/Config.luau`](src/shared/Config.luau),
and [`src/shared/SquishyModels.luau`](src/shared/SquishyModels.luau) builds the 3D
models: the imported meshes when `ReplicatedStorage.SquishyMeshes` has them, and
part-built primitives as fallback, so the game still works in a place without them.

To re-extract the meshes from the clicker's place file:

```bash
lune run tools/extract_meshes.luau
```

## The UI

The interface is the **Essential UI Pack** by Swarve Studios, owned by the repo as
`Assets/MainUi.rbxm` and synced to `StarterGui.MainUi`. Client code never builds
HUD geometry — it finds nodes in that tree and drives them, all through
[`src/client/UiRefs.luau`](src/client/UiRefs.luau). See the *UI Contract* section
of DESIGN.md for the paths and the module map.

To re-extract after editing the pack in Studio:

```bash
lune run tools/extract_ui.luau
```

Monetization (the Shop's Robux packs, the Random button, the wheel's Robux
buttons) is parked: those need real developer-product ids from the Creator
Dashboard, and the client hides any button whose id is still 0.

## Setup

Install [Rokit](https://github.com/rojo-rbx/rokit), then from this folder:

```bash
rokit install
```

That pins Rojo, Selene and Lune to the versions in `rokit.toml`.

## Connecting Studio

1. `rojo serve` in this folder.
2. Open the place in Studio, press the **Rojo** plugin toolbar button, and hit
   **Connect** (default `localhost:34872`).
3. Edits to files under `src/` now stream into Studio live.

If scripts stop updating or appear duplicated, the plugin has silently
disconnected — press **Connect** again.

Studio → repo only flows for the place file: save it back with
**File → Save to File As...** into `place/`.

## Linting

```bash
selene src
```
