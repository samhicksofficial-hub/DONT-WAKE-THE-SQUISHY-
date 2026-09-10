--!strict
-- KnightService — the Knight bodyguard pass (Config.Passes.Knight).
--
-- Owning the pass sets the OwnsKnight attribute (GearService.grant); this
-- service turns that flag into an actual follower: a Knight that spawns beside
-- its owner and trails them around the map, re-spawning if it goes missing and
-- despawning when the owner leaves. Nothing else in the game read that
-- attribute before, so the pass used to grant nothing visible.
--
-- SECURITY / BEHAVIOUR: the imported "The Knight" template is a free-model
-- KILLER NPC ("JeffTheKiller") whose own scripts chase and attack everyone. We
-- take only its LOOK — armour meshes, body colours, helmet, body parts — and
-- STRIP every script on clone, so none of the free model's code ever runs. It
-- does NOT attack: a companion, not a weapon (player-targeting combat would be
-- a griefing vector and is left out on purpose).
--
-- MOVEMENT: the follower is ANCHORED and driven by CFrame (a smooth lerp toward
-- a spot beside its owner) rather than by Humanoid:MoveTo. An imported rig walks
-- unreliably under server MoveTo — Roblox hands its physics ownership to the
-- nearest player's client, which silently defeats server movement, and the rig
-- trips on plot geometry. A CFrame glide is predictable on every surface. The
-- Humanoid is kept only so the armour and body colours render.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local KnightService = {}

local TEMPLATE_FOLDER = "GearItems"
local TEMPLATE_NAME = "The Knight"
local ATTRIBUTE = "OwnsKnight"
-- Where it holds station relative to the owner: a bit to the right and behind
-- (object space; -Z is the owner's forward, so +Z is behind them).
local FOLLOW_OFFSET = CFrame.new(3, 0, 5)
local FOLLOW_ALPHA = 0.12 -- per-frame catch-up; higher snaps faster
local SNAP_RANGE = 60 -- fall this far behind (owner teleported) and jump to them

-- player -> live bodyguard model, and a per-player generation that retires an
-- old follow connection the instant a new guard (or a despawn) supersedes it.
local guards: { [Player]: Model } = {}
local generation: { [Player]: number } = {}

local function findTemplate(): Model?
	local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER)
	local t = folder ~= nil and folder:FindFirstChild(TEMPLATE_NAME) or nil
	return if t ~= nil and t:IsA("Model") then t else nil
end

-- A clone with every script stripped, anchored and non-colliding, or nil when
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
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	-- The rig is moved by CFrame, not by its Humanoid; take the state machine
	-- out of the way so it never fights the glide or tries to "stand up".
	humanoid.PlatformStand = true
	pcall(function()
		(humanoid :: any).EvaluateStateMachine = false
	end)

	local root = clone:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = root

	-- Anchored (CFrame-driven, no physics to fight or replicate) and
	-- non-colliding (players walk through it; it never shoves the owner).
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
		end
	end
	return clone
end

local function despawn(player: Player)
	generation[player] = (generation[player] or 0) + 1 -- retire any follow conn
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

local function spawnFor(player: Player)
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
	local start = ownerRoot.CFrame * FOLLOW_OFFSET
	guard:PivotTo(CFrame.lookAt(start.Position, start.Position + ownerRoot.CFrame.LookVector))
	guard.Parent = Workspace
	guards[player] = guard

	local gen = (generation[player] or 0) + 1
	generation[player] = gen

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if generation[player] ~= gen then
			conn:Disconnect()
			return
		end
		local guardModel = guards[player]
		local ownerNow = ownerRootOf(player)
		if guardModel == nil or guardModel.Parent == nil or ownerNow == nil then
			return -- owner absent/dead; the event handlers respawn or despawn us
		end
		local ownerCF = ownerNow.CFrame
		local spot = ownerCF * FOLLOW_OFFSET
		local goal = CFrame.lookAt(spot.Position, spot.Position + ownerCF.LookVector)
		local current = guardModel:GetPivot()
		if (current.Position - goal.Position).Magnitude > SNAP_RANGE then
			guardModel:PivotTo(goal)
		else
			guardModel:PivotTo(current:Lerp(goal, FOLLOW_ALPHA))
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
