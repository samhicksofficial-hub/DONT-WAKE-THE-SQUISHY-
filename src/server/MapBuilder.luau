--!strict
-- MapBuilder: builds all static world geometry and returns the `map` table
-- described in DESIGN.md ("The map table" + "World conventions").
-- Called exactly once by init.server.luau before any service starts.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local MapBuilder = {}

export type Map = {
	root: Folder,
	squishyFolder: Folder,
	enemyFolder: Folder,
	plotFolder: Folder,
	fieldCenter: Vector3,
	fieldSize: Vector2,
	isInField: (pos: Vector3) -> boolean,
	squishySpawns: { Vector3 },
	enemyWaypoints: { Vector3 },
	enemySpawns: { Vector3 },
	plotSpots: { CFrame },
}

local GROUND_Y = 1 -- top surface of the field / walkway slabs (slabs centered at y = 0.5)

local COLOR_FIELD = Color3.fromRGB(96, 215, 82)
local COLOR_WALKWAY = Color3.fromRGB(163, 162, 165)
local COLOR_WALL = Color3.fromRGB(120, 120, 126)
local COLOR_BASEPLATE = Color3.fromRGB(39, 70, 45)
local COLOR_SPAWN = Color3.fromRGB(214, 214, 220)

local RUG_COLORS = {
	Color3.fromRGB(255, 214, 140),
	Color3.fromRGB(170, 220, 255),
	Color3.fromRGB(255, 170, 200),
	Color3.fromRGB(210, 190, 255),
}

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function makeSlab(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function MapBuilder.Build(): Map
	local fieldSize = Config.Field.Size :: Vector2
	local walkway = Config.Field.WalkwayWidth :: number
	local halfX = fieldSize.X / 2
	local halfZ = fieldSize.Y / 2
	local fieldCenter = Vector3.new(0, GROUND_Y, 0)

	local root = ensureFolder(Workspace, "Map")
	root:ClearAllChildren() -- idempotent rebuilds (fresh servers only ever call this once)
	local squishyFolder = ensureFolder(Workspace, "Squishies")
	local enemyFolder = ensureFolder(Workspace, "Enemies")
	local plotFolder = ensureFolder(Workspace, "Plots")

	-- Baseplate: reuse & recolor the existing one; never move or delete it.
	pcall(function()
		local baseplate = Workspace:FindFirstChild("Baseplate")
		if baseplate and baseplate:IsA("BasePart") then
			baseplate.Color = COLOR_BASEPLATE
			baseplate.Material = Enum.Material.Grass
		end
	end)

	-- Field floor: bright green 1-stud slab centered at the origin, top at GROUND_Y.
	makeSlab(
		"FieldFloor",
		Vector3.new(fieldSize.X, 1, fieldSize.Y),
		CFrame.new(0, GROUND_Y - 0.5, 0),
		COLOR_FIELD,
		root
	)

	-- Walkway ring: north/south strips span the corners, east/west strips fill the sides.
	local ringSpanX = fieldSize.X + walkway * 2
	makeSlab(
		"WalkwayNorth",
		Vector3.new(ringSpanX, 1, walkway),
		CFrame.new(0, GROUND_Y - 0.5, -(halfZ + walkway / 2)),
		COLOR_WALKWAY,
		root
	)
	makeSlab(
		"WalkwaySouth",
		Vector3.new(ringSpanX, 1, walkway),
		CFrame.new(0, GROUND_Y - 0.5, halfZ + walkway / 2),
		COLOR_WALKWAY,
		root
	)
	makeSlab(
		"WalkwayEast",
		Vector3.new(walkway, 1, fieldSize.Y),
		CFrame.new(halfX + walkway / 2, GROUND_Y - 0.5, 0),
		COLOR_WALKWAY,
		root
	)
	makeSlab(
		"WalkwayWest",
		Vector3.new(walkway, 1, fieldSize.Y),
		CFrame.new(-(halfX + walkway / 2), GROUND_Y - 0.5, 0),
		COLOR_WALKWAY,
		root
	)

	-- SpawnLocation: move the existing one onto the south walkway (create if missing).
	pcall(function()
		local spawnLocation = Workspace:FindFirstChildOfClass("SpawnLocation")
		if not spawnLocation then
			local created = Instance.new("SpawnLocation")
			created.Name = "SpawnLocation"
			created.Parent = root
			spawnLocation = created
		end
		local sl = spawnLocation :: SpawnLocation
		sl.Size = Vector3.new(12, 1, 12)
		sl.CFrame = CFrame.new(0, GROUND_Y + 0.5, halfZ + walkway / 2)
		sl.Anchored = true
		sl.Neutral = true
		sl.Color = COLOR_SPAWN
		sl.Material = Enum.Material.SmoothPlastic
		for _, child in sl:GetChildren() do
			if child:IsA("Decal") then
				child:Destroy()
			end
		end
	end)

	-- Low decorative border wall around the OUTSIDE of the walkway, with a gap
	-- wherever a plot sits so nothing blocks walkway -> plot movement.
	local outerX = halfX + walkway
	local outerZ = halfZ + walkway
	local wallHeight = 2
	local gapHalf = Config.Plot.BaseSize.X / 2 + 2

	local function wallSegment(name: string, alongX: boolean, offset: number, fromEdge: number, toEdge: number)
		local length = toEdge - fromEdge
		if length <= 0 then
			return
		end
		local mid = (fromEdge + toEdge) / 2
		local size: Vector3
		local cframe: CFrame
		if alongX then
			size = Vector3.new(length, wallHeight, 1)
			cframe = CFrame.new(mid, wallHeight / 2, offset)
		else
			size = Vector3.new(1, wallHeight, length)
			cframe = CFrame.new(offset, wallHeight / 2, mid)
		end
		makeSlab(name, size, cframe, COLOR_WALL, root)
	end

	local wallSides = {
		{ tag = "N", alongX = true, offset = -(outerZ + 0.5), extent = outerX, quarter = fieldSize.X / 4 },
		{ tag = "S", alongX = true, offset = outerZ + 0.5, extent = outerX, quarter = fieldSize.X / 4 },
		{ tag = "E", alongX = false, offset = outerX + 0.5, extent = outerZ, quarter = fieldSize.Y / 4 },
		{ tag = "W", alongX = false, offset = -(outerX + 0.5), extent = outerZ, quarter = fieldSize.Y / 4 },
	}
	for _, side in wallSides do
		local edge = side.extent + 1
		wallSegment("Wall" .. side.tag .. "1", side.alongX, side.offset, -edge, -(side.quarter + gapHalf))
		wallSegment("Wall" .. side.tag .. "2", side.alongX, side.offset, -(side.quarter - gapHalf), side.quarter - gapHalf)
		wallSegment("Wall" .. side.tag .. "3", side.alongX, side.offset, side.quarter + gapHalf, edge)
	end

	-- Candidate squishy spawn grid, inset from the field edge and centered.
	local squishySpawns: { Vector3 } = {}
	local innerHalfX = halfX - Config.Field.SpawnInset
	local innerHalfZ = halfZ - Config.Field.SpawnInset
	local spacing = Config.Field.SpawnSpacing :: number
	local countX = math.floor((innerHalfX * 2) / spacing) + 1
	local countZ = math.floor((innerHalfZ * 2) / spacing) + 1
	local startX = -((countX - 1) * spacing) / 2
	local startZ = -((countZ - 1) * spacing) / 2
	for ix = 0, countX - 1 do
		for iz = 0, countZ - 1 do
			table.insert(squishySpawns, Vector3.new(startX + ix * spacing, GROUND_Y, startZ + iz * spacing))
		end
	end

	-- Enemy patrol loop: corners + edge midpoints of the inset rectangle, ordered.
	local wpHalfX = halfX - Config.Field.WaypointInset
	local wpHalfZ = halfZ - Config.Field.WaypointInset
	local enemyWaypoints: { Vector3 } = {
		Vector3.new(-wpHalfX, GROUND_Y, -wpHalfZ),
		Vector3.new(0, GROUND_Y, -wpHalfZ),
		Vector3.new(wpHalfX, GROUND_Y, -wpHalfZ),
		Vector3.new(wpHalfX, GROUND_Y, 0),
		Vector3.new(wpHalfX, GROUND_Y, wpHalfZ),
		Vector3.new(0, GROUND_Y, wpHalfZ),
		Vector3.new(-wpHalfX, GROUND_Y, wpHalfZ),
		Vector3.new(-wpHalfX, GROUND_Y, 0),
	}
	local enemySpawns: { Vector3 } = { enemyWaypoints[1], enemyWaypoints[5] }

	-- Plot spots: 2 per side, centered beyond the walkway, facing the field center.
	local plotSpots: { CFrame } = {}
	local plotDepthHalf = Config.Plot.BaseSize.Y / 2
	local plotSides = {
		{ dir = Vector3.new(0, 0, -1), lateral = Vector3.new(1, 0, 0), axisHalf = halfZ, sideQuarter = fieldSize.X / 4 },
		{ dir = Vector3.new(1, 0, 0), lateral = Vector3.new(0, 0, 1), axisHalf = halfX, sideQuarter = fieldSize.Y / 4 },
		{ dir = Vector3.new(0, 0, 1), lateral = Vector3.new(1, 0, 0), axisHalf = halfZ, sideQuarter = fieldSize.X / 4 },
		{ dir = Vector3.new(-1, 0, 0), lateral = Vector3.new(0, 0, 1), axisHalf = halfX, sideQuarter = fieldSize.Y / 4 },
	}
	for _, side in plotSides do
		local dist = side.axisHalf + walkway + plotDepthHalf
		for _, sign in { -1, 1 } do
			local pos = fieldCenter + side.dir * dist + side.lateral * (side.sideQuarter * sign)
			-- Face perpendicular to the field edge (not the field center) so the
			-- 48x36 plot footprint stays axis-aligned with the walkway and wall gaps.
			table.insert(plotSpots, CFrame.lookAt(pos, pos - side.dir))
		end
	end
	assert(#plotSpots == Config.Plot.Count, "plotSpots count does not match Config.Plot.Count")

	-- Cheap decor: a few flat "rug" circles scattered inside the field.
	local rng = Random.new(1337)
	for i = 1, 7 do
		pcall(function()
			local diameter = rng:NextNumber(6, 14)
			local rug = Instance.new("Part")
			rug.Name = "Rug" .. i
			rug.Shape = Enum.PartType.Cylinder
			rug.Size = Vector3.new(0.12, diameter, diameter)
			rug.CFrame = CFrame.new(
				rng:NextNumber(-(innerHalfX - 8), innerHalfX - 8),
				GROUND_Y + 0.06,
				rng:NextNumber(-(innerHalfZ - 8), innerHalfZ - 8)
			) * CFrame.Angles(0, 0, math.rad(90))
			rug.Color = RUG_COLORS[(i - 1) % #RUG_COLORS + 1]
			rug.Material = Enum.Material.SmoothPlastic
			rug.Anchored = true
			rug.CanCollide = false
			rug.CanQuery = false
			rug.CanTouch = false
			rug.Parent = root
		end)
	end

	local function isInField(pos: Vector3): boolean
		return math.abs(pos.X - fieldCenter.X) <= halfX and math.abs(pos.Z - fieldCenter.Z) <= halfZ
	end

	return {
		root = root,
		squishyFolder = squishyFolder,
		enemyFolder = enemyFolder,
		plotFolder = plotFolder,
		fieldCenter = fieldCenter,
		fieldSize = fieldSize,
		isInField = isInField,
		squishySpawns = squishySpawns,
		enemyWaypoints = enemyWaypoints,
		enemySpawns = enemySpawns,
		plotSpots = plotSpots,
	}
end

return MapBuilder
