--!strict
-- Shared tuning values for Don't Wake the Squishy.
-- Anything both the server and the client need to agree on lives here.
-- See DESIGN.md for how these tables are consumed.

local Config = {}

Config.GameName = "DONT WAKE THE SQUISHY!"

Config.Player = {
	WalkSpeed = 16,
}

-- Ordered from most to least common. `weight` drives the field spawn roll.
-- `income` is $ per second for a placed squishy of this rarity.
-- `speedMult` multiplies WalkSpeed while carrying.
Config.Rarities = {
	{ name = "Common",    color = Color3.fromRGB(200, 200, 200), income = 1,     speedMult = 0.92, weight = 55 },
	{ name = "Uncommon",  color = Color3.fromRGB(88, 214, 88),   income = 8,     speedMult = 0.80, weight = 25 },
	{ name = "Rare",      color = Color3.fromRGB(64, 140, 255),  income = 40,    speedMult = 0.66, weight = 12 },
	{ name = "Epic",      color = Color3.fromRGB(170, 85, 255),  income = 250,   speedMult = 0.50, weight = 5.5 },
	{ name = "Legendary", color = Color3.fromRGB(255, 170, 0),   income = 1500,  speedMult = 0.38, weight = 2 },
	{ name = "Mythic",    color = Color3.fromRGB(255, 64, 129),  income = 10000, speedMult = 0.28, weight = 0.5 },
}

-- Fast lookup by rarity name (built below).
Config.RarityByName = {} :: { [string]: any }
for _, rarity in Config.Rarities do
	Config.RarityByName[rarity.name] = rarity
end

-- The collectable roster. `scale` multiplies the base body size.
Config.Squishies = {
	-- Common
	{ name = "Blobby",      rarity = "Common",    color = Color3.fromRGB(150, 200, 255), scale = 1.0 },
	{ name = "Doughy",      rarity = "Common",    color = Color3.fromRGB(245, 225, 180), scale = 1.0 },
	{ name = "Pebble",      rarity = "Common",    color = Color3.fromRGB(170, 170, 180), scale = 0.9 },
	-- Uncommon
	{ name = "Sprout",      rarity = "Uncommon",  color = Color3.fromRGB(120, 220, 120), scale = 1.1 },
	{ name = "Wiggles",     rarity = "Uncommon",  color = Color3.fromRGB(90, 220, 210),  scale = 1.1 },
	-- Rare
	{ name = "Jellybean",   rarity = "Rare",      color = Color3.fromRGB(255, 105, 200), scale = 1.25 },
	{ name = "Frostbite",   rarity = "Rare",      color = Color3.fromRGB(160, 220, 255), scale = 1.25 },
	-- Epic
	{ name = "Glowbo",      rarity = "Epic",      color = Color3.fromRGB(190, 120, 255), scale = 1.45 },
	{ name = "Thunderpuff", rarity = "Epic",      color = Color3.fromRGB(255, 230, 90),  scale = 1.45 },
	-- Legendary
	{ name = "Nebula",      rarity = "Legendary", color = Color3.fromRGB(110, 70, 220),  scale = 1.7 },
	{ name = "Sunny",       rarity = "Legendary", color = Color3.fromRGB(255, 200, 60),  scale = 1.7 },
	-- Mythic
	{ name = "Eclipse",     rarity = "Mythic",    color = Color3.fromRGB(40, 40, 55),    scale = 2.0 },
}

Config.SquishyByName = {} :: { [string]: any }
for _, def in Config.Squishies do
	Config.SquishyByName[def.name] = def
end

-- The two giant patrolling enemies.
Config.Enemies = {
	{
		name = "Mama Squish",
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
	Size = Vector2.new(200, 200), -- XZ studs, centered at origin
	WalkwayWidth = 26,            -- safe ring around the field
	SpawnInterval = 4,            -- seconds between field spawn attempts
	MaxSquishies = 24,            -- cap of freshly-spawned field squishies
	SpawnInset = 22,              -- keep spawns this far from the field edge
	SpawnSpacing = 18,            -- grid spacing between candidate spawn points
	WaypointInset = 30,           -- enemy patrol rectangle inset from field edge
}

Config.Plot = {
	Count = 8,                -- plot spots around the field
	SlotCount = 10,           -- squishy slots per plot
	SlotsPerRow = 5,
	StartUnlocked = 4,
	-- Price to unlock slot N (1-indexed; entries <= StartUnlocked are ignored).
	UnlockPrices = { 0, 0, 0, 0, 150, 1000, 7500, 50000, 350000, 2500000 },
	AccrueTick = 0.5,         -- seconds between income accrual updates
	BaseSize = Vector2.new(48, 36), -- XZ footprint of a plot
}

return Config
