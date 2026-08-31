--!strict
-- ============================================================
--  SQUISHY MODELS — the shared squishy model shop.
--
--  Ported from Squishy Clicker's client Models.luau so this game
--  renders the REAL squishy roster: the same primitive shape
--  builders, the same imported-mesh template path (clone,
--  reassemble, normalise, tint) and the same sparkle treatment.
--
--  SquishyModels.build(spec) -> (Model, height)
--    spec.shape   : catalog shape key ("dumplingmesh", "cubeorange",
--                   "tub", ...). nil or unknown -> primitive dumpling.
--    spec.color   : body / tint colour.
--    spec.sparkle : glittery? (sparkle emitter; gold aura when golden)
--    spec.scale   : display size multiplier, default 1.
--
--  The Model's PrimaryPart is an INVISIBLE anchored box named
--  "Body", sized snugly to the visual's bounding box; `height` is
--  Body.Size.Y. Every visual part is welded to Body with a
--  WeldConstraint, unanchored, massless and non-colliding, so the
--  caller can pivot the whole squishy by the Body — or unanchor
--  Body and weld it to a carrier. The Model comes back unparented.
--
--  Size normalisation: every squishy is scaled so its largest
--  HORIZONTAL extent lands at 3.2 studs at scale 1, however big
--  its mesh imported — then spec.scale multiplies on top. That is
--  what keeps a field of mixed shapes reading as one species.
--
--  Mesh templates are parked under ReplicatedStorage.SquishyMeshes
--  (imported once in Studio — Rojo cannot sync .fbx). A template
--  may be a lone MeshPart OR a Model wrapper that Import 3D split
--  into several MeshParts; every piece is gathered and reassembled
--  preserving its relative offset. A missing template falls back
--  to that shape's primitive builder and explains itself ONCE in
--  the Output — a mesh that silently falls back is exactly the bug
--  that wastes an afternoon.
--
--  Requirable from BOTH server and client: nothing here touches a
--  client- or server-only service, and nothing yields.
-- ============================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Config carries the variant table (Gold, Rainbow). It requires nothing, so
-- there is no cycle.
local Config = require(script.Parent:WaitForChild("Config"))

local SquishyModels = {}

export type BuildSpec = {
	shape: string?,
	color: Color3,
	sparkle: boolean?,
	scale: number?,
	-- Variant name from Config.Variants ("Gold", "Rainbow"); nil = Normal.
	variant: string?,
	-- Tint the mesh even when its shape isn't a tinting one. The giant enemies
	-- use this so they never wear a collectable's stock texture.
	forceTint: boolean?,
}

-- Largest horizontal extent of every squishy at scale 1, in studs.
local BASE_FOOTPRINT = 3.2
-- Where the imported mesh templates live.
local MESH_FOLDER_NAME = "SquishyMeshes"
-- Parts refuse sizes below 0.05 on any axis.
local MIN_AXIS = 0.05

-- Cylinder parts run along their own X axis; this stands one upright.
local UPRIGHT = CFrame.fromEulerAnglesXYZ(0, 0, math.pi / 2)

local FACE_INK = Color3.fromRGB(74, 52, 38)
local LEAF_GREEN = Color3.fromRGB(96, 176, 88)
local TIP_BROWN = Color3.fromRGB(122, 86, 48)
local TUB_CREAM = Color3.fromRGB(246, 240, 230)

-- ---------- rig plumbing ----------
-- Roblox parts have no transform hierarchy, so each model is built as a
-- RIG: a list of pieces plus the offset each sits at relative to the
-- model's origin. Nothing is positioned, scaled, welded or parented until
-- the one finalise step at the end — which is what lets every builder,
-- primitive and mesh alike, share the same normalisation and Body.

type Piece = { inst: BasePart, offset: CFrame }
type Rig = { pieces: { Piece } }

local function addPiece(rig: Rig, inst: BasePart, offset: CFrame)
	table.insert(rig.pieces, { inst = inst, offset = offset })
end

