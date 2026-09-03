--!strict
-- PortalService — the neon ring out on the east dirt is the door into the Slap
-- Tower, the obby players run while their plots earn.
--
-- The ring itself is scenery. MapBuilder's buildPortal draws one, and on a
-- hand-edited map the generated props are thrown away and the SAVED copy under
-- Workspace.Map.Props is what stands in the world — so the portal is resolved
-- from the map root, never from anything this server generated.
--
-- The only moving part is an invisible slab hung across the ring's mouth.
-- Walk through it and the character is pivoted onto the tower's own spawn pad.
--
-- One way on purpose. Dying in the tower respawns the character, and
-- SpawnService puts every arriving character back on its owner's plot, so
-- Reset is already the way home.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PortalService = {}

local TOWER_NAME = "Slap Tower"
-- Clear of the pad, so nobody arrives standing inside it.
local ARRIVE_LIFT = 3.5
-- One trip per player per this long. The trigger is a volume a character can
-- stand in, and Touched fires again for every limb that brushes it.
local COOLDOWN = 3
-- The trigger fills most of the ring's mouth but stops short of the frame, so
-- it takes walking THROUGH the portal rather than clipping its rim.
local MOUTH_FRACTION = 0.82
-- ...and it is given some depth, or a character crossing briskly can tunnel
-- through a paper-thin trigger between two physics frames.
local MOUTH_DEPTH = 5

local lastTrip: { [Player]: number } = {}
local arrival: CFrame? = nil

-- Where the tower starts: its own SpawnLocation, or failing that the lowest
-- part in it — which is the ground floor either way.
local function towerArrival(): CFrame?
	local tower = Workspace:FindFirstChild(TOWER_NAME)
	if tower == nil then
		return nil
	end
	local pad = tower:FindFirstChildWhichIsA("SpawnLocation", true)
	if pad ~= nil then
		-- Adding a Vector3 shifts in WORLD space and keeps the pad's facing, so
		-- the player arrives upright and pointed the way the pad points.
		return pad.CFrame + Vector3.new(0, pad.Size.Y / 2 + ARRIVE_LIFT, 0)
	end
	local lowest: BasePart? = nil
	for _, descendant in tower:GetDescendants() do
		if descendant:IsA("BasePart") then
			if lowest == nil or descendant.Position.Y < (lowest :: BasePart).Position.Y then
				lowest = descendant
			end
		end
	end
	local floor = lowest
	if floor == nil then
		return nil
	end
	return CFrame.new(floor.Position + Vector3.new(0, floor.Size.Y / 2 + ARRIVE_LIFT, 0))
end

-- An invisible slab across the ring's mouth, sized from the model's own
-- bounding box so it still fits a portal the mapper has moved, turned or
-- resized by hand.
local function buildTrigger(portal: Model): BasePart
	local existing = portal:FindFirstChild("PortalTrigger")
	if existing ~= nil then
		existing:Destroy() -- never stack triggers on a restart
	end

	local cframe, size = portal:GetBoundingBox()
	-- The ring is a flat hoop: its thinnest axis is the way you walk through.
	local mouth = { size.X * MOUTH_FRACTION, size.Y * MOUTH_FRACTION, size.Z * MOUTH_FRACTION }
	local thin = 3
	if size.X <= size.Y and size.X <= size.Z then
		thin = 1
	elseif size.Y <= size.Z then
		thin = 2
	end
	mouth[thin] = MOUTH_DEPTH

	local trigger = Instance.new("Part")
	trigger.Name = "PortalTrigger"
	trigger.Size = Vector3.new(mouth[1], mouth[2], mouth[3])
	trigger.CFrame = cframe
	trigger.Anchored = true
	trigger.CanCollide = false
	-- CanQuery off as well: this thing sits in the open air on the walkway, and
	-- an invisible slab that answers raycasts is a floor as far as any
	-- "where is the ground here" cast is concerned.
	trigger.CanQuery = false
	trigger.Transparency = 1
	trigger.Parent = portal
	return trigger
end

-- The player a touched part belongs to. Walks up through accessories and tools,
-- which are Models in their own right hanging off the character.
local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorWhichIsA("Model")
	while model ~= nil do
		local player = Players:GetPlayerFromCharacter(model)
		if player ~= nil then
			return player
		end
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

local function onTouch(hit: BasePart)
	local player = playerFromHit(hit)
	if player == nil then
		return
	end
	local now = os.clock()
	if now - (lastTrip[player] or 0) < COOLDOWN then
		return
	end
	local character = player.Character
	if character == nil or character.Parent == nil then
		return
	end
	-- A ragdolling corpse sliding through the ring is not a player taking a trip.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	-- Re-resolved when it is missing rather than cached forever: the tower is a
	-- saved model, and a mapper may have added it after the server booted.
	local target = arrival or towerArrival()
	if target == nil then
		return
	end
	arrival = target
	lastTrip[player] = now
	character:PivotTo(target)
end

function PortalService.Start(_services: any, map: any)
	local root = (map ~= nil and map.root) or Workspace:FindFirstChild("Map")
	if root == nil then
		warn("[PortalService] no Workspace.Map; the portal stays scenery")
		return
	end
	local props = root:FindFirstChild("Props")
	local portal = props ~= nil and props:FindFirstChild("Portal") or nil
	if portal == nil or not portal:IsA("Model") then
		warn("[PortalService] no Map.Props.Portal to wire up")
		return
	end

	arrival = towerArrival()
	if arrival == nil then
		-- A clean `rojo build` has no Slap Tower in it. That is not a fault:
		-- the ring is generated scenery and stays scenery until the obby exists.
		warn(("[PortalService] no %q in the Workspace; the portal stays scenery"):format(TOWER_NAME))
		return
	end

	buildTrigger(portal :: Model).Touched:Connect(function(hit: BasePart)
		local ok, err = pcall(onTouch, hit)
		if not ok then
			warn(("[PortalService] portal trip failed: %s"):format(tostring(err)))
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastTrip[player] = nil
	end)
end

return PortalService
