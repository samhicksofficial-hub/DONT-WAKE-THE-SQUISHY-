--!strict
-- WheelService — the free-spin wheel behind Frames.Wheel (DESIGN.md,
-- "Progression services"). Contract highlights:
--   * Owns the `Spins` and `NextSpinAt` player attributes. A one-second loop
--     grants +1 spin whenever os.time() passes NextSpinAt and re-arms it.
--   * TrySpin returns the 1-based index of the winning Config.Wheel.Rewards
--     entry so the client can spin the wedge that actually won, or nil when
--     the player is out of spins.
--   * Rewards are granted here: cash through EconomyService (so the rebirth
--     multiplier applies), a squishy delivered to the player's plot through
--     PlotService, or a timed `SpeedBoost` attribute that SquishyService reads
--     when it computes WalkSpeed (this service never touches WalkSpeed).
--   * A speed win is a LOAN of a real Speed Coil from GearService's templates,
--     taken back when the time runs out. The boost RIDES THE COIL: SpeedBoost
--     is set only while a lent one is actually in the player's hands, so
--     putting it away stops the running and taking it out starts it again. The
--     coil only looks the part — the imported model's script is an empty
--     decompiler stub — so the attribute is what actually moves the player, and
--     the loan never touches a coil bought with the pass.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Config = require(sharedFolder:WaitForChild("Config"))
local Util = require(sharedFolder:WaitForChild("Util"))

-- Seconds of a rarity's income paid out when a squishy reward cannot actually
-- be delivered to a plot (no PlotService.TryPlaceSquishy, plot not claimed
-- yet, or every unlocked slot full) — the player still wins something.
local CONSOLATION_SECONDS = 60

local REFILL_INTERVAL = 1 -- seconds between free-spin timer checks

local WheelService = {}

local rng = Random.new()
local servicesRef: any = nil

-- Player -> the speed loan currently running for them. `expiry` doubles as the
-- timer's identity stamp: an older timer firing late compares unequal and
-- leaves a newer loan alone.
-- `toolName` is what the boost rides; nil when this place has no gear art to
-- lend, in which case the boost simply runs for the whole loan.
type Loan = { expiry: number, mult: number, toolName: string? }
local loans: { [Player]: Loan } = {}

-- Rarity name -> the catalog entries of that rarity (built once).
local squishiesByRarity: { [string]: { any } } = {}
for _, def in Config.Squishies do
	local pool = squishiesByRarity[def.rarity]
	if not pool then
		pool = {}
		squishiesByRarity[def.rarity] = pool
	end
	table.insert(pool, def)
end

-- ---------- attributes ----------