local function newPart(shape: Enum.PartType, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- ---------- primitive shape builders ----------
-- Each builder fills the rig with parts already tinted in the squishy's
-- colour and returns the PRIMARY part — the one the face and sparkles
-- ride on. Origins sit at the model's centre; exact overall size doesn't
-- matter because finalise normalises the footprint afterwards.

local function ball(rig: Rig, size: Vector3, color: Color3, offset: CFrame, material: Enum.Material?): Part
	local part = newPart(Enum.PartType.Ball, size, color, material or Enum.Material.SmoothPlastic)
	addPiece(rig, part, offset)
	return part
end

local function box(rig: Rig, size: Vector3, color: Color3, offset: CFrame, material: Enum.Material?): Part
	local part = newPart(Enum.PartType.Block, size, color, material or Enum.Material.SmoothPlastic)
	addPiece(rig, part, offset)
	return part
end

local shapeBuilders: { [string]: (Rig, Color3) -> BasePart } = {}

shapeBuilders.dumpling = function(rig, color)
	local body = ball(rig, Vector3.new(2.5, 2.0, 2.5), color, CFrame.new(0, 0, 0))
	local pleatColor = color:Lerp(Color3.new(1, 1, 1), 0.24)
	for i = 1, 5 do
		local t = (i - 3) / 2 -- -1 .. 1
		ball(
			rig,
			Vector3.new(0.66, 0.54, 0.66),
			pleatColor,
			CFrame.new(t * 0.9, 0.78 - math.abs(t) * 0.14, 0.3 - math.abs(t) * 0.12)
		)
	end
	return body
end

shapeBuilders.ball = function(rig, color)
	return ball(rig, Vector3.new(2.4, 2.15, 2.4), color, CFrame.new(0, 0, 0), Enum.Material.Glass)
end

-- Jelly cubes are translucent so they read as jelly, not dice.
shapeBuilders.jellycube = function(rig, color)
	local body = box(rig, Vector3.new(2.1, 2.1, 2.1), color, CFrame.new(0, 0, 0), Enum.Material.Glass)
	body.Transparency = 0.3
	return body
end

shapeBuilders.cheese = function(rig, color)
	local body = box(rig, Vector3.new(2.3, 1.7, 2.3), color, CFrame.new(0, 0, 0))
	local holeColor = color:Lerp(Color3.fromRGB(90, 60, 15), 0.4)
	-- Half-sunk darker balls fake the holes.
	ball(rig, Vector3.new(0.7, 0.7, 0.7), holeColor, CFrame.new(-0.6, 0.55, 0.85))
	ball(rig, Vector3.new(0.5, 0.5, 0.5), holeColor, CFrame.new(0.7, -0.2, 0.95))
	ball(rig, Vector3.new(0.6, 0.6, 0.6), holeColor, CFrame.new(0.15, 0.86, -0.2))
	ball(rig, Vector3.new(0.55, 0.55, 0.55), holeColor, CFrame.new(-1.0, -0.35, 0.2))
	return body
end

shapeBuilders.banana = function(rig, color)
	-- Balls along a downward arc make the curve; shrinking ends taper it.
	local body: Part? = nil
	for i = 1, 7 do
		local t = (i - 4) / 3 -- -1 .. 1
		local diameter = 0.95 - math.abs(t) * 0.35
		local segment = ball(
			rig,
			Vector3.new(diameter, diameter, diameter),
			color,
			CFrame.new(t * 1.35, 0.35 - t * t * 0.95, 0)
		)
		if i == 4 then
			body = segment
		end
	end
	ball(rig, Vector3.new(0.4, 0.4, 0.4), TIP_BROWN, CFrame.new(-1.5, -0.68, 0))
	ball(rig, Vector3.new(0.4, 0.4, 0.4), TIP_BROWN, CFrame.new(1.5, -0.68, 0))
	return body :: Part
end

shapeBuilders.strawberry = function(rig, color)
	local body = ball(rig, Vector3.new(2.3, 2.5, 2.3), color, CFrame.new(0, -0.1, 0))
	-- Leaf crown: flattened green balls around a stubby stem.
	for i = 1, 5 do
		local angle = (i / 5) * math.pi * 2
		ball(
			rig,
			Vector3.new(0.8, 0.28, 0.5),
			LEAF_GREEN,
			CFrame.new(math.cos(angle) * 0.55, 1.05, math.sin(angle) * 0.55)
		)
	end
	local stem = newPart(Enum.PartType.Cylinder, Vector3.new(0.5, 0.25, 0.25), LEAF_GREEN, Enum.Material.SmoothPlastic)
	addPiece(rig, stem, CFrame.new(0, 1.3, 0) * UPRIGHT)
	return body
end

shapeBuilders.brain = function(rig, color)
	-- Two lumpy hemispheres with a groove between them.
	local body: Part? = nil
	for side = -1, 1, 2 do
		for i = 1, 3 do
			local t = (i - 2) / 1 -- -1, 0, 1
			local lump = ball(
				rig,
				Vector3.new(1.35 - math.abs(t) * 0.3, 1.15 - math.abs(t) * 0.25, 1.35 - math.abs(t) * 0.3),
				color,
				CFrame.new(t * 0.85, 0.15 - t * t * 0.18, side * 0.5)
			)
			if side == 1 and i == 2 then
				body = lump
			end
		end
	end
	-- Brain stem / base
	ball(rig, Vector3.new(2.2, 0.9, 1.8), color:Lerp(Color3.new(0, 0, 0), 0.12), CFrame.new(0, -0.5, 0))
	return body :: Part
end

shapeBuilders.blobfish = function(rig, color)
	local body = ball(rig, Vector3.new(2.6, 1.8, 2.3), color, CFrame.new(0, 0, 0), Enum.Material.Glass)
	body.Transparency = 0.2
	-- The famous droopy nose, hanging off the front.
	local nose = ball(rig, Vector3.new(0.62, 0.78, 0.62), color:Lerp(Color3.new(1, 1, 1), 0.15), CFrame.new(0, -0.18, 1.1))
	nose.Material = Enum.Material.Glass
	nose.Transparency = 0.2
	-- Little side fins.
	for side = -1, 1, 2 do
		local fin = ball(rig, Vector3.new(0.3, 0.55, 0.75), color, CFrame.new(side * 1.3, -0.1, -0.3))
		fin.Material = Enum.Material.Glass
		fin.Transparency = 0.35
	end
	return body
end

shapeBuilders.butter = function(rig, color)
	local body = box(rig, Vector3.new(2.7, 1.15, 1.35), color, CFrame.new(0, 0, 0))
	-- Slightly lighter top face, like the printed wrapper edge.
	box(rig, Vector3.new(2.5, 0.22, 1.2), color:Lerp(Color3.new(1, 1, 1), 0.3), CFrame.new(0, 0.62, 0))
	return body
end

shapeBuilders.cloud = function(rig, color)
	local body = ball(rig, Vector3.new(1.9, 1.5, 1.6), color, CFrame.new(0, 0.1, 0))
	ball(rig, Vector3.new(1.3, 1.1, 1.3), color, CFrame.new(-1.0, -0.1, 0))
	ball(rig, Vector3.new(1.3, 1.1, 1.3), color, CFrame.new(1.0, -0.1, 0))
	ball(rig, Vector3.new(1.1, 0.95, 1.1), color, CFrame.new(-0.45, 0.6, 0))
	ball(rig, Vector3.new(1.0, 0.85, 1.0), color, CFrame.new(0.5, 0.55, 0))
	box(rig, Vector3.new(2.8, 0.5, 1.4), color, CFrame.new(0, -0.5, 0))
	return body
end

shapeBuilders.baby = function(rig, color)
	-- The translucent glitter baby: a head, a body, stubby arms and legs.
	local head = ball(rig, Vector3.new(1.5, 1.4, 1.4), color, CFrame.new(0, 0.75, 0), Enum.Material.Glass)
	head.Transparency = 0.25
	local torso = ball(rig, Vector3.new(1.7, 1.8, 1.4), color, CFrame.new(0, -0.55, 0), Enum.Material.Glass)
	torso.Transparency = 0.25
	for side = -1, 1, 2 do
		local arm = ball(rig, Vector3.new(0.5, 0.9, 0.5), color, CFrame.new(side * 0.95, -0.15, 0), Enum.Material.Glass)
		arm.Transparency = 0.25
		local leg = ball(rig, Vector3.new(0.55, 0.95, 0.55), color, CFrame.new(side * 0.45, -1.35, 0), Enum.Material.Glass)
		leg.Transparency = 0.25
	end
	return head
end

shapeBuilders.drop = function(rig, color)
	-- A teardrop: a big base ball with shrinking balls stacked into the point.
	-- Neon, because these are the glow-in-the-dark ones.
	local body = ball(rig, Vector3.new(2.0, 1.9, 2.0), color, CFrame.new(0, -0.35, 0), Enum.Material.Neon)
	ball(rig, Vector3.new(1.3, 1.2, 1.3), color, CFrame.new(0, 0.5, 0), Enum.Material.Neon)
	ball(rig, Vector3.new(0.75, 0.8, 0.75), color, CFrame.new(0, 1.1, 0), Enum.Material.Neon)
	ball(rig, Vector3.new(0.4, 0.55, 0.4), color, CFrame.new(0, 1.55, 0), Enum.Material.Neon)
	return body
end

shapeBuilders.donut = function(rig, color)
	-- A ring of balls standing face-on.
	local body: Part? = nil
	local count = 10
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local segment = ball(
			rig,
			Vector3.new(1.0, 1.0, 0.9),
			color,
			CFrame.new(math.cos(angle) * 1.0, math.sin(angle) * 1.0, 0),
			Enum.Material.Neon
		)
		if i == 1 then
			body = segment
		end
	end
	return body :: Part
end

shapeBuilders.tub = function(rig, color)
	-- The boxed cake / ice-cream tub: a cream container with a scoop on top.
	local container = newPart(Enum.PartType.Cylinder, Vector3.new(1.3, 2.3, 2.3), TUB_CREAM, Enum.Material.SmoothPlastic)
	addPiece(rig, container, CFrame.new(0, -0.55, 0) * UPRIGHT)
	local rim = newPart(Enum.PartType.Cylinder, Vector3.new(0.25, 2.45, 2.45), TUB_CREAM, Enum.Material.SmoothPlastic)
	addPiece(rig, rim, CFrame.new(0, 0.15, 0) * UPRIGHT)
	local scoop = ball(rig, Vector3.new(1.9, 1.7, 1.9), color, CFrame.new(0, 0.75, 0))
	return scoop
end

-- ---------- imported mesh squishies ----------
-- Real 3D models can't be synced by Rojo: they are imported once in Studio
-- and parked as templates under ReplicatedStorage.SquishyMeshes. Shapes
-- listed here use that template when it exists and quietly fall back to
-- their primitive builder when it doesn't, so the game never breaks in a
-- place without the imports.
export type MeshConfig = {
	template: string,
	-- Spins the imported model about Y so its face points forward (-Z-ish).
	-- Importers disagree about which way is "front", so this is per-model.
	-- Keep it to 90° steps.
	yaw: number,
	-- Tips the model forward about X, in degrees. 90° stands a flat-lying
	-- model up on its edge.
	pitch: number?,
	-- Repaint the mesh in the squishy's colour (SurfaceAppearance.Color
	-- multiplies the texture — one pale pearly mould, thirteen dumplings).
	tint: boolean?,
	-- Shifts the model relative to where it is placed, in studs. Mostly
	-- moot here because the Body is recentred on the visual bounding box,
	-- but ported so tuned values from the clicker keep meaning something.
	offset: Vector3?,
	-- True when the texture already paints a face on: the billboard face
	-- stays off for these, or the squishy ends up with two.
	bakedFace: boolean?,
	-- Groups genuinely interchangeable models (the cube colours). When
	-- `template` isn't in the place, a sibling from the same family stands
	-- in and gets tinted. Only configs sharing this exact family may lend
	-- to each other — never borrowed just for having a similar name.
	family: string?,
	-- Primitive builder to use when no mesh at all is available, so a
	-- missing banana falls back to the banana rather than to a dumpling.
	fallback: string?,
}

