--!strict
-- PlotService: claims a plot spot per player, builds the gameplay furniture
-- inside it (slot platforms, collect/unlock pads, deposit pad), runs the income
-- accrual loop, and handles deposit / collect / unlock touches.
-- See DESIGN.md gameplay rules 2, 3, 4 and 6.
--
-- The BUILDING around that furniture — floor, walls, roof, ceiling lights,
-- house marker, owner sign and spawn point — belongs to BaseBuilder (see the
-- Map Design Contract in DESIGN.md). This service asks it for the shell and
-- then lays its own pieces on the floor top BaseBuilder reports.
--
-- Plot local space (the spot CFrame's LookVector faces the field, so -Z is
-- the plot FRONT toward the walkway and +Z is the BACK):
--   z = -14   deposit pad (front edge)
--   z =  -5   front-row collect pads    z =  1   front-row platforms (slots 1-5)
--   z =   7   back-row collect pads     z = 13   back-row platforms  (slots 6-10)
-- The front row is staggered +4 studs in X so the back row's pads stay
-- reachable between the front platforms.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local SquishyFactory = require(Shared:WaitForChild("SquishyFactory"))

local Palette = Config.Palette

-- Fallback floor height for when BaseBuilder is unavailable; the real value
-- comes back from BaseBuilder.Build per plot.
local DEFAULT_FLOOR_TOP = Config.Base.FloorTop :: number
local TOUCH_DEBOUNCE = 0.4

local SLOT_SPACING = 8
local FRONT_ROW_STAGGER = 2
local FRONT_ROW_Z = 1
local ROW_DEPTH = 12
local PLATFORM_SIZE = Vector3.new(6, 0.4, 6)
local PLATFORM_BORDER_OVERHANG = 1.2 -- darker slab under each platform, per side x2
local PLATFORM_BORDER_THICKNESS = 0.35
local PAD_DIAMETER = 5
local PAD_THICKNESS = 0.28
local PAD_LIFT = 0.06 -- pads float a hair off the floor so they read as flat discs
local PAD_RIM_EXTRA = 1.1
local PAD_RIM_THICKNESS = 0.16
local PAD_FORWARD = 6 -- pad center sits this far in front of its platform center
local DEPOSIT_SIZE = Vector3.new(10, 0.35, 6)
local SPAWN_INSET = 4 -- fallback spawn marker distance in from the front edge
-- The marker sits ON the floor, exactly like BaseBuilder's: SpawnService adds
-- its own standing offset, so lifting it here too would drop the character.
local SPAWN_HEIGHT = 0.5

-- The upgrade plaque, matched to the reference: butter-yellow card with a fat
-- black outline, amber arrow badge, and two stacked lines (price, level step).
local PLAQUE_YELLOW = Color3.fromRGB(255, 214, 74)
local PLAQUE_ARROW_BG = Color3.fromRGB(246, 158, 26)
local PLAQUE_ARROW = Color3.new(1, 1, 1)
-- How high above the collect pad the plaque floats.
-- Clear of the money label sitting on the pad below it.
local UPGRADE_PLAQUE_LIFT = 5.6
-- Roughly one pad wide, so neighbouring plaques never overlap.
local UPGRADE_PLAQUE_SIZE = Vector2.new(5, 3.1)

local COLOR_MONEY = Color3.fromRGB(85, 255, 85)
local COLOR_REFUSE = Color3.fromRGB(255, 70, 70)
local COLOR_WHITE = Color3.new(1, 1, 1)

-- Cylinder parts extend along their X axis; this stands them upright.
local PAD_UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

type SlotRecord = {
	index: number,
	localX: number,
	localZ: number,
	floorTop: number,       -- the storey this slot stands on
	slotOnFloor: number,    -- 1..SlotsPerFloor position within its own storey
	unlocked: boolean,
	occupied: boolean,
	income: number,
	baseIncome: number,     -- level-1 income, variant multiplier included
	level: number,
	rarity: string,
	squishy: Model?,
	upgradePad: BasePart?,
	upgradeLabel: TextLabel?,
	upgradeStepLabel: TextLabel?,
	lastUpgradeTouch: number,
	pending: number,
	lastTouch: number,
	platform: BasePart,
	collectPad: BasePart?,
	collectLabel: TextLabel?,
	unlockPad: BasePart?,
	unlockGui: BillboardGui?,
}

type PlotRecord = {
	player: Player,
	spotIndex: number,
	spotCFrame: CFrame,
	baseCFrame: CFrame,
	model: Model,
	floorTop: number,
	spawnPoint: BasePart?,
	slots: { SlotRecord },
	depositPad: BasePart,
	depositFlashing: boolean,
	lastDepositTouch: number,
	connections: { RBXScriptConnection },
}

local PlotService = {}

local servicesRef: any = nil
local mapRef: any = nil
local popupRemote: RemoteEvent = nil :: any
local plots: { [Player]: PlotRecord } = {}
-- Buying a floor rebuilds the base, which replaces the pad — so the cooldown
-- has to outlive it, or a player standing on the pad buys every floor they can
-- afford in one go.
local FLOOR_BUY_COOLDOWN = 3
local lastFloorBuy: { [Player]: number } = {}
local spotUsed: { boolean } = {}

-- ---------------------------------------------------------------- builders --

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

