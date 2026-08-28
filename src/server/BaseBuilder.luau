--!strict
-- BaseBuilder: builds ONE player's base building — the enclosed room that
-- PlotService then fills with slot platforms, collect/unlock pads and the
-- deposit pad. Matched to the reference screenshots (see the "Map Design
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
	floorTop: number,
}

local Palette = Config.Palette :: any

-- ------------------------------------------------------------ dimensions --
-- Every number here is derived from Config; nothing structural is invented.

local FOOTPRINT = Config.Plot.BaseSize :: Vector2
local HALF_WIDTH = FOOTPRINT.X / 2
local HALF_DEPTH = FOOTPRINT.Y / 2

local FLOOR_TOP = Config.Base.FloorTop :: number
local WALL_H = Config.Base.WallHeight :: number
local WALL_T = Config.Base.WallThickness :: number
local TRIM_H = Config.Base.TrimHeight :: number
local ROOF_T = Config.Base.RoofThickness :: number
local WINDOW_W = Config.Base.WindowWidth :: number
local WINDOW_H = Config.Base.WindowHeight :: number
local WINDOW_SILL = Config.Base.WindowSill :: number
local LIGHT_COUNT = Config.Base.CeilingLights :: number

local WALL_TOP = FLOOR_TOP + WALL_H
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
local HOUSE_BODY = Vector3.new(7, 5.2, 7)
local HOUSE_ROOF_HEIGHT = 3.8
local HOUSE_ROOF_OVERHANG = 1.1
local BOB_HEIGHT = 0.8
local BOB_SPEED = 1.7
local SPIN_SPEED = 0.6
local HOUSE_STEP = 1 / 30

-- Colours the palette does not carry (glass, house trimmings, lamp warmth).
local PANE_COLOR = Color3.fromRGB(24, 28, 36)
local HOUSE_WINDOW_COLOR = Color3.fromRGB(96, 178, 240)
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

