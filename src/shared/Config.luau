--!strict
-- Shared tuning values for Don't Wake the Squishy.
-- Anything both the server and the client need to agree on lives here.
-- The squishy roster and rarities are ported from the user's Squishy Clicker
-- game (Squishy-Clicker-Roblox/src/shared/Squishies.luau) so both games share
-- one canon. `shape` keys map to SquishyModels builders / mesh templates in
-- ReplicatedStorage.SquishyMeshes. See DESIGN.md for how these are consumed.

local Config = {}

Config.GameName = "DONT WAKE THE SQUISHY!"

Config.Player = {
	WalkSpeed = 16,
}

-- Ordered from most to least common. `weight` drives the field spawn roll
-- (clicker odds: out of 1000). `income` is $ per second for a placed squishy.
-- `speedMult` multiplies WalkSpeed while carrying.
Config.Rarities = {
	-- `alertMult` scales an enemy notice radius while you carry one of these:
	-- a Common is barely noticed, a Mythical wakes the whole field.
	{ name = "Common",    color = Color3.fromRGB(148, 155, 164), income = 1,     speedMult = 0.92, weight = 550, alertMult = 1.0 },
	{ name = "Uncommon",  color = Color3.fromRGB(96, 190, 120),  income = 8,     speedMult = 0.80, weight = 250, alertMult = 1.3 },
	{ name = "Rare",      color = Color3.fromRGB(88, 148, 235),  income = 40,    speedMult = 0.66, weight = 120, alertMult = 1.8 },
	{ name = "Epic",      color = Color3.fromRGB(168, 110, 235), income = 250,   speedMult = 0.50, weight = 55,  alertMult = 2.6 },
	{ name = "Legendary", color = Color3.fromRGB(240, 165, 60),  income = 1500,  speedMult = 0.38, weight = 20,  alertMult = 6.0 },
	{ name = "Mythical",  color = Color3.fromRGB(240, 95, 150),  income = 10000, speedMult = 0.28, weight = 5,   alertMult = 10.0 },
}

-- Fast lookup by rarity name (built below).
Config.RarityByName = {} :: { [string]: any }
for _, rarity in Config.Rarities do
	Config.RarityByName[rarity.name] = rarity
end

-- Size multipliers for squishies whose name promises one (from the clicker).
local MINI = 0.7
local GIANT = 1.45

