--!strict
-- SaveService — a player's progress, kept between sessions.
--
-- One DataStore key per player holding everything they have earned: money,
-- rebirths, upgrade levels, spins, an active boost, the index pages they have
-- filled in, and the plot itself — floors bought, ground slots unlocked, and
-- every squishy standing on it with its variant and level.
--
-- Not saved, deliberately: anything the platform already knows. Game passes
-- (VIP, permanent speed, the basement gear) are re-checked against
-- MarketplaceService on join, so a profile can never grant one that was
-- refunded, and daily streaks are DailyService's own store.
--
-- THE ONE RULE THIS FILE EXISTS TO ENFORCE: never write a profile for a player
-- whose load did not come back. A DataStore hiccup on join otherwise looks
-- exactly like a brand-new player, and the first autosave would overwrite
-- everything they own with an empty plot. `loaded[player]` gates every write.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SaveService = {}

local STORE_NAME = "Progress_v1"
-- Seconds between background saves. Long enough not to burn through the write
-- budget on a full server, short enough that a crash costs a couple of minutes.
local AUTOSAVE_SECONDS = 120
-- A plot is built a moment after the player joins; the profile waits for it.
local PLOT_WAIT_SECONDS = 20
local PLOT_POLL = 0.25
-- Retries for the initial read. A failed load is NOT an empty profile.
local LOAD_ATTEMPTS = 3
local LOAD_BACKOFF = 2

local store: DataStore? = nil
local servicesRef: any = nil

-- player -> true once their profile has been read (or confirmed absent).
-- No entry means "do not write": see the header.
local loaded: { [Player]: boolean } = {}
-- player -> the profile as read, so a save can fall back to it for anything
-- the session never managed to apply.
local profiles: { [Player]: any } = {}

local function keyFor(player: Player): string
	return ("p_%d"):format(player.UserId)
end

local function service(name: string): any
	return servicesRef ~= nil and servicesRef[name] or nil
end

-- ---------------------------------------------------------------- gather --

local function numberAttribute(player: Player, name: string, fallback: number): number
	local raw = player:GetAttribute(name)
	return if typeof(raw) == "number" then raw else fallback
end

-- Everything worth writing down, read back out of the live services.
local function gather(player: Player): any
	local economy = service("EconomyService")
	local upgrades = service("UpgradeService")
	local discovery = service("DiscoveryService")
	local plots = service("PlotService")

	local upgradeLevels: { [string]: number } = {}
	if upgrades ~= nil then
		for _, track in upgrades.Tracks() do
			upgradeLevels[track] = upgrades.GetLevel(player, track)
		end
	end

	local previous = profiles[player] or {}
	-- The plot falls back to the profile as loaded. A player who left before
	-- their plot finished building must not have it saved as empty.
	local plot = previous.plot
	if plots ~= nil then
		local ok, exported = pcall(plots.ExportPlot, player)
		if ok and exported ~= nil then
			plot = exported
		end
	end

	return {
		version = 1,
		money = if economy ~= nil then economy.GetMoney(player) else numberAttribute(player, "Money", 0),
		rebirths = numberAttribute(player, "Rebirths", 0),
		spins = numberAttribute(player, "Spins", 0),
		boostUntil = numberAttribute(player, "BoostUntil", 0),
		upgrades = upgradeLevels,
		discovered = if discovery ~= nil then discovery.ExportKeys(player) else (previous.discovered or {}),
		plot = plot,
		savedAt = os.time(),
	}
end

-- ----------------------------------------------------------------- apply --

-- The scalars, which need nothing from the world and can land immediately.
local function applyScalars(player: Player, profile: any)
	local economy = service("EconomyService")
	if economy ~= nil and typeof(profile.money) == "number" then
		economy.SetMoney(player, math.max(0, math.floor(profile.money)))
	end
	if typeof(profile.rebirths) == "number" then
		player:SetAttribute("Rebirths", math.max(0, math.floor(profile.rebirths)))
	end
	if typeof(profile.spins) == "number" then
		player:SetAttribute("Spins", math.max(0, math.floor(profile.spins)))
	end
	-- A boost that expired while they were away is simply over.
	if typeof(profile.boostUntil) == "number" and profile.boostUntil > os.time() then
		player:SetAttribute("BoostUntil", math.floor(profile.boostUntil))
	end

	local upgrades = service("UpgradeService")
	if upgrades ~= nil and typeof(profile.upgrades) == "table" then
		for track, level in profile.upgrades do
			if typeof(track) == "string" and typeof(level) == "number" then
				upgrades.SetLevel(player, track, level)
			end
		end
	end

	local discovery = service("DiscoveryService")
	if discovery ~= nil and typeof(profile.discovered) == "table" then
		discovery.ImportKeys(player, profile.discovered)
	end
end

