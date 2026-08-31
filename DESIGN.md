# DONT WAKE THE SQUISHY! — Architecture Contract

This file is the **binding contract** for all modules. If code disagrees with this doc, the code is wrong.

## Concept
"Don't Wake the Brainrots"-style game. A central **field** is full of sleeping collectable
**squishies** (blob plushies) of varying rarity. Three **giant enemy squishies** patrol the field
asleep; each has a notice radius (larger if you're carrying). Wake one and it chases you and
slaps you: you get flung and drop your carried squishy. Carry squishies back to your **plot**
(safe zone) and stand them on pedestals; each placed squishy accrues $/s onto a green collect pad
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
- `src/server/PlotService.luau`   — plot claiming/building, slots, placing, income accrual, collect pads
- `src/server/SquishyService.luau`— field spawning, pickup/carry/drop, walkspeed ownership
- `src/server/EnemyService.luau`  — 3 giants: patrol, notice, chase, slap
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
  enemySpawns: { Vector3 },    -- one per Config.Enemies entry, spread round the patrol ring
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
- Ground outside the arena is `Workspace.Map.Ground`: slabs (top at y = 0) laid with a hole
  under each base, so the basements have somewhere to be. It is derived from the plot spots
  and rebuilt every start, hand-edited map or not. The holes stop at each base's inner wall
  face, so the ground runs under the outer walls and leaves no rim to fall down.
- MapBuilder must reuse/recolor the existing `Workspace.Baseplate` if present (do not delete
  or move it), then stand it down — CanCollide, CanQuery and CanTouch off, Transparency 1 —
  once the ground slabs are in. CanQuery matters: a merely non-collidable plate still answers
  raycasts, and every "where is the floor" cast would find a phantom surface at y = 0.
- A base is centred on its plot spot, so a spot nearer the field than half the base depth puts
  the building on the walkway. MapBuilder pushes any such spot back out along its own facing;
  hand-placed markers go stale this way whenever `Config.Plot.BaseSize` changes.
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
  Returns nil if not carrying. Called by PlotService when a squishy is placed.
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
  accrual loop, handles placing, collect pads, and slot-unlock pads.
- `GetPlotOrigin(player: Player) -> CFrame?` — the claimed plot spot CFrame (for respawn etc.)

EnemyService:
- `Start(services, map)` — builds every entry in `Config.Enemies`, runs patrol/notice/chase.

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
2. Placing: the owner holds E at the pedestal they want (`PlacePrompt`, enabled only while
   that slot is unlocked and empty) -> PlotService calls `SquishyService.TakeCarriedDef(player)`
   and stands a fresh display squishy (via SquishyFactory, prompt removed, anchored,
   State = "Placed", turned 180 degrees) on THAT slot. Which slot is the player's choice —
   there is no deposit pad and nothing auto-fills the next free one.
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
- `DailyUi.luau` — the seven-day login panel. The pack ships no daily frame, so this
  one **clones `Frames.Index`**, strips its content and keeps the shell (`Stroke`,
  `Ratio`, `Title`). Cloning is deliberate: the frame, the nine-sliced blue title bar
  and the Close button are then the pack's own art. Any new panel that the pack does
  not ship should be built the same way — a hand-styled approximation is what made
  this one the odd menu out.
- `Popups.luau` — unchanged (world-space "+$X").
- `EnemyBounce.luau` — the giants' hop animation. The server leaves each giant's
  `BodyWeld` at identity and this module writes its C0 every render frame,
  because a server-written Weld.C0 reaches players as ~20Hz uninterpolated
  property snaps while a locally written one is per-frame smooth. Cadence is
  distance-based from actual root displacement (smoothed ~0.1s); sleep-walking
  giants hop, stationary sleepers breathe, stationary awake giants ease down —
  and the stationary branches CONVERGE on their target rather than assign it,
  so a giant stopping mid-hop never snaps.

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

---

# Map Design Contract (reference-matched build)

The look is matched to the reference screenshots of the genre leader. Anything
here overrides earlier world-convention notes it contradicts.

## The arena
Seen from above: a bright green grass field, ringed on the inside by a wide
**brown dirt border**, enclosed by **tall dark boundary walls**, under a night
sky. Bases sit in rows outside the field, facing in.

- `Config.Field.Size` grows to 240 x 200. Grass floor top stays y = 1.
- **Dirt border**: a `Config.Field.DirtWidth` (18) ring of brown mulch INSIDE
  the field bounds, hugging the wall. Purely visual — `isInField` and the
  squishy spawn grid still use the full field rect, and squishies may sit on it.
- **Boundary wall**: 14 studs tall, dark charcoal, around the outside of the
  walkway, with a gap at each plot so players walk straight into their base.
- **Walkway** stays the safe ring between field and bases.
- `plotSpots` becomes **4 along the south edge and 4 along the north**, evenly
  spaced across the field width, each facing the field (perpendicular, never
  angled). This is the reference's row-of-bases look.
- **Safe zone markings**: a translucent light strip on the walkway in front of
  each base, plus a "SAFE ZONE" SurfaceGui on the walkway floor.
- **Field props** (decor only, all `CanCollide` where sensible, none inside the
  squishy spawn grid): a few market stalls (post + striped awning + counter),
  a tall "TOP TIME" leaderboard sign near the middle of one edge, and a glowing
  portal frame. Props must not block walking lanes or sit within 10 studs of a
  spawn point.

## A base (what PlotService builds per player)
An enclosed building, open at the front toward the field:

- **Floor**: grey slab, top at 1.2.
- **Side + back walls**: dark charcoal, 14 studs tall, white trim strip along
  the top edge. The back wall's INNER face is warm orange (a thin coloured
  panel), matching the reference interior.
