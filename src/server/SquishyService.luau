--!strict
-- SquishyService — field squishy spawning plus the entire pickup/carry/drop
-- lifecycle. Contract highlights (DESIGN.md):
--   * Fresh field spawns are capped by Config.Field.MaxSquishies and each
--     occupies one spawn point; pickup (or destruction) frees both.
--   * Re-dropped squishies live in map.squishyFolder, stay pickupable, and do
--     NOT count against the spawn cap or occupy spawn points.
--   * This service is the ONLY writer of Humanoid.WalkSpeed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Config = require(sharedFolder:WaitForChild("Config"))
local Util = require(sharedFolder:WaitForChild("Util"))
local SquishyFactory = require(sharedFolder:WaitForChild("SquishyFactory"))

local GROUND_Y = 1 -- top surface of the field/walkway slabs (DESIGN.md)
local CARRY_GAP = 2 -- studs of air between the head top and the carried body base

local SquishyService = {}

type CarryEntry = { model: Model, def: any }
type PlayerConns = { characterAdded: RBXScriptConnection?, died: RBXScriptConnection? }

local rng = Random.new()
local mapRef: any = nil

-- Player -> the squishy they carry.
local carrying: { [Player]: CarryEntry } = {}
local playerConns: { [Player]: PlayerConns } = {}

-- Fresh-spawn bookkeeping (see contract note above).
local spawnOccupants: { [number]: Model } = {} -- spawn point index -> live fresh model
local fieldSpawnIndex: { [Model]: number } = {} -- live fresh model -> spawn point index
local freshCount = 0

-- Frees a fresh field spawn's point + cap slot. Safe to call repeatedly.
local function releaseFieldSpawn(model: Model)
	local index = fieldSpawnIndex[model]
	if index == nil then
		return
	end
	fieldSpawnIndex[model] = nil
	if spawnOccupants[index] == model then
		spawnOccupants[index] = nil
	end
	freshCount -= 1
end

-- Clears carry attributes and takes WalkSpeed back to base.
local function restorePlayer(player: Player)
	player:SetAttribute("Carrying", nil)
	player:SetAttribute("CarrySpeedMult", nil)
	local character = player.Character
	if character ~= nil then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid ~= nil then
			humanoid.WalkSpeed = Config.Player.WalkSpeed
		end
	end
end

function SquishyService.IsCarrying(player: Player): boolean
	return carrying[player] ~= nil
end

-- ProximityPrompt handler for a field squishy (fresh or re-dropped).
local function onPickup(player: Player, model: Model)
	if carrying[player] ~= nil then
		return
	end
	if model:GetAttribute("State") ~= "Sleeping" then
		return
	end
	if model.Parent ~= mapRef.squishyFolder then
		return
	end
	local root = Util.getRoot(player)
	if root == nil then
		return
	end
	local character = player.Character
	if character == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	local body = model:FindFirstChild("Body")
	if body == nil or not body:IsA("BasePart") then
		return
	end
	local squishyName = model:GetAttribute("SquishyName") :: any
	local def = Config.SquishyByName[squishyName]
	if def == nil then
		return
	end

	-- A fresh field spawn frees its spawn point (and cap slot) on pickup.
	releaseFieldSpawn(model)

	model:SetAttribute("State", "Carried")
	local prompt = body:FindFirstChild("PickupPrompt")
	if prompt ~= nil and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = false
	end
	local zzz = body:FindFirstChild("Zzz")
	if zzz ~= nil and zzz:IsA("BillboardGui") then
		zzz.Enabled = false
	end

	body.Anchored = false
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Massless = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	-- Park the body ~2 studs above the head, then weld it to the root so it
	-- rides along with the character.
	local height = SquishyFactory.bodyHeight(def)
	local topY = root.Position.Y + 2.5
	local head = character:FindFirstChild("Head")
	if head ~= nil and head:IsA("BasePart") then
		topY = head.Position.Y + head.Size.Y * 0.5
	end
	local yOffset = (topY + CARRY_GAP + height * 0.5) - root.Position.Y
	body.CFrame = root.CFrame * CFrame.new(0, yOffset, 0)

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = body

	model.Parent = character

	local speedMult = tonumber(model:GetAttribute("SpeedMult")) or 1
	carrying[player] = { model = model, def = def }
	player:SetAttribute("Carrying", def.name)
	player:SetAttribute("CarrySpeedMult", speedMult)
	humanoid.WalkSpeed = Config.Player.WalkSpeed * speedMult
end

