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

## 2b. Giant meshes — IMPORTED, one step left to make them permanent

The three large enemies have their own models. You imported and named them, and
they are now in `ReplicatedStorage.SquishyMeshes` and rendering correctly:

| Source in the repo | Template name | Mesh / texture asset |
|---|---|---|
| `Assets/green-ghost/` | `GreenGhost` | `104001572591103` / `93678723116153` |
| `Assets/spooky-dumpling/` | `SpookyDumpling` | `87444205075691` / `122549821882584` |
| `Assets/pink-monster/` | `PinkMonster` | `137076139008417` / `71222483245165` |

**They are not safe yet.** `ReplicatedStorage.SquishyMeshes` is Rojo-managed —
`default.project.json` maps it to `Assets/SquishyMeshes.rbxm`, which still holds
only the original 15. The next time Rojo syncs that file it replaces the whole
folder and the three giants vanish, back to fallback primitives.

To make them permanent, export the folder back into the repo:

1. In Studio, right-click **`ReplicatedStorage.SquishyMeshes`**.
2. **Save to File...**
3. Overwrite `Assets/SquishyMeshes.rbxm` in this repo.
4. Commit it.

That has to be Studio's own export. A mesh is two uploaded asset ids, and the
obvious shortcut — rebuilding the `.rbxm` offline from those ids with Lune —
does not work: Lune's `MeshPart` has no `MeshId` property, so it silently
writes templates with no geometry at all. I tried it, checked the output, and
threw it away; the file in the repo is untouched.

Once the `.rbxm` has all 18, a clean clone builds the giants with no manual
import, and re-importing is never needed again.

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
