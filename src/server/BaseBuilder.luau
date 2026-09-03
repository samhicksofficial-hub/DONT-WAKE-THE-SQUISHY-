--!strict
-- BaseBuilder: builds ONE player's base building — the enclosed room that
-- PlotService then fills with slot platforms, collect/unlock pads and the
-- pedestals. Matched to the reference screenshots (see the "Map Design
-- Contract" in DESIGN.md): grey floor, dark charcoal walls under a white trim
-- strip, a warm orange inner face on the back wall, white-framed windows with
-- dark panes, a flat roof lit from beneath by glowing ceiling panels, a
-- stylised house marker bobbing overhead and an orange owner sign out front.
--
-- Base local space. `baseCFrame` is the plot origin at ground level with its
-- LookVector aimed at the field, so:
--   -Z  = FRONT, the open side facing the field      +Z  = BACK wall
--   -X  = left when facing the field                 +X  = right
--   y=0 = ground; the floor slab's top is Config.Base.FloorTop
-- Footprint is Config.Plot.BaseSize (X = width, Y = depth).
--
-- Everything built here is parented to the Model handed in. PlotService owns
-- the gameplay furniture; nothing in this file touches it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local BaseBuilder = {}

export type BaseShell = {
	spawnPoint: BasePart,
	floorTop: number,        -- the GROUND floor (players spawn here)
	floorTops: { number },   -- one entry per storey, lowest (deepest) first
	groundIndex: number,     -- which floorTops entry is the ground floor
}

local Palette = Config.Palette :: any

-- ------------------------------------------------------------ dimensions --
-- Every number here is derived from Config; nothing structural is invented.

local FOOTPRINT = Config.Plot.BaseSize :: Vector2
local HALF_WIDTH = FOOTPRINT.X / 2
local HALF_DEPTH = FOOTPRINT.Y / 2

local FLOOR_TOP = Config.Base.FloorTop :: number
-- Floors are decided per base at build time (they are bought), so these are
-- the CEILINGS the geometry must cope with, not a fixed count.
local MAX_ABOVE = Config.Plot.MaxAbove :: number
local MAX_BELOW = Config.Plot.MaxBelow :: number
local FLOOR_HEIGHT = Config.Base.FloorHeight :: number
local SLAB_T = Config.Base.FloorSlabThickness :: number
-- One storey per floor: the building grows upward rather than the rooms
-- getting shorter as floors are added.
local WALL_H = FLOOR_HEIGHT -- one storey; buildShell stacks more as bought
local WALL_T = Config.Base.WallThickness :: number
local TRIM_H = Config.Base.TrimHeight :: number
local ROOF_T = Config.Base.RoofThickness :: number
local WINDOW_W = Config.Base.WindowWidth :: number
local WINDOW_H = Config.Base.WindowHeight :: number
local WINDOW_SILL = Config.Base.WindowSill :: number
local LIGHT_COUNT = Config.Base.CeilingLights :: number

-- Set alongside FLOOR_TOPS: the shell spans every storey the base owns, so a
-- basement drops the base of the walls and an upper floor raises the roof.
local SHELL_BASE = FLOOR_TOP        -- underside of the lowest floor
local SHELL_HEIGHT = FLOOR_HEIGHT   -- lowest floor to ceiling of the highest
local WALL_TOP = FLOOR_TOP + FLOOR_HEIGHT
local ROOF_TOP = WALL_TOP + ROOF_T

-- Trim stands proud of the wall on both faces so it reads as a moulding.
local TRIM_PROUD = 0.3
-- Side walls stop at the back wall's inner face so no two outer faces end up
-- coplanar (which would z-fight along the back corners).
local SIDE_DEPTH = FOOTPRINT.Y - WALL_T
local SIDE_Z = -WALL_T / 2
-- Chunky white corner posts at the open front — what makes the box read "built".
-- They stand a touch proud of the walls for the same anti-z-fight reason.
local PILLAR_SIZE = 2.4
local PILLAR_PROUD = 0.12
-- Warm orange facing on the inner side of the back wall.
local BACK_PANEL_THICKNESS = 0.3
local BACK_PANEL_GAP = 0.05 -- keeps the panel off the wall face, no z-fighting
-- Window frames sit proud of the inner wall face; panes pass through the wall
-- so the opening reads from outside too (no CSG, no fake holes).
local FRAME_BAR = 0.6
local FRAME_PROUD = 0.25
local PANE_OVERHANG = 0.2
-- Two windows per side wall, at a fraction of the base depth either side of centre.
local WINDOW_Z_FRACTION = 0.4
local ROOF_OVERHANG = 1.6
local LIGHT_PANEL_SIZE = 8
local LIGHT_PANEL_THICKNESS = 0.3
local LIGHT_BRIGHTNESS = 0.7
local LIGHT_RANGE = 17

-- Far enough in that the angled board clears the left wall and the pillar.
local SIGN_INSET_X = 7 -- sign centre this far in from the left wall
local SIGN_INSET_Z = 2 -- ...and this far in from the open front edge
local SIGN_POST_HEIGHT = 4
local SIGN_BOARD_SIZE = Vector3.new(9, 5, 0.45)
local SIGN_ANGLE = math.rad(-18) -- swings the board in toward the base centre

local SPAWN_INSET = 4 -- spawn marker this far in from the front edge
local SPAWN_MARKER_HEIGHT = 1

local HOUSE_LIFT = 9 -- house marker floats this far above the roof
local HOUSE_ICON_STUDS = 9 -- billboard size of the floating house icon
local HOUSE_ICON_DISTANCE = 400
local BOB_HEIGHT = 0.8
local BOB_SPEED = 1.7
local SPIN_SPEED = 0.6
local HOUSE_STEP = 1 / 30

-- Colours the palette does not carry (glass, house trimmings, lamp warmth).
local PANE_COLOR = Color3.fromRGB(24, 28, 36)
local LAMP_COLOR = Color3.fromRGB(255, 246, 228)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-- ---------------------------------------------------------------- helpers --

local function newPart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Decoration a player could snag on: solid to look at, invisible to physics.
local function newProp(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
	local part = newPart(parent, name, size, cf, color, material)
	part.CanCollide = false
	part.CanTouch = false
	return part
end

-- ------------------------------------------------------- house marker loop --
-- ONE loop drives every base's floating house. Entries drop out when their
-- model is destroyed (Instance:Destroy nils the Parent of every descendant),
-- so a leaving player never leaks a spinning house.

type HouseEntry = {
	model: Model,
	origin: CFrame,
	phase: number,
}

local houses: { HouseEntry } = {}
local houseLoopStarted = false

local function updateHouse(entry: HouseEntry, clock: number)
	local bob = math.sin(clock * BOB_SPEED + entry.phase) * BOB_HEIGHT
	entry.model:PivotTo(
		entry.origin * CFrame.new(0, bob, 0) * CFrame.Angles(0, clock * SPIN_SPEED + entry.phase, 0)
	)
end

local function startHouseLoop()
	if houseLoopStarted then
		return
	end
	houseLoopStarted = true
	task.spawn(function()
		while true do
			task.wait(HOUSE_STEP)
			local clock = os.clock()
			-- Backwards so removals do not skip an entry.
			for i = #houses, 1, -1 do
				local entry = houses[i]
				-- Destroyed model (Parent nil'd by Destroy) or a broken update:
				-- either way the entry goes, so a leaving player leaks nothing.
				if entry.model.Parent == nil or not pcall(updateHouse, entry, clock) then
					table.remove(houses, i)
				end
			end
		end
	end)
end

-- --------------------------------------------------------------- the shell --

-- Floor slab, three walls, the white trim band and front pillars, the warm
-- orange inner facing on the back wall, and the roof.
-- Walking surface height of each storey, LOWEST FIRST. Floors are bought, so
-- these are set per base at the top of Build and read by every helper below.
-- Build never yields between setting and using them (the avatar fetch is
-- task.spawn'd), so a second base cannot interleave and steal them.
local FLOOR_TOPS: { number } = { FLOOR_TOP }
local FLOORS = 1
local GROUND_INDEX = 1

-- Storey heights for a base with `above` floors on top and `below` beneath.
-- Index 1 is the deepest basement; GROUND_INDEX is the ground floor.
local function computeFloorTops(above: number, below: number)
	above = math.clamp(math.floor(above or 0), 0, MAX_ABOVE)
	below = math.clamp(math.floor(below or 0), 0, MAX_BELOW)
	FLOOR_TOPS = {}
	for level = -below, above do
		table.insert(FLOOR_TOPS, FLOOR_TOP + level * FLOOR_HEIGHT)
	end
	FLOORS = #FLOOR_TOPS
	GROUND_INDEX = below + 1
	-- Walls run from the deepest floor to the ceiling above the highest.
	SHELL_BASE = FLOOR_TOPS[1]
	SHELL_HEIGHT = FLOOR_HEIGHT * FLOORS
	WALL_TOP = SHELL_BASE + SHELL_HEIGHT
	ROOF_TOP = WALL_TOP + ROOF_T
end

-- The ladder: one climbable wooden truss column against the back wall, running
-- from the deepest floor to the top storey's ceiling, through a hatch cut in
-- every slab it passes. It replaced the staircase, which ate a seven-stud lane
-- out of every floor's slot space; the ladder costs a 6x5 hole at the back.
local LADDER_W = 2 -- a TrussPart's cross-section must be exactly 2 x 2
local HATCH_W = 6 -- hatch width in the slab, centred on the ladder
local HATCH_DEPTH = 5 -- how far the hatch reaches forward of the back wall
local LADDER_COLOR = Color3.fromRGB(164, 120, 78) -- warm wood, like the reference

-- TrussParts are natively climbable, so every storey is reachable by the same
-- column with no jumping and no flight geometry at all. Only built when the
-- base has more than one storey.
local function buildLadder(model: Model, baseCFrame: CFrame)
	local height = WALL_TOP - SHELL_BASE
	local ladder = Instance.new("TrussPart")
	ladder.Name = "Ladder"
	ladder.Size = Vector3.new(LADDER_W, height, LADDER_W)
	ladder.CFrame = baseCFrame * CFrame.new(0, SHELL_BASE + height / 2, HALF_DEPTH - WALL_T - LADDER_W / 2)
	ladder.Color = LADDER_COLOR
	ladder.Material = Enum.Material.Wood
	ladder.Anchored = true
	ladder.TopSurface = Enum.SurfaceType.Smooth
	ladder.BottomSurface = Enum.SurfaceType.Smooth
	ladder.Parent = model
end

-- The slab that is storey N's floor and storey N-1's ceiling. It covers the
-- footprint except the ladder hatch at the back-centre, left open to climb
-- through: one full-width piece forward of the hatch, and a strip either side.
local function buildFloorSlab(model: Model, baseCFrame: CFrame, level: number, floorTop: number)
	local slabY = floorTop - SLAB_T / 2
	local frontDepth = FOOTPRINT.Y - WALL_T - HATCH_DEPTH
	newPart(
		model,
		("FloorSlab%d"):format(level),
		Vector3.new(FOOTPRINT.X, SLAB_T, frontDepth),
		baseCFrame * CFrame.new(0, slabY, -(HALF_DEPTH - frontDepth / 2)),
		Palette.BaseFloor,
		Enum.Material.SmoothPlastic
	)
	local stripW = (FOOTPRINT.X - HATCH_W) / 2
	for _, side in { -1, 1 } do
		newPart(
			model,
			("FloorSlab%d%s"):format(level, side < 0 and "Left" or "Right"),
			Vector3.new(stripW, SLAB_T, HATCH_DEPTH + WALL_T),
			baseCFrame * CFrame.new(
				side * (HATCH_W / 2 + stripW / 2),
				slabY,
				HALF_DEPTH - (HATCH_DEPTH + WALL_T) / 2
			),
			Palette.BaseFloor,
			Enum.Material.SmoothPlastic
		)
	end
end

local function buildShell(model: Model, baseCFrame: CFrame)
	newPart(
		model,
		"Floor",
		-- The lowest floor slab: thick enough to read as ground even when the
		-- base has been dug down into basements.
		Vector3.new(FOOTPRINT.X, 1, FOOTPRINT.Y),
		baseCFrame * CFrame.new(0, SHELL_BASE - 0.5, 0),
		Palette.BaseFloor,
		Enum.Material.SmoothPlastic
	)

	local backZ = HALF_DEPTH - WALL_T / 2
	newPart(
		model,
		"BackWall",
		Vector3.new(FOOTPRINT.X, SHELL_HEIGHT, WALL_T),
		baseCFrame * CFrame.new(0, SHELL_BASE + SHELL_HEIGHT / 2, backZ),
		Palette.BaseWall,
		Enum.Material.SmoothPlastic
	)
	newProp(
		model,
		"BackTrim",
		Vector3.new(FOOTPRINT.X + TRIM_PROUD * 2, TRIM_H, WALL_T + TRIM_PROUD * 2),
		baseCFrame * CFrame.new(0, WALL_TOP - TRIM_H / 2, backZ),
		Palette.BaseTrim,
		Enum.Material.SmoothPlastic
	)

	-- The front is open so a player can walk in off the walkway — but that is
	-- only true at ground level. Every storey BELOW the ground floor is
	-- underground, and outside it is the hole the world's ground plane leaves
	-- for this base, so an open front down there was two steps into the void.
	-- Wall the buried storeys in. Its top lands flush with the ground floor's
	-- slab, so the doorway upstairs is untouched, and a base with no basements
	-- gets a height of zero and no wall at all.
	local buriedHeight = FLOOR_TOPS[GROUND_INDEX] - SHELL_BASE
	if buriedHeight > 0.01 then
		newPart(
			model,
			"FrontWall",
			Vector3.new(FOOTPRINT.X, buriedHeight, WALL_T),
			baseCFrame * CFrame.new(0, SHELL_BASE + buriedHeight / 2, -(HALF_DEPTH - WALL_T / 2)),
			Palette.BaseWall,
			Enum.Material.SmoothPlastic
		)
	end

	for _, side in { -1, 1 } do
		local wallX = side * (HALF_WIDTH - WALL_T / 2)
		local label = side < 0 and "Left" or "Right"
		newPart(
			model,
			label .. "Wall",
			Vector3.new(WALL_T, SHELL_HEIGHT, SIDE_DEPTH),
			baseCFrame * CFrame.new(wallX, SHELL_BASE + SHELL_HEIGHT / 2, SIDE_Z),
			Palette.BaseWall,
			Enum.Material.SmoothPlastic
		)
		newProp(
			model,
			label .. "Trim",
			Vector3.new(WALL_T + TRIM_PROUD * 2, TRIM_H, SIDE_DEPTH),
			baseCFrame * CFrame.new(wallX, WALL_TOP - TRIM_H / 2, SIDE_Z),
			Palette.BaseTrim,
			Enum.Material.SmoothPlastic
		)
		-- White post down each front corner, capping the open edge.
		newPart(
			model,
			label .. "Pillar",
			Vector3.new(PILLAR_SIZE, SHELL_HEIGHT, PILLAR_SIZE),
			baseCFrame * CFrame.new(
				side * (HALF_WIDTH - PILLAR_SIZE / 2 + PILLAR_PROUD),
				SHELL_BASE + SHELL_HEIGHT / 2,
				-(HALF_DEPTH - PILLAR_SIZE / 2 + PILLAR_PROUD)
			),
			Palette.BaseTrim,
			Enum.Material.SmoothPlastic
		)
	end

	-- Warm orange facing on the inside of the back wall, stopping under the trim.
	local panelHeight = WALL_H - TRIM_H
	newProp(
		model,
		"BackPanel",
		Vector3.new(FOOTPRINT.X - WALL_T * 2, panelHeight, BACK_PANEL_THICKNESS),
		baseCFrame * CFrame.new(
			0,
			SHELL_BASE + panelHeight / 2,
			HALF_DEPTH - WALL_T - BACK_PANEL_THICKNESS / 2 - BACK_PANEL_GAP
		),
		Palette.BaseBack,
		Enum.Material.SmoothPlastic
	)

	newPart(
		model,
		"Roof",
		Vector3.new(FOOTPRINT.X + ROOF_OVERHANG, ROOF_T, FOOTPRINT.Y + ROOF_OVERHANG),
		baseCFrame * CFrame.new(0, WALL_TOP + ROOF_T / 2, 0),
		Palette.BaseRoof,
		Enum.Material.SmoothPlastic
	)

	-- One ladder serves every storey, so it stands outside the per-level loop.
	if FLOORS > 1 then
		buildLadder(model, baseCFrame)
	end

	-- Upper storeys: a floor slab with a ladder hatch, and a trim band on the
	-- outside marking the storey line.
	for level = 2, FLOORS do
		local floorTop = FLOOR_TOPS[level]
		buildFloorSlab(model, baseCFrame, level, floorTop)

		-- A BAND, not a lid. This used to be one slab the size of the whole
		-- floor plan, which did three things it was never meant to: it sealed
		-- the stairwell opening (so the flight climbed into what looked like a
		-- solid white ceiling), it swallowed the storey's four ceiling panels
		-- whole, and it hid the room below behind an opaque plane. Three
		-- strips hugging the back and side walls mark the same storey line
		-- from outside and leave the interior open, exactly like BackTrim and
		-- LeftTrim/RightTrim do at the top of the walls.
		local bandY = floorTop - SLAB_T - TRIM_H / 2
		newProp(
			model,
			("StoreyBandBack%d"):format(level),
			Vector3.new(FOOTPRINT.X + TRIM_PROUD * 2, TRIM_H, WALL_T + TRIM_PROUD * 2),
			baseCFrame * CFrame.new(0, bandY, HALF_DEPTH - WALL_T / 2),
			Palette.BaseTrim,
			Enum.Material.SmoothPlastic
		)
		for _, side in { -1, 1 } do
			newProp(
				model,
				("StoreyBand%s%d"):format(side < 0 and "Left" or "Right", level),
				Vector3.new(WALL_T + TRIM_PROUD * 2, TRIM_H, SIDE_DEPTH + TRIM_PROUD * 2),
				baseCFrame * CFrame.new(side * (HALF_WIDTH - WALL_T / 2), bandY, SIDE_Z),
				Palette.BaseTrim,
				Enum.Material.SmoothPlastic
			)
		end
	end
end

-- ----------------------------------------------------------------- windows --

-- A white frame standing proud of the inner wall face around a dark pane that
-- passes through the wall, so the opening reads from both sides.
local function buildWindow(model: Model, baseCFrame: CFrame, side: number, localZ: number, label: string, floorTop: number)
	local innerX = side * (HALF_WIDTH - WALL_T)
	local frameX = innerX - side * (FRAME_PROUD / 2)
	-- Sill is measured from THIS storey's floor, so upper windows sit correctly.
	local centerY = floorTop + WINDOW_SILL + WINDOW_H / 2

	local barSpan = WINDOW_W + FRAME_BAR * 2
	for _, vertical in { 1, -1 } do
		newProp(
			model,
			label .. "FrameH",
			Vector3.new(FRAME_PROUD, FRAME_BAR, barSpan),
			baseCFrame * CFrame.new(frameX, centerY + vertical * (WINDOW_H / 2 + FRAME_BAR / 2), localZ),
			Palette.BaseTrim,
			Enum.Material.SmoothPlastic
		)
	end
	for _, along in { 1, -1 } do
		newProp(
			model,
			label .. "FrameV",
			Vector3.new(FRAME_PROUD, WINDOW_H, FRAME_BAR),
			baseCFrame * CFrame.new(frameX, centerY, localZ + along * (WINDOW_W / 2 + FRAME_BAR / 2)),
			Palette.BaseTrim,
			Enum.Material.SmoothPlastic
		)
	end

	local pane = newProp(
		model,
		label .. "Pane",
		Vector3.new(WALL_T + PANE_OVERHANG, WINDOW_H, WINDOW_W),
		baseCFrame * CFrame.new(side * (HALF_WIDTH - WALL_T / 2), centerY, localZ),
		PANE_COLOR,
		Enum.Material.Glass
	)
	pane.Transparency = 0.5
	pane.Reflectance = 0.1
end

-- Two windows per side wall, per storey.
local function buildWindows(model: Model, baseCFrame: CFrame)
	local offset = HALF_DEPTH * WINDOW_Z_FRACTION
	for level = 1, FLOORS do
		for _, side in { -1, 1 } do
			local sideLabel = side < 0 and "Left" or "Right"
			for index, localZ in { -offset, offset } do
				buildWindow(model, baseCFrame, side, localZ, ("%sWindow%d_%d"):format(sideLabel, level, index), FLOOR_TOPS[level])
			end
		end
	end
end

-- ---------------------------------------------------------- ceiling lights --

-- Neon panels recessed into the roof's underside, evenly spaced across the
-- width, each carrying a warm PointLight. This is what makes the interior read
-- bright against the night sky.
-- Every storey gets its own row of panels, set into whatever is above it: the
-- slab of the floor overhead, or the roof for the top storey.
local function buildCeilingLights(model: Model, baseCFrame: CFrame)
	if LIGHT_COUNT < 1 then
		return
	end
	local step = FOOTPRINT.X / LIGHT_COUNT
	for level = 1, FLOORS do
	local ceilingY = if level < FLOORS
		then FLOOR_TOPS[level + 1] - SLAB_T
		else WALL_TOP
	for index = 1, LIGHT_COUNT do
		local localX = (index - (LIGHT_COUNT + 1) / 2) * step
		local panel = newProp(
			model,
			("CeilingLight%d_%d"):format(level, index),
			Vector3.new(LIGHT_PANEL_SIZE, LIGHT_PANEL_THICKNESS, LIGHT_PANEL_SIZE),
			baseCFrame * CFrame.new(localX, ceilingY - LIGHT_PANEL_THICKNESS / 2, 0),
			WHITE,
			Enum.Material.Neon
		)
		local light = Instance.new("PointLight")
		light.Name = "Glow"
		light.Brightness = LIGHT_BRIGHTNESS
		light.Range = LIGHT_RANGE
		light.Color = LAMP_COLOR
		light.Shadows = false
		light.Parent = panel
	end
	end
end

-- ------------------------------------------------------------ house marker --

-- The house icon floating over the roof. It is a flat billboard rather than a
-- built model: the reference games mark a base with a drawn icon, and a
-- billboard reads the same from every angle instead of showing its back.
--
-- It still joins the shared animation loop so it bobs. The loop's spin has no
-- visible effect on a billboard (they always face the camera), which is fine —
-- a flat icon should not appear to turn edge-on anyway.
local function buildHouseMarker(model: Model, baseCFrame: CFrame)
	local house = Instance.new("Model")
	house.Name = "HouseMarker"

	-- An invisible anchor: the loop pivots the model, and the billboard rides it.
	local body = newProp(
		house,
		"Body",
		Vector3.new(1, 1, 1),
		CFrame.new(),
		Palette.HouseBody,
		Enum.Material.SmoothPlastic
	)
	body.Transparency = 1
	house.PrimaryPart = body

	local gui = Instance.new("BillboardGui")
	gui.Name = "HouseGui"
	gui.Size = UDim2.fromScale(HOUSE_ICON_STUDS, HOUSE_ICON_STUDS)
	gui.AlwaysOnTop = false
	gui.MaxDistance = HOUSE_ICON_DISTANCE
	gui.Adornee = body
	gui.Parent = body

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(1, 1)
	icon.Image = Config.Icons.House
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = gui

	local origin = baseCFrame * CFrame.new(0, ROOF_TOP + HOUSE_LIFT, 0)
	house:PivotTo(origin)
	house.Parent = model

	table.insert(houses, {
		model = house,
		origin = origin,
		-- Staggers the bob and spin so a row of bases never pulses in lockstep.
		phase = math.random() * math.pi * 2,
	})
	startHouseLoop()
end

-- -------------------------------------------------------------- owner sign --

-- Orange board on a post at the front-left corner, angled in toward the base
-- centre so it is readable from the field. The avatar fetch YIELDS, so it runs
-- in its own task and never delays the build; a failure just leaves the name.
local function buildOwnerSign(model: Model, baseCFrame: CFrame, player: Player)
	local localX = -(HALF_WIDTH - SIGN_INSET_X)
	local localZ = -(HALF_DEPTH - SIGN_INSET_Z)
	local facing = CFrame.Angles(0, SIGN_ANGLE, 0)

	newProp(
		model,
		"SignPost",
		Vector3.new(0.9, SIGN_POST_HEIGHT, 0.9),
		baseCFrame * CFrame.new(localX, FLOOR_TOPS[GROUND_INDEX] + SIGN_POST_HEIGHT / 2, localZ) * facing,
		Palette.BaseRoof,
		Enum.Material.SmoothPlastic
	)
	local board = newProp(
		model,
		"OwnerSign",
		SIGN_BOARD_SIZE,
		baseCFrame
			* CFrame.new(localX, FLOOR_TOPS[GROUND_INDEX] + SIGN_POST_HEIGHT + SIGN_BOARD_SIZE.Y / 2, localZ)
			* facing,
		Palette.SignBoard,
		Enum.Material.SmoothPlastic
	)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "OwnerGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.Parent = board

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.BackgroundTransparency = 1
	avatar.AnchorPoint = Vector2.new(0.5, 0)
	avatar.Position = UDim2.fromScale(0.5, 0.06)
	-- RelativeYY keeps the headshot square whatever the board's aspect is.
	avatar.SizeConstraint = Enum.SizeConstraint.RelativeYY
	avatar.Size = UDim2.fromScale(0.6, 0.6)
	avatar.ScaleType = Enum.ScaleType.Fit
	avatar.Visible = false
	avatar.Parent = gui

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "OwnerName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.fromScale(0.5, 0.97)
	nameLabel.Size = UDim2.fromScale(0.92, 0.28)
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Text = player.DisplayName
	nameLabel.TextColor3 = WHITE
	nameLabel.TextStrokeColor3 = BLACK
	nameLabel.TextStrokeTransparency = 0
	nameLabel.TextScaled = true
	nameLabel.Parent = gui

	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
		end)
		if not ok or typeof(content) ~= "string" or content == "" then
			return
		end
		if avatar.Parent == nil then
			return
		end
		avatar.Image = content
		avatar.Visible = true
	end)
end

-- -------------------------------------------------------------- spawn point --

-- Invisible marker resting ON the floor at the front centre, facing out toward
-- the field. SpawnService lifts the character above it, so it stays at floor
-- level rather than at torso height.
local function buildSpawnPoint(model: Model, baseCFrame: CFrame): BasePart
	local point = newPart(
		model,
		"SpawnPoint",
		Vector3.new(2, SPAWN_MARKER_HEIGHT, 2),
		-- Always the GROUND floor: players arrive at street level.
		baseCFrame * CFrame.new(0, FLOOR_TOPS[GROUND_INDEX] + SPAWN_MARKER_HEIGHT / 2, -(HALF_DEPTH - SPAWN_INSET)),
		Palette.BaseFloor,
		Enum.Material.SmoothPlastic
	)
	point.Transparency = 1
	point.CanCollide = false
	point.CanTouch = false
	point.CanQuery = false
	return point
end

-- --------------------------------------------------------------- public API --

-- Builds the whole building into `model` and reports what PlotService needs.
-- The shell and the spawn point are the contract, so they build straight; the
-- decorative passes are each guarded so one bad prop never costs a player
-- their base.
-- The sign on an unclaimed base: no avatar, just an invitation.
local function buildVacantSign(model: Model, baseCFrame: CFrame)
	local post = newPart(
		model,
		"SignPost",
		Vector3.new(0.6, SIGN_POST_HEIGHT, 0.6),
		baseCFrame * CFrame.new(
			-(HALF_WIDTH - SIGN_INSET_X),
			FLOOR_TOPS[GROUND_INDEX] + SIGN_POST_HEIGHT / 2,
			-(HALF_DEPTH - SIGN_INSET_Z)
		),
		Palette.SignBoard,
		Enum.Material.SmoothPlastic
	)
	post.CanCollide = false

	local board = newProp(
		model,
		"SignBoard",
		SIGN_BOARD_SIZE,
		baseCFrame
			* CFrame.new(
				-(HALF_WIDTH - SIGN_INSET_X),
				FLOOR_TOPS[GROUND_INDEX] + SIGN_POST_HEIGHT + SIGN_BOARD_SIZE.Y / 2,
				-(HALF_DEPTH - SIGN_INSET_Z)
			)
			* CFrame.Angles(0, SIGN_ANGLE, 0),
		Palette.SignBoard,
		Enum.Material.SmoothPlastic
	)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "VacantGui"
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board

	-- A house icon over the words: the sign reads as "an empty base" at a
	-- distance where the text is still too small to make out.
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0.04)
	icon.Size = UDim2.fromScale(0.36, 0.36)
	icon.Image = Config.Icons.House
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = gui

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0.05, 0.43)
	title.Size = UDim2.fromScale(0.9, 0.27)
	title.Font = Enum.Font.FredokaOne
	title.Text = "PLOT"
	title.TextScaled = true
	title.TextColor3 = WHITE
	title.TextStrokeTransparency = 0.4
	title.TextStrokeColor3 = BLACK
	title.Parent = gui

	local subtitle = title:Clone()
	subtitle.Position = UDim2.fromScale(0.05, 0.7)
	subtitle.Size = UDim2.fromScale(0.9, 0.24)
	subtitle.Text = "AVAILABLE"
	subtitle.TextColor3 = (Palette :: any).Ink or WHITE
	subtitle.Parent = gui