local function newWedge(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Name = name
	wedge.Size = size
	wedge.CFrame = cf
	wedge.Color = color
	wedge.Material = Enum.Material.SmoothPlastic
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanTouch = false
	wedge.Parent = parent
	return wedge
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
local function buildShell(model: Model, baseCFrame: CFrame)
	newPart(
		model,
		"Floor",
		Vector3.new(FOOTPRINT.X, FLOOR_TOP, FOOTPRINT.Y),
		baseCFrame * CFrame.new(0, FLOOR_TOP / 2, 0),
		Palette.BaseFloor,
		Enum.Material.SmoothPlastic
	)

	local backZ = HALF_DEPTH - WALL_T / 2
	newPart(
		model,
		"BackWall",
		Vector3.new(FOOTPRINT.X, WALL_H, WALL_T),
		baseCFrame * CFrame.new(0, FLOOR_TOP + WALL_H / 2, backZ),
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

	for _, side in { -1, 1 } do
		local wallX = side * (HALF_WIDTH - WALL_T / 2)
		local label = side < 0 and "Left" or "Right"
		newPart(
			model,
			label .. "Wall",
			Vector3.new(WALL_T, WALL_H, SIDE_DEPTH),
			baseCFrame * CFrame.new(wallX, FLOOR_TOP + WALL_H / 2, SIDE_Z),
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
			Vector3.new(PILLAR_SIZE, WALL_H, PILLAR_SIZE),
			baseCFrame * CFrame.new(
				side * (HALF_WIDTH - PILLAR_SIZE / 2 + PILLAR_PROUD),
				FLOOR_TOP + WALL_H / 2,
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
			FLOOR_TOP + panelHeight / 2,
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
end

-- ----------------------------------------------------------------- windows --

-- A white frame standing proud of the inner wall face around a dark pane that
-- passes through the wall, so the opening reads from both sides.
local function buildWindow(model: Model, baseCFrame: CFrame, side: number, localZ: number, label: string)
	local innerX = side * (HALF_WIDTH - WALL_T)
	local frameX = innerX - side * (FRAME_PROUD / 2)
	local centerY = FLOOR_TOP + WINDOW_SILL + WINDOW_H / 2

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

local function buildWindows(model: Model, baseCFrame: CFrame)
	local offset = HALF_DEPTH * WINDOW_Z_FRACTION
	for _, side in { -1, 1 } do
		local sideLabel = side < 0 and "Left" or "Right"
		for index, localZ in { -offset, offset } do
			buildWindow(model, baseCFrame, side, localZ, ("%sWindow%d"):format(sideLabel, index))
		end
	end
end

-- ---------------------------------------------------------- ceiling lights --

-- Neon panels recessed into the roof's underside, evenly spaced across the
-- width, each carrying a warm PointLight. This is what makes the interior read
-- bright against the night sky.
local function buildCeilingLights(model: Model, baseCFrame: CFrame)
	if LIGHT_COUNT < 1 then
		return
	end
	local step = FOOTPRINT.X / LIGHT_COUNT
	for index = 1, LIGHT_COUNT do
		local localX = (index - (LIGHT_COUNT + 1) / 2) * step
		local panel = newProp(
			model,
			"CeilingLight" .. tostring(index),
			Vector3.new(LIGHT_PANEL_SIZE, LIGHT_PANEL_THICKNESS, LIGHT_PANEL_SIZE),
			baseCFrame * CFrame.new(localX, WALL_TOP - LIGHT_PANEL_THICKNESS / 2, 0),
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

-- ------------------------------------------------------------ house marker --

-- Stylised house floating over the roof: orange body, red pitched roof from two
-- wedges, a white door and a small blue window. Registered with the shared
-- animation loop rather than spinning up a loop of its own.
local function buildHouseMarker(model: Model, baseCFrame: CFrame)
	local house = Instance.new("Model")
	house.Name = "HouseMarker"

	local body = newProp(house, "Body", HOUSE_BODY, CFrame.new(), Palette.HouseBody, Enum.Material.SmoothPlastic)
	house.PrimaryPart = body

	-- A WedgePart's tall face is its BACK (+Z) and it slopes down toward the
	-- front, so the front half sits unrotated and the back half is spun 180
	-- degrees: both tall faces meet at the ridge.
	local roofWidth = HOUSE_BODY.X + HOUSE_ROOF_OVERHANG
	local roofDepth = HOUSE_BODY.Z + HOUSE_ROOF_OVERHANG
	local roofY = HOUSE_BODY.Y / 2 + HOUSE_ROOF_HEIGHT / 2
	newWedge(
		house,
		"RoofFront",
		Vector3.new(roofWidth, HOUSE_ROOF_HEIGHT, roofDepth / 2),
		CFrame.new(0, roofY, -roofDepth / 4),
		Palette.HouseRoof
	)
	newWedge(
		house,
		"RoofBack",
		Vector3.new(roofWidth, HOUSE_ROOF_HEIGHT, roofDepth / 2),
		CFrame.new(0, roofY, roofDepth / 4) * CFrame.Angles(0, math.pi, 0),
		Palette.HouseRoof
	)

	local faceZ = -(HOUSE_BODY.Z / 2 + 0.1)
	newProp(
		house,
		"Door",
		Vector3.new(1.2, 1.8, 0.2),
		CFrame.new(-0.8, -HOUSE_BODY.Y / 2 + 0.9, faceZ),
		Palette.BaseTrim,
		Enum.Material.SmoothPlastic
	)
	newProp(
		house,
		"Window",
		Vector3.new(1, 1, 0.2),
		CFrame.new(1, 0.6, faceZ),
		HOUSE_WINDOW_COLOR,
		Enum.Material.SmoothPlastic
	)

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
		baseCFrame * CFrame.new(localX, FLOOR_TOP + SIGN_POST_HEIGHT / 2, localZ) * facing,
		Palette.BaseRoof,
		Enum.Material.SmoothPlastic
	)
	local board = newProp(
		model,
		"OwnerSign",
		SIGN_BOARD_SIZE,
		baseCFrame
			* CFrame.new(localX, FLOOR_TOP + SIGN_POST_HEIGHT + SIGN_BOARD_SIZE.Y / 2, localZ)
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
		baseCFrame * CFrame.new(0, FLOOR_TOP + SPAWN_MARKER_HEIGHT / 2, -(HALF_DEPTH - SPAWN_INSET)),
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
function BaseBuilder.Build(player: Player, model: Model, baseCFrame: CFrame): BaseShell
	buildShell(model, baseCFrame)
	local spawnPoint = buildSpawnPoint(model, baseCFrame)

	local ok, err = pcall(buildWindows, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] windows failed for %s: %s"):format(player.Name, tostring(err)))
	end
	ok, err = pcall(buildCeilingLights, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] ceiling lights failed for %s: %s"):format(player.Name, tostring(err)))
	end
	ok, err = pcall(buildHouseMarker, model, baseCFrame)
	if not ok then
		warn(("[BaseBuilder] house marker failed for %s: %s"):format(player.Name, tostring(err)))
	end
	ok, err = pcall(buildOwnerSign, model, baseCFrame, player)
	if not ok then
		warn(("[BaseBuilder] owner sign failed for %s: %s"):format(player.Name, tostring(err)))
	end

	return {
		spawnPoint = spawnPoint,
		floorTop = FLOOR_TOP,
	}
end

return BaseBuilder
