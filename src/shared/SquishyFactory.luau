--!strict
-- Builds squishy Models from the Config catalog. Used by SquishyService for
-- field spawns and by PlotService for placed display copies.
--
-- The 3D visual comes from SquishyModels (mesh templates in
-- ReplicatedStorage.SquishyMeshes with part-built fallbacks, ported from the
-- user's Squishy Clicker game). This module adds the gameplay dressing:
--
--   Model (name = def.name, PrimaryPart = Body)
--     Body (invisible anchored box sized to the visual; from SquishyModels)
--       ProximityPrompt "PickupPrompt" (hold to pick up; enabled)
--       BillboardGui "Info" (name / rarity / $s labels, always on)
--       BillboardGui "Zzz" ("Zzz" label; server toggles Enabled by State)
--     ...visual parts welded to Body (massless, no collide/touch/query)
--
-- Attributes on the Model: SquishyName, Rarity, Income, SpeedMult, Scale,
-- BodyHeight, State ("Sleeping" on creation).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"))
local SquishyModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SquishyModels"))

local SquishyFactory = {}

-- Measured body heights by squishy name, filled in as models get built so
-- bodyHeight() answers accurately after the first create() of each kind.
local measuredHeights: { [string]: number } = {}

-- Estimated height at scale 1 for squishies never built yet (dumpling-ish).
local FALLBACK_HEIGHT = 2.6

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

	local model, height = SquishyModels.build({
		shape = def.shape,
		color = def.color,
		sparkle = def.sparkle,
		scale = def.scale,
	})
	model.Name = def.name
	measuredHeights[def.name] = height

	local body = model.PrimaryPart :: BasePart
	local halfY = height * 0.5

	-- Info billboard: name, rarity, income.
	local info = Instance.new("BillboardGui")
	info.Name = "Info"
	info.Size = UDim2.fromScale(7, 3)
	info.StudsOffsetWorldSpace = Vector3.new(0, halfY + 2.6, 0)
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
	zzz.StudsOffsetWorldSpace = Vector3.new(halfY * 0.5, halfY + 0.8, 0)
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
	model:SetAttribute("Scale", def.scale or 1)
	model:SetAttribute("BodyHeight", height)
	model:SetAttribute("State", "Sleeping")

	return model
end

-- Height of the body for a catalog def (for pivoting onto the ground).
-- Accurate once a squishy of that kind has been built; estimated before then.
function SquishyFactory.bodyHeight(defOrName: any): number
	local def = typeof(defOrName) == "string" and Config.SquishyByName[defOrName] or defOrName
	assert(def ~= nil, "Unknown squishy def")
	local measured = measuredHeights[def.name]
	if measured then
		return measured
	end
	return FALLBACK_HEIGHT * (def.scale or 1)
end

return SquishyFactory