-- The collectable roster: the full Squishy Clicker catalog.
-- `shape` picks the model builder (mesh template with part fallback);
-- `scale` multiplies the normalized display size (default 1).
Config.Squishies = {
	-- Commons: the classic solid-color dumplings
	{ name = "Red Dumpling",    rarity = "Common",    color = Color3.fromRGB(214, 69, 65),   sparkle = false, shape = "dumplingmesh" },
	{ name = "Pink Dumpling",   rarity = "Common",    color = Color3.fromRGB(247, 168, 195), sparkle = false, shape = "dumplingmesh" },
	{ name = "Blue Dumpling",   rarity = "Common",    color = Color3.fromRGB(94, 156, 222),  sparkle = false, shape = "dumplingmesh" },
	{ name = "Green Dumpling",  rarity = "Common",    color = Color3.fromRGB(139, 197, 96),  sparkle = false, shape = "dumplingmesh" },
	-- Commons: everyday squishies
	{ name = "Stretch Banana",  rarity = "Common",    color = Color3.fromRGB(250, 216, 88),  sparkle = false, shape = "bananamesh" },
	{ name = "Coconut Ball",    rarity = "Common",    color = Color3.fromRGB(196, 228, 200), sparkle = false, shape = "coconutmesh" },
	{ name = "Mini Jelly Cube", rarity = "Common",    color = Color3.fromRGB(242, 150, 62),  sparkle = false, shape = "cubeorange", scale = MINI },
	{ name = "Dough Cloud",     rarity = "Common",    color = Color3.fromRGB(250, 248, 244), sparkle = false, shape = "cloudmesh" },
	{ name = "Butter Stick",    rarity = "Common",    color = Color3.fromRGB(247, 210, 96),  sparkle = false, shape = "buttermesh" },
	{ name = "Strawberry",      rarity = "Common",    color = Color3.fromRGB(219, 58, 62),   sparkle = false, shape = "strawberrymesh" },

	-- Uncommons
	{ name = "White Dumpling",  rarity = "Uncommon",  color = Color3.fromRGB(243, 240, 235), sparkle = false, shape = "dumplingmesh" },
	{ name = "Purple Dumpling", rarity = "Uncommon",  color = Color3.fromRGB(158, 122, 216), sparkle = false, shape = "dumplingmesh" },
	{ name = "Teal Dumpling",   rarity = "Uncommon",  color = Color3.fromRGB(84, 196, 196),  sparkle = false, shape = "dumplingmesh" },
	{ name = "Squeeze Cheese",  rarity = "Uncommon",  color = Color3.fromRGB(245, 196, 54),  sparkle = false, shape = "cheesemesh" },
	{ name = "Swirl Cube",      rarity = "Uncommon",  color = Color3.fromRGB(235, 122, 168), sparkle = false, shape = "cubepink" },
	{ name = "Blue Cube",       rarity = "Uncommon",  color = Color3.fromRGB(138, 200, 240), sparkle = false, shape = "cubeblue" },

	-- Rares
	{ name = "Sky Glitter",     rarity = "Rare",      color = Color3.fromRGB(70, 120, 200),  sparkle = true,  shape = "dumplingmesh" },
	{ name = "Olive Glitter",   rarity = "Rare",      color = Color3.fromRGB(140, 150, 70),  sparkle = true,  shape = "dumplingmesh" },
	{ name = "Glitter Cube",    rarity = "Rare",      color = Color3.fromRGB(112, 218, 122), sparkle = true,  shape = "cubegreen" },
	{ name = "Two-Tone Glitter", rarity = "Rare",     color = Color3.fromRGB(186, 142, 235), sparkle = true,  shape = "cubepurple" },
	{ name = "Boxed Cake",      rarity = "Rare",      color = Color3.fromRGB(246, 204, 158), sparkle = true,  shape = "tub" },
	{ name = "Pug Squishy",     rarity = "Rare",      color = Color3.fromRGB(214, 178, 128), sparkle = false, shape = "pugmesh" },
	{ name = "Ice Cube Squishy", rarity = "Rare",     color = Color3.fromRGB(176, 224, 246), sparkle = false, shape = "icecubemesh" },

	-- Epics
	{ name = "Confetti Pink",   rarity = "Epic",      color = Color3.fromRGB(240, 140, 180), sparkle = true,  shape = "dumplingmesh" },
	{ name = "Rainbow Melt",    rarity = "Epic",      color = Color3.fromRGB(190, 220, 120), sparkle = true,  shape = "dumplingmesh" },
	{ name = "Pink Brain",      rarity = "Epic",      color = Color3.fromRGB(240, 158, 170), sparkle = false, shape = "brainmesh" },
	{ name = "Blobfish",        rarity = "Epic",      color = Color3.fromRGB(122, 170, 230), sparkle = false, shape = "blobfishmesh" },
	-- titleLift: the baby is tall, so the default title height put its name
	-- through the ceiling of a plot storey; this hangs it just over the head.
	{ name = "Sugar Baby",      rarity = "Epic",      color = Color3.fromRGB(230, 120, 198), sparkle = true,  shape = "babymesh", titleLift = 0.7 },
	{ name = "Rainbow Butter",  rarity = "Epic",      color = Color3.fromRGB(196, 124, 220), sparkle = false, shape = "rainbuttermesh" },
	{ name = "Sparkle Drop",    rarity = "Epic",      color = Color3.fromRGB(140, 226, 198), sparkle = true,  shape = "dropmesh" },
	{ name = "Giant Banana",    rarity = "Epic",      color = Color3.fromRGB(250, 216, 88),  sparkle = false, shape = "bananamesh",     scale = GIANT },
	{ name = "Giant Butter Stick", rarity = "Epic",   color = Color3.fromRGB(247, 210, 96),  sparkle = false, shape = "buttermesh",     scale = GIANT },
	{ name = "Giant Strawberry", rarity = "Epic",     color = Color3.fromRGB(219, 58, 62),   sparkle = false, shape = "strawberrymesh", scale = GIANT },

	-- Legendary
	{ name = "Gold Glitter",    rarity = "Legendary", color = Color3.fromRGB(226, 178, 66),  sparkle = true,  shape = "dumplingmesh" },
	-- placeYaw: on a shelf the doughnut's default facing shows its back, so a
	-- placed one turns half a circle further than the standard about-face.
	{ name = "Glow Doughnut",   rarity = "Legendary", color = Color3.fromRGB(132, 244, 120), sparkle = true,  shape = "glowdonutmesh", placeYaw = 180 },
	{ name = "Giant Rainbow Butter", rarity = "Legendary", color = Color3.fromRGB(196, 124, 220), sparkle = false, shape = "rainbuttermesh", scale = GIANT },

	-- Mythical: the big iridescent pearl ones
	{ name = "Opal Dumpling",   rarity = "Mythical",  color = Color3.fromRGB(232, 225, 245), sparkle = true,  shape = "opalmesh" },
	{ name = "Giant Opal Dumpling", rarity = "Mythical", color = Color3.fromRGB(232, 225, 245), sparkle = true, shape = "opalmesh", scale = GIANT },
}