- **Window openings**: two on each side wall — a white frame with a dark
  translucent pane, non-collidable.
- **Roof**: a flat dark slab over the whole footprint.
- **Ceiling lights**: four white Neon panels on the roof's underside, each with
  a `PointLight` (Brightness ~1.6, Range ~26).
- **House marker**: a stylised house floating above the roof, built from parts
  (orange body, red wedge roof, white door + blue window), bobbing gently and
  spinning slowly. This replaces the reference's UI house icon — no image asset.
- **Owner sign**: an orange board on the front-left of the base carrying the
  owner's avatar via `Players:GetUserThumbnailAsync` (Size48x48, HeadShot) on an
  ImageLabel in a SurfaceGui, with their display name under it. Wrapped in
  pcall + task.spawn — a thumbnail fetch yields and must never block the build.
- **Slot platforms**: grey squares with a lighter border, in the 2-row grid the
  gameplay already uses.
- **Collect pads** keep their gameplay behaviour but render as flat rounded
  green pads (a cylinder is fine) sitting just above the floor.
- **Spawn point**: an invisible anchored part named `SpawnPoint` at the front
  centre of the base floor, ~4 studs in from the front edge.

## Spawning
Players spawn **at their own base**, every time — first join and every respawn.
- `PlotService.GetSpawnCFrame(player) -> CFrame?` returns that base's spawn
  point (facing out toward the field).
- `SpawnService` (new, started last) waits for the plot to exist, then pivots
  the character there on every `CharacterAdded`, and re-pivots once if the
  character is still at the default spawn a moment later.
- The world `SpawnLocation` stays (Roblox needs one) but is parked under the
  map, `Neutral`, and out of the way; it is only where a character materialises
  for the instant before SpawnService moves it.

## Lighting — COZY (supersedes the earlier night rig)
The art direction is the soft, milky, evenly-lit pastel world of ASMR obby
games. `LightingService` owns it: midday `ClockTime`, modest `Brightness` with a
very high pastel `Ambient` (the fill, not the sun, does the lighting, which is
what flattens shadows into plush shading), a dense warm-pink `Atmosphere` so
distance melts into candy floss, gentle `Bloom`, and a `ColorCorrectionEffect`
("CozyGrade") lifting tint toward warm pink with contrast pulled down. No stars,
no celestial bodies. Base ceiling lights stay dim on purpose — the ambient does
the work, and brighter PointLights blow the pale palette out.