-- The plot, once PlotService has finished building one to put things in.
local function applyPlot(player: Player, profile: any)
	if typeof(profile.plot) ~= "table" then
		return
	end
	local plots = service("PlotService")
	if plots == nil then
		return
	end
	local deadline = os.clock() + PLOT_WAIT_SECONDS
	while plots.GetPlotOrigin(player) == nil do
		if player.Parent == nil or os.clock() >= deadline then
			-- Left, or the plot never appeared. Their profile is untouched on
			-- disk and `plot` falls back to it on the next save, so nothing is
			-- lost by giving up here.
			return
		end
		task.wait(PLOT_POLL)
	end
	local ok, restoredOrErr, count = pcall(plots.ImportPlot, player, profile.plot)
	if not ok then
		warn(("[SaveService] plot restore failed for %s: %s"):format(player.Name, tostring(restoredOrErr)))
		return
	end
	if restoredOrErr == true then
		print(("[%s] restored %s: %d squishies, %d/%d floors"):format(
			Config.GameName,
			player.Name,
			tonumber(count) or 0,
			tonumber(profile.plot.floorsAbove) or 0,
			tonumber(profile.plot.floorsBelow) or 0
		))
	end
end

-- ------------------------------------------------------------ load / save --

local function readProfile(player: Player): (boolean, any)
	local dataStore = store
	if dataStore == nil then
		return false, nil
	end
	for attempt = 1, LOAD_ATTEMPTS do
		local ok, result = pcall(function()
			return dataStore:GetAsync(keyFor(player))
		end)
		if ok then
			return true, result
		end
		if attempt < LOAD_ATTEMPTS then
			task.wait(LOAD_BACKOFF * attempt)
		else
			warn(("[SaveService] load failed for %s: %s"):format(player.Name, tostring(result)))
		end
	end
	return false, nil
end

local function loadPlayer(player: Player)
	local ok, profile = readProfile(player)
	if not ok then
		-- Explicitly NOT marking them loaded: this session will not write, so a
		-- transient DataStore failure costs them one session's progress rather
		-- than everything they have ever earned.
		warn(("[SaveService] %s is playing unsaved this session (their profile is untouched)"):format(player.Name))
		return
	end
	loaded[player] = true
	if typeof(profile) ~= "table" then
		return -- genuinely new player; nothing to apply
	end
	profiles[player] = profile
	local applied, err = pcall(applyScalars, player, profile)
	if not applied then
		warn(("[SaveService] scalar restore failed for %s: %s"):format(player.Name, tostring(err)))
	end
	task.spawn(function()
		local plotOk, plotErr = pcall(applyPlot, player, profile)
		if not plotOk then
			warn(("[SaveService] plot restore errored for %s: %s"):format(player.Name, tostring(plotErr)))
		end
	end)
end

-- `reason` only colours the warning; every path is the same write.
local function savePlayer(player: Player, reason: string): boolean
	if loaded[player] ~= true then
		return false -- never write over a profile that was never read
	end
	local dataStore = store
	if dataStore == nil then
		return false
	end
	local ok, snapshot = pcall(gather, player)
	if not ok then
		warn(("[SaveService] could not gather %s (%s): %s"):format(player.Name, reason, tostring(snapshot)))
		return false
	end
	profiles[player] = snapshot
	-- UpdateAsync, not SetAsync: two servers holding the same player (a rejoin
	-- racing a leave) then queue rather than silently overwrite each other.
	local written, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player), function(_old)
			return snapshot
		end)
	end)
	if not written then
		warn(("[SaveService] save failed for %s (%s): %s"):format(player.Name, reason, tostring(err)))
		return false
	end
	return true
end

-- Public: the dev panel and anything else that wants a save on demand.
function SaveService.SaveNow(player: Player): boolean
	return savePlayer(player, "manual")
end

function SaveService.Start(services: any, _map: any)
	servicesRef = services

	local ok, opened = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = opened
	else
		warn(
			("[%s] SaveService has no DataStore access — progress is session-only this run. In Studio, tick Game Settings > Security > Enable Studio Access to API Services."):format(
				Config.GameName
			)
		)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		savePlayer(player, "leaving")
		loaded[player] = nil
		profiles[player] = nil
	end)

	-- Autosave, staggered per player rather than all at once, so a full server
	-- does not fire twenty writes on the same frame.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(savePlayer, player, "autosave")
				task.wait(0.2)
			end
		end
	end)

	-- Shutdown. BindToClose blocks the server for up to 30s, which is exactly
	-- the window this needs. Studio closes without it, so it is skipped there
	-- to avoid a pointless wait on every playtest stop.
	if not RunService:IsStudio() then
		game:BindToClose(function()
			local pending = 0
			for _, player in Players:GetPlayers() do
				pending += 1
				task.spawn(function()
					savePlayer(player, "shutdown")
					pending -= 1
				end)
			end
			local deadline = os.clock() + 25
			while pending > 0 and os.clock() < deadline do
				task.wait(0.1)
			end
		end)
	end
end

return SaveService
