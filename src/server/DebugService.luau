--!strict
-- DebugService — the server half of the Studio dev panel (src/client/DebugPanel).
--
-- STUDIO ONLY. `Start` returns immediately outside Studio and the remote is
-- never created, so a published server carries no debug surface at all: there
-- is nothing for a client to invoke and nothing to remember to switch off
-- before shipping. That is the whole security model — no allowlist to keep up
-- to date, no flag to leave on by accident.
--
-- Every action happens HERE, through the same public service APIs the game
-- itself uses (see the Cross-service API in DESIGN.md), so a debug action
-- lands the game in a state it could genuinely have reached by playing. The
-- panel only names a command and a payload; it changes nothing on its own.
--
-- Adding a command: put a function in `commands` returning (ok, message). It
-- is pcall'd, and the caller gets a fresh snapshot either way.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local DebugService = {}

local REMOTE_NAME = "DebugCommand"
-- Roughly a character's standing offset above the ground it is placed on.
local STAND_HEIGHT = 5
-- Enough for a fully built-out base (10 slots x 9 storeys) in one press.
local MAX_BULK_PLACE = 120

local TRACKS = { "Speed", "Stealth", "Carry" }

local servicesRef: any = nil
local mapRef: any = nil
local rng = Random.new()

-- Catalog defs grouped by rarity, for "give me a Legendary" rolls.
local byRarity: { [string]: { any } } = {}
for _, def in Config.Squishies :: { any } do
	local pool = byRarity[def.rarity]
	if pool == nil then
		pool = {}
		byRarity[def.rarity] = pool
	end
	table.insert(pool, def)
end

local function service(name: string): any
	return servicesRef ~= nil and servicesRef[name] or nil
end

-- Picks a catalog def: an explicit name wins, otherwise a roll inside `rarity`.
local function pickDef(payload: any): any?
	local name = payload.squishy
	if typeof(name) == "string" and Config.SquishyByName[name] ~= nil then
		return Config.SquishyByName[name]
	end
	local pool = byRarity[tostring(payload.rarity)]
	if pool == nil or #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

-- "3 slots" / "1 slot", spelled out rather than bolted together with an "s".
local function counted(n: number, one: string, many: string): string
	return ("%d %s"):format(n, if n == 1 then one else many)
end

-- "Normal" is the absence of a variant everywhere else, so it maps to nil.
local function pickVariant(payload: any): string?
	local name = payload.variant
	if typeof(name) == "string" and name ~= "Normal" and Config.VariantByName[name] ~= nil then
		return name
	end
	return nil
end

-- ------------------------------------------------------------------ commands --

local commands: { [string]: (Player, any) -> (boolean, string) } = {}

-- A no-op whose only job is to bring back a fresh snapshot.
commands.status = function(_player, _payload)
	return true, ""
end

commands.cash = function(player, payload)
	local economy = service("EconomyService")
	if economy == nil then
		return false, "no EconomyService"
	end
	local set = tonumber(payload.set)
	if set ~= nil then
		economy.SetMoney(player, set)
	else
		-- SetMoney, not AddMoney: a debug grant hands over exactly the number on
		-- the button, never that number times the rebirth multiplier.
		local delta = tonumber(payload.delta) or 0
		economy.SetMoney(player, math.max(0, economy.GetMoney(player) + delta))
	end
	return true, ("money now %s"):format(Util.formatMoney(economy.GetMoney(player)))
end