local function newBillboard(adornee: BasePart, name: string, widthStuds: number, heightStuds: number, offsetY: number, maxDistance: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Size = UDim2.fromScale(widthStuds, heightStuds)
	gui.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = maxDistance
	gui.Parent = adornee
	return gui
end

local function newLabel(parent: Instance, text: string, color: Color3, order: number, heightScale: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Label" .. tostring(order)
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, heightScale, 0)
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

-- ------------------------------------------------------------------ helpers --

-- True when the touching part belongs to the living character of the owner.
local function isOwnerTouch(plot: PlotRecord, hitPart: BasePart): boolean
	local character = hitPart.Parent
	if character == nil then
		return false
	end
	local touchingPlayer = Players:GetPlayerFromCharacter(character)
	if touchingPlayer == nil or touchingPlayer ~= plot.player then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- Shows what collecting would actually pay: rebirth multiplies income inside
-- EconomyService.AddMoney, so the raw pending figure would understate it.
local function updateCollectLabel(plot: PlotRecord, slot: SlotRecord)
	local label = slot.collectLabel
	if label == nil then
		return
	end
	local payout = slot.pending
	local economy = servicesRef ~= nil and servicesRef.EconomyService or nil
	if economy ~= nil and typeof(economy.PreviewIncome) == "function" then
		local ok, previewed = pcall(economy.PreviewIncome, plot.player, slot.pending)
		if ok and typeof(previewed) == "number" then
			payout = previewed
		end
	end
	local shown = math.floor(payout)
	if shown < 1 then
		label.Text = "$0"
		label.TextTransparency = 0.55
	else
		label.Text = Util.formatMoney(shown)
		label.TextTransparency = 0
	end
end

local function findNextLockedIndex(plot: PlotRecord): number?
	for _, slot in plot.slots do
		if not slot.unlocked then
			return slot.index
		end
	end
	return nil
end

local function findFreeSlot(plot: PlotRecord): SlotRecord?
	for _, slot in plot.slots do
		if slot.unlocked and not slot.occupied then
			return slot
		end
	end
	return nil
end

-- ---------------------------------------------------------------- collecting --

local function onCollectTouched(plot: PlotRecord, slot: SlotRecord, hitPart: BasePart)
	if not slot.unlocked then
		return
	end
	if not isOwnerTouch(plot, hitPart) then
		return
	end
	local now = os.clock()
	if now - slot.lastTouch < TOUCH_DEBOUNCE then
		return
	end
	slot.lastTouch = now
	local amount = math.floor(slot.pending)
	if amount < 1 then
		return
	end
	slot.pending = 0
	-- Pop up what actually landed in the balance, not the raw figure: rebirth
	-- multiplies income inside AddMoney.
	local credited = servicesRef.EconomyService.AddMoney(plot.player, amount)
	if typeof(credited) ~= "number" then
		credited = amount
	end
	local pad = slot.collectPad
	if pad ~= nil then
		popupRemote:FireClient(plot.player, credited, pad.Position)
	end
	updateCollectLabel(plot, slot)
end

local function createCollectPad(plot: PlotRecord, slot: SlotRecord)
	local cf = plot.baseCFrame
		* CFrame.new(slot.localX, slot.floorTop + PAD_LIFT + PAD_THICKNESS / 2, slot.localZ - PAD_FORWARD)
		* PAD_UPRIGHT
	local pad = newPart(
		plot.model,
		"CollectPad" .. tostring(slot.index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		cf,
		Palette.CollectPad,
		Enum.Material.Neon
	)
	pad.Shape = Enum.PartType.Cylinder
	pad.CanCollide = false
	-- A darker disc flat on the floor under the pad, so it reads as a tile
	-- rather than a floating coin. Parented to the pad: it dies with it.
	local rim = newPart(
		pad,
		"Rim",
		Vector3.new(PAD_RIM_THICKNESS, PAD_DIAMETER + PAD_RIM_EXTRA, PAD_DIAMETER + PAD_RIM_EXTRA),
		plot.baseCFrame
			* CFrame.new(slot.localX, slot.floorTop + PAD_RIM_THICKNESS / 2, slot.localZ - PAD_FORWARD)
			* PAD_UPRIGHT,
		Palette.SlotBorder,
		Enum.Material.SmoothPlastic
	)
	rim.Shape = Enum.PartType.Cylinder
	rim.CanCollide = false
	rim.CanTouch = false
	rim.CanQuery = false
	local gui = newBillboard(pad, "PendingGui", 4.5, 1.8, 2.2, 90)
	slot.collectPad = pad
	slot.collectLabel = newLabel(gui, "$0", COLOR_MONEY, 1, 1)
	updateCollectLabel(plot, slot)
	table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
		onCollectTouched(plot, slot, hitPart)
	end))
end

-- ---------------------------------------------------------------- unlocking --

local function revealUnlockPad(slot: SlotRecord)
	local pad = slot.unlockPad
	if pad ~= nil then
		pad.Transparency = 0.3
		pad.CanTouch = true
	end
	local gui = slot.unlockGui
	if gui ~= nil then
		gui.Enabled = true
	end
end

local function unlockSlot(plot: PlotRecord, slot: SlotRecord)
	slot.unlocked = true
	local pad = slot.unlockPad
	if pad ~= nil then
		pad:Destroy()
	end
	slot.unlockPad = nil
	slot.unlockGui = nil
	slot.platform.Color = Palette.SlotPlatform
	createCollectPad(plot, slot)
	local nextLocked = findNextLockedIndex(plot)
	if nextLocked ~= nil then
		revealUnlockPad(plot.slots[nextLocked])
	end
end

local function onUnlockTouched(plot: PlotRecord, slot: SlotRecord, hitPart: BasePart)
	if slot.unlocked then
		return
	end
	-- Rule 4: only the NEXT locked slot is purchasable.
	if findNextLockedIndex(plot) ~= slot.index then
		return
	end
	if not isOwnerTouch(plot, hitPart) then
		return
	end
	local now = os.clock()
	if now - slot.lastTouch < TOUCH_DEBOUNCE then
		return
	end
	slot.lastTouch = now
	-- Prices are per position ON the ground floor, not per global slot index.
	local price = Config.Plot.UnlockPrices[slot.slotOnFloor] or 0
	if not servicesRef.EconomyService.TrySpend(plot.player, price) then
		return
	end
	unlockSlot(plot, slot)
