--!strict
-- Small helpers shared by server and client.

local Util = {}

local SUFFIXES = {
	{ 1e18, "Qt" },
	{ 1e15, "Qa" },
	{ 1e12, "T" },
	{ 1e9, "B" },
	{ 1e6, "M" },
	{ 1e3, "k" },
}

-- 1234 -> "$1.23k", 52190 -> "$52.19k", 950 -> "$950". Always <= 2 decimals,
-- trailing zeros trimmed ("$1.5k", "$2k").
function Util.formatMoney(amount: number): string
	local sign = amount < 0 and "-" or ""
	local n = math.abs(amount)
	for _, entry in SUFFIXES do
		local threshold = entry[1] :: number
		if n >= threshold then
			local value = n / threshold
			local text = string.format("%.2f", value)
			text = text:gsub("%.?0+$", "")
			return ("%s$%s%s"):format(sign, text, entry[2] :: string)
		end
	end
	return ("%s$%d"):format(sign, math.floor(n + 0.5))
end

-- Picks an entry from a list of tables that each carry a `weight` field.
function Util.weightedRandom<T>(list: { T }, rng: Random): T
	local total = 0
	for _, entry in list do
		total += (entry :: any).weight
	end
	local roll = rng:NextNumber() * total
	for _, entry in list do
		roll -= (entry :: any).weight
		if roll <= 0 then
			return entry
		end
	end
	return list[#list]
end

-- Distance ignoring height.
function Util.xzDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Root part of a player's character, if alive and in the world.
function Util.getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

return Util
