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
-- After a failed load, keep trying quietly in the background so a transient
-- DataStore blip at join does not doom the whole session to unsaved.
local RELOAD_INTERVAL = 30
-- Retries for a leaving/shutdown write. The load retries; the save must too, or
-- one throttle at logout loses the session's tail.
local SAVE_ATTEMPTS = 3
local SAVE_BACKOFF = 1
-- Processed developer-product receipts remembered per profile, newest kept, so
-- a re-delivered receipt is recognised and never granted twice. Roblox only
-- re-delivers recent unacknowledged receipts, so this stays small.
local RECEIPT_MEMORY = 200

local store: DataStore? = nil
local servicesRef: any = nil

-- player -> true once their profile has been read (or confirmed absent).
-- No entry means "do not write": see the header.
local loaded: { [Player]: boolean } = {}
-- player -> true once the profile's scalars are applied (or the player is new).
-- ShopService gates receipt grants on this so a purchase is never granted into
-- a session that is about to have its Money/Spins overwritten by the load.
local ready: { [Player]: boolean } = {}
-- player -> true only once the plot has actually been restored (or there was
-- nothing to restore). Until then `gather` must NOT trust the live plot: it is
-- the empty one built before the profile landed, and saving it wipes the base.
local plotRestored: { [Player]: boolean } = {}
-- player -> ordered list of processed receipt PurchaseIds (persisted), so every
-- product handler is idempotent across a crash-and-rejoin, not just the pack.
local receiptLog: { [Player]: { string } } = {}
-- player -> the profile as read, so a save can fall back to it for anything
-- the session never managed to apply.
local profiles: { [Player]: any } = {}
-- player -> money the plot earned while they were away, held for the popup's
-- Collect button rather than credited silently. Never written to the profile:
-- once collected the balance simply carries it.
local offlinePending: { [Player]: number } = {}

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
	-- their plot finished building — OR whose profile has not restored into the
	-- live plot yet — must not have it saved as the empty starter base. Only
	-- once `plotRestored` is set is the live plot the truth worth writing.
	local plot = previous.plot
	local plotIsFresh = false
	if plots ~= nil and plotRestored[player] == true then
		local ok, exported = pcall(plots.ExportPlot, player)
		if ok and exported ~= nil then
			plot = exported
			plotIsFresh = true
		end
	end

	-- The plot's raw $/s right now, so the next visit can pay out what the
	-- shelf earned in between (see Config.Offline). Same fallback rule as the
	-- plot itself: a fresh rate is only trusted when the plot it was read from
	-- actually exists, or a half-built session would zero a real rate.
	local incomeRate = tonumber(previous.incomeRate) or 0
	if plotIsFresh and plots ~= nil then
		local rateOk, rate = pcall(plots.GetIncomeRate, player)
		if rateOk and typeof(rate) == "number" then
			incomeRate = rate
		end
	end

	return {
		version = 1,
		money = if economy ~= nil then economy.GetMoney(player) else numberAttribute(player, "Money", 0),
		incomeRate = incomeRate,
		rebirths = numberAttribute(player, "Rebirths", 0),
		spins = numberAttribute(player, "Spins", 0),
		boostUntil = numberAttribute(player, "BoostUntil", 0),
		-- One-time purchases must stay bought across sessions, or the shop
		-- would offer them again to someone who already paid.
		starterPack = player:GetAttribute("StarterPackOwned") == true,
		upgrades = upgradeLevels,
		discovered = if discovery ~= nil then discovery.ExportKeys(player) else (previous.discovered or {}),
		plot = plot,
		-- Processed receipt ids, so a re-delivery after a crash is not re-granted.
		receipts = receiptLog[player] or previous.receipts or {},
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
	if profile.starterPack == true then
		player:SetAttribute("StarterPackOwned", true)
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
	-- Nothing to restore: the live plot the player builds this session IS the
	-- truth, so let `gather` trust it immediately.
	if typeof(profile.plot) ~= "table" then
		plotRestored[player] = true
		return
	end
	local plots = service("PlotService")
	if plots == nil then
		plotRestored[player] = true
		return
	end
	local deadline = os.clock() + PLOT_WAIT_SECONDS
	while plots.GetPlotOrigin(player) == nil do
		if player.Parent == nil or os.clock() >= deadline then
			-- Left, or the plot never appeared. plotRestored stays false so the
			-- profile's stored plot is kept on the next save — nothing is lost
			-- by giving up here.
			return
		end
		task.wait(PLOT_POLL)
	end
	local ok, restoredOrErr, count = pcall(plots.ImportPlot, player, profile.plot)
	if not ok then
		warn(("[SaveService] plot restore failed for %s: %s"):format(player.Name, tostring(restoredOrErr)))
		return
	end
	-- Restored (or the plot was empty either way): the live plot is now the
	-- profile, safe to export and save from here on.
	plotRestored[player] = true
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

-- What the plot earned while its owner was away, priced from the profile's
-- $/s and held for the popup's Collect button. OfflineChecked is the client's
-- signal that the verdict is in (pending or not), so DailyUi knows when it may
-- take the stage.
local function computeOffline(player: Player, profile: any)
	local offline = Config.Offline :: any
	local away = os.time() - (tonumber(profile.savedAt) or os.time())
	local rate = tonumber(profile.incomeRate) or 0
	if away < (tonumber(offline.MinimumAwaySeconds) or 60) or rate <= 0 then
		return
	end
	-- The cap is a clock, not a number: stopping the away time at
	-- MaxAwaySeconds caps the payout at rate x that many seconds, and the
	-- limit scales with the plot instead of flattening every big base to the
	-- same figure.
	away = math.min(away, tonumber(offline.MaxAwaySeconds) or 10800)
	-- The figure shown is the figure paid, multipliers already in, so the
	-- popup can never contradict the balance afterwards.
	local preview = rate * away
	local economy = service("EconomyService")
	if economy ~= nil then
		local ok, previewed = pcall(economy.PreviewIncome, player, preview)
		if ok and typeof(previewed) == "number" then
			preview = previewed
		end
	end
	local pending = math.floor(preview)
	if pending >= 1 then
		offlinePending[player] = pending
		player:SetAttribute("OfflinePending", pending)
	end
end

-- Restores a successfully read profile into the live session and opens the
-- gates (ready → receipts may grant; plotRestored → the plot may be saved).
-- `allowOffline` is false on the background-recovery path, where the offline
-- verdict has already been delivered for this session.
local function applyLoadedProfile(player: Player, profile: any, allowOffline: boolean)
	profiles[player] = profile
	receiptLog[player] = if typeof(profile.receipts) == "table" then profile.receipts else {}
	local applied, err = pcall(applyScalars, player, profile)
	if not applied then
		warn(("[SaveService] scalar restore failed for %s: %s"):format(player.Name, tostring(err)))
	end
	-- After the scalars: the multiplier preview reads the restored rebirths.
	if allowOffline then
		pcall(computeOffline, player, profile)
	end
	ready[player] = true
	player:SetAttribute("OfflineChecked", true)
	task.spawn(function()
		local plotOk, plotErr = pcall(applyPlot, player, profile)
		if not plotOk then
			warn(("[SaveService] plot restore errored for %s: %s"):format(player.Name, tostring(plotErr)))
		end
	end)
end

-- Everything a brand-new (or recovered-empty) player needs: nothing to restore,
-- so every gate opens at once and the live session is the truth.
local function markFresh(player: Player)
	receiptLog[player] = {}
	plotRestored[player] = true
	ready[player] = true
	player:SetAttribute("OfflineChecked", true)
end

local function loadPlayer(player: Player)
	local ok, profile = readProfile(player)
	if not ok then
		-- Do NOT mark loaded: this session will not overwrite their real save.
		-- But it is not terminal — keep retrying quietly so a transient blip is
		-- recovered mid-session, and set SaveDisabled so the client can warn the
		-- player their progress is at risk rather than losing it silently.
		warn(("[SaveService] %s could not load — session not saving yet, retrying in the background"):format(player.Name))
		player:SetAttribute("SaveDisabled", true)
		player:SetAttribute("OfflineChecked", true)
		task.spawn(function()
			while player.Parent ~= nil and loaded[player] ~= true do
				task.wait(RELOAD_INTERVAL)
				if player.Parent == nil then
					return
				end
				local rok, rprofile = readProfile(player)
				if rok then
					loaded[player] = true
					player:SetAttribute("SaveDisabled", nil)
					if typeof(rprofile) == "table" then
						applyLoadedProfile(player, rprofile, false)
					else
						markFresh(player)
					end
					print(("[%s] recovered %s's profile on retry; saving re-enabled"):format(Config.GameName, player.Name))
					return
				end
			end
		end)
		return
	end
	loaded[player] = true
	if typeof(profile) ~= "table" then
		markFresh(player) -- genuinely new player; nothing to apply
		return
	end
	applyLoadedProfile(player, profile, true)
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
	local myStamp = tonumber(snapshot.savedAt) or 0
	-- UpdateAsync with a stale-write guard: queueing alone still lets an older
	-- session clobber a newer one (a rejoin on a second server racing this
	-- server's delayed leave-save). If the stored profile is NEWER than ours,
	-- keep it. Retried a few times so one throttle at logout is not fatal.
	for attempt = 1, SAVE_ATTEMPTS do
		local written, err = pcall(function()
			dataStore:UpdateAsync(keyFor(player), function(old)
				if type(old) == "table" and (tonumber(old.savedAt) or 0) > myStamp then
					return old
				end
				return snapshot
			end)
		end)
		if written then
			return true
		end
		warn(("[SaveService] save attempt %d/%d failed for %s (%s): %s"):format(
			attempt, SAVE_ATTEMPTS, player.Name, reason, tostring(err)))
		if attempt < SAVE_ATTEMPTS then
			task.wait(SAVE_BACKOFF * attempt)
		end
	end
	return false
end

-- Public: the dev panel and anything else that wants a save on demand.
function SaveService.SaveNow(player: Player): boolean
	return savePlayer(player, "manual")
end

-- True once the profile's scalars are applied (or the player is new). Until
-- then a grant would be overwritten by the pending load, so ShopService holds
-- receipts as NotProcessedYet — Roblox re-delivers them once this is true.
function SaveService.IsReady(player: Player): boolean
	return ready[player] == true
end

-- Whether this exact receipt was already granted (survives a crash-and-rejoin),
-- so a re-delivery is acknowledged without granting the reward a second time.
function SaveService.WasProcessed(player: Player, purchaseId: string): boolean
	local log = receiptLog[player]
	if log == nil then
		return false
	end
	for _, id in log do
		if id == purchaseId then
			return true
		end
	end
	return false
end

-- Records a granted receipt and persists it immediately, so a crash in the
-- window before the next autosave cannot lose the paid grant OR let the
-- re-delivery double-grant it.
function SaveService.MarkProcessed(player: Player, purchaseId: string)
	local log = receiptLog[player]
	if log == nil then
		log = {}
		receiptLog[player] = log
	end
	table.insert(log, purchaseId)
	while #log > RECEIPT_MEMORY do
		table.remove(log, 1)
	end
	savePlayer(player, "receipt")
end

-- Deletes the stored profile outright — the dev panel's progress wipe. The
-- in-memory copy goes too, and the player is marked loaded regardless of how
-- their join went: with the profile gone there is nothing left for the
-- write-gate to protect, and the session SHOULD keep saving, because what it
-- writes next is the freshly reset state.
function SaveService.WipeProgress(player: Player): boolean
	local dataStore = store
	if dataStore == nil then
		return false
	end
	local ok, err = pcall(function()
		dataStore:RemoveAsync(keyFor(player))
	end)
	if not ok then
		warn(("[SaveService] wipe failed for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	profiles[player] = nil
	offlinePending[player] = nil
	player:SetAttribute("OfflinePending", nil)
	-- Wiped clean: the session keeps saving, writing the freshly reset state.
	receiptLog[player] = {}
	plotRestored[player] = true
	ready[player] = true
	loaded[player] = true
	return true
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

	-- The while-you-were-away popup's Collect button. Credits exactly the
	-- figure that was shown — the multipliers were applied when it was priced,
	-- so this is a straight addition, not another AddMoney.
	local claim = ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("OfflineClaim")
	if claim ~= nil and claim:IsA("RemoteFunction") then
		claim.OnServerInvoke = function(player: Player)
			local pending = offlinePending[player]
			offlinePending[player] = nil
			player:SetAttribute("OfflinePending", nil)
			if pending == nil then
				return nil
			end
			local economy = service("EconomyService")
			if economy ~= nil then
				economy.SetMoney(player, economy.GetMoney(player) + pending)
			end
			return pending
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		savePlayer(player, "leaving")
		loaded[player] = nil
		ready[player] = nil
		plotRestored[player] = nil
		receiptLog[player] = nil
		profiles[player] = nil
		offlinePending[player] = nil
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