end

-- Created hidden/inactive for every locked slot; only the next locked slot's
-- pad is revealed via revealUnlockPad.
local function createUnlockPad(plot: PlotRecord, slot: SlotRecord)
	local cf = plot.baseCFrame
		* CFrame.new(slot.localX, slot.floorTop + PAD_LIFT + PAD_THICKNESS / 2, slot.localZ - PAD_FORWARD)
		* PAD_UPRIGHT
	local pad = newPart(
		plot.model,
		"UnlockPad" .. tostring(slot.index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		cf,
		Palette.UnlockPad,
		Enum.Material.Neon
	)
	pad.Shape = Enum.PartType.Cylinder
	pad.CanCollide = false
	pad.Transparency = 1
	pad.CanTouch = false
	local gui = newBillboard(pad, "UnlockGui", 5, 2.6, 3, 90)
	gui.Enabled = false
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = gui
	-- Prices are per position ON the ground floor, not per global slot index.
	local price = Config.Plot.UnlockPrices[slot.slotOnFloor] or 0
	newLabel(gui, Util.formatMoney(price), COLOR_MONEY, 1, 0.55)
	newLabel(gui, "Unlock", COLOR_WHITE, 2, 0.45)
	slot.unlockPad = pad
	slot.unlockGui = gui
	table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
		onUnlockTouched(plot, slot, hitPart)
	end))
end

-- ---------------------------------------------------------------- depositing --

-- ------------------------------------------------------------- levelling --

-- The yellow upgrade plaque: a rounded card with a fat black outline, an arrow
-- badge on the left and two stacked lines on the right — the big price and the
-- small "Lvl 4 > Lvl 5" step. Returns both labels so the caller can retext them.
local function buildUpgradePlaque(gui: BillboardGui): (TextLabel, TextLabel)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = PLAQUE_YELLOW
	card.BorderSizePixel = 0
	card.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.26, 0)
	corner.Parent = card

	local outline = Instance.new("UIStroke")
	outline.Thickness = 4
	outline.Color = Color3.new(0, 0, 0)
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Parent = card

	-- Arrow badge: a darker rounded square with an up-arrow glyph in it.
	local badge = Instance.new("Frame")
	badge.Name = "ArrowBadge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.fromScale(0.04, 0.5)
	badge.Size = UDim2.fromScale(0.21, 0.76)
	badge.BackgroundColor3 = PLAQUE_ARROW_BG
	badge.BorderSizePixel = 0
	badge.Parent = card
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0.25, 0)
	badgeCorner.Parent = badge

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromScale(1, 1)
	arrow.Font = Enum.Font.FredokaOne
	arrow.Text = "\u{2B06}" -- upward arrow
	arrow.TextScaled = true
	arrow.TextColor3 = PLAQUE_ARROW
	arrow.TextStrokeTransparency = 0.2
	arrow.TextStrokeColor3 = Color3.new(0, 0, 0)
	arrow.Parent = badge

	local price = Instance.new("TextLabel")
	price.Name = "Price"
	price.BackgroundTransparency = 1
	price.AnchorPoint = Vector2.new(0, 0)
	price.Position = UDim2.fromScale(0.28, 0.07)
	price.Size = UDim2.fromScale(0.68, 0.46)
	price.Font = Enum.Font.FredokaOne
	price.Text = ""
	price.TextScaled = true
	price.TextColor3 = COLOR_WHITE
	price.TextStrokeTransparency = 0
	price.TextStrokeColor3 = Color3.new(0, 0, 0)
	price.Parent = card

	local step = Instance.new("TextLabel")
	step.Name = "Step"
	step.BackgroundTransparency = 1
	step.AnchorPoint = Vector2.new(0, 0)
	step.Position = UDim2.fromScale(0.28, 0.55)
	step.Size = UDim2.fromScale(0.68, 0.38)
	step.Font = Enum.Font.FredokaOne
	step.Text = ""
	step.TextScaled = true
	-- White on a black stroke: cocoa-on-yellow washed out at play distance.
	step.TextColor3 = COLOR_WHITE
	step.TextStrokeTransparency = 0
	step.TextStrokeColor3 = Color3.new(0, 0, 0)
	step.Parent = card

	return price, step
end


-- Refreshes the squishy's own billboard and the upgrade pad's price line to
-- match its current level.
local function refreshSlotLevel(slot: SlotRecord)
	slot.income = Config.incomeAtLevel(slot.baseIncome, slot.rarity, slot.level)

	local model = slot.squishy
	if model ~= nil and model.Parent ~= nil then
		model:SetAttribute("Level", slot.level)
		model:SetAttribute("Income", slot.income)
		-- The factory's Info billboard: line 2 carries the level, line 3 the rate.
		local info = model:FindFirstChild("Info", true)
		if info ~= nil then
			local levelLabel = info:FindFirstChild("Label2")
			if levelLabel ~= nil and levelLabel:IsA("TextLabel") then
				levelLabel.Text = ("%s  Lvl %d"):format(slot.rarity, slot.level)
			end
			local rateLabel = info:FindFirstChild("Label3")
			if rateLabel ~= nil and rateLabel:IsA("TextLabel") then
				rateLabel.Text = Util.formatMoney(slot.income) .. "/s"
			end
		end
	end

	local price = slot.upgradeLabel
	local step = slot.upgradeStepLabel
	if price ~= nil then
		local cost = Config.levelUpCost(slot.baseIncome, slot.rarity, slot.level)
		if cost == nil then
			price.Text = "MAX"
			if step ~= nil then
				step.Text = ("Lvl %d"):format(slot.level)
			end
		else
			price.Text = Util.formatMoney(cost)
			if step ~= nil then
				step.Text = ("Lvl %d > Lvl %d"):format(slot.level, slot.level + 1)
			end
		end
	end
end