end

-- Builds a base. Pass a Player for a claimed plot, or nil for an unclaimed one:
-- a vacant plot gets the same building (so the street line never has a gap) but
-- no owner avatar, no floating house marker and a "PLOT AVAILABLE" sign.
-- `floors` says how many storeys sit above and below the ground floor; nil
-- means a plain ground-floor base. Floors are bought, so this is per base.
function BaseBuilder.Build(player: Player?, model: Model, baseCFrame: CFrame, floors: { above: number, below: number }?): BaseShell
	local who = player and player.Name or "vacant plot"
	computeFloorTops(floors and floors.above or 0, floors and floors.below or 0)
	buildShell(model, baseCFrame)
	local spawnPoint = buildSpawnPoint(model, baseCFrame)

	local ok, err = pcall(buildWindows, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] windows failed for %s: %s"):format(who, tostring(err)))
	end
	ok, err = pcall(buildCeilingLights, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] ceiling lights failed for %s: %s"):format(who, tostring(err)))
	end

	if player ~= nil then
		ok, err = pcall(buildHouseMarker, model, baseCFrame)
		if not ok then
			warn(("[BaseBuilder] house marker failed for %s: %s"):format(who, tostring(err)))
		end
		ok, err = pcall(buildOwnerSign, model, baseCFrame, player)
		if not ok then
			warn(("[BaseBuilder] owner sign failed for %s: %s"):format(who, tostring(err)))
		end
	else
		ok, err = pcall(buildVacantSign, model, baseCFrame)
		if not ok then
			warn(("[BaseBuilder] vacant sign failed: %s"):format(tostring(err)))
		end
	end

	return {
		spawnPoint = spawnPoint,
		floorTop = FLOOR_TOPS[GROUND_INDEX],
		floorTops = table.clone(FLOOR_TOPS),
		groundIndex = GROUND_INDEX,
	}
