--!strict
-- EnemyService — the two giant squishies (Config.Enemies) that patrol the
-- field asleep, notice nearby players, chase them, and slap them (fling +
-- forced squishy drop). DESIGN.md rule 5 is the contract for this file.
--
-- Enemy model tree:
--   Model (name = cfg.name, PrimaryPart = HumanoidRootPart)
--     HumanoidRootPart (invisible box, CanCollide false, server-owned physics)
--     Humanoid (WalkSpeed per state, JumpPower 0, name/health hidden)
--     Body (invisible bounding box from SquishyModels.build, welded to root)
--       NameTag (BillboardGui, red enemy name, always on)
--       Zzz (BillboardGui, shown while Sleeping)
--       Alert (BillboardGui, red "!", shown while Chasing)
--     ...visual mesh/primitive parts from SquishyModels.build (welded to Body)
--
-- Each giant has its own imported model, picked by cfg.shape. cfg.color is only
-- the fallback primitive's colour, used until that mesh is imported; a giant
-- that BORROWS a collectable's shape sets cfg.tint to be painted instead.
-- Eyes/faces are baked into the meshes, so the only "awake" cue is the Alert
-- billboard.
--
-- Attributes on the Model (EnemyService owns): EnemyName, State
-- ("Sleeping" | "Chasing" | "Returning"), TargetUserId (0 unless chasing).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local SquishyModels = require(Shared:WaitForChild("SquishyModels")) :: any

local EnemyService = {}

-- Set at Start; the Stealth upgrade shrinks notice radii per player.
local upgradeService: any = nil

local TICK = 0.15 -- seconds between state-machine steps
local WAYPOINT_REACH = 6 -- studs (XZ) to count a waypoint as reached
local ROOT_BASE_SIZE = Vector3.new(2, 2, 1)
local NAME_COLOR = Color3.fromRGB(255, 70, 70)

-- One BillboardGui holding a single centered FredokaOne label.
local function makeBillboard(
	parent: Instance,
	name: string,
	widthStuds: number,
	heightStuds: number,
	offset: Vector3,
	text: string,
	textColor: Color3,
	enabled: boolean
): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = name
	billboard.Size = UDim2.fromScale(widthStuds, heightStuds)
	billboard.StudsOffsetWorldSpace = offset
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 250
	billboard.Enabled = enabled

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = textColor
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.Parent = billboard

	billboard.Parent = parent
	return billboard
end

-- Builds one giant enemy from its Config.Enemies entry, pivots it onto the
-- ground at spawnPos, parents it, and claims server network ownership.
local function buildEnemy(cfg: any, spawnPos: Vector3, parent: Instance): any
	local scale = cfg.scale :: number
	local rootSize = ROOT_BASE_SIZE * scale

	local model = Instance.new("Model")
	model.Name = cfg.name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = rootSize
	root.Transparency = 1
	root.Anchored = false
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.Material = Enum.Material.SmoothPlastic
	root.Parent = model
	model.PrimaryPart = root

	-- Real squishy visual (giant-sized): an invisible snug "Body" box with the
	-- mesh/primitive parts welded to it, from the shared builder.
	local visual, visualHeight = SquishyModels.build({
		shape = cfg.shape,
		color = cfg.color,
		sparkle = false,
		scale = scale,
		-- Opt-in, not always-on. A giant with its OWN imported model keeps the
		-- texture it shipped with; only one BORROWING a collectable's shape
		-- needs painting, so it never wears that collectable's stock texture.
		forceTint = cfg.tint == true,
	})

	-- Humanoid keeps the root center at (HipHeight + rootSize.Y/2) above the
	-- floor; solve so the visual's base hovers just above the ground when the
	-- visual's Body is centered on the root.
	local hipHeight = math.max((visualHeight :: number) * 0.5 - rootSize.Y * 0.5 + 0.4, 0.5)

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	pcall(function()
		-- R15 semantics: HipHeight drives the hover height (no legs needed).
		humanoid.RigType = Enum.HumanoidRigType.R15
	end)
	humanoid.HipHeight = hipHeight
	humanoid.WalkSpeed = cfg.patrolSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.HealthDisplayDistance = 0
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	-- Center the visual on the root, unanchor its Body, and weld it on; then
	-- move everything out of the returned wrapper Model and drop the wrapper.
	visual:PivotTo(root.CFrame)
	local body = (visual :: Model).PrimaryPart :: BasePart
	body.Anchored = false
	body.Massless = true
	body.CanQuery = false
	local bodyWeld = Instance.new("WeldConstraint")
	bodyWeld.Part0 = root
	bodyWeld.Part1 = body
	bodyWeld.Parent = body
	for _, child in (visual :: Model):GetChildren() do
		child.Parent = model
	end
	visual:Destroy()

	local halfHeight = (visualHeight :: number) * 0.5
	makeBillboard(body, "NameTag", 16, 3.5, Vector3.new(0, halfHeight + 6.5, 0), cfg.name, NAME_COLOR, true)
	local zzz = makeBillboard(body, "Zzz", 8, 5, Vector3.new(body.Size.X * 0.3, halfHeight + 2, 0), "Zzz", Color3.fromRGB(160, 200, 255), true)
	local alert = makeBillboard(body, "Alert", 5, 6, Vector3.new(0, halfHeight + 2.5, 0), "!", Color3.fromRGB(255, 40, 40), false)

	model:SetAttribute("EnemyName", cfg.name)
	model:SetAttribute("State", "Sleeping")
	model:SetAttribute("TargetUserId", 0)

	model:PivotTo(CFrame.new(spawnPos + Vector3.new(0, hipHeight + rootSize.Y * 0.5, 0)))
	model.Parent = parent

	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	return {
		cfg = cfg,
		model = model,
		root = root,
		humanoid = humanoid,
		zzz = zzz,
		alert = alert,
		waypointIndex = 1,
		chaseEndsAt = 0,
		noticeBlockedUntil = 0,
	}