local function onUpgradeTouched(plot: PlotRecord, slot: SlotRecord, hitPart: BasePart)
	if not slot.occupied or not isOwnerTouch(plot, hitPart) then
		return
	end
	local now = os.clock()
	if now - slot.lastUpgradeTouch < TOUCH_DEBOUNCE then
		return
	end
	slot.lastUpgradeTouch = now

	local cost = Config.levelUpCost(slot.baseIncome, slot.rarity, slot.level)
	if cost == nil then
		return -- maxed
	end
	local economy = servicesRef.EconomyService
	if not economy.TrySpend(plot.player, cost) then
		return -- can't afford it; the pad just does nothing
	end
	slot.level += 1
	refreshSlotLevel(slot)
end

-- The yellow "upgrade" step in front of an occupied slot. Built once per slot
-- and then only shown/hidden, so a redeposit never stacks pads.
local function showUpgradePad(plot: PlotRecord, slot: SlotRecord)
	local pad = slot.upgradePad
	if pad == nil then
		pad = newPart(
			plot.model,
			"UpgradePad" .. tostring(slot.index),
			Vector3.new(PAD_DIAMETER * 1.15, PAD_THICKNESS, 2.2),
			plot.baseCFrame
				* CFrame.new(slot.localX, slot.floorTop + PAD_LIFT + PAD_THICKNESS / 2, slot.localZ - PAD_FORWARD * 0.45),
			Palette.UnlockPad,
			Enum.Material.Neon
		)
		pad.CanCollide = false
		-- The plaque floats above the collect pad rather than over the upgrade
		-- slab itself: that is where the reference puts it, and it keeps the
		-- price clear of the money label sitting on the green pad below.
		local anchor = slot.collectPad or pad
		local gui = newBillboard(
			anchor,
			"UpgradeGui",
			UPGRADE_PLAQUE_SIZE.X,
			UPGRADE_PLAQUE_SIZE.Y,
			UPGRADE_PLAQUE_LIFT,
			95
		)
		local price, step = buildUpgradePlaque(gui)
		slot.upgradeLabel = price
		slot.upgradeStepLabel = step
		slot.upgradePad = pad
		table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
			onUpgradeTouched(plot, slot, hitPart)
		end))
	end
	pad.Transparency = 0
	pad.CanTouch = true
	-- The plaque hangs off the collect pad, not the upgrade slab.
	local anchor = slot.collectPad or pad
	local gui = anchor:FindFirstChild("UpgradeGui")
	if gui ~= nil and gui:IsA("BillboardGui") then
		gui.Enabled = true
	end
	refreshSlotLevel(slot)
end

local function placeSquishy(plot: PlotRecord, slot: SlotRecord, def: any)
	local model = SquishyFactory.create(def.name, def.variant)
	local prompt = model:FindFirstChild("PickupPrompt", true)
	if prompt ~= nil then
		prompt:Destroy()
	end
	local zzz = model:FindFirstChild("Zzz", true)
	if zzz ~= nil and zzz:IsA("BillboardGui") then
		zzz.Enabled = false
	end
	model:SetAttribute("State", "Placed")
	model.Parent = plot.model
	local height = SquishyFactory.bodyHeight(def.name)
	model:PivotTo(slot.platform.CFrame * CFrame.new(0, slot.platform.Size.Y / 2 + height / 2, 0))
	slot.occupied = true
	slot.pending = 0
	slot.level = 1
	slot.rarity = (model:GetAttribute("Rarity") :: string?) or "Common"
	-- Level 1 income is what the factory stamped (variant multiplier included);
	-- every level after that is derived from it.
	slot.baseIncome = (model:GetAttribute("Income") :: number?) or 0
	slot.income = slot.baseIncome
	slot.squishy = model
	updateCollectLabel(plot, slot)
	showUpgradePad(plot, slot)
end

local function flashDepositPad(plot: PlotRecord)
	if plot.depositFlashing then
		return
	end
	plot.depositFlashing = true
	local pad = plot.depositPad
	pad.Color = COLOR_REFUSE
	task.delay(0.35, function()
		if pad.Parent ~= nil then
			pad.Color = Palette.DepositPad
		end
		plot.depositFlashing = false
	end)
end

local function onDepositTouched(plot: PlotRecord, hitPart: BasePart)
	if not isOwnerTouch(plot, hitPart) then
		return
	end
	local now = os.clock()
	if now - plot.lastDepositTouch < TOUCH_DEBOUNCE then
		return
	end
	plot.lastDepositTouch = now
	local slot = findFreeSlot(plot)
	if slot == nil then
		-- Rule 2: all unlocked slots full -> refuse, leave the player carrying.
		if servicesRef.SquishyService.IsCarrying(plot.player) then
			flashDepositPad(plot)
		end
		return
	end
	local def = servicesRef.SquishyService.TakeCarriedDef(plot.player)
	if def == nil then
		return
	end
	local ok, err = pcall(placeSquishy, plot, slot, def)
	if not ok then
		warn(("[PlotService] failed to place squishy for %s: %s"):format(plot.player.Name, tostring(err)))
	end
end

-- ------------------------------------------------------------------- shell --

-- The building itself is BaseBuilder's job. It is a builder, not a service, so
-- it is required directly as a sibling module rather than through the services
-- table. It may be missing on a partial sync: resolve it once, lazily, and fail
-- soft so a plot is still playable without its shell.
local baseBuilder: any = nil
local baseBuilderResolved = false
local baseBuilderWarned = false