end

-- ------------------------------------------------------- hand-edited shells --

-- Said once, not once per plot: eight identical warnings is noise.
local footprintWarned = false
local layoutWarned = false

-- Bumped whenever the generated interior changes shape enough that a saved
-- shell would bring the OLD geometry back (slot furniture is reused by name,
-- so stale furniture means stale positions). Version 2 is the ladder-and-
-- wall-lines layout that replaced the staircase.
local SHELL_LAYOUT_VERSION = 2

-- Attributes stamped on a saved shell by tools/build_plots_in_studio.luau.
-- The storey heights are NOT stored: they are a pure function of the floor
-- counts, so recomputing them keeps one source of truth and cannot drift.
BaseBuilder.ShellAttributes = {
	SpotIndex = "ShellSpotIndex",
	FloorsAbove = "ShellFloorsAbove",
	FloorsBelow = "ShellFloorsBelow",
	-- The footprint the shell was BUILT at. Config.Plot.BaseSize is tuning, so
	-- it can change under a place that already has shells saved in it — and a
	-- shell cut for the old size adopted into the new layout is a wrong-sized
	-- room with the slot grid hanging out through its walls. Stamping the size
	-- lets Adopt refuse it and say why, instead of building something broken.
	FootprintX = "ShellFootprintX",
	FootprintY = "ShellFootprintY",
	-- Which interior layout the shell was cut for (see SHELL_LAYOUT_VERSION).
	LayoutVersion = "ShellLayoutVersion",
}

