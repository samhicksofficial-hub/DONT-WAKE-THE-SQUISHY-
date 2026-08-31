# Assets & IDs needed from the account owner

Everything in the game today is built from parts, text and code — it runs with
none of this. This list is what would take it the last step toward the
reference look and switch on the parked monetization.

Each row says **where the number goes**. Send them over (or paste them straight
into `src/shared/Config.luau`) and the matching feature turns itself on.

---

## 1. Developer Products — repeatable purchases
Create at **Creator Dashboard → your experience → Monetization → Developer Products**.
IDs go in `Config.Products` (`src/shared/Config.luau`). While an ID is `0` the
client hides that button, so nothing looks broken in the meantime.

| Config key | What it should sell | Where it shows up |
|---|---|---|
| `StarterPack` | Small cash + a squishy or two, cheap | Shop panel, first card |
| `ProPack` | Bigger cash + rarer squishies | Shop panel, second card |
| `ItemsOnly` | Squishies, no cash | Shop panel |
| `CashOnly` | Cash bundle | Shop panel |
| `Random` | One random squishy dropped on your base | HUD, right-hand "Random" button |
| `WheelSpins3` | +3 wheel spins | Wheel panel, first Robux button |
| `WheelSpins9` | +9 wheel spins | Wheel panel, second Robux button |
| `CarryUpgrade` | Instantly buy the next Carry level | Upgrades panel, Carry card |
| `RebirthSkip` | Skip the cash cost of the next rebirth | Rebirth panel, "Skip" button |
| `Steal` | Take one squishy off another player's plot, keeping its level and variant | "Steal" prompt on other players' placed squishies |

## 2. Game Passes — one-time perks
Create at **Monetization → Passes**. These need a `Config.Passes` table (I'll add
it when the IDs exist) and a little gameplay work behind each one:

| Suggested pass | What I'd wire it to |
|---|---|
| Slap Protection | Giants notice you but never land a slap (reference shows this as a base-side purchase) |
| Lock Base | Blocks other players stealing from your base — **needs the stealing feature built first** |
| Auto Collect | Collect pads pay out on their own, no walking over them |
| 2x Money | A permanent multiplier stacked on top of rebirths |
| Extra Slots | Starts you with more unlocked plot slots |

## 2b. Import the three giant meshes — the only thing stopping them looking right

The three large enemies now have their own models, staged in the repo:

| Folder | Import as | Used by |
|---|---|---|
| `Assets/green-ghost/base.obj` | `GreenGhost` | Green Ghost |
| `Assets/spooky-dumpling/base.obj` | `SpookyDumpling` | Spooky Dumpling |
| `Assets/pink-monster/base.obj` | `PinkMonster` | Pink Monster |

Rojo cannot sync a `.obj` — geometry has to be uploaded through Studio, the
same way the collectable squishies were. For each one:

1. **Stop any playtest first.** Anything created while playing is thrown away.
2. Studio → **Avatar → Import 3D** (or Asset Manager → Meshes → Add).
3. Pick the `base.obj`. Leave "Import with textures" on — the `texture.png`
   beside it is wired up in `base.mtl`, so it comes in automatically.
4. Drag the result into **`ReplicatedStorage.SquishyMeshes`** and rename it to
   exactly the name in the table above. A Model wrapper is fine, including one
   Studio split into several MeshParts.
5. **Ctrl+S.**

Until then each giant falls back to a plain primitive and prints a line in the
Output naming the template it wants — the game runs, it just looks wrong.

Two things worth knowing:

- **If one faces backwards**, flip its `yaw` in `MESH_SHAPES`
  (`src/shared/SquishyModels.luau`) between `0` and `180`. I set all three to
  `180`, which is right for most of the existing imports, but I could not check
  these without the meshes in the place.
- **Triangle counts** are 10.3k / 17.7k / 17.3k, all under Roblox's 21k
  per-MeshPart limit, so none of them need decimating.

## 3. Images — DONE
The Free Icon Pack 3.0.1 (Basic) you sent has been uploaded to your account and
wired in: see `tools/upload_icons.md` for which asset id came from which file,
and `Config.Icons` for the ids themselves.

That covers the house marker, the padlock and the shield rows that used to be
listed here. `Calendar`, `Star` and `Coil` are uploaded and staged but not drawn
anywhere yet — they are waiting on the daily-rewards HUD button, the event board
and the speed-coil gear respectively.

Nothing further is needed from you for images unless you want art the pack does
not cover (field stalls and machines are still built from parts, which read fine
at distance).

## 3b. Enable DataStores
Daily-login streaks are the one thing that must survive a session, so they use
a DataStore. In Studio, tick **Game Settings > Security > Enable Studio Access
to API Services** or streaks stay session-only while you test (the game still
runs; it warns once). Nothing to do on a live server.

## 4. Optional
- **Published place ID** — lets me test with more than one player (plot claiming,
  stealing, the leaderboard) instead of Studio solo play.
- **Group ID** — if the game should live under a group rather than your account.

---

## What I do NOT need
- Squishy models — already ported from your Squishy Clicker place
  (`Assets/SquishyMeshes.rbxm`, 15 templates).
- UI — the Essential UI Pack is in the repo (`Assets/MainUi.rbxm`).
- Player avatars on base signs — fetched at runtime with
  `Players:GetUserThumbnailAsync`, no upload needed.