local MESH_SHAPES: { [string]: MeshConfig } = {
	-- The Mythical keeps the opal texture exactly as imported.
	opalmesh = { template = "OpalDumpling", yaw = 180, bakedFace = true, fallback = "dumpling" },
	-- Every other dumpling: same mesh, tinted.
	dumplingmesh = { template = "OpalDumpling", yaw = 180, tint = true, bakedFace = true, fallback = "dumpling" },
	-- No bakedFace on these, and they aren't dumplings, so they wear no
	-- face at all — real bananas and butter sticks don't have one.
	bananamesh = { template = "BananaSquishy", yaw = 180, fallback = "banana" },
	buttermesh = { template = "ButterSquishy", yaw = 180, fallback = "butter" },
	-- Rainbow Butter has its own tie-dye model, so it needs no tinting.
	-- Its wrapper text sits on the top face, so it gets stood upright.
	rainbuttermesh = { template = "RainbowButter", yaw = 0, pitch = 90, fallback = "butter" },
	glowdonutmesh = { template = "GlowDonut", yaw = 0, fallback = "donut" },
	cheesemesh = { template = "SquishCheese", yaw = 0, fallback = "cheese" },
	coconutmesh = { template = "CoconutBall", yaw = 0, fallback = "ball" },
	-- Imported facing away — flipped so the face points forward.
	babymesh = { template = "GlitterBaby", yaw = 180, fallback = "baby" },
	dropmesh = { template = "SparkleDrop", yaw = 0, fallback = "drop" },
	brainmesh = { template = "SquishyBrain", yaw = 0, fallback = "brain" },
	blobfishmesh = { template = "BlobfishSquishy", yaw = 0, fallback = "blobfish" },
	cloudmesh = { template = "DoughCloud", yaw = 180, fallback = "cloud" },
	strawberrymesh = { template = "StrawberrySquishy", yaw = 0, fallback = "strawberry" },
	-- No pug among the primitives, so a plain ball stands in if the model
	-- isn't in the place. Imported facing away — flipped.
	pugmesh = { template = "PugSquishy", yaw = 180, fallback = "ball" },
	icecubemesh = { template = "IceCubeSquishy", yaw = 0, fallback = "jellycube" },
	-- The cubes come as one model per colour, named <Colour>CubeSquishy.
	-- Each asks for its own colour and settles for a tinted sibling if that
	-- one hasn't been made yet.
	cubeorange = { template = "OrangeCubeSquishy", family = "CubeSquishy", yaw = 0, fallback = "jellycube" },
	cubepink = { template = "PinkCubeSquishy", family = "CubeSquishy", yaw = 0, fallback = "jellycube" },
	cubeblue = { template = "BlueCubeSquishy", family = "CubeSquishy", yaw = 0, fallback = "jellycube" },
	cubegreen = { template = "GreenCubeSquishy", family = "CubeSquishy", yaw = 0, fallback = "jellycube" },
	cubepurple = { template = "PurpleCubeSquishy", family = "CubeSquishy", yaw = 0, fallback = "jellycube" },
}

