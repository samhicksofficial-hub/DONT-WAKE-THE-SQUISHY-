# Assets & IDs needed from the account owner

Everything in the game today is built from parts, text and code — it runs with
none of this. This list is what would take it the last step toward the
reference look and switch on the parked monetization.

Each row says **where the number goes**. Send them over (or paste them straight
into `src/shared/Config.luau`) and the matching feature turns itself on.

---

## 1. Monetization — DONE (ids live in `Config`)
All 19 developer products and passes were created on the Creator Dashboard
under the group experience (placeId `118499294741014`) on 2026-09-11 and wired
into `Config.Products` / `Config.Passes`. Each id was matched back to its key by
`GetProductInfo` name lookup, not by list order. The Robux **price** lives only
on the Dashboard — the client shows whatever `GetProductInfo` reports live, so
re-pricing needs no code change.

**Developer products** (`Config.Products`):

| Config key | Sells | ID |
|---|---|---|
| `StarterPack` | $100k + Gold Epic + 5 spins | 3712212383 |
| `SleepAll` | every Evil Squishy sleeps 60s | 3712212440 |
| `ServerLuck` | 15 min rarer spawns, whole server | 3712212497 |
| `SlapProtection` | 15 min slap immunity | 3712212545 |
| `BaseLock` | 15 min laser wall | 3712212612 |
| `Steal` | take one squishy (Base Lock blocks it) | 3712212718 |
| `Boost2x` | 30 min double income | 3712212745 |
| `CashSmall` | $50k | 3712212790 |
| `CashMedium` | $500k | 3712212830 |
| `CashLarge` | $5M | 3712212884 |
| `CashHuge` | $5B | 3712212953 |
| `CashMega` | $50B | 3712213026 |
| `WheelSpins3` | +3 spins | 3712213102 |
| `WheelSpins9` | +9 spins | 3712213149 |

**Game passes** (`Config.Passes`):

| Config key | Grants | ID |
|---|---|---|
| `VIP` | 1.5x income forever | 1979522326 |
| `PermanentSpeed` | +6 walkspeed forever | 1976582557 |
| `SpeedCoil` | the coil, basement stand | 1975100605 |
| `Glock` | the Block-17 pistol (the Roblox pass is already named "Block-17" — matches) | 1978712402 |
| `Knight` | bodyguard, basement stand | 1976768555 |

`SlapHand` stays parked at `0` on purpose: everyone gets the slap hand free as
default kit, so a pass for it would sell nothing.

**Price note (2026-09-11):** the base prices set on the Dashboard are the
intended ones (Knight 599, VIP 199, $50B 2599, etc.) — no change needed.
`GetProductInfo` returns TWO fields: `UserBasePriceInRobux` (the base, what a
normal player pays) and `PriceInRobux` (already reduced by the 10% Roblox
Premium discount, and returned that reduced value to EVERYONE — a no-Premium
server reads it too). The UI must display the base, so `Util.robuxPrice` prefers
`UserBasePriceInRobux`; every price-display site uses it. Premium members still
get their discount applied by Roblox at the purchase prompt.

## 2b. Imported meshes — IN THE PLACE, one export left to make them permanent

Several meshes now live in `ReplicatedStorage.SquishyMeshes` and render
correctly, but they were added to the LIVE place, not to the repo yet:

- The three giants: `GreenGhost`, `SpookyDumpling`, `PinkMonster`.
- `ButterSquishy`, `PugSquishy`.
- The five jelly cubes: `OrangeCubeSquishy`, `PinkCubeSquishy`, `BlueCubeSquishy`,
  `GreenCubeSquishy`, `PurpleCubeSquishy` — all cloned from the one imported
  `jelly_squish_cube` and tinted to each config colour (translucent Glass skin
  over a brighter SmoothPlastic gel core). Added 2026-09-15.

**They are not safe yet.** `ReplicatedStorage.SquishyMeshes` is Rojo-managed —
`default.project.json` maps it to `Assets/SquishyMeshes.rbxm`, which still holds
only the original 15. The next time Rojo rebuilds that folder from the file (a
reconnect after a Studio restart) it replaces the whole folder and every mesh
above vanishes back to fallback primitives.

To make them permanent, export the folder back into the repo:

1. In Studio, right-click **`ReplicatedStorage.SquishyMeshes`**.
2. **Save to File...**
3. Overwrite `Assets/SquishyMeshes.rbxm` in this repo.
4. Commit it.

That has to be Studio's own export. A mesh is uploaded asset ids, and the
obvious shortcut — rebuilding the `.rbxm` offline from those ids with Lune —
does not work: Lune's `MeshPart` has no `MeshId` property, so it silently
writes templates with no geometry at all.

Once the `.rbxm` holds all of them, a clean clone builds every squishy with no
manual import, and re-importing is never needed again.

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