local function getBaseBuilder(): any
	if not baseBuilderResolved then
		baseBuilderResolved = true
		local moduleScript = (script.Parent :: any):FindFirstChild("BaseBuilder")
		if moduleScript ~= nil then
			local ok, result = pcall(function()
				return (require :: any)(moduleScript)
			end)
			if ok and typeof(result) == "table" and typeof(result.Build) == "function" then
				baseBuilder = result
			elseif not ok then
				warn(("[PlotService] BaseBuilder failed to load: %s"):format(tostring(result)))
			end
		end
	end
	if baseBuilder == nil and not baseBuilderWarned then
		baseBuilderWarned = true
		warn("[PlotService] BaseBuilder unavailable — plots build without their building shell")
	end
	return baseBuilder
end

-- ---------------------------------------------------------------- plot build --

-- Returns true once the plot is registered.
-- Defined below (it needs buildPlot), declared here so buildPlot can call it.
local buildFloorPrompt: (PlotRecord) -> ()

-- ----------------------------------------------------------------- floors --
-- Floors are bought one at a time, alternating upward and downward so the
-- building grows in both directions. Buying one REBUILDS the base at the new
-- height and puts every placed squishy back exactly as it was — simpler and
-- far less error-prone than splicing new geometry into a live building.

-- How many extra floors this player owns, and which direction the next one goes.
local function floorCounts(player: Player): (number, number)
	local above = tonumber(player:GetAttribute("FloorsAbove")) or 0
	local below = tonumber(player:GetAttribute("FloorsBelow")) or 0
	return math.floor(above), math.floor(below)
end

-- Price of the next floor, or nil when the base is fully built out.
local function nextFloorCost(player: Player): (number?, string?)
	local above, below = floorCounts(player)
	local owned = above + below
	local price = (Config.Plot.FloorPrices :: { number })[owned + 1]
	if price == nil then
		return nil, nil
	end
	-- Alternate up, down, up, down... so the tower and the basement grow
	-- together rather than one running away.
	local goUp = above <= below and above < (Config.Plot.MaxAbove :: number)
	if not goUp and below >= (Config.Plot.MaxBelow :: number) then
		if above >= (Config.Plot.MaxAbove :: number) then
			return nil, nil
		end
		return price, "above"
	end
	return price, goUp and "above" or "below"
end

-- Snapshot of everything a rebuild must restore.
local function snapshotSlots(plot: PlotRecord): { any }
	local saved = {}
	for _, slot in plot.slots do
		if slot.occupied and slot.squishy ~= nil then
			table.insert(saved, {
				squishyName = slot.squishy:GetAttribute("SquishyName"),
				variant = slot.squishy:GetAttribute("Variant"),
				level = slot.level,
				pending = slot.pending,
				unlocked = slot.unlocked,
			})
		end
	end
	return saved
end