-- Said once per template. A mesh that silently falls back to a primitive
-- is exactly the bug that wastes an afternoon, so the Output always
-- explains itself — either which mesh is in use, or precisely what is
-- missing and how to fix it.
local meshReported: { [string]: boolean } = {}

-- Names get typed by hand in Studio, so case, spaces and underscores
-- shouldn't decide whether a model is found: "Squishy Cube" and
-- "squishy_cube" both mean SquishyCube.
local function loosen(name: string): string
	return (name:lower():gsub("[^%a%d]", ""))
end

local function meshFolder(): Instance?
	return ReplicatedStorage:FindFirstChild(MESH_FOLDER_NAME)
end

local function findMeshEntry(templateName: string): Instance?
	local folder = meshFolder()
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(templateName, true)
	if exact then
		return exact
	end
	local wanted = loosen(templateName)
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("MeshPart") or descendant:IsA("Model") then
			if loosen(descendant.Name) == wanted then
				return descendant
			end
		end
	end
	return nil
end

-- A model belonging to the same family, to stand in for a colour nobody
-- has made yet. Only models another config actually claims for that family
-- count: matching on the name alone once let IceCubeSquishy — a squishy in
-- its own right — get borrowed by whichever cube colour happened to be
-- missing.
local function findMeshFamily(family: string): Instance?
	local folder = meshFolder()
	if not folder then
		return nil
	end
	local kin: { [string]: boolean } = {}
	for _, config in MESH_SHAPES do
		if config.family == family then
			kin[loosen(config.template)] = true
		end
	end
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("MeshPart") or descendant:IsA("Model") then
			if kin[loosen(descendant.Name)] then
				return descendant
			end
		end
	end
	return nil