commands.upgrade = function(player, payload)
	if payload.maxAll == true then
		for _, name in TRACKS do
			local values = (Config.Upgrades :: any)[name].values
			player:SetAttribute("Upgrade_" .. name, #values)
		end
		return true, "every upgrade track maxed"
	end

	local track = payload.track
	if typeof(track) ~= "string" or (Config.Upgrades :: any)[track] == nil then
		return false, "unknown upgrade track"
	end
	local values = (Config.Upgrades :: any)[track].values
	local current = tonumber(player:GetAttribute("Upgrade_" .. track)) or 1
	local wanted = tonumber(payload.level) or (current + (tonumber(payload.delta) or 0))
	local level = math.clamp(math.floor(wanted), 1, #values)
	player:SetAttribute("Upgrade_" .. track, level)
	return true, ("%s level %d/%d"):format(track, level, #values)
end

commands.rebirth = function(player, payload)
	local multipliers = Config.Rebirth.Multipliers :: { number }
	local current = tonumber(player:GetAttribute("Rebirths")) or 0
	local wanted = tonumber(payload.set) or (current + (tonumber(payload.delta) or 0))
	-- Multipliers are indexed by count + 1, so the last entry is the last count.
	local count = math.clamp(math.floor(wanted), 0, #multipliers - 1)
	player:SetAttribute("Rebirths", count)

	local rebirth = service("RebirthService")
	local mult = if rebirth ~= nil then rebirth.GetMultiplier(player) else 1
	return true, ("rebirth %d (income x%s)"):format(count, tostring(mult))
end

commands.give = function(player, payload)
	local squishy = service("SquishyService")
	if squishy == nil then
		return false, "no SquishyService"
	end
	local def = pickDef(payload)
	if def == nil then
		return false, "no squishy matches that rarity"
	end
	local variant = pickVariant(payload)
	if not squishy.GiveCarried(player, def.name, variant) then
		return false, "could not hand it over (already carrying?)"
	end
	local prefix = if variant ~= nil then variant .. " " else ""
	return true, ("carrying %s%s"):format(prefix, def.name)
end

commands.drop = function(player, _payload)
	local squishy = service("SquishyService")
	if squishy == nil then
		return false, "no SquishyService"
	end
	if not squishy.IsCarrying(player) then
		return false, "not carrying anything"
	end
	squishy.ForceDrop(player)
	return true, "dropped where you stand"
end

commands.spawnField = function(_player, payload)
	local squishy = service("SquishyService")
	if squishy == nil then
		return false, "no SquishyService"
	end
	local rarity = tostring(payload.rarity)
	if Config.RarityByName[rarity] == nil then
		return false, "unknown rarity"
	end
	local model = squishy.SpawnRarity(rarity)
	if model == nil then
		return false, ("field spawn of a %s failed"):format(rarity)
	end
	return true, ("%s spawned in the field"):format(model.Name)
end

commands.place = function(player, payload)
	local plot = service("PlotService")
	if plot == nil then
		return false, "no PlotService"
	end
	local wanted = math.clamp(math.floor(tonumber(payload.count) or 1), 1, MAX_BULK_PLACE)
	local variant = pickVariant(payload)
	local placed = 0
	for _ = 1, wanted do
		local def = pickDef(payload)
		if def == nil then
			break
		end
		-- A copy, because TryPlaceSquishy reads `variant` off the def it is given
		-- and the catalog entry must stay clean.
		local defCopy = table.clone(def)
		defCopy.variant = variant
		local ok, done = pcall(plot.TryPlaceSquishy, player, defCopy)
		if not ok or done ~= true then
			break
		end
		placed += 1
	end
	if placed == 0 then
		return false, "no free unlocked slot"
	end
	return true, ("placed " .. counted(placed, "squishy", "squishies"))
end

commands.clearPlot = function(player, _payload)
	local plot = service("PlotService")
	if plot == nil then
		return false, "no PlotService"
	end
	local cleared = plot.DebugClearSlots(player)
	return true, ("cleared " .. counted(cleared, "slot", "slots"))
end

commands.unlockAll = function(player, _payload)
	local plot = service("PlotService")
	if plot == nil then
		return false, "no PlotService"
	end
	local opened = plot.DebugUnlockAll(player)
	return true, ("opened " .. counted(opened, "slot", "slots"))
end

commands.floors = function(player, payload)
	local plot = service("PlotService")
	if plot == nil then
		return false, "no PlotService"
	end
	local above = math.floor(tonumber(payload.above) or 0)
	local below = math.floor(tonumber(payload.below) or 0)
	if not plot.DebugSetFloors(player, above, below) then
		return false, "no plot claimed yet"
	end
	return true, ("base rebuilt: %d up, %d down"):format(
		math.clamp(above, 0, Config.Plot.MaxAbove :: number),
		math.clamp(below, 0, Config.Plot.MaxBelow :: number)
	)
end

commands.enemies = function(player, payload)
	local enemy = service("EnemyService")
	if enemy == nil then
		return false, "no EnemyService"
	end
	local action = tostring(payload.action)
	if action == "freeze" then
		enemy.SetFrozen(true)
		return true, "giants frozen where they stand"
	elseif action == "thaw" then
		enemy.SetFrozen(false)
		return true, "giants patrolling again"
	elseif action == "wake" then
		local woken = enemy.WakeOn(player)
		return true, (counted(woken, "giant", "giants") .. " chasing you")
	elseif action == "calm" then
		enemy.CalmAll()
		return true, "giants back to sleep"
	end
	return false, ("unknown enemy action '%s'"):format(action)
end

commands.event = function(_player, payload)
	local event = service("EventService")
	if event == nil then
		return false, "no EventService"
	end
	local index = math.floor(tonumber(payload.index) or 1)
	local seconds = math.max(0, tonumber(payload.seconds) or 3)
	if not event.SetCountdown(index, seconds) then
		return false, "no such event"
	end
	local cfg = (Config.Events :: { any })[index]
	return true, ("%s event lands in %ds"):format(if cfg ~= nil then cfg.name else "?", seconds)
end

commands.spins = function(player, payload)
	local current = tonumber(player:GetAttribute("Spins")) or 0
	local total = math.max(0, current + math.floor(tonumber(payload.delta) or 1))
	player:SetAttribute("Spins", total)
	return true, counted(total, "spin", "spins")
end

commands.discoverAll = function(player, _payload)
	local discovery = service("DiscoveryService")
	if discovery == nil then
		return false, "no DiscoveryService"
	end
	local added = 0
	for _, def in Config.Squishies :: { any } do
		for _, variant in Config.Variants :: { any } do
			if not discovery.IsDiscovered(player, def.name, variant.name) then
				discovery.MarkDiscovered(player, def.name, variant.name)
				added += 1
			end
		end
	end
	return true, ("index filled in (%d new)"):format(added)
end

commands.daily = function(player, _payload)
	local daily = service("DailyService")
	if daily == nil then
		return false, "no DailyService"
	end
	local day = daily.Claim(player)
	if day == nil then
		return false, "already claimed today"
	end
	return true, ("claimed daily reward, day %d"):format(day)
end

commands.teleport = function(player, payload)
	local character = player.Character
	if character == nil then
		return false, "no character to move"
	end
	local where = tostring(payload.where)
	local ground: CFrame? = nil

	if where == "plot" then
		local plot = service("PlotService")
		ground = if plot ~= nil then plot.GetSpawnCFrame(player) else nil
	elseif where == "field" then
		ground = CFrame.new(mapRef.fieldCenter :: Vector3)
	elseif where == "board" then
		local board = mapRef.root:FindFirstChild("EventBoard")
		if board ~= nil and board:IsA("PVInstance") then
			-- Under the board on the ground, not floating up beside it.
			local at = board:GetPivot().Position
			ground = CFrame.new(at.X, (mapRef.fieldCenter :: Vector3).Y, at.Z)
		end
	end

	if ground == nil then
		return false, ("nowhere to teleport for '%s'"):format(where)
	end
	character:PivotTo(ground * CFrame.new(0, STAND_HEIGHT, 0))
	return true, ("teleported to the %s"):format(where)
end

-- ------------------------------------------------------------------ dispatch --

-- The state the panel prints in its status block. Everything else it needs
-- (money, upgrade levels, rebirths, spins, what you carry) is already a player
-- attribute it can read for itself.
local function snapshot(player: Player): any
	local info: any = { plot = nil, frozen = false }

	local plot = service("PlotService")
	if plot ~= nil and typeof(plot.DebugSnapshot) == "function" then
		local ok, result = pcall(plot.DebugSnapshot, player)
		info.plot = if ok then result else nil
	end

	local enemy = service("EnemyService")
	if enemy ~= nil and typeof(enemy.IsFrozen) == "function" then
		local ok, result = pcall(enemy.IsFrozen)
		info.frozen = ok and result == true
	end

	return info
end

local function handle(player: Player, command: any, payload: any): any
	if typeof(command) ~= "string" then
		return { ok = false, message = "bad command" }
	end
	local handler = commands[command]
	if handler == nil then
		return { ok = false, message = ("unknown command '%s'"):format(command) }
	end

	local body = if typeof(payload) == "table" then payload else {}
	local ran, okOrErr, message = pcall(handler, player, body)
	if not ran then
		warn(("[DebugService] %s failed for %s: %s"):format(command, player.Name, tostring(okOrErr)))
		return { ok = false, message = tostring(okOrErr), snapshot = snapshot(player) }
	end
	return { ok = okOrErr == true, message = tostring(message), snapshot = snapshot(player) }
end

function DebugService.Start(services: any, map: any)
	-- The one and only gate. No remote exists outside Studio, so the panel has
	-- nothing to talk to in a published server.
	if not RunService:IsStudio() then
		return
	end
	servicesRef = services
	mapRef = map

	local remote = Instance.new("RemoteFunction")
	remote.Name = REMOTE_NAME
	remote.OnServerInvoke = function(player: Player, command: any, payload: any)
		return handle(player, command, payload)
	end
	remote.Parent = ReplicatedStorage:WaitForChild("Remotes")

	print(("[%s] dev panel ready (Studio only) — press F4"):format(Config.GameName))
end

return DebugService
