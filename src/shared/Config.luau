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
	{ name = "Sugar Baby",      rarity = "Epic",      color = Color3.fromRGB(230, 120, 198), sparkle = true,  shape = "babymesh" },
	{ name = "Rainbow Butter",  rarity = "Epic",      color = Color3.fromRGB(196, 124, 220), sparkle = false, shape = "rainbuttermesh" },
	{ name = "Sparkle Drop",    rarity = "Epic",      color = Color3.fromRGB(140, 226, 198), sparkle = true,  shape = "dropmesh" },
	{ name = "Giant Banana",    rarity = "Epic",      color = Color3.fromRGB(250, 216, 88),  sparkle = false, shape = "bananamesh",     scale = GIANT },
	{ name = "Giant Butter Stick", rarity = "Epic",   color = Color3.fromRGB(247, 210, 96),  sparkle = false, shape = "buttermesh",     scale = GIANT },
	{ name = "Giant Strawberry", rarity = "Epic",     color = Color3.fromRGB(219, 58, 62),   sparkle = false, shape = "strawberrymesh", scale = GIANT },

	-- Legendary
	{ name = "Gold Glitter",    rarity = "Legendary", color = Color3.fromRGB(226, 178, 66),  sparkle = true,  shape = "dumplingmesh" },
	{ name = "Glow Doughnut",   rarity = "Legendary", color = Color3.fromRGB(132, 244, 120), sparkle = true,  shape = "glowdonutmesh" },
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
--   effect: how SquishyModels dresses it — "none" | "gold" | "rainbow"
--   weight: roll chance against every other variant
--   income: income multiplier
Config.Variants = {
	{ name = "Normal",  effect = "none",    weight = 880, income = 1,  prefix = "" },
	{ name = "Gold",    effect = "gold",    weight = 100, income = 5,  prefix = "Gold ",
		color = Color3.fromRGB(255, 206, 74) },
	{ name = "Rainbow", effect = "rainbow", weight = 20,  income = 25, prefix = "Rainbow " },
}

Config.VariantByName = {} :: { [string]: any }
for _, variant in Config.Variants do
	Config.VariantByName[variant.name] = variant
end

-- The two giant patrolling enemies: monstrous versions of real squishies.
-- `shape` + `color` (as tint) feed SquishyModels.build; `scale` is huge.
Config.Enemies = {
	{
		name = "Mama Squish",
		shape = "opalmesh",
		color = Color3.fromRGB(255, 130, 180),
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
		name = "Grumpo",
		shape = "strawberrymesh",
		color = Color3.fromRGB(150, 90, 220),
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
	-- Staircase up the left side of the plot, hugging the wall.
	StairWidth = 7,
	StairSteps = 11,
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
	CollectPad = Color3.fromRGB(132, 232, 166),   -- mint jelly
	DepositPad = Color3.fromRGB(160, 226, 246),   -- blue raspberry
	UnlockPad = Color3.fromRGB(255, 214, 150),    -- caramel
	SignBoard = Color3.fromRGB(242, 166, 134),    -- peach board
	HouseBody = Color3.fromRGB(255, 214, 130),    -- butter house
	HouseRoof = Color3.fromRGB(238, 130, 156),    -- raspberry roof
	SafeZone = Color3.fromRGB(206, 226, 255),     -- cool pastel blue
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

Config.Rebirth = {
	-- Cash needed for rebirth N (1-indexed: [1] is the first rebirth).
	Costs = { 50000, 500000, 5000000, 50000000, 500000000 },
	-- Income multiplier granted at each rebirth count (index 1 = 0 rebirths).
	Multipliers = { 1, 1.5, 2.25, 3.4, 5, 7.5 },
	-- Rebirth resets money and upgrade levels; placed squishies stay.
	ResetsUpgrades = true,
}

Config.Wheel = {
	SpinCooldown = 300,   -- seconds between free spins
	StartingSpins = 1,
	-- Six wedges, matching the pack's SpinWheel.Pattern slots 1..6.
	-- kind: "cash" (amount), "squishy" (rarity), "speed" (mult + duration)
	Rewards = {
		{ kind = "cash",    label = "$500",     amount = 500,   weight = 30 },
		{ kind = "squishy", label = "Rare",     rarity = "Rare", weight = 22 },
		{ kind = "cash",    label = "$5K",      amount = 5000,  weight = 20 },
		{ kind = "speed",   label = "2x Speed", mult = 2, duration = 60, weight = 15 },
		{ kind = "squishy", label = "Epic",     rarity = "Epic", weight = 10 },
		{ kind = "squishy", label = "Legendary", rarity = "Legendary", weight = 3 },
	},
}

-- Robux developer products / passes. All 0 until they are created in the
-- Creator Dashboard; the client HIDES any button or pack whose id is still 0,
-- so nothing here ever guesses an id. Fill these in to switch them on.
Config.Products = {
	StarterPack = 0,
	ProPack = 0,
	ItemsOnly = 0,
	CashOnly = 0,
	Random = 0,
	WheelSpins3 = 0,
	WheelSpins9 = 0,
	CarryUpgrade = 0,
	RebirthSkip = 0,
}

Config.Plot = {
	Count = 8,                -- plot spots around the field
	Floors = 2,               -- storeys per base; slots fill the ground floor first
	SlotsPerRow = 5,
	RowsPerFloor = 2,
	-- Floors * RowsPerFloor * SlotsPerRow. Slots 1-10 are downstairs,
	-- 11-20 upstairs, so the second storey is something you grow into.
	SlotCount = 20,
	StartUnlocked = 4,
	-- Price to unlock slot N (1-indexed; entries <= StartUnlocked are ignored).
	UnlockPrices = {
		0, 0, 0, 0,
		150, 1000, 7500, 50000, 350000, 2500000,
		-- Upstairs: the second storey is late-game, priced past the first
		-- rebirths rather than as a straight continuation.
		18e6, 120e6, 800e6, 5e9, 32e9,
		200e9, 1.3e12, 8e12, 50e12, 300e12,
	},
	AccrueTick = 0.5,         -- seconds between income accrual updates
	BaseSize = Vector2.new(56, 42), -- XZ footprint of a plot (4 per 240-wide edge)
}

return Config