end

-- Import 3D wraps meshes in a Model, and SPLITS anything too dense into
-- several MeshParts. Both are normal, so gather every part and rebuild the
-- whole assembly rather than grabbing one piece and rendering a fragment.
local function collectMeshParts(entry: Instance): { BasePart }
	if entry:IsA("BasePart") then
		return { entry }
	end
	local parts: { BasePart } = {}
	for _, descendant in entry:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function reportMissingMesh(shape: string, templateName: string, entry: Instance?)
	if entry then
		warn(
			("[SquishyModels] '%s' found '%s' [%s] under ReplicatedStorage.%s, but there are no parts inside it — using the primitive shape instead."):format(
				shape,
				templateName,
				entry.ClassName,
				MESH_FOLDER_NAME
			)
		)
		return
	end

	local folder = meshFolder()
	if not folder then
		warn(
			("[SquishyModels] '%s' wants a mesh template named '%s', but ReplicatedStorage has no '%s' folder — using the primitive shape. Fix: STOP the playtest first (anything created while playing is thrown away when you stop), make a Folder named '%s' in ReplicatedStorage, then drag the imported model in and rename it to exactly '%s'. A Model wrapper is fine, including one Studio split into several MeshParts."):format(
				shape,
				templateName,
				MESH_FOLDER_NAME,
				MESH_FOLDER_NAME,
				templateName
			)
		)
		return
	end

	local found: { string } = {}
	for _, child in folder:GetChildren() do
		table.insert(found, ("%s [%s]"):format(child.Name, child.ClassName))
	end
	warn(
		("[SquishyModels] '%s' wants a mesh template named '%s' somewhere under ReplicatedStorage.%s, and nothing there has that name — using the primitive shape. Fix: STOP the playtest first (anything created while playing is thrown away when you stop), then drag the imported model into the folder and rename it to exactly '%s'. A Model wrapper is fine, including one Studio split into several MeshParts. The folder currently holds: %s"):format(
			shape,
			templateName,
			MESH_FOLDER_NAME,
			templateName,
			#found > 0 and table.concat(found, ", ") or "nothing"
		)
	)
end

local tintReported = false

-- SurfaceAppearance.Color multiplies the ColorMap, which is what lets one
-- pearly texture become a whole colour range. MeshPart.Color is set too as
-- a fallback for meshes imported without a SurfaceAppearance.
local function tintMesh(mesh: BasePart, color: Color3)
	mesh.Color = color

	local appearance = mesh:FindFirstChildOfClass("SurfaceAppearance")
	if not appearance then
		return
	end
	local ok = pcall(function()
		(appearance :: any).Color = color
	end)
	if not ok and not tintReported then
		tintReported = true
		warn(
			"[SquishyModels] This Studio build's SurfaceAppearance has no Color property, so tinted dumplings will all wear the opal texture. Fix: update Studio, or delete the SurfaceAppearance from the template to fall back to flat colours."
		)
	end