-- Gives a joining player their starting spins and arms the free-spin timer.
-- Idempotent: never overwrites a value this session already set.
local function setupPlayer(player: Player)
	if player:GetAttribute("Spins") == nil then
		player:SetAttribute("Spins", Config.Wheel.StartingSpins)
	end
	if player:GetAttribute("NextSpinAt") == nil then
		player:SetAttribute("NextSpinAt", os.time() + Config.Wheel.SpinCooldown)
	end
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[WheelService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

function WheelService.GetSpins(player: Player): number
	local value = player:GetAttribute("Spins")
	return if typeof(value) == "number" then value else 0
end

-- ---------- rewards ----------

local function addMoney(player: Player, amount: number)
	local economy = servicesRef and servicesRef.EconomyService
	if economy then
		economy.AddMoney(player, amount)
	end
end

-- Stamped on a lent tool so the timer only ever takes back what the wheel
-- handed out, and never a coil the player bought with the game pass.
local LOAN_ATTRIBUTE = "WheelLoan"

local function gearByKey(key: string): any
	for _, gear in Config.Gear :: { any } do
		if gear.key == key then
			return gear
		end
	end
	return nil
end

-- True while the player is already holding a lent copy of `toolName`, wherever
-- they have put it. A second speed win extends the loan rather than handing
-- over a second identical coil.
local function holdsLoan(player: Player, toolName: string): boolean
	for _, place in { player:FindFirstChildOfClass("Backpack"), player:FindFirstChildOfClass("StarterGear"), player.Character } do
		if place ~= nil then
			for _, child in place:GetChildren() do
				if child:IsA("Tool") and child.Name == toolName and child:GetAttribute(LOAN_ATTRIBUTE) == true then
					return true
				end
			end
		end
	end
	return false
end

-- Puts a copy of a Config.Gear tool in the player's kit for the length of the
-- loan, and returns the tool's name so the boost knows what to ride. Nil means
-- there was nothing to lend and the caller should fall back.
--
-- StarterGear as well as Backpack, so dying does not end the loan early.
--
-- A player who already owns the pass is lent NOTHING — they carry their own,
-- and a loan timer must never confiscate a pass item — but the name still comes
-- back, so winning the wedge speeds up the coil they already have instead of
-- paying them nothing at all.
local function lendTool(player: Player, gearKey: string): string?
	local gearService = servicesRef and servicesRef.GearService
	local gear = gearByKey(gearKey)
	if gearService == nil or gear == nil then
		return nil
	end
	local ok, template = pcall(gearService.Template, gear)
	if not ok or template == nil or not template:IsA("Tool") then
		return nil
	end
	if player:GetAttribute("Owns" .. tostring(gear.key)) == true then
		return template.Name
	end
	if holdsLoan(player, template.Name) then
		return template.Name -- a loan already running; extending it is enough
	end
	for _, container in { player:FindFirstChildOfClass("Backpack"), player:FindFirstChildOfClass("StarterGear") } do
		if container ~= nil then
			local clone = template:Clone()
			clone:SetAttribute(LOAN_ATTRIBUTE, true)
			-- A dropped tool lands in the Workspace, where the recall cannot
			-- reach it: a lent coil left lying on the field would outlive its
			-- loan and be free for anyone. Borrowed things do not get dropped.
			clone.CanBeDropped = false
			clone.Parent = container
		end
	end
	return template.Name
end

-- Takes back every copy the wheel lent, including one currently equipped.
local function recallTools(player: Player)
	for _, place in { player:FindFirstChildOfClass("Backpack"), player:FindFirstChildOfClass("StarterGear"), player.Character } do
		if place ~= nil then
			for _, child in place:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute(LOAN_ATTRIBUTE) == true then
					child:Destroy()
				end
			end
		end
	end
end

-- True while the loan's tool is actually in the player's hands. An equipped
-- Tool is a child of the Character; sitting in the Backpack it is not.
--
-- Matched by NAME rather than by the loan stamp, so a pass owner's own coil
-- counts too. Only the recall stays restricted to lent copies.
local function holdingTool(player: Player, toolName: string): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name == toolName then
			return true
		end
	end
	return false
end

-- The boost follows the coil: on only while it is held AND the loan is still
-- running. SquishyService watches this attribute and re-applies WalkSpeed when
-- it moves, so setting it here is the whole job.
local function refreshBoost(player: Player)
	local loan = loans[player]
	if loan == nil then
		player:SetAttribute("SpeedBoost", nil)
		return
	end
	-- No tool to ride — this place carries no gear art — so the boost runs for
	-- the whole loan rather than a win paying out nothing.
	if loan.toolName == nil or holdingTool(player, loan.toolName) then
		player:SetAttribute("SpeedBoost", loan.mult)
	else
		player:SetAttribute("SpeedBoost", nil)
	end
end

-- Starts a speed loan: the gear the reward names goes into the player's kit for
-- `reward.duration` seconds, and the multiplier rides the gear rather than the
-- clock — put the coil away and you walk, take it out again and you run, until
-- the loan runs out and the coil goes home. The coil is scenery on its own: its
-- imported script is an empty stub, so SpeedBoost is what actually moves the
-- player, and nothing here writes WalkSpeed itself.
local function lendSpeed(player: Player, reward: any)
	local duration = tonumber(reward.duration) or 0
	if duration <= 0 then
		return
	end
	local toolName: string? = nil
	if typeof(reward.gear) == "string" then
		local ok, name = pcall(lendTool, player, reward.gear)
		if ok and typeof(name) == "string" then
			toolName = name
		end
	end
	local expiry = os.clock() + duration
	loans[player] = { expiry = expiry, mult = reward.mult, toolName = toolName }
	-- Usually a no-op right here: the coil arrives in the Backpack, so the
	-- player is not holding it yet and equipping it is what starts the running.
	refreshBoost(player)
	task.delay(duration, function()
		-- Only the timer holding the current stamp may end the loan, so a
		-- second win is never cut short by the first win's timer.
		local loan = loans[player]
		if loan == nil or loan.expiry ~= expiry then
			return
		end
		loans[player] = nil
		pcall(recallTools, player)
		pcall(refreshBoost, player)
	end)
end

-- Delivers a random squishy of `rarityName` to the player's plot. Falls back
-- to a cash consolation when PlotService cannot take it (see
-- CONSOLATION_SECONDS above).
local function grantSquishy(player: Player, rarityName: string)
	local pool = squishiesByRarity[rarityName]
	if not pool or #pool == 0 then
		return
	end
	local def = pool[rng:NextInteger(1, #pool)]

	local plotService = servicesRef and servicesRef.PlotService
	if plotService and typeof(plotService.TryPlaceSquishy) == "function" then
		local ok, placed = pcall(plotService.TryPlaceSquishy, player, def)
		if ok and placed then
			return
		end
	end

	local rarity = Config.RarityByName[rarityName]
	local income = if rarity then rarity.income else 0
	addMoney(player, income * CONSOLATION_SECONDS)
end

local function grantReward(player: Player, reward: any)
	if reward.kind == "cash" then
		addMoney(player, reward.amount)
	elseif reward.kind == "squishy" then
		grantSquishy(player, reward.rarity)
	elseif reward.kind == "speed" then
		lendSpeed(player, reward)
	end
end

-- ---------- spinning ----------

-- Spends one spin and rolls a wedge. Returns the winning wedge's 1-based
-- index into Config.Wheel.Rewards (the client spins to it), or nil when the
-- player has no spins left.
function WheelService.TrySpin(player: Player): number?
	local spins = WheelService.GetSpins(player)
	if spins < 1 then
		return nil
	end
	player:SetAttribute("Spins", spins - 1)

	local rewards = Config.Wheel.Rewards :: { any }
	local reward = Util.weightedRandom(rewards, rng)
	local index = table.find(rewards, reward) or 1

	-- The wedge is already decided: a bad grant must not cost the player the
	-- animation (or the spin), so it is contained here.
	local ok, err = pcall(grantReward, player, reward)
	if not ok then
		warn(("[WheelService] reward %d failed for %s: %s"):format(index, player.Name, tostring(err)))
	end
	return index
end

-- Hands out one free spin per SpinCooldown, per player.
local function refillLoop()
	while true do
		task.wait(REFILL_INTERVAL)
		local now = os.time()
		for _, player in Players:GetPlayers() do
			local ok, err = pcall(function()
				local nextAt = player:GetAttribute("NextSpinAt")
				if typeof(nextAt) ~= "number" then
					player:SetAttribute("NextSpinAt", now + Config.Wheel.SpinCooldown)
					return
				end
				if now >= nextAt then
					player:SetAttribute("Spins", WheelService.GetSpins(player) + 1)
					player:SetAttribute("NextSpinAt", now + Config.Wheel.SpinCooldown)
				end
			end)
			if not ok then
				warn(("[WheelService] refill failed for %s: %s"):format(player.Name, tostring(err)))
			end
		end
	end
end

function WheelService.Start(services: any, _map: any)
	servicesRef = services

	-- Equipping and unequipping a tool is just it moving between the Backpack
	-- and the Character, so watching the Character's children catches both —
	-- and keeps working across a respawn, where StarterGear hands over a fresh
	-- copy of the tool that no per-instance connection would know about.
	local function watchCharacter(player: Player, character: Model)
		local function onToolMoved(child: Instance)
			if child:IsA("Tool") then
				pcall(refreshBoost, player)
			end
		end
		character.ChildAdded:Connect(onToolMoved)
		character.ChildRemoved:Connect(onToolMoved)
		pcall(refreshBoost, player)
	end

	local function watchPlayer(player: Player)
		safeSetup(player)
		player.CharacterAdded:Connect(function(character)
			watchCharacter(player, character)
		end)
		if player.Character ~= nil then
			watchCharacter(player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player)
		loans[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local spin = remotes:WaitForChild("Spin") :: RemoteFunction
	spin.OnServerInvoke = function(player: Player)
		return WheelService.TrySpin(player)
	end

	task.spawn(refillLoop)
end

return WheelService