All colour lives in `Config.Palette`, which is the whole art direction in one
table: milky pastels and food colours (mint lawn, biscuit border, vanilla and
pale-strawberry checkered walkway, cream walls, frosting-pink roofs, butter slot
tiles, candy pads). Nothing is darker than a soft caramel; text uses
`Palette.Ink`, a soft cocoa, never pure black.

## Hand-edited plot shells

`Workspace.PlotShells` holds one saved base building per spot, put there by
`tools/build_plots_in_studio.luau`. It is the plot equivalent of
`Workspace.Map`'s `HandEdited` switch.

- **`PlotShells` is the source, `Plots` is the runtime folder.** PlotService only
  ever reads `PlotShells` and copies out of it; it never writes there. Keeping
  them apart means a live plot being built, rebuilt or destroyed cannot touch
  what the owner has been editing.
- **The folder leaves the Workspace at server start.** `claimShellFolder()`
  reparents it to `ServerStorage` before the first plot is built. It has to be
  AUTHORED in Workspace — that is the only place you can edit it — but the
  shells stand at the very coordinates the live plots occupy, so left there
  every base renders twice: a static shell z-fighting the live one, its frozen
  "$0" sitting on top of the real collect-pad total. In ServerStorage it is
  still readable for cloning and replicates to nobody.
- **The split is still shell vs furniture.** An adopted shell replaces
  `BaseBuilder.Build` only. PlotService lays its own gameplay pieces (platforms,
  pads, plaques) on top exactly as before, so nothing runtime-owned is editable
  by hand.
- **Storey heights are recomputed, never stored.** A shell records only
  `ShellSpotIndex`, `ShellFloorsAbove`, `ShellFloorsBelow`; `BaseBuilder.Adopt`
  recomputes the floor tops from those. One source of truth, no drift.
- **A shell saved at a different floor count is refused.** Its walls, stairs and
  slabs are cut for the floors it had, so `Adopt` returns nil and the generator
  takes over for that plot. This is why buying a floor drops a plot back to
  generated geometry.
- **Shells are saved unowned**, wearing the vacant sign with no house marker.
  `BaseBuilder.DressForOwner` performs the swap when a plot is claimed — the same
  decision `Build` makes inline from whether a player was passed.

New BaseBuilder API: `ShellAttributes`, `TagShell(model, spotIndex, floors)`,
`Adopt(model, floors) -> BaseShell?`, `DressForOwner(model, baseCFrame, player, floors)`.

## Placing, and what pads no longer do

A carried squishy is placed by **holding E at the pedestal you want**, not by
walking over the deposit pad. The prompt lives on the pedestal's abacus, is
enabled only while its slot is unlocked and empty, and checks ownership and
carrying in its handler (a ProximityPrompt is one shared instance, so per-player
state cannot gate `Enabled`).

`refreshPlacePrompt` must be called anywhere a slot's `unlocked` or `occupied`
changes — placing, unlocking, rebuilding after a floor purchase, and being
stolen from. Missing one leaves a prompt that offers a slot it cannot fill.

There is no deposit pad any more. It had no job left once placing became a
per-pedestal choice, and a labelled pad that does nothing reads as broken.

The upgrade plaque is **click-only**: `CanTouch` is false and there is no
Touched connection, so brushing past a slot can never buy a level by accident.

## Safe zones lift the carry penalty

`SquishyService` polls the strips in `map.safeZones` at 4 Hz and sets the
`InSafeZone` attribute; `applySpeed` skips the carry multiplier while it is
true, and writes `CarrySpeedMult = 1` so the HUD reads "no drag" instead of
going stale.

Polled, not Touched-driven: `Touched`/`TouchEnded` on a thin slab you are
standing still on is unreliable, and being stuck slow (or stuck fast) on the
last stretch home is the worst place for that bug. Eight strips against a few
players a few times a second costs nothing.

`map.safeZones` is resolved from `Workspace.Map`, never from the generator's
scratch folder — on a hand-edited map the generated strips are thrown away and
the saved ones (which the owner may have moved) are the real ones.

## No Zzz on field squishies

`SquishyFactory` builds no "Zzz" billboard: a whole field of them read as
clutter. The giants keep theirs (`EnemyService` builds its own), where it is the
tell that matters. `SquishyService` still toggles a "Zzz" by name on pickup and
re-drop; both sites are nil-guarded, so they are simply no-ops now.

