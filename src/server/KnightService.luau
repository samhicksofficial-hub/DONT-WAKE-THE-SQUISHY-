--!strict
-- KnightService — the Knight bodyguard pass (Config.Passes.Knight).
--
-- Owning the pass sets the OwnsKnight attribute (GearService.grant); this
-- service turns that flag into an actual follower: a Knight that spawns beside
-- its owner and trails them around the map, re-spawning if it dies and
-- despawning when the owner leaves. Nothing else in the game read that
-- attribute before, so the pass used to grant nothing visible.
--
-- SECURITY / BEHAVIOUR: the imported "The Knight" template is a free-model
-- KILLER NPC ("JeffTheKiller") whose own scripts chase and attack everyone. We
-- take only its LOOK — armour meshes, body colours, helmet, body parts — and
-- STRIP every script on clone, so none of the free model's code ever runs. The
-- bodyguard is inert except for the follow loop here. It does NOT attack: a
-- companion, not a weapon. Player-targeting combat is a deliberate non-goal
-- (it would be a griefing vector) and can be designed later if wanted.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local KnightService = {}

local TEMPLATE_FOLDER = "GearItems"
local TEMPLATE_NAME = "The Knight"
local ATTRIBUTE = "OwnsKnight"
local FOLLOW_GAP = 6 -- studs it tries to hold off the owner
local FOLLOW_TICK = 0.35 -- seconds between re-targets
local SNAP_RANGE = 90 -- if it falls this far behind, teleport it back
local RESPAWN_DELAY = 2 -- seconds before a fallen guard returns

-- player -> live bodyguard model, and a per-player generation that invalidates
-- an old follow loop the instant a new guard (or a despawn) supersedes it.
local guards: { [Player]: Model } = {}
local generation: { [Player]: number } = {}

local function findTemplate(): Model?
	local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER)
	local t = folder ~= nil and folder:FindFirstChild(TEMPLATE_NAME) or nil
	return if t ~= nil and t:IsA("Model") then t else nil
end

-- A clone with every script stripped and a usable humanoid + root, or nil when
-- the place carries no Knight art (a clean rojo build).
local function buildGuard(): Model?
	local template = findTemplate()
	if template == nil then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "KnightGuard"

	-- Kill JeffTheKillerMain, AnimateSauce, Respawn, Health — every source
	-- container the free model shipped. Collected first, destroyed after.
	local doomed: { Instance } = {}
	for _, d in clone:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			table.insert(doomed, d)
		end
	end
	for _, d in doomed do
		d:Destroy()
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		clone:Destroy()
		return nil
	end
	-- No name plate, no health bar, and it can't be shoved off the map by its
	-- own ragdoll — it is scenery that walks.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false

	local root = clone:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = root

	-- Unanchored so it can walk; non-colliding with players so it never shoves
	-- the owner around or jams a doorway.
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
		end
	end
	return clone
end

local function despawn(player: Player)
	generation[player] = (generation[player] or 0) + 1 -- invalidate any loop
	local guard = guards[player]
	guards[player] = nil
	if guard ~= nil then
		pcall(function()
			guard:Destroy()
		end)
	end
end

local function ownerRootOf(player: Player): BasePart?
	local character = player.Character
	local root = character ~= nil and character:FindFirstChild("HumanoidRootPart") or nil
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local spawnFor -- forward declaration (the loop can ask for a respawn)

spawnFor = function(player: Player)
	despawn(player) -- one guard at a time
	if player:GetAttribute(ATTRIBUTE) ~= true then
		return
	end
	local ownerRoot = ownerRootOf(player)
	if ownerRoot == nil then
		return -- no character yet; CharacterAdded will call us again
	end
	local guard = buildGuard()
	if guard == nil then
		return
	end
	guard:PivotTo(CFrame.new(ownerRoot.Position + Vector3.new(FOLLOW_GAP, 0, 0)))
	guard.Parent = Workspace
	guards[player] = guard

	local gen = (generation[player] or 0) + 1
	generation[player] = gen

	-- A fallen guard (fell off the map, drowned, etc.) comes back once.
	local humanoid = guard:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid.Died:Connect(function()
			task.wait(RESPAWN_DELAY)
			if generation[player] == gen and player.Parent ~= nil and player:GetAttribute(ATTRIBUTE) == true then
				spawnFor(player)
			end
		end)
	end

	task.spawn(function()
		while generation[player] == gen do
			task.wait(FOLLOW_TICK)
			if generation[player] ~= gen then
				break
			end
			local guardModel = guards[player]
			local ownerNow = ownerRootOf(player)
			if guardModel == nil or guardModel.Parent == nil or ownerNow == nil then
				break -- guard gone or owner dead/absent; respawn is event-driven
			end
			local hum = guardModel:FindFirstChildOfClass("Humanoid")
			local gRoot = guardModel:FindFirstChild("HumanoidRootPart")
			if hum == nil or gRoot == nil or not gRoot:IsA("BasePart") then
				break
			end
			local target = ownerNow.Position
			local away = gRoot.Position - target
			if away.Magnitude > SNAP_RANGE then
				guardModel:PivotTo(CFrame.new(target + Vector3.new(FOLLOW_GAP, 0, 0)))
			else
				-- Hold a few studs off so it trails rather than stands on them.
				local dir = if away.Magnitude > 0.1 then Vector3.new(away.X, 0, away.Z).Unit else Vector3.new(1, 0, 0)
				hum:MoveTo(target + dir * FOLLOW_GAP)
			end
		end
	end)
end

function KnightService.Start(_services: any, _map: any)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			-- Let the character settle before measuring where to place the guard.
			task.wait(1)
			if player:GetAttribute(ATTRIBUTE) == true then
				spawnFor(player)
			end
		end)
		player.CharacterRemoving:Connect(function()
			despawn(player)
		end)
		-- Bought mid-session: PromptGamePassPurchaseFinished sets the attribute.
		player:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
			if player:GetAttribute(ATTRIBUTE) == true then
				spawnFor(player)
			else
				despawn(player)
			end
		end)
		if player.Character ~= nil and player:GetAttribute(ATTRIBUTE) == true then
			spawnFor(player)
		end
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(despawn)
end

return KnightService
