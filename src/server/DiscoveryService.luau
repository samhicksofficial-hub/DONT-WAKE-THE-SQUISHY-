--!strict
-- DiscoveryService — which squishies each player has picked up this session.
-- Session-only (no datastores), so the set is a plain table keyed by Player.
--
-- Discovery is PER VARIANT: a Gold Red Dumpling fills the Gold page of the
-- index, not the Normal one, so every entry is keyed `variant .. "|" .. name`
-- ("Normal|Red Dumpling", "Gold|Red Dumpling"). Replication uses the
-- `Discovered` RemoteEvent (DESIGN.md): the full array of keys on join, then a
-- single key string on each new discovery. The client (IndexUi) accepts both
-- shapes and treats a bare name with no "|" as Normal.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DiscoveryService = {}

-- Player -> set of discovered keys (`variant .. "|" .. name`).
local discovered: { [Player]: { [string]: boolean } } = {}

-- One key per (squishy, variant) pair; nil or junk variants count as Normal.
local function keyFor(squishyName: string, variantName: any): string
	local variant = if typeof(variantName) == "string" and variantName ~= "" then variantName else "Normal"
	return variant .. "|" .. squishyName
end
-- Player -> the CharacterAdded connection used to re-send the full set.
local respawnConns: { [Player]: RBXScriptConnection } = {}

local discoveredRemote: RemoteEvent? = nil

local function setFor(player: Player): { [string]: boolean }
	local set = discovered[player]
	if set == nil then
		set = {}
		discovered[player] = set
	end
	return set
end

-- Every key the player has found, as an array (order is not meaningful).
local function toArray(player: Player): { string }
	local keys: { string } = {}
	local set = discovered[player]
	if set ~= nil then
		for key in set do
			table.insert(keys, key)
		end
	end
	return keys
end

-- Sends the whole set. Fired on join and again on each spawn, because a join
-- fire can beat the client's own listener into existence.
local function sendFullSet(player: Player)
	local remote = discoveredRemote
	if remote == nil then
		return
	end
	remote:FireClient(player, toArray(player))
end

local function setupPlayer(player: Player)
	setFor(player)
	sendFullSet(player)
	local existing = respawnConns[player]
	if existing ~= nil then
		existing:Disconnect()
	end
	respawnConns[player] = player.CharacterAdded:Connect(function()
		local ok, err = pcall(sendFullSet, player)
		if not ok then
			warn(("[DiscoveryService] resend failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end)
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[DiscoveryService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

local function cleanupPlayer(player: Player)
	discovered[player] = nil
	local conn = respawnConns[player]
	if conn ~= nil then
		conn:Disconnect()
		respawnConns[player] = nil
	end
end

-- Records a first find of (squishy, variant) and tells that client about it.
-- No-op when already known, so SquishyService can call it on every pickup.
function DiscoveryService.MarkDiscovered(player: Player, squishyName: string, variantName: string?)
	if typeof(squishyName) ~= "string" then
		return
	end
	local key = keyFor(squishyName, variantName)
	local set = setFor(player)
	if set[key] then
		return
	end
	set[key] = true
	local remote = discoveredRemote
	if remote ~= nil then
		remote:FireClient(player, key)
	end
end

function DiscoveryService.IsDiscovered(player: Player, squishyName: string, variantName: string?): boolean
	local set = discovered[player]
	return set ~= nil and set[keyFor(squishyName, variantName)] == true
end

function DiscoveryService.Start(_services: any, _map: any)
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	discoveredRemote = remotes:WaitForChild("Discovered") :: RemoteEvent

	Players.PlayerAdded:Connect(safeSetup)
	Players.PlayerRemoving:Connect(cleanupPlayer)
	for _, player in Players:GetPlayers() do
		safeSetup(player)
	end
end

return DiscoveryService
