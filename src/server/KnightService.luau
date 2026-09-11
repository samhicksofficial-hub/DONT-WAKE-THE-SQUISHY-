--!strict
-- KnightService — the Knight bodyguard pass (Config.Passes.Knight).
--
-- Owning the pass sets the OwnsKnight attribute (GearService.grant); this
-- service turns that flag into an actual follower: a Knight that spawns beside
-- its owner and trails them around the map, re-spawning if it goes missing and
-- despawning when the owner leaves.
--
-- SECURITY / BEHAVIOUR: the imported "The Knight" template is a free-model
-- KILLER NPC ("JeffTheKiller") whose own scripts chase and attack everyone. We
-- take only its LOOK and STRIP every script on clone, so none of the free
-- model's code ever runs. It does NOT attack: a companion, not a weapon
-- (player-targeting combat would be a griefing vector and is left out on
-- purpose). Jeff's leftover Knife prop is deleted too — the Knight carries his
-- own sword, fitted into his right hand and welded to the arm.
--
-- MOVEMENT: only the ROOT is anchored and CFrame-glided toward a spot beside
-- the owner (Humanoid:MoveTo on an imported rig is unreliable — physics
-- ownership near players silently defeats server movement). The limbs stay
-- unanchored on their Motor6D joints, which is what lets Roblox's own R6
-- walk/idle animations move them: a fully anchored rig ignores animation.
-- Feet are kept on the ground by raycasting the floor under the follow spot
-- and standing the rig at its measured foot offset above the hit.

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
-- Roblox's own classic R6 animations — loadable in any game, unlike
-- creator-locked uploads.
local WALK_ANIMATION = "rbxassetid://180426354"
local IDLE_ANIMATION = "rbxassetid://180435571"
local WALK_THRESHOLD = 1.5 -- studs/s of actual glide below which it stands idle

-- player -> live bodyguard model, and a per-player generation that retires an
-- old follow connection the instant a new guard (or a despawn) supersedes it.
local guards: { [Player]: Model } = {}
local generation: { [Player]: number } = {}

local function findTemplate(): Model?
	local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER)
	local t = folder ~= nil and folder:FindFirstChild(TEMPLATE_NAME) or nil
	return if t ~= nil and t:IsA("Model") then t else nil
end

-- The free model authored the sword floating beside the rig (its old scripts
-- attached it at runtime, and those are gone on purpose). Geometry finds the
-- grip: the blade is the longest single part, so the handle end of the long
-- axis is the one farther from the blade's own centre. The sword is pivoted so
-- the grip sits in the right palm, carried at rest — blade trailing behind
-- him, tip a touch above the grip, per the owner's sketch — then welded to the
-- arm so the walk swing carries it.
local function fitSword(clone: Model)
	local sword = clone:FindFirstChild("Knight Sword")
	local rightArm = clone:FindFirstChild("Right Arm")
	if sword == nil or not sword:IsA("Model") or rightArm == nil or not rightArm:IsA("BasePart") then
		return
	end

	local scf, ssize = sword:GetBoundingBox()
	local axis: Vector3
	local length: number
	if ssize.X >= ssize.Y and ssize.X >= ssize.Z then
		axis, length = scf.XVector, ssize.X
	elseif ssize.Y >= ssize.Z then
		axis, length = scf.YVector, ssize.Y
	else
		axis, length = scf.ZVector, ssize.Z
	end

	local blade: BasePart? = nil
	local bladeLen = 0
	for _, p in sword:GetDescendants() do
		if p:IsA("BasePart") then
			local longest = math.max(p.Size.X, p.Size.Y, p.Size.Z)
			if longest > bladeLen then
				bladeLen = longest
				blade = p
			end
		end
	end
	local toBlade = axis
	if blade ~= nil and (blade.Position - scf.Position):Dot(axis) < 0 then
		toBlade = -axis
	end

	-- A hair in from the handle tip, where a fist would close.
	local grip = scf.Position - toBlade * (length / 2 - 0.6)
	local palm = (rightArm.CFrame * CFrame.new(0, -0.95, 0)).Position
	local target = (-clone:GetPivot().LookVector + Vector3.yAxis * 0.25).Unit

	local dot = math.clamp(toBlade:Dot(target), -1, 1)
	local rotation: CFrame
	if dot > 0.9999 then
		rotation = CFrame.identity
	elseif dot < -0.9999 then
		rotation = CFrame.fromAxisAngle(rightArm.CFrame.LookVector, math.pi)
	else
		rotation = CFrame.fromAxisAngle(toBlade:Cross(target).Unit, math.acos(dot))
	end

	-- world map: X -> palm + rotation * (X - grip)
	sword:PivotTo(CFrame.new(palm) * rotation * CFrame.new(-grip) * sword:GetPivot())

	for _, p in sword:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.Massless = true
			p.CanCollide = false
			p.CanQuery = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = rightArm
			weld.Part1 = p
			weld.Parent = p
		end
	end