local function buildPlot(player: Player, spotIndex: number): boolean
	local spotCFrame = mapRef.plotSpots[spotIndex] :: CFrame
	local spotPos = spotCFrame.Position
	local baseCFrame = CFrame.new(spotPos.X, 0, spotPos.Z) * spotCFrame.Rotation

	local footprint = Config.Plot.BaseSize :: Vector2
	local halfDepth = footprint.Y / 2

	local model = Instance.new("Model")
	model.Name = player.Name

	-- Shell first: floor, walls, roof, ceiling lights, house marker, owner sign
	-- and spawn point, all reported back with the floor height to build on.
	local floorTop = DEFAULT_FLOOR_TOP
	local floorTops: { number } = { DEFAULT_FLOOR_TOP }
	local groundIndex = 1
	local spawnPoint: BasePart? = nil
	local shellBuilt = false
	local builder = getBaseBuilder()
	if builder ~= nil then
		local above, below = floorCounts(player)
		local ok, shell = pcall(builder.Build, player, model, baseCFrame, { above = above, below = below })
		if ok and typeof(shell) == "table" then
			shellBuilt = true
			if typeof(shell.floorTop) == "number" then
				floorTop = shell.floorTop
			end
			-- One entry per storey; slots above the ground floor stand on these.
			if typeof(shell.floorTops) == "table" and #shell.floorTops > 0 then
				floorTops = shell.floorTops
			end
			if typeof(shell.groundIndex) == "number" then
				groundIndex = shell.groundIndex
			end
			local point = shell.spawnPoint
			if typeof(point) == "Instance" and point:IsA("BasePart") then
				spawnPoint = point
			end
		elseif not ok then
			warn(("[PlotService] BaseBuilder.Build failed for %s: %s"):format(player.Name, tostring(shell)))
		end
	end

	if not shellBuilt then
		-- Bare fallback: just enough floor to stand the gameplay pieces on.
		newPart(
			model,
			"Floor",
			Vector3.new(footprint.X, floorTop, footprint.Y),
			baseCFrame * CFrame.new(0, floorTop / 2, 0),
			Palette.BaseFloor,
			Enum.Material.SmoothPlastic
		)
	end

	if spawnPoint == nil then
		local marker = newPart(
			model,
			"SpawnPoint",
			Vector3.new(2, 1, 2),
			baseCFrame * CFrame.new(0, floorTop + SPAWN_HEIGHT, -(halfDepth - SPAWN_INSET)),
			Palette.BaseFloor,
			Enum.Material.SmoothPlastic
		)
		marker.Transparency = 1
		marker.CanCollide = false
		marker.CanTouch = false
		marker.CanQuery = false
		spawnPoint = marker
	end

	-- Deposit pad at the front edge, facing the walkway.
	local depositPad = newPart(
		model,
		"DepositPad",
		DEPOSIT_SIZE,
		baseCFrame * CFrame.new(0, floorTop + PAD_LIFT + DEPOSIT_SIZE.Y / 2, -(halfDepth - 4)),
		Palette.DepositPad,
		Enum.Material.Neon
	)
	depositPad.CanCollide = false
	local depositBorder = newPart(
		depositPad,
		"Border",
		Vector3.new(DEPOSIT_SIZE.X + PAD_RIM_EXTRA, PAD_RIM_THICKNESS, DEPOSIT_SIZE.Z + PAD_RIM_EXTRA),
		baseCFrame * CFrame.new(0, floorTop + PAD_RIM_THICKNESS / 2, -(halfDepth - 4)),
		Palette.SlotBorder,
		Enum.Material.SmoothPlastic
	)
	depositBorder.CanCollide = false
	depositBorder.CanTouch = false
	depositBorder.CanQuery = false
	local depositGui = newBillboard(depositPad, "DepositGui", 6, 2, 2.8, 110)
	newLabel(depositGui, "Deposit", COLOR_WHITE, 1, 1)

	local plot: PlotRecord = {
		player = player,
		spotIndex = spotIndex,
		spotCFrame = spotCFrame,
		baseCFrame = baseCFrame,
		model = model,
		floorTop = floorTop,
		spawnPoint = spawnPoint,
		slots = {},
		depositPad = depositPad,
		depositFlashing = false,
		lastDepositTouch = 0,
		connections = {},
	}

	table.insert(plot.connections, depositPad.Touched:Connect(function(hitPart: BasePart)
		onDepositTouched(plot, hitPart)
	end))

	-- Slot platforms: staggered rows toward the back of the plot, filling the
	-- ground floor before climbing to the next storey.
	local slotsPerRow = Config.Plot.SlotsPerRow :: number
	local rowsPerFloor = math.max(1, Config.Plot.RowsPerFloor :: number)
	local slotsPerFloor = slotsPerRow * rowsPerFloor
	-- Ten slots per storey the base owns, laid floor by floor from the deepest
	-- basement up. The ground floor sells its slots one at a time; a floor you
	-- BOUGHT arrives with all ten already open.
	local totalSlots = slotsPerFloor * #floorTops
	for index = 1, totalSlots do
		local floorIndex = math.floor((index - 1) / slotsPerFloor)
		local withinFloor = (index - 1) % slotsPerFloor
		local row = math.floor(withinFloor / slotsPerRow)
		local col = withinFloor % slotsPerRow
		local slotFloorTop = floorTops[floorIndex + 1] or floorTop
		local isGroundFloor = (floorIndex + 1) == groundIndex
		local localX = (col - (slotsPerRow - 1) / 2) * SLOT_SPACING
			+ (row == 0 and FRONT_ROW_STAGGER or 0)
		local localZ = FRONT_ROW_Z + row * ROW_DEPTH
		-- Ground floor: the usual staged unlock. Any other floor was paid for
		-- as a whole, so every slot on it is open from the moment it exists.
		local unlocked = if isGroundFloor
			then withinFloor < (Config.Plot.StartUnlocked :: number)
			else true
		-- Each slot reads as a tile: a darker border slab flat on the floor with
		-- the grey platform sitting on top of it.
		local border = newPart(
			model,
			"SlotBorder" .. tostring(index),
			Vector3.new(
				PLATFORM_SIZE.X + PLATFORM_BORDER_OVERHANG,
				PLATFORM_BORDER_THICKNESS,
				PLATFORM_SIZE.Z + PLATFORM_BORDER_OVERHANG
			),
			baseCFrame * CFrame.new(localX, slotFloorTop + PLATFORM_BORDER_THICKNESS / 2, localZ),
			Palette.SlotBorder,
			Enum.Material.SmoothPlastic
		)
		border.CanCollide = false
		border.CanTouch = false
		border.CanQuery = false
		local platform = newPart(
			model,
			"SlotPlatform" .. tostring(index),
			PLATFORM_SIZE,
			baseCFrame
				* CFrame.new(localX, slotFloorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y / 2, localZ),
			unlocked and Palette.SlotPlatform or Palette.SlotBorder,
			Enum.Material.SmoothPlastic
		)
		local slot: SlotRecord = {
			index = index,
			localX = localX,
			localZ = localZ,
			floorTop = slotFloorTop,
			slotOnFloor = withinFloor + 1,
			unlocked = unlocked,
			occupied = false,
			income = 0,
			baseIncome = 0,
			level = 1,
			rarity = "Common",
			squishy = nil,
			upgradePad = nil,
			upgradeLabel = nil,
			upgradeStepLabel = nil,
			lastUpgradeTouch = 0,
			pending = 0,
			lastTouch = 0,
			platform = platform,
			collectPad = nil,
			collectLabel = nil,
			unlockPad = nil,
			unlockGui = nil,
		}
		plot.slots[index] = slot
		if unlocked then
			createCollectPad(plot, slot)
		else
			createUnlockPad(plot, slot)
		end
	end

	-- Rule 4: reveal only the next locked slot's unlock pad.
	local nextLocked = findNextLockedIndex(plot)
	if nextLocked ~= nil then
		revealUnlockPad(plot.slots[nextLocked])
	end

	model.Parent = mapRef.plotFolder

	if player.Parent == nil then
		-- Player left mid-build; clean up and report failure so the spot frees.
		for _, connection in plot.connections do
			connection:Disconnect()
		end
		model:Destroy()
		return false
	end

	plots[player] = plot
	-- The purchase point for the next storey, up or down.
	pcall(buildFloorPrompt, plot)
	return true
end

-- ------------------------------------------------------------ vacant plots --
-- Every unclaimed spot still gets its building, so the row never has a hole in
-- it. A vacant base is the same shell minus the owner's avatar and floating
-- house, with a "PLOT AVAILABLE" sign; it carries no gameplay furniture and no
-- connections, so tearing it down is just a Destroy.

local vacantModels: { [number]: Model } = {}

local function clearVacant(spotIndex: number)
	local model = vacantModels[spotIndex]
	if model ~= nil then
		vacantModels[spotIndex] = nil
		model:Destroy()
	end
end