-- Stamps a freshly built shell so it can be recognised and reused after being
-- saved into the place and edited by hand.
function BaseBuilder.TagShell(model: Model, spotIndex: number, floors: { above: number, below: number }?)
	local attrs = BaseBuilder.ShellAttributes
	model:SetAttribute(attrs.SpotIndex, spotIndex)
	model:SetAttribute(attrs.FloorsAbove, floors and floors.above or 0)
	model:SetAttribute(attrs.FloorsBelow, floors and floors.below or 0)
	model:SetAttribute(attrs.FootprintX, FOOTPRINT.X)
	model:SetAttribute(attrs.FootprintY, FOOTPRINT.Y)
	model:SetAttribute(attrs.LayoutVersion, SHELL_LAYOUT_VERSION)
end

-- Reads a saved shell back into the same BaseShell the generator returns, so
-- PlotService can lay its gameplay furniture onto a building it did not build.
--
-- Returns nil when the model cannot stand in for a generated shell — no spawn
-- point, or it was saved at a different storey count. A shell's walls, stairs
-- and floor slabs are all cut for the floors it had, so one saved with a
-- basement cannot be reused by an owner who has not bought one.
function BaseBuilder.Adopt(model: Model, floors: { above: number, below: number }?): BaseShell?
	local attrs = BaseBuilder.ShellAttributes
	local wantAbove = floors and floors.above or 0
	local wantBelow = floors and floors.below or 0
	local savedAbove = tonumber(model:GetAttribute(attrs.FloorsAbove)) or 0
	local savedBelow = tonumber(model:GetAttribute(attrs.FloorsBelow)) or 0
	if savedAbove ~= wantAbove or savedBelow ~= wantBelow then
		return nil
	end

	-- A shell cut for an older interior would resurrect it: stairs where the
	-- ladder belongs, slot furniture reused by name at the old positions. Only
	-- a shell saved under the current layout may stand in for the generator.
	local savedLayout = tonumber(model:GetAttribute(attrs.LayoutVersion)) or 1
	if savedLayout ~= SHELL_LAYOUT_VERSION then
		if not layoutWarned then
			layoutWarned = true
			warn(
				"[BaseBuilder] the saved plot shells predate the ladder-and-wall-lines layout, so they were ignored and the bases generated instead. Re-run tools/build_plots_in_studio.luau to re-save them."
			)
		end
		return nil
	end

	-- A shell cut for a different footprint cannot stand in for this one: the
	-- walls would be in the wrong place and the slot grid would spill through
	-- them. Refuse loudly rather than build a broken room. Re-running
	-- tools/build_plots_in_studio.luau re-cuts the shells at the current size.
	local savedX = tonumber(model:GetAttribute(attrs.FootprintX))
	local savedY = tonumber(model:GetAttribute(attrs.FootprintY))
	if savedX == nil or savedY == nil then
		-- Saved before the stamp existed, so MEASURE it: buildShell always cuts
		-- the ground "Floor" to exactly the footprint. Trusting a missing stamp
		-- is what let a 56x42 shell get adopted into a 56x58 layout — the guard
		-- read nil, skipped itself, and built the old cramped room.
		local savedFloor = model:FindFirstChild("Floor")
		if savedFloor ~= nil and savedFloor:IsA("BasePart") then
			savedX = savedFloor.Size.X
			savedY = savedFloor.Size.Z
		end
	end
	if savedX == nil or savedY == nil then
		return nil -- cannot prove it fits; generate rather than guess
	end
	if math.abs(savedX - FOOTPRINT.X) > 0.01 or math.abs(savedY - FOOTPRINT.Y) > 0.01 then
		if not footprintWarned then
			footprintWarned = true
			warn(
				("[BaseBuilder] the saved plot shells are %.0f x %.0f but Config.Plot.BaseSize is now %.0f x %.0f, so they were ignored and the bases generated instead. Re-run tools/build_plots_in_studio.luau to re-cut them at the new size."):format(
					savedX,
					savedY,
					FOOTPRINT.X,
					FOOTPRINT.Y
				)
			)
		end
		return nil
	end

	local spawnPoint = model:FindFirstChild("SpawnPoint", true)
	if spawnPoint == nil or not spawnPoint:IsA("BasePart") then
		return nil
	end

	computeFloorTops(wantAbove, wantBelow)
	return {
		spawnPoint = spawnPoint,
		floorTop = FLOOR_TOPS[GROUND_INDEX],
		floorTops = table.clone(FLOOR_TOPS),
		groundIndex = GROUND_INDEX,
	}
end

-- Swaps an adopted shell's dressing over to a claimed base.
--
-- Shells are saved with no owner, so they wear the vacant sign and have no
-- house marker — Build decides that at the end from whether a player was
-- passed. An adopted shell needs the same decision applied afterwards: the
-- vacant sign comes off, the floating house marker and the owner's name board
-- go on. Called only for claimed plots; a vacant one is already correct.
function BaseBuilder.DressForOwner(model: Model, baseCFrame: CFrame, player: Player, floors: { above: number, below: number }?)
	computeFloorTops(floors and floors.above or 0, floors and floors.below or 0)

	-- buildVacantSign leaves SignPost + SignBoard; buildOwnerSign rebuilds its
	-- own SignPost, so both of the vacant pieces go.
	for _, name in { "SignPost", "SignBoard" } do
		local existing = model:FindFirstChild(name)
		if existing ~= nil then
			existing:Destroy()
		end
	end

	local ok, err = pcall(buildHouseMarker, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] house marker failed for %s: %s"):format(player.Name, tostring(err)))
	end
	ok, err = pcall(buildOwnerSign, model, baseCFrame, player)
	if not ok then
		warn(("[BaseBuilder] owner sign failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

return BaseBuilder
