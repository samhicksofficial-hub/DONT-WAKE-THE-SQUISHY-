--!strict
-- Builds squishy Models from the Config catalog. Used by SquishyService for
-- field spawns and by PlotService for placed display copies.
--
-- Model tree produced by `create`:
--   Model (name = def.name, PrimaryPart = Body)
--     Body (Part, Ball, anchored, CanCollide false) -- the blob
--       ProximityPrompt "PickupPrompt" (hold to pick up; enabled)
--       BillboardGui "Info" (name / rarity / $s labels, always on)
--       BillboardGui "Zzz" ("Zzz" label; server toggles Enabled by State)
--     EyeL, EyeR (Parts, welded to Body, massless)
--
-- Attributes on the Model: SquishyName, Rarity, Income, SpeedMult, Scale,
-- State ("Sleeping" on creation).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"))

local SquishyFactory = {}

-- Base body dimensions at scale 1 (squashed ball, like a plushie).
local BASE_SIZE = Vector3.new(3.4, 2.6, 3.4)

local function makeLabel(parent: Instance, text: string, color: Color3, size: number, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Label" .. order
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, size)
	label.LayoutOrder = order
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.Parent = parent
	return label
end

-- Creates a ready-to-place squishy. The caller parents it and pivots it so the
-- body's base sits on the ground (`model:PivotTo(CFrame.new(pos + Vector3.new(0, height/2, 0)))`
-- with `height = SquishyFactory.bodyHeight(def)`).
function SquishyFactory.create(squishyName: string): Model
	local def = Config.SquishyByName[squishyName]
	assert(def ~= nil, ("Unknown squishy '%s'"):format(squishyName))
	local rarity = Config.RarityByName[def.rarity]
	assert(rarity ~= nil, ("Unknown rarity '%s'"):format(def.rarity))

	local model = Instance.new("Model")
	model.Name = def.name

	local size = BASE_SIZE * def.scale
	-- Block + sphere SpecialMesh: a Ball part ignores non-uniform Size (renders as
	-- a sphere of the smallest axis); the mesh gives a true squashed ellipsoid.
	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = size
	body.Color = def.color
	body.Material = Enum.Material.SmoothPlastic
	body.Anchored = true
	body.CanCollide = false
	body.CanTouch = false
	local bodyMesh = Instance.new("SpecialMesh")
	bodyMesh.MeshType = Enum.MeshType.Sphere
	bodyMesh.Parent = body
	body.Parent = model
	model.PrimaryPart = body

	-- Eyes: two black flattened balls on the front (-Z) face.
	for i, xOffset in { -0.28, 0.28 } do
		local eye = Instance.new("Part")
		eye.Name = i == 1 and "EyeL" or "EyeR"
		eye.Size = Vector3.new(0.5, 0.7, 0.28) * def.scale
		local eyeMesh = Instance.new("SpecialMesh")
		eyeMesh.MeshType = Enum.MeshType.Sphere
		eyeMesh.Parent = eye
		eye.Color = Color3.fromRGB(25, 25, 30)
		eye.Material = Enum.Material.SmoothPlastic
		eye.Anchored = false
		eye.Massless = true
		eye.CanCollide = false
		eye.CanTouch = false
		eye.CanQuery = false
		eye.CFrame = body.CFrame * CFrame.new(size.X * xOffset, size.Y * 0.12, -size.Z * 0.42)
		eye.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = eye
		weld.Parent = eye
	end

	-- Info billboard: name, rarity, income.
	local info = Instance.new("BillboardGui")
	info.Name = "Info"
	info.Size = UDim2.fromScale(7, 3)
	info.StudsOffsetWorldSpace = Vector3.new(0, size.Y * 0.5 + 2.6, 0)
	info.AlwaysOnTop = false
	info.MaxDistance = 90
	info.Parent = body
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = info
	makeLabel(info, def.name, Color3.new(1, 1, 1), 26, 1)
	makeLabel(info, def.rarity, rarity.color, 18, 2)
	makeLabel(info, Util.formatMoney(rarity.income) .. "/s", Color3.fromRGB(85, 255, 85), 18, 3)

	-- Zzz billboard, shown while sleeping.
	local zzz = Instance.new("BillboardGui")
	zzz.Name = "Zzz"
	zzz.Size = UDim2.fromScale(3, 2)
	zzz.StudsOffsetWorldSpace = Vector3.new(size.X * 0.35, size.Y * 0.5 + 0.8, 0)
	zzz.AlwaysOnTop = false
	zzz.MaxDistance = 70
	zzz.Enabled = true
	zzz.Parent = body
	makeLabel(zzz, "Zzz", Color3.fromRGB(160, 200, 255), 24, 1)

	-- Pickup prompt.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = def.name
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
	prompt.Parent = body

	model:SetAttribute("SquishyName", def.name)
	model:SetAttribute("Rarity", def.rarity)
	model:SetAttribute("Income", rarity.income)
	model:SetAttribute("SpeedMult", rarity.speedMult)
	model:SetAttribute("Scale", def.scale)
	model:SetAttribute("State", "Sleeping")

	return model
end

-- Height of the body for a catalog def (for pivoting onto the ground).
function SquishyFactory.bodyHeight(defOrName: any): number
	local def = typeof(defOrName) == "string" and Config.SquishyByName[defOrName] or defOrName
	assert(def ~= nil, "Unknown squishy def")
	return BASE_SIZE.Y * def.scale
end

return SquishyFactory