local function buildVacant(spotIndex: number)
	if vacantModels[spotIndex] ~= nil or spotUsed[spotIndex] then
		return
	end
	local builder = getBaseBuilder()
	if builder == nil then
		return -- no shell builder: leave the spot empty rather than half-build
	end
	local spotCFrame = (mapRef.plotSpots :: { CFrame })[spotIndex]
	if spotCFrame == nil then
		return
	end
	local spotPos = spotCFrame.Position
	local baseCFrame = CFrame.new(spotPos.X, 0, spotPos.Z) * spotCFrame.Rotation

	local model = Instance.new("Model")
	model.Name = ("VacantPlot%d"):format(spotIndex)
	local ok, err = pcall(builder.Build, nil, model, baseCFrame)
	if not ok then
		warn(("[PlotService] vacant plot %d failed: %s"):format(spotIndex, tostring(err)))
		model:Destroy()
		return
	end
	model.Parent = mapRef.plotFolder
	vacantModels[spotIndex] = model
end

-- Rebuilds a player's base at its current floor count and puts every placed
-- squishy back where it was. Called after buying a floor.
local function rebuildPlot(player: Player)
	local plot = plots[player]
	if plot == nil then
		return
	end
	local saved = snapshotSlots(plot)
	local groundUnlocks = 0
	for _, slot in plot.slots do
		if slot.unlocked and slot.slotOnFloor <= (Config.Plot.SlotsPerFloor :: number) then
			groundUnlocks = math.max(groundUnlocks, slot.slotOnFloor)
		end
	end

	local spotIndex = plot.spotIndex
	for _, connection in plot.connections do
		connection:Disconnect()
	end
	plot.model:Destroy()
	plots[player] = nil

	local ok, built = pcall(buildPlot, player, spotIndex)
	if not ok or built ~= true then
		warn(("[PlotService] rebuild failed for %s: %s"):format(player.Name, tostring(built)))
		return
	end

	-- Restore: ground-floor unlocks first, then the squishies in slot order.
	local fresh = plots[player]
	if fresh == nil then
		return
	end
	for _, slot in fresh.slots do
		if slot.slotOnFloor <= groundUnlocks then
			slot.unlocked = true
		end
	end
	local index = 1
	for _, slot in fresh.slots do
		local entry = saved[index]
		if entry == nil then
			break
		end
		if slot.unlocked and not slot.occupied and entry.squishyName ~= nil then
			local def = Config.SquishyByName[entry.squishyName]
			if def ~= nil then
				local defCopy = table.clone(def)
				defCopy.variant = entry.variant
				local placedOk = pcall(placeSquishy, fresh, slot, defCopy)
				if placedOk then
					slot.level = entry.level or 1
					slot.pending = entry.pending or 0
					refreshSlotLevel(slot)
					updateCollectLabel(fresh, slot)
				end
			end
			index += 1
		end
	end
end

-- The "Next Floor" purchase point: a prompt at the back of the base that adds
-- a storey (alternating up and down) and rebuilds around what is already there.
function buildFloorPrompt(plot: PlotRecord)
	local player = plot.player
	local footprint = Config.Plot.BaseSize :: Vector2
	local post = newPart(
		plot.model,
		"FloorUnlock",
		Vector3.new(5, 6, 2),
		plot.baseCFrame * CFrame.new(footprint.X / 2 - 6, plot.floorTop + 3, footprint.Y / 2 - 4),
		Palette.UnlockPad,
		Enum.Material.Neon
	)
	post.CanCollide = false
	post.CanTouch = true

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FloorPrompt"
	prompt.ActionText = "Unlock!"
	prompt.ObjectText = "Next Floor"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = post

	local function refresh()
		local cost, direction = nextFloorCost(player)
		if cost == nil then
			prompt.Enabled = false
			post.Transparency = 1
			return
		end
		prompt.Enabled = true
		post.Transparency = 0
		prompt.ObjectText = ("Next Floor (%s)"):format(direction == "below" and "basement" or "upstairs")
		prompt.ActionText = ("%s  Unlock!"):format(Util.formatMoney(cost))
	end
	refresh()

	local function buyFloor(buyer: Player)
		if buyer ~= player then
			return
		end
		local now = os.clock()
		if now - (lastFloorBuy[player] or 0) < FLOOR_BUY_COOLDOWN then
			return
		end
		lastFloorBuy[player] = now
		local cost, direction = nextFloorCost(player)
		if cost == nil or direction == nil then
			return
		end
		if not servicesRef.EconomyService.TrySpend(player, cost) then
			return
		end
		local above, below = floorCounts(player)
		if direction == "above" then
			player:SetAttribute("FloorsAbove", above + 1)
		else
			player:SetAttribute("FloorsBelow", below + 1)
		end
		-- The rebuild replaces this pad along with the rest of the base.
		task.spawn(rebuildPlot, player)
	end

	table.insert(plot.connections, prompt.Triggered:Connect(buyFloor))
	-- Walking into it works too: the prompt is the advertised way in, but every
	-- other purchase in the base is a pad you step on, so this matches.
	table.insert(plot.connections, post.Touched:Connect(function(hitPart: BasePart)
		if isOwnerTouch(plot, hitPart) then
			buyFloor(player)
		end
	end))
end

local function claimPlot(player: Player)
	if plots[player] ~= nil then
		return
	end
	local spotIndex: number? = nil
	for i = 1, #(mapRef.plotSpots :: { CFrame }) do
		if not spotUsed[i] then
			spotIndex = i
			break
		end
	end
	if spotIndex == nil then
		warn(("[PlotService] no free plot spot for %s"):format(player.Name))
		return
	end
	spotUsed[spotIndex] = true
	-- The placeholder goes before the real base goes up, so the two never
	-- occupy the same spot.
	clearVacant(spotIndex)
	local ok, result = pcall(buildPlot, player, spotIndex)
	if not ok or result ~= true then
		spotUsed[spotIndex] = false
		if not ok then
			warn(("[PlotService] failed to build plot for %s: %s"):format(player.Name, tostring(result)))
		end
		buildVacant(spotIndex) -- put the placeholder back
	end