end

local function nearestWaypointIndex(waypoints: { Vector3 }, pos: Vector3): number
	local bestIndex = 1
	local bestDist = math.huge
	for index, point in waypoints do
		local dist = Util.xzDistance(pos, point)
		if dist < bestDist then
			bestDist = dist
			bestIndex = index
		end
	end
	return bestIndex
end

-- Single writer for everything that varies by state: State/TargetUserId
-- attributes, billboards, WalkSpeed. The Alert billboard is the only visual
-- "awake" cue (faces are baked into the squishy meshes).
local function applyState(enemy: any, state: string)
	local chasing = state == "Chasing"
	local sleeping = state == "Sleeping"
	local model = enemy.model :: Model
	model:SetAttribute("State", state)
	if not chasing then
		model:SetAttribute("TargetUserId", 0)
	end
	local zzz = enemy.zzz :: BillboardGui
	local alert = enemy.alert :: BillboardGui
	zzz.Enabled = sleeping
	alert.Enabled = chasing
	local humanoid = enemy.humanoid :: Humanoid
	humanoid.WalkSpeed = chasing and enemy.cfg.chaseSpeed or enemy.cfg.patrolSpeed
end

-- Nearest alive player inside the field and within this enemy's notice
-- radius (larger radius when that player is carrying a squishy).
local function findTarget(enemy: any, map: any, squishyService: any): Player?
	local best: Player? = nil
	local bestDist = math.huge
	local enemyPos = (enemy.root :: BasePart).Position
	for _, player in Players:GetPlayers() do
		local root = Util.getRoot(player)
		if root and map.isInField(root.Position) then
			local radius = enemy.cfg.noticeRadius
			if squishyService.IsCarrying(player) then
				radius = enemy.cfg.noticeRadiusCarrying
				-- What you are carrying decides how far it gives you away: a
				-- Common barely registers, a Mythical wakes the whole field.
				local rarityName = player:GetAttribute("CarryRarity")
				local rarity = typeof(rarityName) == "string" and Config.RarityByName[rarityName] or nil
				local alertMult = rarity ~= nil and tonumber(rarity.alertMult) or nil
				if alertMult ~= nil and alertMult > 0 then
					radius *= alertMult
				end
			end
			-- The player's Stealth upgrade shrinks how far this giant notices.
			if upgradeService ~= nil then
				local ok, stealth = pcall(function()
					return upgradeService.GetValue(player, "Stealth")
				end)
				if ok and typeof(stealth) == "number" and stealth > 0 then
					radius *= stealth
				end
			end
			local dist = Util.xzDistance(enemyPos, root.Position)
			if dist <= radius and dist < bestDist then
				bestDist = dist
				best = player
			end
		end
	end
	return best
end

-- Fling the victim up and away, stun via PlatformStand, force-drop their
-- carried squishy.
local function slap(enemy: any, target: Player, targetRoot: BasePart, squishyService: any)
	local cfg = enemy.cfg
	local away = targetRoot.Position - (enemy.root :: BasePart).Position
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.05 then
		local look = (enemy.root :: BasePart).CFrame.LookVector
		away = Vector3.new(look.X, 0, look.Z)
	end
	if away.Magnitude < 0.05 then
		away = Vector3.new(0, 0, -1)
	end
	away = away.Unit
	targetRoot.AssemblyLinearVelocity = away * cfg.flingSpeed + Vector3.new(0, cfg.flingSpeed * 0.6, 0)

	local targetHumanoid: Humanoid? = nil
	local character = targetRoot.Parent
	if character then
		targetHumanoid = character:FindFirstChildOfClass("Humanoid")
	end
	if targetHumanoid then
		targetHumanoid.PlatformStand = true
		task.delay(cfg.stunTime, function()
			if targetHumanoid.Parent ~= nil then
				targetHumanoid.PlatformStand = false
			end
		end)
	end

	pcall(function()
		squishyService.ForceDrop(target)
	end)
