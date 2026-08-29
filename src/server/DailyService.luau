--!strict
-- DailyService — the seven-day login ladder.
--
-- Daily rewards only mean anything if they survive a session, so this is the
-- one system in the game that persists. It stores two numbers per player in a
-- DataStore: the UTC day they last claimed, and how far up the ladder they are.
--
--   * claimed today already        -> nothing to claim
--   * last claim was YESTERDAY     -> streak + 1 (wrapping past day 7 to 1)
--   * anything older (or first time)-> streak resets to day 1
--
-- DataStores are unavailable in Studio unless "Enable Studio Access to API
-- Services" is ticked, and can fail on a live server too. Every call is
-- pcall'd and falls back to memory: a player can always claim, they just will
-- not carry a streak between sessions until storage works.
--
-- Attributes (client reads): DailyStreak, DailyClaimable.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DailyService = {}

local STORE_NAME = "DailyRewards_v1"
local LADDER = Config.DailyRewards :: { any }

local servicesRef: any = nil
local store: DataStore? = nil
local storeWarned = false

-- player -> { lastDay: number, streak: number }
local state: { [Player]: { lastDay: number, streak: number } } = {}

-- Whole UTC days since the epoch: the unit a "daily" reward is counted in.
local function today(): number
	return math.floor(os.time() / 86400)
end

local function keyFor(player: Player): string
	return ("p_%d"):format(player.UserId)
end

-- Reads a player's saved record, or a blank one when storage is unavailable.
local function load(player: Player): { lastDay: number, streak: number }
	local blank = { lastDay = 0, streak = 0 }
	local dataStore = store
	if dataStore == nil then
		return blank
	end
	local ok, saved = pcall(function()
		return dataStore:GetAsync(keyFor(player))
	end)
	if not ok then
		if not storeWarned then
			storeWarned = true
			warn("[DailyService] DataStore unavailable — streaks will not persist. In Studio, tick Game Settings > Security > Enable Studio Access to API Services.")
		end
		return blank
	end
	if typeof(saved) == "table" then
		return {
			lastDay = tonumber((saved :: any).lastDay) or 0,
			streak = tonumber((saved :: any).streak) or 0,
		}
	end
	return blank
end

local function save(player: Player, record: { lastDay: number, streak: number })
	local dataStore = store
	if dataStore == nil then
		return
	end
	local ok, err = pcall(function()
		dataStore:SetAsync(keyFor(player), record)
	end)
	if not ok then
		warn(("[DailyService] save failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- What day of the ladder this player would claim next, 1..#LADDER.
local function pendingDay(record: { lastDay: number, streak: number }): number
	local day = today()
	if record.lastDay == day - 1 then
		-- Consecutive login: step up, wrapping back to 1 past the end.
		return (record.streak % #LADDER) + 1
	end
	-- First ever, or the streak lapsed.
	return 1
end

local function publish(player: Player)
	local record = state[player]
	if record == nil then
		return
	end
	local claimable = record.lastDay ~= today()
	player:SetAttribute("DailyStreak", record.streak)
	player:SetAttribute("DailyClaimable", claimable)
	player:SetAttribute("DailyNextDay", pendingDay(record))
end

-- Hands over one ladder entry. Returns false when the reward could not be
-- delivered (no plot for a squishy, say) so the caller can pay cash instead.
local function grant(player: Player, reward: any): boolean
	if reward.kind == "cash" then
		servicesRef.EconomyService.AddMoney(player, reward.amount)
		return true
	elseif reward.kind == "spins" then
		local current = tonumber(player:GetAttribute("Spins")) or 0
		player:SetAttribute("Spins", current + (reward.spins or 1))
		return true
	elseif reward.kind == "squishy" then
		local pool = {}
		for _, def in Config.Squishies :: { any } do
			if def.rarity == reward.rarity then
				table.insert(pool, def)
			end
		end
		if #pool == 0 then
			return false
		end
		local def = table.clone(pool[math.random(1, #pool)])
		def.variant = reward.variant
		local plotService = servicesRef.PlotService
		if plotService ~= nil and typeof(plotService.TryPlaceSquishy) == "function" then
			local ok, placed = pcall(plotService.TryPlaceSquishy, player, def)
			if ok and placed then
				return true
			end
		end
		-- No room on the plot: pay out its worth instead of dropping it.
		local rarity = Config.RarityByName[reward.rarity]
		if rarity ~= nil then
			servicesRef.EconomyService.AddMoney(player, rarity.income * 120)
			return true
		end
		return false
	end
	return false
end

function DailyService.GetStreak(player: Player): number
	local record = state[player]
	return record ~= nil and record.streak or 0
end

function DailyService.CanClaim(player: Player): boolean
	local record = state[player]
	return record ~= nil and record.lastDay ~= today()
end

-- Claims today's reward. Returns the ladder day claimed, or nil if there was
-- nothing to claim.
function DailyService.Claim(player: Player): number?
	local record = state[player]
	if record == nil or record.lastDay == today() then
		return nil
	end
	local day = pendingDay(record)
	local reward = LADDER[day]
	if reward == nil then
		return nil
	end

	-- Bank the claim BEFORE granting: a failed grant must not leave the day
	-- claimable again, and grant() already falls back to cash.
	record.lastDay = today()
	record.streak = day
	state[player] = record
	publish(player)
	task.spawn(save, player, record)

	local ok, err = pcall(grant, player, reward)
	if not ok then
		warn(("[DailyService] grant failed for %s: %s"):format(player.Name, tostring(err)))
	end
	return day
end

function DailyService.Start(services: any, _map: any)
	servicesRef = services

	local ok, dataStore = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = ok and dataStore or nil
	if not ok then
		warn("[DailyService] no DataStore access — streaks are session-only this run.")
	end

	local function setup(player: Player)
		state[player] = load(player)
		publish(player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			local okSetup, err = pcall(setup, player)
			if not okSetup then
				warn(("[DailyService] setup failed for %s: %s"):format(player.Name, tostring(err)))
			end
		end)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(setup, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		state[player] = nil
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local claimRemote = remotes:WaitForChild("DailyClaim")
	if claimRemote:IsA("RemoteFunction") then
		claimRemote.OnServerInvoke = function(player: Player)
			local okClaim, day = pcall(DailyService.Claim, player)
			return okClaim and day or nil
		end
	end
end

return DailyService
