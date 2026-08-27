# DONT WAKE THE SQUISHY!

A Roblox experience. Source of truth is this repo; Studio is the viewport.

## Layout

| Path | Syncs into Studio as |
| --- | --- |
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |
| `Assets/` | Raw `.obj`/`.mtl`/texture source for meshes (imported by hand) |
| `place/` | The saved `.rbxl` place file |

## Setup

Install [Rokit](https://github.com/rojo-rbx/rokit), then from this folder:

```
rokit install
```

That pins Rojo and Selene to the versions in `rokit.toml`.

## Connecting Studio

1. `rojo serve` in this folder.
2. Open the place in Studio, go to the **Rojo** plugin toolbar button, and press **Connect** (default `localhost:34872`).
3. Edits to files under `src/` now stream into Studio live.

Studio -> repo only flows for the place file: save it back with
**File -> Save to File As...** into `place/`.

## Linting

```
selene src
```
