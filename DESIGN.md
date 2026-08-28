# DONT WAKE THE SQUISHY! — Architecture Contract

This file is the **binding contract** for all modules. If code disagrees with this doc, the code is wrong.

## Concept
"Don't Wake the Brainrots"-style game. A central **field** is full of sleeping collectable
**squishies** (blob plushies) of varying rarity. Two **giant enemy squishies** patrol the field
asleep; each has a notice radius (larger if you're carrying). Wake one and it chases you and
slaps you: you get flung and drop your carried squishy. Carry squishies back to your **plot**
(safe zone) and deposit them on slots; each placed squishy accrues $/s onto a green collect pad
that the owner touches to collect. Rarity means higher income but a stronger carry slowdown.

## Rojo layout (already mapped, do not change)
- `src/shared`  -> `ReplicatedStorage.Shared` (ModuleScripts)
- `src/server`  -> `ServerScriptService.Server` (init.server.luau + sibling ModuleScripts as children)
- `src/client`  -> `StarterPlayer.StarterPlayerScripts.Client` (init.client.luau + sibling ModuleScripts as children)

Server modules are required as `script.ModuleName` from `init.server.luau`.
Client modules are required as `script.ModuleName` from `init.client.luau`.
Shared is `ReplicatedStorage:WaitForChild("Shared")`.

## Files & owners
Already written (spine — do NOT rewrite, only read):
- `src/shared/Config.luau`        — all tuning data (rarities, squishy catalog, enemies, plot, field)
- `src/shared/Util.luau`          — formatMoney, weightedRandom, xz distance helpers
- `src/shared/SquishyFactory.luau`— builds a squishy Model from a catalog name
- `src/shared/SquishyModels.luau` — 3D visuals: mesh templates + primitive fallbacks (clicker port)
- `src/server/init.server.luau`   — creates Remotes, builds map, Start()s services in order
- `src/client/init.client.luau`   — waits for shared, Start()s UI modules

To implement:
- `src/server/MapBuilder.luau`    — static world: field, walkway, plots ring positions, waypoints
- `src/server/EconomyService.luau`— leaderstats + Money attribute + AddMoney
- `src/server/PlotService.luau`   — plot claiming/building, slots, deposit, income accrual, collect pads
- `src/server/SquishyService.luau`— field spawning, pickup/carry/drop, walkspeed ownership
- `src/server/EnemyService.luau`  — 2 giants: patrol, notice, chase, slap
- `src/client/Hud.luau`           — top-center money HUD
- `src/client/AlertUi.luau`       — chase warning vignette + carry slowdown indicator
- `src/client/Popups.luau`        — floating "+$X" world popups from the Popup remote

## Server service pattern
Every server module returns a table with `Start(services, map)`.
`init.server.luau` does:
```lua
local services = {}
services.Config        = Config                     -- shared config module
services.EconomyService = require(script.EconomyService)
services.PlotService    = require(script.PlotService)
services.SquishyService = require(script.SquishyService)
services.EnemyService   = require(script.EnemyService)
local map = require(script.MapBuilder).Build()
services.EconomyService.Start(services, map)
services.PlotService.Start(services, map)
services.SquishyService.Start(services, map)
services.EnemyService.Start(services, map)
```
Never `require` sibling services from each other — always go through the `services` table
passed to `Start` (avoids require cycles). Keep a local reference from Start.

## The `map` table (returned by `MapBuilder.Build()`)
```lua
{
  root: Folder,                -- Workspace.Map (all static geometry inside)
  squishyFolder: Folder,       -- Workspace.Squishies (field squishies live here)
  enemyFolder: Folder,         -- Workspace.Enemies
  plotFolder: Folder,          -- Workspace.Plots
  fieldCenter: Vector3,        -- center of field at ground level (y = top of floor)
  fieldSize: Vector2,          -- XZ extents of the field
  isInField: (pos: Vector3) -> boolean,  -- XZ containment test of the field rect
  squishySpawns: { Vector3 },  -- ground positions where field squishies may spawn
  enemyWaypoints: { Vector3 }, -- patrol loop (ordered, ground positions)
  enemySpawns: { Vector3 },    -- exactly 2, ground positions
  plotSpots: { CFrame },       -- 8 CFrames; position = plot center at ground, LookVector faces the field
}
```
"Ground position" means y is the **top surface** of the floor there; models are pivoted so
their base sits at that y.

## World conventions
- Ground plane: baseplate top at y = 0. Field floor & walkway are 1-stud slabs (centered y = 0.5,
  top at y = 1). All gameplay happens on top of these (y = 1).
- Field: `Config.Field.Size` (200 x 200) centered at origin, bright green slab. The walkway ring
  around it (`Config.Field.WalkwayWidth`) is the safe zone; plots sit on the outside of the ring.
- MapBuilder must reuse/recolor the existing `Workspace.Baseplate` if present (do not delete),
  and move the existing `Workspace.SpawnLocation` onto the south walkway (create one if missing).
- Everything MapBuilder creates goes under `Workspace.Map` except the three empty folders
  (`Squishies`, `Enemies`, `Plots`) which are direct children of Workspace.
- All static parts: Anchored = true. Use Enum.Material.SmoothPlastic unless noted.

## Attributes (the cross-boundary data plane — client reads these, server writes)
Player attributes:
- `Money: number` — mirror of leaderstats Money (EconomyService owns)
- `Carrying: string?` — squishy display name while carrying, else nil (SquishyService owns)
- `CarrySpeedMult: number?` — active speed multiplier while carrying, else nil (SquishyService owns)

Squishy Model attributes (set by SquishyFactory / SquishyService / PlotService):
- `SquishyName: string`, `Rarity: string`, `Income: number`, `SpeedMult: number`, `Scale: number`
- `State: string` — "Sleeping" | "Carried" | "Placed"

Enemy Model attributes (EnemyService owns):
- `EnemyName: string`
- `State: string` — "Sleeping" | "Chasing" | "Returning"
- `TargetUserId: number` — UserId while chasing, else 0

## Remotes
`init.server.luau` creates `ReplicatedStorage.Remotes` (Folder) containing:
- `Popup: RemoteEvent` — server fires `FireClient(player, amount: number, worldPos: Vector3)`
  whenever that player collects money. Client renders a floating "+$X" at worldPos.

## Cross-service API (exact signatures)
EconomyService:
- `Start(services, map)`
- `AddMoney(player: Player, amount: number)` — updates leaderstats + attribute. Floors to int.
- `GetMoney(player: Player) -> number`
- `TrySpend(player: Player, amount: number) -> boolean` — deduct if affordable, else false.

SquishyService:
- `Start(services, map)` — starts the field spawn loop and pickup prompt handling.
- `IsCarrying(player: Player) -> boolean`
- `TakeCarriedDef(player: Player) -> table?` — if carrying: destroys the carried model, restores
  walkspeed, clears attributes, and returns the catalog def table (`Config`-shaped, see below).
  Returns nil if not carrying. Called by PlotService on successful deposit.
- `ForceDrop(player: Player)` — if carrying: detach the model, re-anchor it at the player's
  position snapped to ground (y = 1), set State = "Sleeping", re-enable its ProximityPrompt,
  parent it to `map.squishyFolder` (it can be picked up again; it does NOT count against the
  field spawn cap when re-dropped — keep tracking simple: dropped squishies just stay in the
  folder and are pickupable). Restores walkspeed + clears attributes. Called by EnemyService
  on slap, and internally on death/leave.
- Walkspeed rule: SquishyService is the ONLY writer of `Humanoid.WalkSpeed`
  (`Config.Player.WalkSpeed * SpeedMult` while carrying, base otherwise). EnemyService stuns
  via `Humanoid.PlatformStand`, never via WalkSpeed.

PlotService:
- `Start(services, map)` — claims plots on PlayerAdded, builds plot structures, runs the income
  accrual loop, handles deposit zones, collect pads, and slot-unlock pads.
- `GetPlotOrigin(player: Player) -> CFrame?` — the claimed plot spot CFrame (for respawn etc.)

EnemyService:
- `Start(services, map)` — builds both enemies from `Config.Enemies`, runs patrol/notice/chase.

## Squishy catalog def shape (from `Config.Squishies` entries)
```lua
{ name: string, rarity: string, color: Color3, sparkle: boolean, shape: string, scale: number? }
```
The roster is ported from the user's Squishy Clicker game (its `src/shared/Squishies.luau` is
canon — 38 squishies (33 base + 5 Giant editions), rarities Common/Uncommon/Rare/Epic/Legendary/**Mythical**). `shape` picks
a builder in `src/shared/SquishyModels.luau` (ported from the clicker's Models.luau): a mesh
template cloned from `ReplicatedStorage.SquishyMeshes` when present (extracted from the
clicker's place file into `Assets/SquishyMeshes.rbxm`; loadable via
`game:GetObjects("rbxasset://SquishyMeshes.rbxm")` after copying it into Studio's content
folder), else a part-built primitive fallback. `SquishyModels.build(spec) -> (Model, height)`
returns an invisible anchored "Body" PrimaryPart box with all visual parts welded to it.
Income/speedMult/rarity color come from `Config.Rarities[rarity]`. `SquishyFactory.create(name)`
adds billboards/prompt/attributes on top and returns a ready Model (anchored, State =
"Sleeping", prompt enabled). Look at `src/shared/SquishyFactory.luau` for the exact tree.

## Gameplay rules of record
1. Pickup: ProximityPrompt (hold) on a squishy with State = "Sleeping". Server verifies the
   player is not already carrying. Carried squishy: unanchored, massless, welded ~2 studs above
   the character's head, all its parts CanCollide/CanQuery/CanTouch = false, prompt disabled,
   State = "Carried". WalkSpeed = base * SpeedMult.
2. Deposit: player touches their OWN plot's deposit pad while carrying -> PlotService calls
   `SquishyService.TakeCarriedDef(player)`, places a fresh display squishy (via SquishyFactory,
   prompt disabled/removed, anchored, State = "Placed") on the next FREE UNLOCKED slot. If all
   unlocked slots are full, deposit is refused (leave the player carrying; optional: brief
   red flash on the pad).
3. Income: every `Config.Plot.AccrueTick` seconds each occupied slot accrues
   `income * elapsed` into that slot's pending pool; its green collect pad shows the formatted
   pending amount on a readable label. Owner touches the pad -> `EconomyService.AddMoney`,
   pool resets to 0, fire the Popup remote at the pad position.
4. Slot unlocking: slots 1..StartUnlocked are free. The next locked slot shows its price on a
   dimmed pad; owner touches it -> `EconomyService.TrySpend` -> unlock permanently (this session).
   Only the NEXT locked slot is purchasable (one at a time, in order).
5. Enemies: patrol waypoints asleep (slow, Zzz billboard). Notice check: nearest player whose
   character is inside the field AND within `noticeRadius` (or `noticeRadiusCarrying` if that
   player carries). On notice: State = "Chasing", TargetUserId set, chase at chaseSpeed for up to
   `chaseDuration` seconds. Chase ends early if target leaves the field, dies, or is slapped.
   Within `slapRange`: fling target (`flingSpeed`, up + away), `SquishyService.ForceDrop(target)`,
   brief PlatformStand stun (`stunTime`), then enemy State = "Returning" -> walk to nearest
   waypoint -> after `sleepCooldown` seconds asleep again (cannot notice while Returning or
   during cooldown).
6. Death/leave while carrying: ForceDrop at (or near) where they were. On PlayerRemoving,
   free the plot: destroy the plot structure and its placed squishies.

## Style rules
- Header every file with `--!strict`; be pragmatic — cast with `:: any` where Instance tree
  typing fights you rather than contorting the code.
- No NEW hardcoded asset ids in code (no Sounds/Decals/Meshes from the marketplace). The
  user-owned mesh/texture ids already inside the `SquishyMeshes` templates are fine — they are
  data, not code. Other geometry from Parts, text from Billboard/SurfaceGuis only. Neon
  material for glowy pads.
- No `wait()` — use `task.wait`. No deprecated APIs. Connections to characters/players must be
  cleaned up (store and Disconnect, or use Destroying/AncestryChanged appropriately).
- Never error the whole service on one bad instance: pcall around per-entity work in loops.
- Selene is configured; keep code lint-clean (no unused vars, no shadowing).
- UI text font: Enum.Font.FredokaOne everywhere (bubbly game feel). Money green:
  Color3.fromRGB(85, 255, 85) with black TextStroke.
- Use `Util.formatMoney` for ALL money text (server SurfaceGuis and client HUD alike).

---

# UI Contract (Essential UI Pack — Swarve Studios)

The game's entire interface is the **Essential UI Pack**, owned by the repo as
`Assets/MainUi.rbxm` and synced by Rojo to `StarterGui.MainUi` (a ScreenGui,
ResetOnSpawn = false, IgnoreGuiInset = true). Client code NEVER builds HUD
geometry: it finds nodes in this tree and drives them. Panels ship hidden
(`Visible = false`) except `Frames.Notifications`.

To re-extract after editing the pack in Studio: `lune run tools/extract_ui.luau`.

## The tree (paths client code relies on)
```
MainUi (ScreenGui)
  HUD
    Left.Buttons1.{Index,Rebirth,Shop}   -- TextButton; .Text.Text, .Notification (badge)
    Left.Buttons2.{Invite,Wheel}         -- TextButton; Wheel.Text.Text shows "Spin (N)"
    Labels.{Money,Offline}               -- TextLabel
    Drop                                 -- TextButton; .Text.Text
    Right.Random                         -- TextButton; .Text.Text, .Price.Text
  Frames
    Upgrades  .{PowerScrolling,DistanceScrolling}  -- ScrollingFrame + UIListLayout
              .CarryUpgrade.{Buttons.{Money,Robux}, Stats.{Before,After}.Text, Image.Text}
              .Title.{Shop (title label), Close}
    Notifications.Instructions           -- TextLabel (contextual hint line)
    Shop      .Scrolling.{StarterPack,ProPack,ItemsOnly,CashOnly}  -- Robux packs
    Rebirth   .{Rebirth,Skip} buttons, .Frame.{Bar.{Progress,Text}, Stats.{Before,After}, RebirthBoost}
    Index     .Scrolling (UIGridLayout), .Buttons.{Normal,Golden,Diamond}
    Wheel     .SpinWheel.Pattern.{1..6}, .Buttons.{SpinButton,RobuxButton1,RobuxButton2}, .RedArrow, .Close
  Effect.{Image1..Image4}                -- screen-edge vignette (red pulse while chased)
```
Every panel's `Title.Close` (and `Wheel.Close`) closes it. Panel titles are the
`Title.Shop` TextLabel (the pack's name for it — do not rename).

## Client module map
- `src/client/UiRefs.luau` — **foundation.** Resolves the tree once and exposes
  `UiRefs.get() -> refs`, `UiRefs.openPanel(name)`, `UiRefs.closePanel(name)`,
  `UiRefs.togglePanel(name)`, `UiRefs.setBadge(button, shown)`, `UiRefs.bindButton(button, fn)`
  (click + hover pop), `UiRefs.notify(text, seconds)`. Only one panel is open at a
  time. Written by hand; other client modules require it and NEVER search PlayerGui.
- `Hud.luau` — Money (count-up tween), Offline (shows total $/s income), Drop button
  (fires `Remotes.Drop`; visible only while carrying), Random button (hidden until
  a Robux product id exists).
- `AlertUi.luau` — Effect vignette pulses red while an enemy targets you; carry state
  and contextual hints via `UiRefs.notify`.
- `Panels.luau` — wires Left column buttons to panels, Close buttons, Invite button
  (SocialService), and Wheel spin-count badge.
- `IndexUi.luau` — fills `Index.Scrolling` from `Config.Squishies`, greying undiscovered.
- `UpgradesUi.luau`, `RebirthUi.luau`, `WheelUi.luau` — drive their panels from the
  attributes below and fire the remotes.
- `Popups.luau` — unchanged (world-space "+$X").

## Progression services (server)
- `UpgradeService` — `Start(services, map)`, `GetLevel(player, track) -> number`,
  `GetValue(player, track) -> number` (the tuning value at the player's level),
  `TryBuy(player, track) -> boolean`. Tracks: `"Speed" | "Stealth" | "Carry"`.
  Owns player attributes `Upgrade_Speed`, `Upgrade_Stealth`, `Upgrade_Carry` (levels,
  1-based). Rebirth resets them to 1.
- `RebirthService` — `Start`, `GetCount(player) -> number`, `TryRebirth(player) -> boolean`.
  Owns attribute `Rebirths`; multiplies all income via `EconomyService`.
- `WheelService` — `Start`, `GetSpins(player) -> number`, `TrySpin(player) -> number?`
  (returns the winning `Config.Wheel.Rewards` index, or nil). Owns attributes
  `Spins` and `NextSpinAt` (os.time seconds). Grants cash / a squishy delivered to
  the player's plot / a timed speed boost.
- `DiscoveryService` — `Start`, `MarkDiscovered(player, squishyName)`,
  `IsDiscovered(player, squishyName) -> boolean`. Called by SquishyService on first
  pickup. Replicates via the `Discovered` remote.

## New player attributes (server writes, client reads)
- `Upgrade_Speed`, `Upgrade_Stealth`, `Upgrade_Carry` — numbers, 1-based levels
- `Rebirths` — number
- `Spins` — number; `NextSpinAt` — os.time() when the next free spin lands
- `SpeedBoost` — active multiplier from the wheel (nil/1 when none)

## New remotes (`ReplicatedStorage.Remotes`)
- `Drop: RemoteEvent` — client→server, drop the carried squishy where you stand
- `BuyUpgrade: RemoteEvent` — client→server `(track: string)`
- `DoRebirth: RemoteEvent` — client→server
- `Spin: RemoteFunction` — client→server, returns the winning reward index or nil
- `Discovered: RemoteEvent` — server→client `(names: {string})` full set on join,
  and `(name: string)` on each new discovery (client accepts both shapes)

## Cross-service effects of upgrades (who applies what)
- **Speed / Carry**: `SquishyService` remains the ONLY writer of `Humanoid.WalkSpeed`.
  Base = `UpgradeService.GetValue(player, "Speed")` (not `Config.Player.WalkSpeed`),
  times `SpeedBoost` if set. While carrying, multiply by the drag-adjusted rarity
  penalty: `1 - (1 - rarity.speedMult) * UpgradeService.GetValue(player, "Carry")`.
- **Stealth**: `EnemyService` multiplies its notice radii by
  `UpgradeService.GetValue(player, "Stealth")` per candidate player.
- **Rebirth multiplier**: `EconomyService.AddMoney` applies it (single choke point),
  so pads/wheel/all sources scale together.

## Monetization (parked — needs the user's Creator Dashboard)
`Shop` packs, the `Random` button, and the Wheel's Robux buttons need real
developer-product ids. `Config.Products` holds them; while an id is 0 the client
HIDES that button/pack. No code guesses ids.