end

-- A clone with every script stripped, sword in hand, root anchored, or nil
-- when the place carries no Knight art (a clean rojo build).
local function buildGuard(): Model?
	local template = findTemplate()
	if template == nil then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "KnightGuard"

	-- Kill every source container the free model shipped. Collected first,
	-- destroyed after.
	local doomed: { Instance } = {}
	for _, d in clone:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			table.insert(doomed, d)
		end
	end
	for _, d in doomed do
		d:Destroy()
	end

	-- Jeff's knife is not knightly.
	local knife = clone:FindFirstChild("Knife")
	if knife ~= nil then
		knife:Destroy()
	end

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		clone:Destroy()
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	if humanoid:FindFirstChildOfClass("Animator") == nil then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local root = clone:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = root

	fitSword(clone)

	-- Only the root is anchored: the glide drives it, the Motor6D joints carry
	-- the unanchored limbs, and that is what lets the walk animation move them
	-- (a fully anchored rig ignores animation). Nothing collides: players walk
	-- straight through their bodyguard.
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = d == root
			d.CanCollide = false
			d.CanQuery = false
			d.Massless = d ~= root
		end
	end

	-- How far the pivot (root) sits above the lowest point (the soles), so the
	-- follow loop can stand the rig exactly on whatever floor it raycasts.
	local bboxCF, bboxSize = clone:GetBoundingBox()
	clone:SetAttribute("FootOffset", clone:GetPivot().Position.Y - (bboxCF.Position.Y - bboxSize.Y / 2))
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

	local footOffset = tonumber(guard:GetAttribute("FootOffset")) or 3

	-- Roblox's own R6 walk/idle, faded between by how fast the glide is
	-- actually moving. pcall-guarded: a failed load just means no animation.
	local humanoid = guard:FindFirstChildOfClass("Humanoid")
	local animator = humanoid ~= nil and humanoid:FindFirstChildOfClass("Animator") or nil
	local function loadTrack(id: string): AnimationTrack?
		if animator == nil then
			return nil
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(animator.LoadAnimation, animator, animation)
		return if ok then track else nil
	end
	local walkTrack = loadTrack(WALK_ANIMATION)
	local idleTrack = loadTrack(IDLE_ANIMATION)
	if idleTrack ~= nil then
		idleTrack.Looped = true
		idleTrack:Play()
	end
	if walkTrack ~= nil then
		walkTrack.Looped = true
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local gen = (generation[player] or 0) + 1
	generation[player] = gen

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
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
		local spotPos = (ownerCF * FOLLOW_OFFSET).Position

		-- Stand on the actual floor under the follow spot, not at the owner's
		-- hip height — different rigs, different legs.
		local character = ownerNow.Parent
		rayParams.FilterDescendantsInstances = if character ~= nil then { guardModel, character } else { guardModel }
		local hit = Workspace:Raycast(spotPos + Vector3.new(0, 6, 0), Vector3.new(0, -40, 0), rayParams)
		local goalY = if hit ~= nil then hit.Position.Y + footOffset else spotPos.Y
		local goalPos = Vector3.new(spotPos.X, goalY, spotPos.Z)
		local goal = CFrame.lookAt(goalPos, goalPos + ownerCF.LookVector)

		local current = guardModel:GetPivot()
		local newCF: CFrame
		if (current.Position - goal.Position).Magnitude > SNAP_RANGE then
			newCF = goal
		else
			newCF = current:Lerp(goal, FOLLOW_ALPHA)
		end
		guardModel:PivotTo(newCF)

		if walkTrack ~= nil and idleTrack ~= nil and dt > 0 then
			local step = newCF.Position - current.Position
			local speed = Vector3.new(step.X, 0, step.Z).Magnitude / dt
			if speed > WALK_THRESHOLD then
				if not walkTrack.IsPlaying then
					idleTrack:Stop(0.2)
					walkTrack:Play(0.2)
				end
				walkTrack:AdjustSpeed(math.clamp(speed / 14, 0.5, 2))
			elseif walkTrack.IsPlaying then
				walkTrack:Stop(0.2)
				idleTrack:Play(0.2)
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
