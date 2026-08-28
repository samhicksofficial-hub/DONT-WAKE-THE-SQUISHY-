--!strict
-- MapBuilder: builds all static world geometry and returns the `map` table
-- described in DESIGN.md ("The map table" + the Map Design Contract).
-- Called exactly once by init.server.luau before any service starts.
--
-- The arena, matched to the reference screenshots:
--   * a bright green grass field with a brown dirt/mulch border hugging its edge
--   * a light walkway ring around it (the safe zone)
--   * a tall dark charcoal boundary wall outside the walkway, broken by a gap
--     in front of every plot so players walk straight into their base
--   * four bases in a row along the south edge and four along the north
--   * decor props (market stalls, a TOP TIME leaderboard, a glowing portal)
--     parked on the dirt border, clear of the squishy spawn grid and of the
--     walkway-to-field lanes
--
-- Numbers and colours all come from Config.Field / Config.Plot / Config.Palette.

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

local Palette = Config.Palette :: any

-- Top surface of the field / walkway slabs (slabs are 1 stud, centered at 0.5).
local GROUND_Y = 1
-- Boundary wall footprint depth; its INNER face lines up with the walkway edge.
local WALL_THICKNESS = 2
-- Extra clearance either side of a plot in the boundary wall gap.
local WALL_GAP_MARGIN = 6
-- Props must keep at least this far from any squishy spawn point (contract).
local PROP_SPAWN_CLEARANCE = 10
-- Safe-zone decal thickness / lift above the walkway so nothing z-fights.
local MARKING_LIFT = 0.04

-- The baseplate reads as darker ground outside the arena: the same grass hue,
-- pushed well down toward black rather than a second hardcoded colour.
local BASEPLATE_COLOR = (Palette.Grass :: Color3):Lerp(Color3.new(0, 0, 0), 0.62)
-- Awning stripes and prop timber reuse palette entries instead of new colours.
local AWNING_STRIPES = { Palette.HouseRoof :: Color3, Palette.BaseTrim :: Color3 }

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

local function makePart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
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