Config.SquishyByName = {} :: { [string]: any }
for _, def in Config.Squishies do
	Config.SquishyByName[def.name] = def
end

-- ---------------------------------------------------------------- variants --
-- A variant is the SAME squishy wearing a rarer coat: it keeps the shape and
-- the rarity, multiplies the income, and gets an unmistakable effect. Rolled
-- independently of which squishy you get, so any squishy can turn up golden.
-- Ordered commonest first; the index shows one page per entry in this order.
--   effect: how SquishyModels dresses it — "none" | "gold" | "rainbow", or a
--           one-coat treatment ("diamond" | "galaxy" | "undead" | "frozen")
--   weight: roll chance against every other variant
--   income: income multiplier
--   color:  the label/tab colour (Rainbow has none: its label stays white and
--           its tab wears a gradient instead of a tint)
Config.Variants = {
	{ name = "Normal",  effect = "none",    weight = 858, income = 1,   prefix = "" },
	{ name = "Gold",    effect = "gold",    weight = 90,  income = 5,   prefix = "Gold ",
		color = Color3.fromRGB(255, 206, 74) },
	{ name = "Diamond", effect = "diamond", weight = 30,  income = 10,  prefix = "Diamond ",
		color = Color3.fromRGB(158, 224, 255) },
	{ name = "Rainbow", effect = "rainbow", weight = 14,  income = 25,  prefix = "Rainbow " },
	{ name = "Galaxy",  effect = "galaxy",  weight = 5,   income = 50,  prefix = "Galaxy ",
		color = Color3.fromRGB(148, 106, 245) },
	{ name = "Undead",  effect = "undead",  weight = 2,   income = 75,  prefix = "Undead ",
		color = Color3.fromRGB(132, 196, 92) },
	{ name = "Frozen",  effect = "frozen",  weight = 1,   income = 120, prefix = "Frozen ",
		color = Color3.fromRGB(196, 238, 255) },
}

Config.VariantByName = {} :: { [string]: any }
for _, variant in Config.Variants do
	Config.VariantByName[variant.name] = variant
end