## Display pedestals

Every slot carries an Ionic column (`buildPedestal`, PlotService). Bottom to
top it follows the real order: square plinth, torus/scotia/torus base
mouldings, fluted shaft, then the capital — necking, echinus, two volutes and
the abacus the squishy stands on.

- **It exists to clear the plaque.** A squishy sitting flat on its platform was
  hidden behind the upgrade sign in front of it. `PEDESTAL_HEIGHT` (3.05) is
  what `placeSquishy` adds, and it must stay above the plaque's top edge
  (`PLAQUE_STAND_OFF + UPGRADE_PLAQUE_SIZE.Y` = 2.75 above the platform).
- **Everything is decorative**: `CanCollide`, `CanTouch` and `CanQuery` are all
  off, so a column can never block a player walking onto their own slot.
- **Cost is 16 parts per slot**, 6 of them flutes. At the 80-slot maximum that
  is 1,280 parts. `FLUTE_COUNT` is the dial if that ever needs trimming — the
  flutes are the least legible detail at play distance.
- Columns stand on locked slots too, so an empty slot reads as a place a
  squishy belongs rather than a bare tile.

## The upgrade plaque is a print, not a board

The plaque part is `Transparency = 1`. Only the rounded card printed on its
front face is meant to read; the part's square edges were showing around and
behind it. The part itself stays for the ClickDetector, the Touched connection
and as a surface for the SurfaceGui to print on.

Because of that, **showing and hiding the plaque is the SurfaceGui's
`Enabled`, never the part's `Transparency`** — setting transparency back to 0
would put the rectangle right back.

## The countdown sign is hand-editable

`Workspace.Map.EventBoard` is built by `tools/build_map_in_studio.luau` (via the
public `EventService.BuildBoard(map)`) so it lives in the saved place. At server
start EventService **adopts a saved board** and only builds one when the place
has none — same rule as a hand-edited map or a saved plot shell.

- Labels are found **by name** (`Event1..EventN`), not by their position in a
  flat list. A saved board may have been moved, re-parented or had a face
  rebuilt by hand, and the old stride-based lookup only held for a board the
  service had just built itself.
- A saved board missing an `EventN` label warns and names what is missing, so a
  countdown with nowhere to draw is never silent.
- Deleting `Workspace.Map.EventBoard` gets a freshly generated one back.

## Icons (`Config.Icons`)

Every icon the game draws is a Roblox asset id, never a file path — a local PNG
cannot be referenced at runtime. The ids live in `Config.Icons` and their
provenance is recorded in `tools/upload_icons.md`.

Rules:
- **Never inline an `rbxassetid://` in a builder or UI module.** Add a key to
  `Config.Icons` and reference it, so one upload swap updates every use.
- Icons are drawn untinted (`ImageColor3` white) so the pack's own colour and
  black outline come through. `ImageColor3` is reserved for *state* — the
  upgrade plaque greys its arrow with it when the owner cannot afford a level.
- Use `ScaleType = Fit`, never `Stretch`: the pack's art is square and
  stretching it breaks the outline weight.
- A billboard is not a face of its part. When a part is hidden by setting
  `Transparency = 1`, any billboard on it must be switched off separately
  (`gui.Enabled = false`) or the icon hangs in mid-air — see the next-floor post.

Who draws what:

| Key | Drawn by |
|---|---|
| `Upgrade` | the arrow on the podium upgrade plaque (`PlotService`) |
| `House` | the marker floating over every base, and the vacant-plot sign (`BaseBuilder`) |
| `Lock` | slot unlock pads and the next-floor post (`PlotService`) |
| `Cash`, `Wheel`, `Gift` | the seven daily reward cards, one per reward kind (`DailyUi`) |
| `Calendar`, `Shield`, `Star`, `Coil` | uploaded and staged, not drawn yet |

## Still parked (needs the user)
Icon-based UI props in the reference (Slap Protection shield, Lock Base padlock,
gear/shop item art) need uploaded image assets and gamepass ids; they are NOT
faked with lookalike geometry.