end

local function releasePlot(player: Player)
	local plot = plots[player]
	if plot == nil then
		return
	end
	plots[player] = nil
	lastFloorBuy[player] = nil
	spotUsed[plot.spotIndex] = false
	for _, connection in plot.connections do
		connection:Disconnect()
	end
	plot.model:Destroy()
	-- The spot goes back to being an advertised empty plot.
	buildVacant(plot.spotIndex)
end

-- ------------------------------------------------------------------ accrual --

local function accruePlot(plot: PlotRecord, elapsed: number)
	for _, slot in plot.slots do
		if slot.occupied then
			slot.pending += slot.income * elapsed
			updateCollectLabel(plot, slot)
		end
	end
end

-- -------------------------------------------------------------------- public --

function PlotService.Start(services: any, map: any)
	servicesRef = services
	mapRef = map
	popupRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Popup") :: RemoteEvent
	spotUsed = table.create(#(map.plotSpots :: { CFrame }), false)

	-- Stand up a placeholder on every spot first, so an empty server still looks
	-- like a street of bases. claimPlot swaps one out as each player arrives.
	for spotIndex = 1, #(map.plotSpots :: { CFrame }) do
		local ok, err = pcall(buildVacant, spotIndex)
		if not ok then
			warn(("[PlotService] vacant plot %d failed: %s"):format(spotIndex, tostring(err)))
		end
	end

	Players.PlayerAdded:Connect(claimPlot)
	Players.PlayerRemoving:Connect(releasePlot)
	for _, player in Players:GetPlayers() do
		task.spawn(claimPlot, player)
	end

	task.spawn(function()
		while true do
			local elapsed = task.wait(Config.Plot.AccrueTick)
			for _, plot in plots do
				local ok, err = pcall(accruePlot, plot, elapsed)
				if not ok then
					warn(("[PlotService] accrual failed for %s: %s"):format(plot.player.Name, tostring(err)))
				end
			end
		end
	end)
end

function PlotService.GetPlotOrigin(player: Player): CFrame?
	local plot = plots[player]
	if plot ~= nil then
		return plot.spotCFrame
	end
	return nil
end

-- Where SpawnService drops this player's character: the base's SpawnPoint part,
-- facing out toward the field. Nil while the player has no plot yet.
function PlotService.GetSpawnCFrame(player: Player): CFrame?
	local plot = plots[player]
	if plot == nil then
		return nil
	end
	local point = plot.spawnPoint
	if point == nil or point.Parent == nil then
		return nil
	end
	return point.CFrame
end

-- Drops a squishy straight onto a free slot without the player carrying it
-- home — how the wheel delivers a squishy prize. Returns false when the player
-- has no plot or no free unlocked slot (the caller then pays out instead).
-- Everything StealService needs to describe one placed squishy: who owns it,
-- which slot it sits in, and what it is worth right now.
function PlotService.DescribePlaced(model: Model): any?
	for player, plot in plots do
		for _, slot in plot.slots do
			if slot.occupied and slot.squishy == model then
				return {
					owner = player,
					slotIndex = slot.index,
					squishyName = slot.squishy:GetAttribute("SquishyName"),
					variant = slot.squishy:GetAttribute("Variant"),
					level = slot.level,
					income = slot.income,
					rarity = slot.rarity,
				}
			end
		end
	end
	return nil
end

-- Moves a placed squishy from its owner's plot to `thief`'s, keeping its level
-- and variant. Fails (changing nothing) if the thief has no free slot, so a
-- paid steal never destroys the goods without delivering them.
function PlotService.StealSquishy(model: Model, thief: Player): boolean
	local info = PlotService.DescribePlaced(model)
	if info == nil or info.owner == thief then
		return false
	end
	local thiefPlot = plots[thief]
	if thiefPlot == nil then
		return false
	end
	local target = findFreeSlot(thiefPlot)
	if target == nil then
		return false
	end

	local victimPlot = plots[info.owner]
	local victimSlot = victimPlot ~= nil and victimPlot.slots[info.slotIndex] or nil
	if victimSlot == nil then
		return false
	end

	local def = Config.SquishyByName[info.squishyName]
	if def == nil then
		return false
	end
	local defCopy = table.clone(def)
	defCopy.variant = info.variant

	-- Place it on the thief's plot FIRST; only clear the victim once it landed.
	local ok = pcall(placeSquishy, thiefPlot, target, defCopy)
	if not ok then
		return false
	end
	target.level = info.level or 1
	refreshSlotLevel(target)
	updateCollectLabel(thiefPlot, target)

	-- Clear the victim's slot: the squishy, its pending cash and its pad.
	if victimSlot.squishy ~= nil then
		victimSlot.squishy:Destroy()
	end
	victimSlot.squishy = nil
	victimSlot.occupied = false
	victimSlot.pending = 0
	victimSlot.income = 0
	victimSlot.baseIncome = 0
	victimSlot.level = 1
	local pad = victimSlot.upgradePad
	if pad ~= nil then
		pad.Transparency = 1
		pad.CanTouch = false
		local gui = pad:FindFirstChild("UpgradeGui")
		if gui ~= nil and gui:IsA("BillboardGui") then
			gui.Enabled = false
		end
	end
	updateCollectLabel(victimPlot, victimSlot)
	return true
end

function PlotService.TryPlaceSquishy(player: Player, def: any): boolean
	if def == nil then
		return false
	end
	local plot = plots[player]
	if plot == nil then
		return false
	end
	local slot = findFreeSlot(plot)
	if slot == nil then
		return false
	end
	local ok, err = pcall(placeSquishy, plot, slot, def)
	if not ok then
		warn(("[PlotService] wheel placement failed for %s: %s"):format(player.Name, tostring(err)))
		return false
	end
	return true
end

return PlotService