-- One spawn attempt: respects the fresh cap and spawn point occupancy.
local function trySpawn()
	if freshCount >= Config.Field.MaxSquishies then
		return
	end
	local spawns = mapRef.squishySpawns :: { Vector3 }
	local freeIndices = {}
	for index in ipairs(spawns) do
		if spawnOccupants[index] == nil then
			table.insert(freeIndices, index)
		end
	end
	if #freeIndices == 0 then
		return
	end
	local spawnIndex = freeIndices[rng:NextInteger(1, #freeIndices)]

	local rarity = Util.weightedRandom(Config.Rarities, rng) :: any
	local candidates = {}
	for _, catalogDef in Config.Squishies do
		if catalogDef.rarity == rarity.name then
			table.insert(candidates, catalogDef)
		end
	end
	if #candidates == 0 then
		return
	end
	local def = candidates[rng:NextInteger(1, #candidates)] :: any

	local model = SquishyFactory.create(def.name)
	local point = spawns[spawnIndex]
	local height = SquishyFactory.bodyHeight(def)
	local yaw = rng:NextNumber(0, math.pi * 2)
	model:PivotTo(CFrame.new(point.X, GROUND_Y + height * 0.5, point.Z) * CFrame.Angles(0, yaw, 0))

	fieldSpawnIndex[model] = spawnIndex
	spawnOccupants[spawnIndex] = model
	freshCount += 1
	model.Destroying:Connect(function()
		releaseFieldSpawn(model)
	end)

	local body = model:FindFirstChild("Body")
	local prompt = if body ~= nil then body:FindFirstChild("PickupPrompt") else nil
	if prompt ~= nil and prompt:IsA("ProximityPrompt") then
		prompt.Triggered:Connect(function(triggeredBy: Player)
			local ok, err = pcall(onPickup, triggeredBy, model)
			if not ok then
				warn(("[SquishyService] pickup failed: %s"):format(tostring(err)))
			end
		end)
	end

	model.Parent = mapRef.squishyFolder
end

-- Consumes the carried squishy (deposit). Returns the catalog def, or nil.
function SquishyService.TakeCarriedDef(player: Player): any
	local entry = carrying[player]
	if entry == nil then
		return nil
	end
	carrying[player] = nil
	pcall(function()
		entry.model:Destroy()
	end)
	restorePlayer(player)
	return entry.def
end

-- Detaches the carried squishy and puts it back on the ground where the
-- player stands (clamped to the field + walkway rectangle). The dropped model
-- stays pickupable and never re-enters fresh-spawn bookkeeping.
function SquishyService.ForceDrop(player: Player)
	local entry = carrying[player]
	if entry == nil then
		return
	end
	carrying[player] = nil

	local model = entry.model
	local ok = pcall(function()
		local body = model:FindFirstChild("Body")
		if body == nil or not body:IsA("BasePart") then
			error("carried model has no Body")
		end

		local weld = body:FindFirstChild("CarryWeld")
		if weld ~= nil then
			weld:Destroy()
		end

		body.Anchored = true
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CanTouch = true
				descendant.CanQuery = true
				descendant.CanCollide = false
			end
		end

		local character = player.Character
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		local at = if root ~= nil and root:IsA("BasePart") then root.Position else body.Position
		local extentX = mapRef.fieldSize.X * 0.5 + Config.Field.WalkwayWidth
		local extentZ = mapRef.fieldSize.Y * 0.5 + Config.Field.WalkwayWidth
		local x = math.clamp(at.X, mapRef.fieldCenter.X - extentX, mapRef.fieldCenter.X + extentX)
		local z = math.clamp(at.Z, mapRef.fieldCenter.Z - extentZ, mapRef.fieldCenter.Z + extentZ)
		local height = SquishyFactory.bodyHeight(entry.def)
		model:PivotTo(CFrame.new(x, GROUND_Y + height * 0.5, z))

		local prompt = body:FindFirstChild("PickupPrompt")
		if prompt ~= nil and prompt:IsA("ProximityPrompt") then
			prompt.Enabled = true
		end
		local zzz = body:FindFirstChild("Zzz")
		if zzz ~= nil and zzz:IsA("BillboardGui") then
			zzz.Enabled = true
		end

		model:SetAttribute("State", "Sleeping")
		model.Parent = mapRef.squishyFolder
	end)
	if not ok then
		-- Model is unusable (destroyed with a character, etc.): make sure no
		-- half-carried remnant survives.
		pcall(function()
			model:Destroy()
		end)
	end

	restorePlayer(player)
end

-- New characters never start out carrying: shed stale carry state and reset
-- WalkSpeed to base (this service owns WalkSpeed).
local function onCharacterAdded(player: Player, character: Model)
	if carrying[player] ~= nil then
		SquishyService.ForceDrop(player)
	end
	player:SetAttribute("Carrying", nil)
	player:SetAttribute("CarrySpeedMult", nil)

	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	humanoid.WalkSpeed = Config.Player.WalkSpeed

	local conns = playerConns[player]
	if conns == nil then
		return -- player already left
	end
	local oldDied = conns.died
	if oldDied ~= nil then
		oldDied:Disconnect()
	end
	conns.died = humanoid.Died:Connect(function()
		SquishyService.ForceDrop(player)
	end)
end

function SquishyService.Start(_services: any, map: any)
	mapRef = map

	local function watchPlayer(player: Player)
		local conns = {} :: PlayerConns
		playerConns[player] = conns
		conns.characterAdded = player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		local existing = player.Character
		if existing ~= nil then
			task.spawn(onCharacterAdded, player, existing)
		end
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		-- Drop any carried squishy where they stood before the character goes.
		SquishyService.ForceDrop(player)
		local conns = playerConns[player]
		playerConns[player] = nil
		if conns ~= nil then
			local characterAdded = conns.characterAdded
			if characterAdded ~= nil then
				characterAdded:Disconnect()
			end
			local died = conns.died
			if died ~= nil then
				died:Disconnect()
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Field.SpawnInterval)
			local ok, err = pcall(trySpawn)
			if not ok then
				warn(("[SquishyService] spawn failed: %s"):format(tostring(err)))
			end
		end
	end)
end

return SquishyService