end

local function tryBuildMesh(rig: Rig, shape: string, config: MeshConfig, color: Color3, forceTint: boolean?): BasePart?
	local templateName = config.template
	local entry = findMeshEntry(templateName)

	-- No model in this exact colour? Borrow a sibling and paint it.
	local borrowed = false
	if not entry and config.family then
		entry = findMeshFamily(config.family)
		borrowed = entry ~= nil
	end

	local parts = if entry then collectMeshParts(entry) else {}
	if #parts == 0 then
		if not meshReported[templateName] then
			meshReported[templateName] = true
			reportMissingMesh(shape, templateName, entry)
		end
		return nil
	end

	-- One bounding box around every piece, so a split model recentres as a
	-- single object instead of each fragment doing its own thing. (Native
	-- size is kept here; the finalise step normalises the whole rig.)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, part in parts do
		local half = part.Size * 0.5
		low = low:Min(part.Position - half)
		high = high:Max(part.Position + half)
	end
	local centre = (low + high) * 0.5

	-- Pitch first in the model's own frame, then yaw about the world's.
	local orient = CFrame.fromEulerAnglesXYZ(0, math.rad(config.yaw), 0)
		* CFrame.fromEulerAnglesXYZ(math.rad(config.pitch or 0), 0, 0)
	-- Applied outside the yaw, so a nudge always shifts the assembled model
	-- the way it is seen regardless of how the model is turned.
	local shift = CFrame.new(config.offset or Vector3.zero)

	-- The face and sparkles ride the biggest piece.
	local primary: BasePart = parts[1]
	local biggest = -1

	for _, part in parts do
		local clone = part:Clone()
		-- A borrowed model is always tinted, whatever the config says: it
		-- is wearing the wrong colour by definition. forceTint does the same
		-- for callers (the giant enemies) that must not wear stock textures.
		if config.tint or borrowed or forceTint then
			tintMesh(clone, color)
		end
		-- Configured orientation first, then whatever rotation the piece
		-- carries, so the assembly turns as a unit and each piece keeps its
		-- own orientation.
		addPiece(rig, clone, shift * orient * CFrame.new(part.Position - centre) * part.CFrame.Rotation)

		local volume = clone.Size.X * clone.Size.Y * clone.Size.Z
		if volume > biggest then
			biggest = volume
			primary = clone
		end
	end

	if not meshReported[templateName] then
		meshReported[templateName] = true
		if borrowed then
			print(
				("[SquishyModels] '%s': no %s in the place, so %q is standing in, tinted. Add one named '%s' to give it its own."):format(
					shape,
					templateName,
					(entry :: Instance).Name,
					templateName
				)
			)
		else
			print(
				("[SquishyModels] Using imported mesh '%s' for '%s' (%d part%s)."):format(
					templateName,
					shape,
					#parts,
					#parts == 1 and "" or "s"
				)
			)
		end
	end
	return primary
end

-- ---------- faces & sparkle ----------

-- Only dumplings have faces. The shop squishies are bananas, butter sticks
-- and jelly cubes — real ones have no features, and a face stuck on the
-- side of a banana reads as a mistake rather than a character.
local FACE_SHAPES: { [string]: boolean } = {
	dumpling = true,
	dumplingmesh = true,
	opalmesh = true,
}

-- A SPARKLE squishy painted in the gold hue band gets the golden aura.
-- Judged by hue so no list has to be maintained; only called for sparkle
-- squishies, which keeps plain yellows like butter and cheese out.
local function isGolden(color: Color3): boolean
	local hue, saturation, value = color:ToHSV()
	return hue > 0.09 and hue < 0.145 and saturation > 0.62 and value > 0.6
end

-- The billboard face rides the primary part so it always turns toward the
-- viewer. `footprint` is the finished model's horizontal size in studs;
-- the gui scales with it so a Giant's face isn't a Mini's.
local function attachFace(primary: BasePart, sparkle: boolean, footprint: number)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Face"
	gui.Adornee = primary
	-- BillboardGui scale components are in studs.
	gui.Size = UDim2.fromScale(footprint * 0.63, footprint * 0.37)
	-- CAMERA-space offset, not world-space: it slides the face toward
	-- whoever is looking, so it always reads as painted on the front of the
	-- body. Must stay a touch beyond the widest model radius or the parts
	-- poke through and swallow the face.
	gui.StudsOffset = Vector3.new(0, footprint * 0.02, footprint * 0.57)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Enabled = true
	gui.Parent = primary

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = sparkle and "✧•ᴗ•✧" or "•ᴗ•"
	label.TextColor3 = FACE_INK
	label.TextScaled = true
	label.Parent = gui