end

local function stepSleeping(enemy: any, map: any, squishyService: any)
	local waypoints = map.enemyWaypoints :: { Vector3 }
	local rootPos = (enemy.root :: BasePart).Position
	local targetPoint = waypoints[enemy.waypointIndex]
	if targetPoint == nil then
		return
	end
	if Util.xzDistance(rootPos, targetPoint) <= WAYPOINT_REACH then
		enemy.waypointIndex = (enemy.waypointIndex % #waypoints) + 1
		targetPoint = waypoints[enemy.waypointIndex]
	end
	local humanoid = enemy.humanoid :: Humanoid
	humanoid:MoveTo(targetPoint)

	if os.clock() >= enemy.noticeBlockedUntil then
		local target = findTarget(enemy, map, squishyService)
		if target then
			enemy.model:SetAttribute("TargetUserId", target.UserId)
			enemy.chaseEndsAt = os.clock() + enemy.cfg.chaseDuration
			applyState(enemy, "Chasing")
		end
	end
end

local function stepChasing(enemy: any, map: any, squishyService: any)
	local now = os.clock()
	local root = enemy.root :: BasePart
	local humanoid = enemy.humanoid :: Humanoid
	local targetUserId = (enemy.model :: Model):GetAttribute("TargetUserId")

	local target: Player? = nil
	if typeof(targetUserId) == "number" and targetUserId ~= 0 then
		target = Players:GetPlayerByUserId(targetUserId)
	end
	local targetRoot: BasePart? = nil
	if target then
		targetRoot = Util.getRoot(target)
	end
	if target == nil or targetRoot == nil then
		applyState(enemy, "Returning")
		return
	end

	-- Give up: timer elapsed, target escaped the field, or we somehow left it.
	if now >= enemy.chaseEndsAt
		or not map.isInField(targetRoot.Position)
		or not map.isInField(root.Position)
	then
		applyState(enemy, "Returning")
		return
	end

	-- A target already stunned (slapped by the other giant) ends this chase too —
	-- otherwise two chasers juggle a PlatformStanding player with repeat slaps.
	local targetHumanoid = (target.Character :: Model):FindFirstChildOfClass("Humanoid")
	if targetHumanoid and targetHumanoid.PlatformStand then
		applyState(enemy, "Returning")
		return
	end

	if Util.xzDistance(root.Position, targetRoot.Position) <= enemy.cfg.slapRange then
		slap(enemy, target, targetRoot, squishyService)
		applyState(enemy, "Returning")
		return
	end

	humanoid:MoveTo(targetRoot.Position)
end

local function stepReturning(enemy: any, map: any)
	local waypoints = map.enemyWaypoints :: { Vector3 }
	local root = enemy.root :: BasePart
	local humanoid = enemy.humanoid :: Humanoid
	local index = nearestWaypointIndex(waypoints, root.Position)
	local point = waypoints[index]
	if point == nil then
		enemy.noticeBlockedUntil = os.clock() + enemy.cfg.sleepCooldown
		applyState(enemy, "Sleeping")
		return
	end
	enemy.waypointIndex = index
	if Util.xzDistance(root.Position, point) <= WAYPOINT_REACH then
		enemy.noticeBlockedUntil = os.clock() + enemy.cfg.sleepCooldown
		applyState(enemy, "Sleeping")
	else
		humanoid:MoveTo(point)
	end
end

local function stepEnemy(enemy: any, map: any, squishyService: any)
	local state = (enemy.model :: Model):GetAttribute("State")
	if state == "Chasing" then
		stepChasing(enemy, map, squishyService)
	elseif state == "Returning" then
		stepReturning(enemy, map)
	else
		stepSleeping(enemy, map, squishyService)
	end
end

local function runEnemy(enemy: any, map: any, squishyService: any)
	while (enemy.model :: Model).Parent ~= nil do
		local ok, err = pcall(stepEnemy, enemy, map, squishyService)
		if not ok then
			warn(("[EnemyService] %s step failed: %s"):format((enemy.model :: Model).Name, tostring(err)))
		end
		task.wait(TICK)
	end
end

function EnemyService.Start(services: any, map: any)
	local config = services.Config
	local squishyService = services.SquishyService
	upgradeService = services.UpgradeService

	for index, cfg in config.Enemies :: { any } do
		local spawnPos = map.enemySpawns[index] or map.enemySpawns[1] or map.fieldCenter
		local ok, err = pcall(function()
			local enemy = buildEnemy(cfg, spawnPos, map.enemyFolder)
			enemy.waypointIndex = nearestWaypointIndex(map.enemyWaypoints, (enemy.root :: BasePart).Position)
			applyState(enemy, "Sleeping")
			task.spawn(runEnemy, enemy, map, squishyService)
		end)
		if not ok then
			warn(("[EnemyService] failed to start enemy '%s': %s"):format(tostring(cfg.name), tostring(err)))
		end
	end
end

return EnemyService
