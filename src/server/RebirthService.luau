--!strict
-- RebirthService — owns the `Rebirths` player attribute and the income
-- multiplier that comes with it (Config.Rebirth).
--
-- Rebirth N costs Config.Rebirth.Costs[N]; a nil cost means fully rebirthed.
-- The multiplier is Config.Rebirth.Multipliers[count + 1] (index 1 = zero
-- rebirths). This service only PROVIDES the multiplier — EconomyService.AddMoney
-- is the single choke point that applies it (DESIGN.md).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Config = require(sharedFolder:WaitForChild("Config"))

local RebirthService = {}

local economyService: any = nil
local upgradeService: any = nil

local function setupPlayer(player: Player)
	if typeof(player:GetAttribute("Rebirths")) ~= "number" then
		player:SetAttribute("Rebirths", 0)
	end
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[RebirthService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- Wipes a balance without touching multipliers. Prefers EconomyService.SetMoney
-- and falls back to spending the whole balance.
local function zeroMoney(player: Player)
	if economyService == nil then
		return
	end
	if typeof(economyService.SetMoney) == "function" then
		economyService.SetMoney(player, 0)
		return
	end
	economyService.TrySpend(player, economyService.GetMoney(player))
end

function RebirthService.GetCount(player: Player): number
	local current = player:GetAttribute("Rebirths")
	if typeof(current) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(current))
end

-- Income multiplier for the player's current rebirth count, clamped to the
-- last tuning entry so extra rebirths never fall off the table.
function RebirthService.GetMultiplier(player: Player): number
	local multipliers = Config.Rebirth.Multipliers
	local index = math.clamp(RebirthService.GetCount(player) + 1, 1, #multipliers)
	return multipliers[index]
end

-- Charges the full next-rebirth cost, then (per Config.Rebirth.ResetsUpgrades)
-- resets upgrade levels and zeroes money. Placed squishies are untouched.
function RebirthService.TryRebirth(player: Player): boolean
	if economyService == nil then
		return false
	end
	local count = RebirthService.GetCount(player)
	local cost = Config.Rebirth.Costs[count + 1]
	if cost == nil then
		return false
	end
	if not economyService.TrySpend(player, cost) then
		return false
	end
	player:SetAttribute("Rebirths", count + 1)
	if Config.Rebirth.ResetsUpgrades then
		if upgradeService ~= nil then
			upgradeService.ResetLevels(player)
		end
		zeroMoney(player)
	end
	return true
end

function RebirthService.Start(services: any, _map: any)
	economyService = services.EconomyService
	upgradeService = services.UpgradeService

	Players.PlayerAdded:Connect(safeSetup)
	for _, player in Players:GetPlayers() do
		safeSetup(player)
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local doRebirth = remotes:WaitForChild("DoRebirth") :: RemoteEvent
	doRebirth.OnServerEvent:Connect(function(player: Player)
		local ok, err = pcall(function()
			RebirthService.TryRebirth(player)
		end)
		if not ok then
			warn(("[RebirthService] rebirth failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end)
end

return RebirthService