end

-- The sparkle emitter uses only the engine's built-in sparkle sheet — no
-- uploaded asset ids. (The clicker's glitter face-textures used a custom
-- upload, so they stay behind; the emitter carries the glitter feel.)
local function attachSparkles(primary: BasePart, color: Color3)
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "Sparkles"
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Rate = 14
	sparkles.Lifetime = NumberRange.new(0.6, 1.1)
	sparkles.Speed = NumberRange.new(1.5, 3.5)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.LightEmission = 0.9
	sparkles.Acceleration = Vector3.new(0, -4, 0)
	sparkles.Enabled = true

	-- GOLD is treasure everywhere: a sparkle squishy painted in the gold
	-- band runs golden sparkles and a warm glow rides the body.
	if isGolden(color) then
		sparkles.Color = ColorSequence.new(Color3.fromRGB(240, 190, 70))
		sparkles.Rate = 18
		sparkles.LightEmission = 1
		local lamp = Instance.new("PointLight")
		lamp.Name = "GoldLight"
		lamp.Color = Color3.fromRGB(240, 190, 70)
		lamp.Brightness = 1.6
		lamp.Range = 12
		lamp.Parent = primary
	end

	sparkles.Parent = primary
end

-- ---------- finalise ----------
-- One exit for every build path: measure the rig, scale it so the largest
-- horizontal extent hits `footprint`, and wrap it around an invisible
-- anchored Body sized snugly to the result. Every visual part ends up
-- welded to the Body, unanchored, massless and non-colliding.

local function finalize(rig: Rig, footprint: number): (Model, number)
	-- Rig-space bounding box. The rotated-extents maths is exact for boxes
	-- at any rotation (and conservative-enough for balls and cylinders).
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, piece in rig.pieces do
		local rot = piece.offset.Rotation
		local half = piece.inst.Size * 0.5
		local right, up, look = rot.RightVector, rot.UpVector, rot.LookVector
		local reach = Vector3.new(
			math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
			math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
			math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
		)
		local pos = piece.offset.Position
		low = low:Min(pos - reach)
		high = high:Max(pos + reach)
	end
	if low.X == math.huge then
		low, high = Vector3.zero, Vector3.zero
	end

	local centre = (low + high) * 0.5
	local extents = high - low
	local scaleFactor = footprint / math.max(extents.X, extents.Z, MIN_AXIS)

	local model = Instance.new("Model")
	model.Name = "Squishy"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(
		math.max(extents.X * scaleFactor, MIN_AXIS),
		math.max(extents.Y * scaleFactor, MIN_AXIS),
		math.max(extents.Z * scaleFactor, MIN_AXIS)
	)
	body.CFrame = CFrame.new()
	body.Transparency = 1
	body.Anchored = true
	body.CanCollide = false
	body.CanTouch = false
	body.Material = Enum.Material.SmoothPlastic
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model
	model.PrimaryPart = body

	for _, piece in rig.pieces do
		local inst = piece.inst
		local size = inst.Size * scaleFactor
		inst.Size = Vector3.new(math.max(size.X, MIN_AXIS), math.max(size.Y, MIN_AXIS), math.max(size.Z, MIN_AXIS))
		inst.CFrame = CFrame.new((piece.offset.Position - centre) * scaleFactor) * piece.offset.Rotation
		inst.Anchored = false
		inst.Massless = true
		inst.CanCollide = false
		inst.CanTouch = false
		inst.CanQuery = false
		inst.Parent = model

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = inst
		weld.Parent = inst
	end

	return model, body.Size.Y
end

-- ---------- the one public door ----------

-- ---------------------------------------------------------------- variants --
-- A variant repaints a finished rig. Gold goes metallic yellow; Rainbow cycles
-- every visible part's hue together from one shared loop, so a shelf of them
-- pulses in step rather than each running its own timer.

local rainbowParts: { BasePart } = {}
local rainbowLoopStarted = false

local function startRainbowLoop()
	if rainbowLoopStarted then
		return
	end
	rainbowLoopStarted = true
	task.spawn(function()
		while true do
			task.wait(1 / 20)
			local hue = (os.clock() * 0.25) % 1
			local color = Color3.fromHSV(hue, 0.85, 1)
			-- Backwards so removals never skip an entry.
			for i = #rainbowParts, 1, -1 do
				local part = rainbowParts[i]
				if part.Parent == nil then
					table.remove(rainbowParts, i)
				else
					part.Color = color
					-- A part that kept its painted face is tinted through its
					-- SurfaceAppearance, so the cycle has to drive that too or
					-- the face-bearing squishies would sit at one fixed hue.
					local appearance = part:FindFirstChildOfClass("SurfaceAppearance")
					if appearance ~= nil then
						pcall(function()
							(appearance :: any).Color = color
						end)
					end
				end
			end
		end
	end)
