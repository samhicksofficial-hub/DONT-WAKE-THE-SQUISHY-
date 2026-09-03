--!strict
-- UpgradeService — the three cash upgrade tracks from Config.Upgrades
-- ("Speed" | "Stealth" | "Carry"). Levels are 1-based and live in the player
-- attributes `Upgrade_Speed` / `Upgrade_Stealth` / `Upgrade_Carry`, which are
-- the client's read side (see DESIGN.md, "New player attributes").
--
-- This service only owns the numbers. Who applies them:
--   * Speed / Carry -> SquishyService (sole writer of Humanoid.WalkSpeed)
--   * Stealth       -> EnemyService (scales its notice radii)
-- Level 1 is the free starting level, so `prices[level]` is the cost of the
-- NEXT level and a nil price means the track is maxed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Config = require(sharedFolder:WaitForChild("Config"))

local UpgradeService = {}

-- Whitelist: client input is checked against this before Config is indexed.
local TRACKS = { "Speed", "Stealth", "Carry" }
local IS_TRACK: { [string]: boolean } = {}
for _, name in TRACKS do
	IS_TRACK[name] = true
end

local economyService: any = nil

local function attributeName(track: string): string
	return "Upgrade_" .. track
end

-- True only for a whitelisted track name (never trusts the client).
local function isTrack(track: any): boolean
	return typeof(track) == "string" and IS_TRACK[track] == true
end

local function trackData(track: string): any
	return (Config.Upgrades :: any)[track]
end

-- Gives a player every missing level attribute its starting value of 1.
local function setupPlayer(player: Player)
	for _, track in TRACKS do
		local current = player:GetAttribute(attributeName(track))
		if typeof(current) ~= "number" then
			player:SetAttribute(attributeName(track), 1)
		end
	end
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[UpgradeService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- Current level, clamped into the track's value list (1-based, never nil).
function UpgradeService.GetLevel(player: Player, track: string): number
	if not isTrack(track) then
		return 1
	end
	local values = trackData(track).values
	local current = player:GetAttribute(attributeName(track))
	if typeof(current) ~= "number" then
		return 1
	end
	return math.clamp(math.floor(current), 1, #values)
end

-- The tuning value at the player's level (clamped to the last entry).
function UpgradeService.GetValue(player: Player, track: string): number
	if not isTrack(track) then
		return 1
	end
	local values = trackData(track).values
	local level = math.min(UpgradeService.GetLevel(player, track), #values)
	return values[level]
end

-- Spends the next level's price and bumps the level. False when the track is
-- maxed (no price for this level), unknown, or the player can't afford it.
function UpgradeService.TryBuy(player: Player, track: string): boolean
	if not isTrack(track) or economyService == nil then
		return false
	end
	local level = UpgradeService.GetLevel(player, track)
	local price = trackData(track).prices[level]
	if price == nil then
		return false
	end
	if not economyService.TrySpend(player, price) then
		return false
	end
	player:SetAttribute(attributeName(track), level + 1)
	return true
end

-- The track names, for callers that have to walk all of them (SaveService).
function UpgradeService.Tracks(): { string }
	return table.clone(TRACKS)
end

-- Restores a level without charging for it. SaveService only — every other
-- route to a higher level goes through TryBuy and pays. Clamped to the track's
-- own value list, so a profile saved before a track was shortened cannot push
-- a player past the end of it.
function UpgradeService.SetLevel(player: Player, track: string, level: number)
	if not isTrack(track) or typeof(level) ~= "number" then
		return
	end
	local values = trackData(track).values
	player:SetAttribute(attributeName(track), math.clamp(math.floor(level), 1, #values))
end

-- Back to the free starting level on every track (called by RebirthService).
function UpgradeService.ResetLevels(player: Player)
	for _, track in TRACKS do
		player:SetAttribute(attributeName(track), 1)
	end
end

function UpgradeService.Start(services: any, _map: any)
	economyService = services.EconomyService

	Players.PlayerAdded:Connect(safeSetup)
	for _, player in Players:GetPlayers() do
		safeSetup(player)
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local buyUpgrade = remotes:WaitForChild("BuyUpgrade") :: RemoteEvent
	buyUpgrade.OnServerEvent:Connect(function(player: Player, track: any)
		if not isTrack(track) then
			return
		end
		local ok, err = pcall(function()
			UpgradeService.TryBuy(player, track :: string)
		end)
		if not ok then
			warn(("[UpgradeService] buy failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end)
end

return UpgradeService
