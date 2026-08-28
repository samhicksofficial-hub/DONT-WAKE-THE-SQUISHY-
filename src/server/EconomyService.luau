--!strict
-- EconomyService: session-only money (no datastores). Owns the leaderstats
-- "Money" IntValue and the mirrored `Money` player attribute (see DESIGN.md,
-- "Attributes"). Everything else reads money through this service.

local Players = game:GetService("Players")

local EconomyService = {}

-- Set at Start; AddMoney asks it for the rebirth income multiplier.
local rebirthService: any = nil

-- The player's Money IntValue, if their leaderstats exist yet.
local function findMoneyValue(player: Player): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return nil
	end
	return leaderstats:FindFirstChild("Money") :: IntValue?
end

-- Builds leaderstats + Money (idempotent) and syncs the attribute.
local function setupPlayer(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		leaderstats = folder
	end
	local money = leaderstats:FindFirstChild("Money")
	if not money then
		local value = Instance.new("IntValue")
		value.Name = "Money"
		value.Value = 0
		value.Parent = leaderstats
		money = value
	end
	player:SetAttribute("Money", (money :: IntValue).Value)
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[EconomyService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- Writes both sides of the data plane together.
local function setMoney(player: Player, newValue: number)
	local money = findMoneyValue(player)
	if not money then
		return
	end
	money.Value = newValue
	player:SetAttribute("Money", newValue)
end

function EconomyService.GetMoney(player: Player): number
	local money = findMoneyValue(player)
	return if money then money.Value else 0
end

-- Adds `amount` (fractional accrual pools welcome); result floors to an int.
-- Every income source funnels through here, so the rebirth multiplier is
-- applied at this one choke point (pads, wheel rewards, everything).
function EconomyService.AddMoney(player: Player, amount: number)
	local scaled = amount
	if amount > 0 and rebirthService then
		local ok, multiplier = pcall(function()
			return rebirthService.GetMultiplier(player)
		end)
		if ok and typeof(multiplier) == "number" and multiplier > 0 then
			scaled = amount * multiplier
		end
	end
	setMoney(player, math.floor(EconomyService.GetMoney(player) + scaled))
end

-- Sets a player's balance directly, ignoring multipliers (rebirth reset).
function EconomyService.SetMoney(player: Player, amount: number)
	setMoney(player, math.max(0, math.floor(amount)))
end

-- Deducts `amount` if affordable and returns true, else false and no change.
function EconomyService.TrySpend(player: Player, amount: number): boolean
	local cost = math.max(0, math.floor(amount))
	local current = EconomyService.GetMoney(player)
	if current < cost then
		return false
	end
	setMoney(player, current - cost)
	return true
end

function EconomyService.Start(services: any, _map: any)
	rebirthService = services.RebirthService
	Players.PlayerAdded:Connect(safeSetup)
	for _, player in Players:GetPlayers() do
		safeSetup(player)
	end
end

return EconomyService