end

-- Applies a variant's look to an already-built model. Unknown or "none"
-- variants leave it exactly as it was.

-- Recolours one part for a variant while keeping whatever art is painted on it.
--
-- A SurfaceAppearance's Color MULTIPLIES its ColorMap, so tinting it gold
-- leaves the painted face showing THROUGH the gold rather than erasing it.
-- That is the whole difference between a gold dumpling and a gold blob, and it
-- is why the face is no longer substituted with a billboard overlay.
--
-- A MeshPart's baked TextureID does not respond to Color at all, so for those
-- the texture still has to go before a coat means anything. None of the
-- textured-without-SurfaceAppearance templates carry a face (bananas, butter,
-- cheese are all faceless), so nothing is lost there.
--
-- Returns true when the part kept art that draws its face.
local function paintVariant(part: BasePart, color: Color3): boolean
	local appearance = part:FindFirstChildOfClass("SurfaceAppearance")
	if appearance ~= nil then
		local ok = pcall(function()
			(appearance :: any).Color = color
		end)
		if ok then
			part.Color = color
			return true
		end
		-- A Studio build old enough to have no Color on SurfaceAppearance: the
		-- coat can only show if the appearance goes, face and all.
		appearance:Destroy()
	end
	if part:IsA("MeshPart") then
		(part :: MeshPart).TextureID = ""
	end
	part.Color = color
	return false
end

-- Returns true only when the face art could NOT be kept, so the caller knows to
-- fall back to a billboard face.
local function applyVariant(model: Model, variantName: string?): boolean
	if variantName == nil or variantName == "Normal" then
		return false
	end
	local variant = (Config :: any).VariantByName[variantName]
	if variant == nil or variant.effect == "none" then
		return false
	end

	local visuals: { BasePart } = {}
	for _, descendant in model:GetDescendants() do
		-- The Body is the invisible bounding box; only repaint what is seen.
		if descendant:IsA("BasePart") and descendant.Name ~= "Body" and descendant.Transparency < 1 then
			table.insert(visuals, descendant)
		end
	end

	if variant.effect == "gold" then
		local keptArt = false
		for _, part in visuals do
			if paintVariant(part, variant.color or Color3.fromRGB(255, 206, 74)) then
				keptArt = true
			else
				-- Only a part wearing no surface art gets the metal treatment;
				-- Metal over a SurfaceAppearance washes the painted face out.
				part.Material = Enum.Material.Metal
				part.Reflectance = 0.35
			end
		end
		return not keptArt
	elseif variant.effect == "rainbow" then
		local keptArt = false
		for _, part in visuals do
			if paintVariant(part, Color3.fromHSV(0, 0.85, 1)) then
				keptArt = true
			else
				part.Material = Enum.Material.Neon
			end
			table.insert(rainbowParts, part)
		end
		startRainbowLoop()
		return not keptArt
	end
	return false
end

function SquishyModels.build(spec: BuildSpec): (Model, number)
	local rig: Rig = { pieces = {} }
	local color = spec.color
	local sparkle = spec.sparkle == true
	local footprint = BASE_FOOTPRINT * (spec.scale or 1)

	local shapeKey = spec.shape or "dumpling"
	local primary: BasePart? = nil
	local textureFace = false

	local meshConfig = MESH_SHAPES[spec.shape or ""]
	if meshConfig then
		primary = tryBuildMesh(rig, spec.shape :: string, meshConfig, color, spec.forceTint)
		textureFace = primary ~= nil and meshConfig.bakedFace == true
	end
	if not primary then
		-- Fell back to a primitive, so the effective shape is that one —
		-- and anything unknown lands on the dumpling.
		shapeKey = (if meshConfig then meshConfig.fallback else nil) or spec.shape or "dumpling"
		local builder = shapeBuilders[shapeKey]
		if not builder then
			shapeKey = "dumpling"
			builder = shapeBuilders.dumpling
		end
		primary = builder(rig, color)
	end
	local primaryPart = primary :: BasePart

	if sparkle then
		attachSparkles(primaryPart, color)
	end

	-- A billboard face is only built when there is one to show: a dumpling
	-- whose texture doesn't already paint it on.
	if FACE_SHAPES[shapeKey] == true and not textureFace then
		attachFace(primaryPart, sparkle, footprint)
	end

	local model, height = finalize(rig, footprint)
	local stripped = applyVariant(model, spec.variant)

	-- Only reached when the variant could NOT keep the painted face (an old
	-- Studio build with no Color on SurfaceAppearance). Normally the face
	-- survives the coat and no billboard is needed.
	if stripped and textureFace and FACE_SHAPES[shapeKey] == true then
		attachFace(primaryPart, sparkle, footprint)
	end

	return model, height
end

return SquishyModels