-- Decoration a player could snag on: visible but completely inert.
local function makeDecor(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = makePart(parent, name, size, cframe, color)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function makeSurfaceGui(part: BasePart, face: Enum.NormalId, pixelsPerStud: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Adornee = part
	gui.Parent = part
	return gui
end

local function makeLabel(parent: Instance, text: string, position: UDim2, size: UDim2, opacity: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = position
	label.Size = size
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = Palette.BaseTrim
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextTransparency = 1 - opacity
	label.Parent = parent
	return label
end

-- ------------------------------------------------------------------- props --

-- A market stall: four corner posts, a striped awning of alternating slabs,
-- a counter across the front and a back board. `facing` points at the field.
local function buildStall(parent: Instance, index: number, pos: Vector3, facing: Vector3)
	local stall = Instance.new("Model")
	stall.Name = ("Stall%d"):format(index)

	local base = CFrame.lookAt(pos, pos + facing)
	local width, depth, postHeight = 14, 8, 7

	for corner = 1, 4 do
		local sx = (corner == 1 or corner == 4) and 1 or -1
		local sz = (corner <= 2) and 1 or -1
		makeDecor(
			stall,
			("Post%d"):format(corner),
			Vector3.new(0.8, postHeight, 0.8),
			base * CFrame.new(sx * (width / 2 - 0.5), postHeight / 2, sz * (depth / 2 - 0.5)),
			Palette.SignBoard
		)
	end

	makeDecor(
		stall,
		"Counter",
		Vector3.new(width, 1, 2),
		base * CFrame.new(0, 3.2, -(depth / 2 - 1)),
		Palette.BaseTrim
	)
	makeDecor(
		stall,
		"CounterFront",
		Vector3.new(width, 3.2, 0.5),
		base * CFrame.new(0, 1.6, -(depth / 2 - 0.2)),
		Palette.SignBoard
	)
	makeDecor(
		stall,
		"BackBoard",
		Vector3.new(width, 4, 0.4),
		base * CFrame.new(0, 4.6, depth / 2 - 0.3),
		Palette.BaseWall
	)

	local stripeCount = 6
	local stripeWidth = width / stripeCount
	for stripe = 1, stripeCount do
		local offsetX = -width / 2 + (stripe - 0.5) * stripeWidth
		makeDecor(
			stall,
			("Awning%d"):format(stripe),
			Vector3.new(stripeWidth, 0.4, depth + 2),
			base
				* CFrame.new(offsetX, postHeight + 0.7, -0.6)
				* CFrame.Angles(math.rad(10), 0, 0),
			AWNING_STRIPES[(stripe - 1) % #AWNING_STRIPES + 1]
		)
	end

	stall.Parent = parent
end

-- The tall TOP TIME leaderboard: two legs and a dark board carrying a
-- SurfaceGui with a title and placeholder rank rows.
local function buildLeaderboard(parent: Instance, pos: Vector3, facing: Vector3)
	local sign = Instance.new("Model")
	sign.Name = "TopTimeSign"

	local base = CFrame.lookAt(pos, pos + facing)
	local boardWidth, boardHeight, legHeight = 18, 12, 7

	for leg = 1, 2 do
		local sx = leg == 1 and -1 or 1
		makeDecor(
			sign,
			("Leg%d"):format(leg),
			Vector3.new(1.2, legHeight, 1.2),
			base * CFrame.new(sx * (boardWidth / 2 - 2), legHeight / 2, 0),
			Palette.BaseWall
		)
	end

	local board = makeDecor(
		sign,
		"Board",
		Vector3.new(boardWidth, boardHeight, 0.8),
		base * CFrame.new(0, legHeight + boardHeight / 2, 0),
		Palette.BoundaryWall
	)

	-- Front face normal is the part's LookVector, so the gui faces the field.
	local gui = makeSurfaceGui(board, Enum.NormalId.Front, 26)
	local title = makeLabel(gui, "TOP TIME", UDim2.fromScale(0.05, 0.04), UDim2.fromScale(0.9, 0.22), 1)
	title.TextColor3 = Palette.HouseBody

	local rows = { "1.  ---", "2.  ---", "3.  ---", "4.  ---" }
	for rank, text in rows do
		makeLabel(
			gui,
			text,
			UDim2.fromScale(0.1, 0.3 + (rank - 1) * 0.16),
			UDim2.fromScale(0.8, 0.13),
			0.72
		)
	end

	sign.Parent = parent
end

-- A glowing portal: a ring of Neon segments standing on the dirt, with a faint
-- neon disc filling it.
local function buildPortal(parent: Instance, pos: Vector3, facing: Vector3)
	local portal = Instance.new("Model")
	portal.Name = "Portal"

	local radius = 9
	local segments = 16
	local center = pos + Vector3.new(0, radius, 0)
	local base = CFrame.lookAt(center, center + facing)
	local segmentLength = 2 * radius * math.sin(math.pi / segments) * 1.2

	for index = 1, segments do
		local angle = (index - 1) * (2 * math.pi / segments)
		local ring = makeDecor(
			portal,
			("Ring%d"):format(index),
			Vector3.new(segmentLength, 1.6, 1.6),
			base
				* CFrame.new(math.cos(angle) * radius, math.sin(angle) * radius, 0)
				* CFrame.Angles(0, 0, angle + math.pi / 2),
			Palette.SafeZone
		)
		ring.Material = Enum.Material.Neon
	end

	local disc = makeDecor(
		portal,
		"Veil",
		Vector3.new(0.4, radius * 2 - 1, radius * 2 - 1),
		base * CFrame.Angles(0, math.rad(90), 0),
		Palette.SafeZone
	)
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.Neon
	disc.Transparency = 0.72

	portal.Parent = parent
end

-- ------------------------------------------------------------------- build --

function MapBuilder.Build(): Map
	local fieldSize = Config.Field.Size :: Vector2
	local walkway = Config.Field.WalkwayWidth :: number
	local dirt = Config.Field.DirtWidth :: number
	local wallHeight = Config.Field.WallHeight :: number
	local halfX = fieldSize.X / 2
	local halfZ = fieldSize.Y / 2
	local fieldCenter = Vector3.new(0, GROUND_Y, 0)
	local outerX = halfX + walkway
	local outerZ = halfZ + walkway

	local root = ensureFolder(Workspace, "Map")
	root:ClearAllChildren() -- idempotent rebuilds (fresh servers only ever call this once)
	local props = ensureFolder(root, "Props")
	local squishyFolder = ensureFolder(Workspace, "Squishies")
	local enemyFolder = ensureFolder(Workspace, "Enemies")
	local plotFolder = ensureFolder(Workspace, "Plots")

	-- Baseplate: reuse & recolor the existing one; never move or delete it.
	pcall(function()
		local baseplate = Workspace:FindFirstChild("Baseplate")
		if baseplate and baseplate:IsA("BasePart") then
			baseplate.Color = BASEPLATE_COLOR
			baseplate.Material = Enum.Material.Grass
		end
	end)

	-- Field floor. The dirt border is four slabs hugging the field edge and the
	-- grass is the rectangle they leave behind: every piece has its top at
	-- GROUND_Y and none of them overlap, so nothing z-fights.
	local grassX = fieldSize.X - dirt * 2
	local grassZ = fieldSize.Y - dirt * 2
	local floorCF = CFrame.new(0, GROUND_Y - 0.5, 0)
	makePart(root, "FieldFloor", Vector3.new(grassX, 1, grassZ), floorCF, Palette.Grass)

	makePart(
		root,
		"DirtNorth",
		Vector3.new(fieldSize.X, 1, dirt),
		floorCF * CFrame.new(0, 0, -(halfZ - dirt / 2)),
		Palette.Dirt
	)
	makePart(
		root,
		"DirtSouth",
		Vector3.new(fieldSize.X, 1, dirt),
		floorCF * CFrame.new(0, 0, halfZ - dirt / 2),
		Palette.Dirt
	)
	makePart(
		root,
		"DirtWest",
		Vector3.new(dirt, 1, grassZ),
		floorCF * CFrame.new(-(halfX - dirt / 2), 0, 0),
		Palette.Dirt
	)
	makePart(
		root,
		"DirtEast",
		Vector3.new(dirt, 1, grassZ),
		floorCF * CFrame.new(halfX - dirt / 2, 0, 0),
		Palette.Dirt
	)

	-- Walkway ring: north/south strips span the corners, east/west fill the sides.
	local ringSpanX = fieldSize.X + walkway * 2
	makePart(
		root,
		"WalkwayNorth",
		Vector3.new(ringSpanX, 1, walkway),
		floorCF * CFrame.new(0, 0, -(halfZ + walkway / 2)),
		Palette.Walkway
	)
	makePart(
		root,
		"WalkwaySouth",
		Vector3.new(ringSpanX, 1, walkway),
		floorCF * CFrame.new(0, 0, halfZ + walkway / 2),
		Palette.Walkway
	)
	makePart(
		root,
		"WalkwayEast",
		Vector3.new(walkway, 1, fieldSize.Y),
		floorCF * CFrame.new(halfX + walkway / 2, 0, 0),
		Palette.Walkway
	)
	makePart(
		root,
		"WalkwayWest",
		Vector3.new(walkway, 1, fieldSize.Y),
		floorCF * CFrame.new(-(halfX + walkway / 2), 0, 0),
		Palette.Walkway
	)

	-- Plot spots: four in a row along the south edge (+Z) and four along the
	-- north (-Z), evenly spaced across the field width. Each looks straight at
	-- the field (perpendicular to its edge), never angled at the field centre,
	-- so the footprints stay axis-aligned with the walkway and the wall gaps.
	local plotCount = Config.Plot.Count :: number
	local perEdge = math.floor(plotCount / 2)
	local plotFootprint = Config.Plot.BaseSize :: Vector2
	local plotDist = halfZ + walkway + plotFootprint.Y / 2
	local plotStep = fieldSize.X / perEdge
	local plotXs: { number } = {}
	for i = 1, perEdge do
		table.insert(plotXs, -halfX + plotStep * (i - 0.5))
	end

	local plotSpots: { CFrame } = {}
	local plotEdges = {
		{ z = plotDist, look = Vector3.new(0, 0, -1) },
		{ z = -plotDist, look = Vector3.new(0, 0, 1) },
	}
	for _, edge in plotEdges do
		for _, px in plotXs do
			local pos = Vector3.new(px, GROUND_Y, edge.z)
			table.insert(plotSpots, CFrame.lookAt(pos, pos + edge.look))
		end
	end
	assert(#plotSpots == plotCount, "plotSpots count does not match Config.Plot.Count")

	-- Boundary wall: tall dark charcoal, hugging the OUTSIDE of the walkway,
	-- with a walk-through gap in front of every plot. Collidable — it is the
	-- edge of the arena.
	local gapHalf = (plotFootprint.X + WALL_GAP_MARGIN) / 2
	local wallY = wallHeight / 2

	local function edgeWall(tag: string, zOffset: number)
		local cursor = -outerX
		local piece = 0
		local function run(stop: number)
			if stop - cursor <= 0.01 then
				return
			end
			piece += 1
			makePart(
				root,
				("Wall%s%d"):format(tag, piece),
				Vector3.new(stop - cursor, wallHeight, WALL_THICKNESS),
				CFrame.new((cursor + stop) / 2, wallY, zOffset),
				Palette.BoundaryWall
			)
		end
		for _, px in plotXs do
			run(math.clamp(px - gapHalf, -outerX, outerX))
			cursor = math.max(cursor, math.min(px + gapHalf, outerX))
		end
		run(outerX)
	end

	edgeWall("South", outerZ + WALL_THICKNESS / 2)
	edgeWall("North", -(outerZ + WALL_THICKNESS / 2))

	local sideWallLength = (outerZ + WALL_THICKNESS) * 2
	makePart(
		root,
		"WallEast",
		Vector3.new(WALL_THICKNESS, wallHeight, sideWallLength),
		CFrame.new(outerX + WALL_THICKNESS / 2, wallY, 0),
		Palette.BoundaryWall
	)
	makePart(
		root,
		"WallWest",
		Vector3.new(WALL_THICKNESS, wallHeight, sideWallLength),
		CFrame.new(-(outerX + WALL_THICKNESS / 2), wallY, 0),
		Palette.BoundaryWall
	)

	-- Safe-zone markings: a translucent strip across the walkway in front of
	-- every plot, with "SAFE ZONE" laid flat on it. Oriented from the plot spot
	-- so each one reads the right way up for the base it belongs to.
	local markings = ensureFolder(root, "SafeZones")
	for index, spot in plotSpots do
		pcall(function()
			local edgeSign = spot.LookVector.Z < 0 and 1 or -1
			local stripPos = Vector3.new(
				spot.Position.X,
				GROUND_Y + MARKING_LIFT,
				edgeSign * (halfZ + walkway / 2)
			)
			local strip = makeDecor(
				markings,
				("SafeZone%d"):format(index),
				Vector3.new(plotFootprint.X, 0.08, walkway - 2),
				CFrame.lookAt(stripPos, stripPos + spot.LookVector),
				Palette.SafeZone
			)
			strip.Transparency = 0.82
			strip.Material = Enum.Material.SmoothPlastic

			local gui = makeSurfaceGui(strip, Enum.NormalId.Top, 18)
			makeLabel(gui, "SAFE ZONE", UDim2.fromScale(0.1, 0.22), UDim2.fromScale(0.8, 0.56), 0.55)
		end)
	end

	-- WorldSpawn: Roblox needs exactly one SpawnLocation, but SpawnService moves
	-- arriving characters onto their base immediately. Park it outside the wall
	-- on solid baseplate (never in the void — SpawnService leaves a player here
	-- if their plot never builds) and make it inert.
	pcall(function()
		local existing = Workspace:FindFirstChildOfClass("SpawnLocation")
		if not existing then
			local created = Instance.new("SpawnLocation")
			created.Parent = root
			existing = created
		end
		local spawnPart = existing :: SpawnLocation
		spawnPart.Name = "WorldSpawn"
		spawnPart.Size = Vector3.new(8, 1, 8)
		spawnPart.CFrame = CFrame.new(-(outerX + 40), 0.5, 0)
		spawnPart.Anchored = true
		spawnPart.CanCollide = false
		spawnPart.CanQuery = false
		spawnPart.CanTouch = false
		spawnPart.Transparency = 1
		spawnPart.Neutral = true
		spawnPart.Duration = 0
		spawnPart.Enabled = true
		for _, child in spawnPart:GetChildren() do
			if child:IsA("Decal") or child:IsA("Texture") then
				child:Destroy()
			end
		end
	end)

	-- Candidate squishy spawn grid: inset from the FULL field rect (the dirt
	-- border is only paint, squishies may sit on it).
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

	-- Field props. They live on the EAST and WEST dirt border: the north and
	-- south borders are the walkway-to-field lanes in front of the eight bases,
	-- and the middle of the field is the squishy spawn grid. Each anchor is
	-- checked against the grid before it is built, so a retuned Config can never
	-- quietly drop a stall on top of a spawn point.
	local dirtMid = halfX - dirt / 2
	local propSpecs = {
		{ kind = "stall", pos = Vector3.new(-dirtMid, GROUND_Y, -55), facing = Vector3.new(1, 0, 0), radius = 9 },
		{ kind = "stall", pos = Vector3.new(-dirtMid, GROUND_Y, 55), facing = Vector3.new(1, 0, 0), radius = 9 },
		{ kind = "stall", pos = Vector3.new(dirtMid, GROUND_Y, -55), facing = Vector3.new(-1, 0, 0), radius = 9 },
		{ kind = "stall", pos = Vector3.new(dirtMid, GROUND_Y, 55), facing = Vector3.new(-1, 0, 0), radius = 9 },
		{ kind = "board", pos = Vector3.new(-dirtMid - 1, GROUND_Y, 0), facing = Vector3.new(1, 0, 0), radius = 10 },
		{ kind = "portal", pos = Vector3.new(dirtMid + 1, GROUND_Y, 0), facing = Vector3.new(-1, 0, 0), radius = 10 },
	}

	local function propIsClear(pos: Vector3, radius: number): boolean
		local needed = radius + PROP_SPAWN_CLEARANCE
		for _, spawnPos in squishySpawns do
			local dx = pos.X - spawnPos.X
			local dz = pos.Z - spawnPos.Z
			if dx * dx + dz * dz < needed * needed then
				return false
			end
		end
		return true
	end

	local stallIndex = 0
	for _, spec in propSpecs do
		local ok, err = pcall(function()
			if not propIsClear(spec.pos, spec.radius) then
				warn(("[MapBuilder] skipped %s prop at %s: too close to a squishy spawn"):format(
					spec.kind,
					tostring(spec.pos)
				))
				return
			end
			if spec.kind == "stall" then
				stallIndex += 1
				buildStall(props, stallIndex, spec.pos, spec.facing)
			elseif spec.kind == "board" then
				buildLeaderboard(props, spec.pos, spec.facing)
			else
				buildPortal(props, spec.pos, spec.facing)
			end
		end)
		if not ok then
			warn(("[MapBuilder] prop '%s' failed to build: %s"):format(spec.kind, tostring(err)))
		end
	end

	-- Visual only: the dirt border is inside the field, so containment stays the
	-- full rect (squishies spawn on and can be carried off the mulch).
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