-- The display name with only the variant WORD coloured — "Gold Olive Glitter"
-- paints "Gold" gold and leaves the squishy's own name in the label's colour.
-- Returns RichText markup, so the label showing it must set RichText = true.
-- Rainbow has no single colour: its word cycles one hue per letter instead.
function Config.richDisplayName(squishyName: string, variantName: string?): string
	local variant = if variantName ~= nil then Config.VariantByName[variantName] else nil
	if variant == nil or variant.prefix == nil or variant.prefix == "" then
		return squishyName
	end
	local word = ((variant.prefix :: string):gsub("%s+$", ""))
	local painted: string
	if variant.name == "Rainbow" then
		local letters = {}
		for i = 1, #word do
			-- 0.85 stops the wheel short of wrapping back round to red.
			local color = Color3.fromHSV(((i - 1) / #word) * 0.85, 0.8, 1)
			letters[#letters + 1] = ('<font color="#%s">%s</font>'):format(color:ToHex(), word:sub(i, i))
		end
		painted = table.concat(letters)
	else
		local color = (variant.color :: Color3?) or Color3.new(1, 1, 1)
		painted = ('<font color="#%s">%s</font>'):format(color:ToHex(), word)
	end
	return painted .. " " .. squishyName
end

-- The two giant patrolling enemies: monstrous versions of real squishies.
-- `shape` + `color` (as tint) feed SquishyModels.build; `scale` is huge.
Config.Enemies = {
	-- The giants have their OWN imported models, so none of them set `tint`:
	-- each keeps the texture it shipped with. `color` is only the fallback
	-- primitive's colour, used until the meshes are imported.
	{
		name = "Green Ghost",
		shape = "ghostmesh",
		color = Color3.fromRGB(126, 226, 148),
		scale = 7,               -- body scale relative to a 1.0-scale squishy
		patrolSpeed = 7,
		chaseSpeed = 17,
		noticeRadius = 28,
		noticeRadiusCarrying = 42,
		chaseDuration = 8,       -- seconds before it gives up
		slapRange = 8,           -- studs from enemy center to target root
		flingSpeed = 70,         -- studs/sec knockback impulse
		stunTime = 1.2,          -- seconds of PlatformStand on the victim
		sleepCooldown = 4,       -- seconds after returning before it can notice again
	},
	{
		name = "Spooky Dumpling",
		shape = "spookymesh",
		color = Color3.fromRGB(196, 186, 216),
		scale = 6,
		patrolSpeed = 8,
		chaseSpeed = 18,
		noticeRadius = 25,
		noticeRadiusCarrying = 38,
		chaseDuration = 7,
		slapRange = 7.5,
		flingSpeed = 78,
		stunTime = 1.2,
		sleepCooldown = 3.5,
	},
	{
		name = "Pink Monster",
		shape = "monstermesh",
		color = Color3.fromRGB(240, 130, 178),
		scale = 5.5,
		patrolSpeed = 9,
		chaseSpeed = 19,
		noticeRadius = 22,
		noticeRadiusCarrying = 34,
		chaseDuration = 6,
		slapRange = 7,
		flingSpeed = 85,
		stunTime = 1.2,
		sleepCooldown = 3,
	},
}

Config.Field = {
	Size = Vector2.new(240, 200),  -- XZ studs, centered at origin
	WalkwayWidth = 26,             -- safe ring around the field
	DirtWidth = 18,                -- brown mulch border inside the field edge
	WallHeight = 14,               -- dark boundary wall around the arena
	SpawnInterval = 4,             -- seconds between field spawn attempts
	MaxSquishies = 26,             -- cap of freshly-spawned field squishies
	SpawnInset = 26,               -- keep spawns this far from the field edge
	SpawnSpacing = 18,             -- grid spacing between candidate spawn points
	WaypointInset = 34,            -- enemy patrol rectangle inset from field edge
}

-- The look, matched to the reference screenshots (see the Map Design Contract
-- in DESIGN.md). Base = one player's enclosed building.
Config.Base = {
	-- Interior height of ONE storey, floor to ceiling. Total wall height is
	-- this times Config.Plot.Floors, so adding a floor makes the building
	-- taller rather than squashing the rooms.
	FloorHeight = 13,
	FloorSlabThickness = 1, -- the slab between storeys
	WallThickness = 1.5,
	RoofThickness = 1.2,
	FloorTop = 1.2,
	TrimHeight = 0.8,      -- white strip along the top of each wall
	WindowWidth = 10,
	WindowHeight = 5,
	WindowSill = 5,        -- height of the window's bottom edge above its floor
	CeilingLights = 4,     -- per storey
	-- Storeys are linked by a climbable wooden ladder against the back wall
	-- (see BaseBuilder). The old staircase ate a seven-stud lane out of every
	-- floor; the ladder needs only a hatch in each slab.
}

-- Cozy / ASMR-obby palette: milky pastels and food colours, nothing darker
-- than a soft caramel. Everything the map builds reads its colour from here,
-- so this table is the whole art direction in one place.
Config.Palette = {
	Grass = Color3.fromRGB(142, 214, 148),        -- soft mint lawn
	Dirt = Color3.fromRGB(226, 176, 124),         -- biscuit crumb border
	Walkway = Color3.fromRGB(250, 234, 240),      -- vanilla icing
	WalkwayAlt = Color3.fromRGB(236, 198, 220),   -- the other checker tile, pale strawberry
	BoundaryWall = Color3.fromRGB(238, 162, 198), -- bubblegum wall
	BaseWall = Color3.fromRGB(246, 222, 210),     -- cream
	BaseTrim = Color3.fromRGB(255, 252, 250),     -- whipped white
	BaseBack = Color3.fromRGB(246, 182, 162),     -- strawberry-milk back wall
	BaseFloor = Color3.fromRGB(240, 222, 234),    -- soft tile
	BaseRoof = Color3.fromRGB(230, 142, 178),     -- pink frosting roof
	SlotPlatform = Color3.fromRGB(255, 226, 150), -- butter tile
	SlotBorder = Color3.fromRGB(228, 190, 140),   -- toasted edge
	CollectPad = Color3.fromRGB(124, 220, 62),    -- vivid grass green, like the reference pads
	UnlockPad = Color3.fromRGB(255, 214, 150),    -- caramel
	SignBoard = Color3.fromRGB(242, 166, 134),    -- peach board
	HouseBody = Color3.fromRGB(255, 214, 130),    -- butter house
	HouseRoof = Color3.fromRGB(238, 130, 156),    -- raspberry roof
	SafeZone = Color3.fromRGB(206, 226, 255),     -- cool pastel blue
	-- The display pedestals. Warm ivory rather than grey marble, so a Greek
	-- column still sits inside the candy palette instead of fighting it.
	PedestalStone = Color3.fromRGB(248, 240, 226),
	PedestalShade = Color3.fromRGB(226, 210, 186), -- the mouldings, a shade deeper
	-- Text and outlines. Never pure black: a soft cocoa keeps the world plush
	-- while still reading clearly on pale boards.
	Ink = Color3.fromRGB(104, 74, 82),
}

-- ---------- progression (drives the Essential UI Pack panels) ----------

-- Upgrade tracks bought with cash. Level 1 is the free starting level, so
-- `prices[n]` is the cost to reach level n + 1. `values[n]` is the effect at
-- level n; the UI shows values[level] -> values[level + 1] as before/after.
Config.Upgrades = {
	-- Left scrolling column in the Upgrades panel.
	Speed = {
		title = "Speed",
		suffix = " spd",
		-- Base walkspeed at each level.
		values = { 16, 18, 20, 22, 24, 26, 28, 30 },
		prices = { 250, 1200, 6000, 30000, 150000, 800000, 4000000 },
	},
	-- Right scrolling column.
	Stealth = {
		title = "Stealth",
		suffix = "% notice",
		-- Multiplier applied to every enemy's notice radius.
		values = { 1.0, 0.92, 0.85, 0.78, 0.7, 0.62, 0.55, 0.45 },
		prices = { 400, 2000, 9000, 45000, 220000, 1100000, 6000000 },
	},
	-- The wide CarryUpgrade card at the bottom: shrinks the rarity carry
	-- penalty, so `effective = 1 - (1 - speedMult) * values[level]`.
	Carry = {
		title = "Carry",
		suffix = "% drag",
		values = { 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3 },
		prices = { 500, 2500, 11000, 55000, 260000, 1300000, 7000000 },
	},
}

-- ------------------------------------------------------- squishy levelling --
-- A placed squishy earns more the more you feed it. Income at level L is
-- `base * growth^(L-1)`, and the cost of the NEXT level is
-- `base * PriceFactor * growth^L` — so a rarer squishy both starts higher and
-- climbs faster, but costs proportionally more to push.
Config.Levels = {
	MaxLevel = 50,
	PriceFactor = 45,
	-- Per-rarity income growth per level. Better rarities scale harder.
	Growth = {
		Common = 1.14,
		Uncommon = 1.17,
		Rare = 1.21,
		Epic = 1.26,
		Legendary = 1.32,
		Mythical = 1.40,
	},
	DefaultGrowth = 1.15,
}

-- Income of a squishy of `rarityName` at `level`, from a level-1 `baseIncome`.
function Config.incomeAtLevel(baseIncome: number, rarityName: string, level: number): number
	local growth = (Config.Levels.Growth :: any)[rarityName] or Config.Levels.DefaultGrowth
	return baseIncome * growth ^ (math.max(1, level) - 1)
end

-- Cash to go from `level` to `level + 1`. Returns nil at max level.
function Config.levelUpCost(baseIncome: number, rarityName: string, level: number): number?
	if level >= Config.Levels.MaxLevel then
		return nil
	end
	local growth = (Config.Levels.Growth :: any)[rarityName] or Config.Levels.DefaultGrowth
	return math.max(1, math.floor(baseIncome * Config.Levels.PriceFactor * growth ^ level))
end

-- ---------------------------------------------------------------- events --
-- Guaranteed high-tier spawns on a timer, advertised on a big board in the
-- arena so everyone can see the clock and be waiting when it lands.
Config.Events = {
	{ name = "Legendary", rarity = "Legendary", interval = 300, color = Color3.fromRGB(240, 165, 60) },
	{ name = "Mythic",    rarity = "Mythical",  interval = 900, color = Color3.fromRGB(240, 95, 150) },
}

-- Where the countdown board stands and how big it is.
Config.EventBoard = {
	Height = 26,       -- board centre above the ground
	Size = Vector2.new(56, 18),
	Offset = Vector3.new(0, 0, -0.62), -- fraction of the field, toward the north edge
}

-- --------------------------------------------------------- daily rewards --
-- A seven day ladder. Logging in on consecutive real-life days walks it up;
-- missing a day drops you back to day 1. Day 7 is worth coming back for.
--   kind: "cash" (amount) | "squishy" (rarity, optional variant) | "spins" (count)
Config.DailyRewards = {
	{ day = 1, kind = "cash",    label = "$50k",          amount = 50e3 },
	{ day = 2, kind = "cash",    label = "$1.5m",         amount = 1.5e6 },
	{ day = 3, kind = "spins",   label = "3 Spins",       spins = 3 },
	{ day = 4, kind = "cash",    label = "$25m",          amount = 25e6 },
	{ day = 5, kind = "squishy", label = "Epic Squishy",  rarity = "Epic" },
	{ day = 6, kind = "cash",    label = "$500m",         amount = 500e6 },
	{ day = 7, kind = "squishy", label = "GOLD Mythical", rarity = "Mythical", variant = "Gold" },
}

Config.Rebirth = {
	-- Cash needed for rebirth N (1-indexed: [1] is the first rebirth).
	Costs = { 50000, 500000, 5000000, 50000000, 500000000 },
	-- Income multiplier granted at each rebirth count (index 1 = 0 rebirths).
	Multipliers = { 1, 1.5, 2.25, 3.4, 5, 7.5 },
	-- Rebirth resets money and upgrade levels; placed squishies stay.
	ResetsUpgrades = true,
}

Config.Wheel = {
	-- Seconds of play between free spins. The timer only runs while the player
	-- is actually in a server, and it starts over on each visit (NextSpinAt is
	-- not saved), so this is half an hour of PLAY, not of wall clock. At the
	-- old 300 a session threw spins at the player faster than the wheel could
	-- stay interesting.
	SpinCooldown = 1800,
	StartingSpins = 1,
	-- Six wedges, matching the pack's SpinWheel.Pattern slots 1..6.
	-- kind: "cash" (amount), "squishy" (rarity), "speed" (mult + duration)
	--
	-- The speed wedge is a LOAN, never a permanent upgrade. `duration` is the
	-- seconds it lasts; `gear` names a Config.Gear entry whose tool is handed
	-- over for the same stretch, so the win arrives as a Speed Coil you can
	-- see in your backpack rather than a number you cannot. WheelService takes
	-- both back when the time is up — permanent speed is a game pass, and it
	-- has to stay worth buying.
	--
	-- `mult` applies only while that coil is actually HELD, so the reward plays
	-- like a coil rather than a timer: put it away and you walk.
	--
	-- The coil is a PROP. The imported model's only script is an empty Synapse
	-- decompiler stub, so holding it does nothing by itself; the speed comes
	-- from the SpeedBoost attribute that SquishyService folds into WalkSpeed.
	Rewards = {
		{ kind = "cash",    label = "$500",     amount = 500,   weight = 30 },
		{ kind = "squishy", label = "Rare",     rarity = "Rare", weight = 22 },
		{ kind = "cash",    label = "$5K",      amount = 5000,  weight = 20 },
		{ kind = "speed",   label = "2x Speed", mult = 2, duration = 300, gear = "SpeedCoil", weight = 15 },
		{ kind = "squishy", label = "Epic",     rarity = "Epic", weight = 10 },
		{ kind = "squishy", label = "Legendary", rarity = "Legendary", weight = 3 },
	},
}

-- Robux developer products (the CONSUMABLE purchases). All 0 until they are
-- created in the Creator Dashboard, so nothing here ever guesses an id: ShopUi
-- shows a card whose id is still 0 greyed with no live price, and ShopService
-- grants nothing for a receipt it has no handler for. Fill these in to switch
-- them on.
Config.Products = {
	StarterPack = 0, -- one-time bundle: cash + a guaranteed squishy + spins
	Boost2x = 0,     -- double income for Shop.Boost2xMinutes
	CashSmall = 0,   -- the three cash bundles (amounts in Config.Shop)
	CashMedium = 0,
	CashLarge = 0,
	WheelSpins3 = 0,
	WheelSpins9 = 0,
	-- Pay Robux to take a squishy off another player's plot. Stealing stays
	-- switched off until this id exists.
	Steal = 0,
	-- The two defence pads at a plot's front door (DefenseService). Parked at
	-- 0 like everything else: the pads say "Coming soon" and prompt nothing.
	SlapProtection = 0,
	BaseLock = 0,
	-- The two SERVER-WIDE boosts on the BoostUi side buttons: everyone in the
	-- server benefits, whoever pays.
	SleepAll = 0,   -- every Evil Squishy sleeps for Boosts.SleepSeconds
	ServerLuck = 0, -- rarer field spawns for Boosts.LuckMinutes
}

-- The server-wide boosts BoostUi sells (Products.SleepAll / ServerLuck).
Config.Boosts = {
	SleepSeconds = 60,
	LuckMinutes = 15,
	-- Luck tempers every spawn-roll weight to weight^(1/LuckPower), which
	-- squeezes the gap between Common and Mythical instead of flattening it:
	-- at 2, a Mythical goes from one roll in two hundred to about one in
	-- thirty, and the same tempering applies to the variant roll, so the
	-- Golds start dropping too.
	LuckPower = 2,
	-- BoostUi button art: Sam's uploads (the pink Zzz squishy and the clover),
	-- verified by eye against the asset ids on 2026-09-07.
	SleepImage = 120781003340705,
	LuckImage = 79715243708996,
}

-- What the defence pads sell (DefenseService). Slap Protection guards against
-- OTHER PLAYERS' slap hands only — the giants ignore it, because a defence you
-- can buy against the game's core threat would sell the game out from under
-- itself. Lock Base drops a laser wall across the front opening that only the
-- owner can walk through.
Config.Defense = {
	SlapProtectionMinutes = 15,
	BaseLockMinutes = 15,
}

-- The plot keeps earning while its owner is away. SaveService prices it from
-- the plot's $/s at the moment of the last save, and the while-you-were-away
-- popup hands it over on the next join — nothing is credited silently.
Config.Offline = {
	-- The away clock stops here, so the most an absence can pay is the plot's
	-- rate times this many seconds (through the same multipliers as any other
	-- payout). Six hours halved, per the design: rate x 21600 / 2.
	MaxAwaySeconds = 21600 / 2,
	-- Shorter absences pay nothing, so a crash-and-rejoin does not open a
	-- ceremony over pocket change.
	MinimumAwaySeconds = 60,
}

-- Game passes: the PERMANENT purchases. Same 0-means-parked rule.
Config.Passes = {
	VIP = 0,            -- permanent income multiplier (Shop.VipIncomeMult)
	PermanentSpeed = 0, -- permanent walkspeed bonus (Shop.PermanentSpeedBonus)
	-- The gear on the basement stands (Config.Gear). Fill these in from the
	-- Creator Dashboard and the stands start selling with no code change.
	SpeedCoil = 0,
	SlapHand = 0,
	Glock = 0,
	Knight = 0,
}

-- The gear sold from the item stands in a base's BASEMENT storeys.
--
-- Stand N on an item floor shows entry N of this list; stands past the end of
-- it stay bare. `template` is a child of ServerStorage.GearItems — the models
-- themselves live in the place, not in this repo, because they are imported
-- art. A missing template costs that stand its display, nothing more.
--
-- `kind` says what owning the pass actually hands over:
--   "tool"      a Tool copied into the player's Backpack and StarterGear
--   "bodyguard" a follower model — the pass is granted as an attribute and the
--               gear's own scripts do the rest
Config.Gear = {
	{ key = "SpeedCoil", pass = "SpeedCoil", template = "SpeedCoil", kind = "tool",
		name = "Speed Coil", blurb = "Run faster, forever" },
	{ key = "SlapHand", pass = "SlapHand", template = "DefaultSlap", kind = "tool",
		name = "Slap Hand", blurb = "Send them flying" },
	-- displayYaw: the pistol model lies side-on to the stand's front, so its
	-- display copy turns a quarter to face the room.
	{ key = "Glock", pass = "Glock", template = "Glock-17", kind = "tool",
		name = "Glock-17", blurb = "Look the part", displayYaw = 90 },
	{ key = "Knight", pass = "Knight", template = "The Knight", kind = "bodyguard",
		name = "The Knight", blurb = "Your own bodyguard" },
}

-- What the shop's items actually grant — one place to tune, read by
-- ShopService (grants) and ShopUi (card labels) so they can never disagree.
Config.Shop = {
	-- The one-time starter bundle (Products.StarterPack; priced R$9 in the
	-- Dashboard). Tuned to compress the first hour, never the first day:
	-- cash enough for ground slots and first upgrades but well short of a
	-- floor, a Gold Epic that puts the variant system on show from minute
	-- one, and a handful of spins — worth paying for now that they drip at
	-- one per half hour. One per player; the profile remembers.
	StarterPackCash = 100e3,
	StarterPackSpins = 5,
	StarterPackRarity = "Epic",
	StarterPackVariant = "Gold",
	Boost2xMinutes = 30,
	Boost2xMult = 2,
	VipIncomeMult = 1.5,
	PermanentSpeedBonus = 6, -- studs/s on top of the base walkspeed
	CashAmounts = { Small = 50e3, Medium = 500e3, Large = 5e6 },
}

Config.Plot = {
	Count = 8,                -- plot spots around the field
	-- Floors are BOUGHT. Everyone starts with the ground floor; up to MaxAbove
	-- storeys can be added on top, each dearer than the last. A bought floor
	-- arrives with all its slots open.
	MaxAbove = 4,
	-- The single basement is the ITEMS floor: its stands hold gear rather than
	-- squishies (PlotService builds them as item slots, no placing, no income).
	MaxBelow = 1,
	-- Price of the Nth extra floor, counting both directions together, so the
	-- last floor costs the same whichever way you grew. Five entries because
	-- MaxAbove + MaxBelow is five.
	--
	-- The creep STEEPENS floor by floor (x20, x25, x30, x33) instead of the
	-- old flat x12: the first extra floor stays an early-game purchase, and
	-- each one after it bites harder, so the last is a project even for a
	-- plot pulling billions a second.
	FloorPrices = { 500e3, 10e6, 250e6, 7.5e9, 250e9 },
	SlotsPerRow = 5,
	RowsPerFloor = 2,
	-- Slots on ONE floor. The ground floor sells its slots individually (the
	-- early game); every bought floor arrives with all ten already open, which
	-- is what you are paying the floor price for.
	SlotsPerFloor = 10,
	StartUnlocked = 4,
	-- Price to unlock ground-floor slot N (entries <= StartUnlocked ignored).
	UnlockPrices = { 0, 0, 0, 0, 150, 1000, 7500, 50000, 350000, 2500000 },
	AccrueTick = 0.5,         -- seconds between income accrual updates
	-- XZ footprint of a plot. Width is capped near 60 by the spacing between
	-- neighbours (fieldSize.X / 4); DEPTH grows outward into open ground, which
	-- is where the room for the stair lane and the slot rows came from.
	BaseSize = Vector2.new(56, 58),
}

-- Icons from the Free Icon Pack 3.0.1 (Basic), uploaded once to the owner's
-- account. A local PNG can never be referenced at runtime, so these are the
-- moderated asset ids the game actually draws; they only need redoing if the
-- game moves to a different account. tools/upload_icons.md records the source
-- file behind each id.
Config.Icons = {
	Upgrade = "rbxassetid://86014261095925",
	House = "rbxassetid://118336776033036",
	Cash = "rbxassetid://98948172539240",
	Gift = "rbxassetid://125895167437717",
	Calendar = "rbxassetid://76476455943304",
	Lock = "rbxassetid://84394998921158",
	Shield = "rbxassetid://73099523361961",
	Star = "rbxassetid://135507557051697",
	Coil = "rbxassetid://77650920811206",
	Wheel = "rbxassetid://91374848059044",
}

return Config
