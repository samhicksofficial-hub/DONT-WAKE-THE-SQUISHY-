--!strict
-- PlotService: claims a plot spot per player, builds the gameplay furniture
-- inside it (slot platforms, pedestals, collect and unlock pads), runs the
-- income accrual loop, and handles placing, collecting and unlocking.
-- See DESIGN.md gameplay rules 2, 3, 4 and 6.
--
-- The BUILDING around that furniture — floor, walls, roof, ceiling lights,
-- house marker, owner sign and spawn point — belongs to BaseBuilder (see the
-- Map Design Contract in DESIGN.md). This service asks it for the shell and
-- then lays its own pieces on the floor top BaseBuilder reports.
--
-- Plot local space (the spot CFrame's LookVector faces the field, so -Z is
-- the plot FRONT toward the walkway and +Z is the BACK). The slots stand in
-- TWO LINES hugging the side walls — slots 1-5 along the left wall, 6-10 along
-- the right — every one turned to face the clear centre aisle, with its
-- collect pad and plaque in front of it toward the aisle. The ladder to the
-- other storeys is at the back-centre, the spawn at the front-centre, and the
-- aisle between the pads stays walkable end to end.
--
-- Each slot's furniture is laid out in the slot's OWN frame (local -Z toward
-- the aisle), so "in front of the platform" is one rule that holds on both
-- sides; see slotLayout and slotFrame.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local SquishyFactory = require(Shared:WaitForChild("SquishyFactory"))

local Palette = Config.Palette

-- Fallback floor height for when BaseBuilder is unavailable; the real value
-- comes back from BaseBuilder.Build per plot.
local DEFAULT_FLOOR_TOP = Config.Base.FloorTop :: number
local TOUCH_DEBOUNCE = 0.4

-- Slot grid: two lines of five, one along each side wall, facing each other
-- across the aisle. Spacing runs along Z (the plot's depth); the lines sit a
-- touch back of centre so the front stays clear around the spawn point.
local SLOT_SPACING = 9 -- centre-to-centre along a wall line
local LINE_Z_CENTER = 2
local PLATFORM_SIZE = Vector3.new(6, 0.4, 6)
-- Platform centre distance from the plot midline: snug to the wall's inner
-- face with a one-stud gap so nothing clips through it.
local LINE_X = (Config.Plot.BaseSize :: Vector2).X / 2
	- (Config.Base.WallThickness :: number)
	- PLATFORM_SIZE.X / 2
	- 1
local PLATFORM_BORDER_OVERHANG = 1.2 -- darker slab under each platform, per side x2
local PLATFORM_BORDER_THICKNESS = 0.35
local PAD_DIAMETER = 5
local PAD_THICKNESS = 0.28
local PAD_LIFT = 0.06 -- pads float a hair off the floor so they read as flat discs
local PAD_RIM_EXTRA = 1.1
local PAD_RIM_THICKNESS = 0.16
local PAD_FORWARD = 6 -- pad center sits this far in front of its platform center
local SPAWN_INSET = 4 -- fallback spawn marker distance in from the front edge
-- The marker sits ON the floor, exactly like BaseBuilder's: SpawnService adds
-- its own standing offset, so lifting it here too would drop the character.
local SPAWN_HEIGHT = 0.5

-- The upgrade plaque, matched to the reference: butter-yellow card with a fat
-- black outline, amber arrow badge, and two stacked lines (price, level step).
local PLAQUE_YELLOW = Color3.fromRGB(255, 214, 74)
-- The Upgrade icon ships its own gold, so "on" is an untinted white and
-- "off" is the same slate the card greys to.
local PLAQUE_ARROW = Color3.new(1, 1, 1)
-- The cannot-afford state, straight from the reference: slate card, pale arrow.
local PLAQUE_GREY = Color3.fromRGB(110, 114, 124)
local PLAQUE_ARROW_GREY = Color3.fromRGB(158, 162, 172)
-- The board sits on the podium: this much clear air under it, and this far
-- forward of the podium's front face so it never z-fights the platform.
local PLAQUE_STAND_OFF = 0.35
local PLAQUE_FRONT_OFFSET = 0.6
-- Roughly one pad wide, so neighbouring plaques never overlap.
local UPGRADE_PLAQUE_SIZE = Vector2.new(4.6, 2.4)

local COLOR_MONEY = Color3.fromRGB(85, 255, 85)
local COLOR_WHITE = Color3.new(1, 1, 1)

-- Cylinder parts extend along their X axis; this stands one upright. The extra
-- spin about that (now vertical) axis turns the flat top so a SurfaceGui
-- printed on it reads left-to-right from the front of the plot instead of
-- sideways.
local PAD_UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(90), 0, 0)

type SlotRecord = {
	index: number,
	localX: number,
	localZ: number,
	yaw: number,            -- the slot faces the aisle; see slotLayout
	floorTop: number,       -- the storey this slot stands on
	slotOnFloor: number,    -- 1..SlotsPerFloor position within its own storey
	isGroundFloor: boolean, -- ground floor sells its slots one at a time
	isItemSlot: boolean,    -- basement stand: holds gear, never a squishy
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
	upgradeArrow: ImageLabel?,
	upgradeCard: Frame?,
	lastUpgradeTouch: number,
	pending: number,
	lastTouch: number,
	platform: BasePart,
	collectPad: BasePart?,
	collectLabel: TextLabel?,
	unlockPad: BasePart?,
	placePrompt: ProximityPrompt?,
	pedestalTop: BasePart?,
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

-- An icon sized to sit in the same UIListLayout column as newLabel's text.
local function newIcon(parent: Instance, image: string, order: number, heightScale: number): ImageLabel
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon" .. tostring(order)
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.new(1, 0, heightScale, 0)
	icon.LayoutOrder = order
	icon.Image = image
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = parent
	return icon
end

-- ---------------------------------------------------------------- pedestals --
-- An Ionic column under every squishy, so a placed one stands clear of the
-- upgrade plaque in front of it instead of hiding behind it.
--
-- Read bottom to top, it is the real order of an Ionic order: square plinth,
-- the torus/scotia/torus base mouldings, a fluted shaft, then the capital —
-- necking ring, echinus, a pair of volutes and the square abacus the squishy
-- actually sits on.
--
-- Every piece is decorative: nothing collides, touches or answers a raycast, so
-- a column can never block a player walking onto their own slot.

-- A cylinder part extends along its X axis; this stands one upright.
local CYLINDER_UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
-- A volute is a disc seen face-on from the front of the column, so its axis
-- lies along Z rather than Y.
local VOLUTE_FACING = CFrame.Angles(0, math.rad(90), 0)

-- Total lift from the platform top to where a squishy stands.
local PEDESTAL_HEIGHT = 3.05
-- Fluting is the most expensive part of the column (one thin cylinder each) and
-- the least legible at play distance. Six reads as fluted without the cost of a
-- real twenty-four.
local FLUTE_COUNT = 6

local function newPedestalPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	shape: Enum.PartType?
): Part
	local part = newPart(parent, name, size, cf, color, Enum.Material.SmoothPlastic)
	if shape ~= nil then
		part.Shape = shape
	end
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	return part
end

-- `origin` is the centre of the platform's top face. Returns the abacus — the
-- slab on top — because that is where the squishy stands and so where the
-- "hold E to place" prompt belongs.
local function buildPedestal(parent: Instance, origin: CFrame, index: number): BasePart
	local stone = Palette.PedestalStone
	local shade = Palette.PedestalShade
	local tag = tostring(index)
	local cylinder = Enum.PartType.Cylinder

	local function ring(name: string, diameter: number, thickness: number, y: number, color: Color3)
		newPedestalPart(
			parent,
			name .. tag,
			Vector3.new(thickness, diameter, diameter),
			origin * CFrame.new(0, y + thickness / 2, 0) * CYLINDER_UPRIGHT,
			color,
			cylinder
		)
	end

	-- Base: square plinth, then the round mouldings that sit on it.
	newPedestalPart(
		parent,
		"PedestalPlinth" .. tag,
		Vector3.new(3, 0.35, 3),
		origin * CFrame.new(0, 0.175, 0),
		shade
	)
	ring("PedestalTorus", 2.7, 0.3, 0.35, stone)
	ring("PedestalScotia", 2.2, 0.25, 0.65, shade)
	ring("PedestalBase", 2.45, 0.22, 0.9, stone)

	-- Shaft, with the flutes standing proud around it.
	local shaftY = 1.12
	local shaftH = 1.35
	ring("PedestalShaft", 1.9, shaftH, shaftY, stone)
	for flute = 1, FLUTE_COUNT do
		local angle = (flute - 1) * (math.pi * 2 / FLUTE_COUNT)
		newPedestalPart(
			parent,
			("PedestalFlute%s_%d"):format(tag, flute),
			Vector3.new(shaftH, 0.26, 0.26),
			origin
				* CFrame.new(math.sin(angle) * 0.95, shaftY + shaftH / 2, math.cos(angle) * 0.95)
				* CYLINDER_UPRIGHT,
			shade,
			cylinder
		)
	end

	-- Capital: necking, echinus, the two volutes, and the abacus on top.
	ring("PedestalNeck", 2, 0.16, 2.47, shade)
	ring("PedestalEchinus", 2.25, 0.2, 2.63, stone)
	for side, sign in { -1, 1 } do
		newPedestalPart(
			parent,
			("PedestalVolute%s_%d"):format(tag, side),
			Vector3.new(0.55, 0.85, 0.85),
			origin * CFrame.new(sign * 0.95, 2.85, 0) * VOLUTE_FACING,
			stone,
			cylinder
		)
	end
	return newPedestalPart(
		parent,
		"PedestalAbacus" .. tag,
		Vector3.new(2.5, 0.22, 2.5),
		origin * CFrame.new(0, 2.94, 0),
		stone
	)
end

-- ------------------------------------------------------------ slot layout --
-- Where slot N sits inside a base. Shared by the runtime build and by
-- PlotService.BuildSlotFurniture (which the plot tool calls), so the saved
-- shells and the live plots can never drift apart on positioning.

export type SlotLayout = {
	floorTop: number,
	localX: number,
	localZ: number,
	yaw: number, -- turns the slot so its local -Z faces the centre aisle
	slotOnFloor: number,
	isGroundFloor: boolean,
	isItemFloor: boolean, -- a basement storey: item stands, never squishies
}

local function slotLayout(index: number, floorTops: { number }, groundIndex: number, fallbackTop: number): SlotLayout
	local slotsPerRow = Config.Plot.SlotsPerRow :: number
	local rowsPerFloor = math.max(1, Config.Plot.RowsPerFloor :: number)
	local slotsPerFloor = slotsPerRow * rowsPerFloor

	local floorIndex = math.floor((index - 1) / slotsPerFloor)
	local withinFloor = (index - 1) % slotsPerFloor
	-- Row 0 is the line along the LEFT wall, row 1 the right; both face the
	-- aisle, so their furniture mirrors rather than repeats.
	local row = math.floor(withinFloor / slotsPerRow)
	local col = withinFloor % slotsPerRow
	local side = if row == 0 then -1 else 1
	return {
		floorTop = floorTops[floorIndex + 1] or fallbackTop,
		localX = side * LINE_X,
		localZ = (col - (slotsPerRow - 1) / 2) * SLOT_SPACING + LINE_Z_CENTER,
		-- Local -Z must point at the aisle: rotating by yaw maps -Z onto
		-- (-sin yaw, 0, -cos yaw), so the left line takes -90 degrees (-Z
		-- becomes the base's +X) and the right line +90.
		yaw = side * math.rad(90),
		slotOnFloor = withinFloor + 1,
		isGroundFloor = (floorIndex + 1) == groundIndex,
		isItemFloor = (floorIndex + 1) < groundIndex,
	}
end

-- The slot's own frame at floor level y=0: origin under the platform centre,
-- -Z toward the aisle. Everything a slot owns is placed in this frame, which
-- is what lets the two mirrored lines share every construction rule.
local function slotFrame(baseCFrame: CFrame, layout: SlotLayout): CFrame
	return baseCFrame * CFrame.new(layout.localX, 0, layout.localZ) * CFrame.Angles(0, layout.yaw, 0)
end

-- Same frame recovered from a live slot record.
local function slotRecordFrame(plot: PlotRecord, slot: SlotRecord): CFrame
	return plot.baseCFrame * CFrame.new(slot.localX, 0, slot.localZ) * CFrame.Angles(0, slot.yaw, 0)
end

-- A part already sitting in the model under this name — furniture inherited
-- from a hand-edited shell. Reused rather than rebuilt, so what the owner saved
-- (and moved) is what the plot actually gets.
local function existingPart(parent: Instance, name: string): BasePart?
	local found = parent:FindFirstChild(name)
	if found ~= nil and found:IsA("BasePart") then
		return found
	end
	return nil
end

-- The "hold E to place" prompt only offers itself on a slot that could actually
-- take a squishy. Carrying is per-player and a prompt is one shared instance,
-- so that half is enforced in the handler instead.
local function refreshPlacePrompt(slot: SlotRecord)
	local prompt = slot.placePrompt
	if prompt ~= nil then
		prompt.Enabled = slot.unlocked and not slot.occupied
	end
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
		-- Item stands are open but never take a squishy.
		if slot.unlocked and not slot.occupied and not slot.isItemSlot then
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

-- Builds just the collect pad's geometry — the green disc and the darker rim
-- under it. Split out so the plot tool can put the same discs into a saved
-- shell, where the owner can see and move them.
-- `frame` is the slot's own frame at floor level (slotFrame / slotRecordFrame):
-- the pad sits PAD_FORWARD along its -Z, which is toward the aisle.
local function buildCollectPadGeometry(parent: Instance, frame: CFrame, index: number, layoutFloorTop: number): BasePart
	local cf = frame
		* CFrame.new(0, layoutFloorTop + PAD_LIFT + PAD_THICKNESS / 2, -PAD_FORWARD)
		* PAD_UPRIGHT
	-- Matte, not Neon: a neon pad blows out to white and loses the green
	-- entirely, which is what made these read as pale discs.
	local pad = newPart(
		parent,
		"CollectPad" .. tostring(index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		cf,
		Palette.CollectPad,
		Enum.Material.SmoothPlastic
	)
	pad.Shape = Enum.PartType.Cylinder
	pad.CanCollide = false
	-- A darker disc flat on the floor under the pad, so it reads as a tile
	-- rather than a floating coin. Parented to the pad: it dies with it.
	local rim = newPart(
		pad,
		"Rim",
		Vector3.new(PAD_RIM_THICKNESS, PAD_DIAMETER + PAD_RIM_EXTRA, PAD_DIAMETER + PAD_RIM_EXTRA),
		frame
			* CFrame.new(0, layoutFloorTop + PAD_RIM_THICKNESS / 2, -PAD_FORWARD)
			* PAD_UPRIGHT,
		Palette.SlotBorder,
		Enum.Material.SmoothPlastic
	)
	rim.Shape = Enum.PartType.Cylinder
	rim.CanCollide = false
	rim.CanTouch = false
	rim.CanQuery = false
	return pad
end

-- The money readout printed on a pad's face. Find-or-create, because a pad
-- inherited from a saved shell already carries one.
local function ensurePendingLabel(pad: BasePart): TextLabel
	local gui = pad:FindFirstChild("PendingGui")
	if gui == nil or not gui:IsA("SurfaceGui") then
		-- The amount is PRINTED ON the pad, not floating over it: an upright
		-- cylinder's flat top is its +X face, so Right is the face pointing up.
		local created = Instance.new("SurfaceGui")
		created.Name = "PendingGui"
		created.Face = Enum.NormalId.Right
		created.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		created.PixelsPerStud = 64
		created.LightInfluence = 0
		created.Adornee = pad
		created.Parent = pad
		gui = created
	end
	local surface = gui :: SurfaceGui
	surface.Enabled = true

	local existing = surface:FindFirstChild("Amount")
	if existing ~= nil and existing:IsA("TextLabel") then
		return existing
	end

	local amount = Instance.new("TextLabel")
	amount.Name = "Amount"
	amount.BackgroundTransparency = 1
	amount.AnchorPoint = Vector2.new(0.5, 0.5)
	amount.Position = UDim2.fromScale(0.5, 0.5)
	amount.Size = UDim2.fromScale(0.86, 0.42)
	amount.Font = Enum.Font.FredokaOne
	amount.Text = "$0"
	amount.TextScaled = true
	amount.TextColor3 = COLOR_WHITE
	amount.TextStrokeTransparency = 0
	amount.TextStrokeColor3 = Color3.new(0, 0, 0)
	amount.Parent = surface
	return amount
end

local function createCollectPad(plot: PlotRecord, slot: SlotRecord)
	-- A pad inherited from a hand-edited shell is reused where it stands; only
	-- a plot without one builds a fresh disc.
	local pad = existingPart(plot.model, "CollectPad" .. tostring(slot.index))
	if pad == nil then
		pad = buildCollectPadGeometry(plot.model, slotRecordFrame(plot, slot), slot.index, slot.floorTop)
	else
		-- Locked slots park their inherited pad out of sight (see the slot
		-- loop); unlocking brings it back.
		pad.Transparency = 0
		pad.CanTouch = true
		local rim = pad:FindFirstChild("Rim")
		if rim ~= nil and rim:IsA("BasePart") then
			rim.Transparency = 0
		end
	end

	slot.collectPad = pad
	slot.collectLabel = ensurePendingLabel(pad)
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
	refreshPlacePrompt(slot)
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
	local cf = slotRecordFrame(plot, slot)
		* CFrame.new(0, slot.floorTop + PAD_LIFT + PAD_THICKNESS / 2, -PAD_FORWARD)
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
	local gui = newBillboard(pad, "UnlockGui", 5, 3.6, 3.4, 90)
	gui.Enabled = false
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = gui
	-- A padlock above the price: locked slots read as locked before the price
	-- is legible, which is what tells a new player the slot is buyable at all.
	newIcon(gui, Config.Icons.Lock, 0, 0.34)
	-- Prices are per position ON the ground floor, not per global slot index.
	local price = Config.Plot.UnlockPrices[slot.slotOnFloor] or 0
	newLabel(gui, Util.formatMoney(price), COLOR_MONEY, 1, 0.38)
	newLabel(gui, "Unlock", COLOR_WHITE, 2, 0.28)
	slot.unlockPad = pad
	slot.unlockGui = gui
	table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
		onUnlockTouched(plot, slot, hitPart)
	end))
end

-- ------------------------------------------------------------ gear stands --
-- A basement stand: the gear standing on the pedestal, a name board over it,
-- and a pad in front that prompts the Robux purchase. GearService owns the
-- catalogue, the price and the prompt; the furniture is this file's job,
-- because the frames, the pad geometry and the shell-reuse rules live here.

-- How tall a display is scaled to, whatever it started as: a Glock and a
-- Knight are wildly different sizes and both have to read on the same plinth.
local GEAR_DISPLAY_HEIGHT = 4.2
local GEAR_DISPLAY_LIFT = 0.4 -- clear of the pedestal cap

local function dressGearStand(plot: PlotRecord, slot: SlotRecord)
	local top = slot.pedestalTop
	local gear = nil
	local gearService = servicesRef ~= nil and servicesRef.GearService or nil
	if gearService ~= nil then
		local ok, found = pcall(gearService.ForStand, slot.slotOnFloor)
		gear = if ok then found else nil
	end

	if gear == nil or gearService == nil then
		-- Past the end of the catalogue: leave the stand bare, as before.
		if top ~= nil then
			local gui = newBillboard(top, "ItemStandGui", 5, 2.4, 2.4, 60)
			local layoutGui = Instance.new("UIListLayout")
			layoutGui.FillDirection = Enum.FillDirection.Vertical
			layoutGui.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layoutGui.Parent = gui
			newLabel(gui, "Item Stand", COLOR_WHITE, 1, 0.5)
			newLabel(gui, "coming soon", Palette.SafeZone, 2, 0.34)
		end
		return
	end

	-- The item itself, standing on the plinth.
	if top ~= nil then
		local okDisplay, display = pcall(gearService.BuildDisplay, gear, "GearDisplay" .. tostring(slot.index))
		if okDisplay and display ~= nil then
			display.Parent = plot.model
			local _, size = display:GetBoundingBox()
			local tallest = math.max(size.X, size.Y, size.Z)
			if tallest > 0.01 then
				display:ScaleTo(GEAR_DISPLAY_HEIGHT / tallest)
			end
			local _, scaled = display:GetBoundingBox()
			display:PivotTo(
				top.CFrame * CFrame.new(0, top.Size.Y / 2 + GEAR_DISPLAY_LIFT + scaled.Y / 2, 0)
			)
		end

		local gui = newBillboard(top, "ItemStandGui", 6, 2.6, 5.4, 90)
		local layoutGui = Instance.new("UIListLayout")
		layoutGui.FillDirection = Enum.FillDirection.Vertical
		layoutGui.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layoutGui.Parent = gui
		newLabel(gui, gear.name, COLOR_WHITE, 1, 0.5)
		newLabel(gui, gear.blurb, Palette.SafeZone, 2, 0.34)
	end

	-- ...and the pad you step on to buy it, where a collect pad would go.
	local pad = newPart(
		plot.model,
		"GearPad" .. tostring(slot.index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		slotRecordFrame(plot, slot)
			* CFrame.new(0, slot.floorTop + PAD_LIFT + PAD_THICKNESS / 2, -PAD_FORWARD)
			* PAD_UPRIGHT,
		Palette.UnlockPad,
		Enum.Material.Neon
	)
	pad.Shape = Enum.PartType.Cylinder
	pad.CanCollide = false

	local padGui = newBillboard(pad, "GearPadGui", 5, 3.4, 3.2, 90)
	local padLayout = Instance.new("UIListLayout")
	padLayout.FillDirection = Enum.FillDirection.Vertical
	padLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	padLayout.Parent = padGui
	local priceLabel = newLabel(padGui, "Coming soon", COLOR_WHITE, 1, 0.46)
	newLabel(padGui, "step on to buy", Palette.SafeZone, 2, 0.3)

	-- The price is a web call. Spawned so a slow lookup never holds up the
	-- rest of the plot, and the label simply retexts when it lands.
	task.spawn(function()
		local okPrice, price = pcall(gearService.PriceAsync, gear)
		if okPrice and typeof(price) == "number" and priceLabel.Parent ~= nil then
			priceLabel.Text = ("R$ %d"):format(price)
			priceLabel.TextColor3 = COLOR_MONEY
		end
	end)

	table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
		if not isOwnerTouch(plot, hitPart) then
			return
		end
		local now = os.clock()
		if now - slot.lastTouch < TOUCH_DEBOUNCE then
			return
		end
		slot.lastTouch = now
		pcall(gearService.PromptPurchase, plot.player, gear)
	end))
end

-- ------------------------------------------------------------- levelling --

-- The yellow upgrade plaque: a rounded card with a fat black outline, an arrow
-- badge on the left and two stacked lines on the right — the big price and the
-- small "Lvl 4 > Lvl 5" step. Returns both labels so the caller can retext them.
local function buildUpgradePlaque(board: BasePart): (TextLabel, TextLabel, ImageLabel, Frame)
	-- Painted on the board itself, on both faces so it reads from either side.
	local gui = Instance.new("SurfaceGui")
	gui.Name = "UpgradeGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 64
	gui.LightInfluence = 0
	gui.Adornee = board
	gui.Parent = board
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = PLAQUE_YELLOW
	card.BorderSizePixel = 0
	-- Explicit ZIndex everywhere: a BillboardGui defaults to Global behaviour,
	-- where same-ZIndex siblings can paint over each other unpredictably — which
	-- is what was swallowing the level line.
	card.ZIndex = 1
	card.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.26, 0)
	corner.Parent = card

	local outline = Instance.new("UIStroke")
	outline.Thickness = 4
	outline.Color = Color3.new(0, 0, 0)
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Parent = card

	-- The reference draws a bare fat outlined arrow straight on the card, no
	-- badge box behind it. This is the pack's Upgrade icon, which already
	-- carries its own gold fill and black outline — so it is drawn untinted
	-- and only tinted grey when the owner cannot afford the level.
	local arrow = Instance.new("ImageLabel")
	arrow.Name = "Arrow"
	arrow.BackgroundTransparency = 1
	arrow.AnchorPoint = Vector2.new(0, 0.5)
	arrow.Position = UDim2.fromScale(0.03, 0.5)
	arrow.Size = UDim2.fromScale(0.22, 0.78)
	arrow.Image = Config.Icons.Upgrade
	arrow.ImageColor3 = PLAQUE_ARROW
	arrow.ScaleType = Enum.ScaleType.Fit
	arrow.ZIndex = 3
	arrow.Parent = card

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
	price.ZIndex = 3
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
	step.ZIndex = 3
	step.Parent = card

	return price, step, arrow, card
end

-- Greys the whole board out when the owner cannot afford the next level (or
-- the squishy is maxed), exactly like the reference: slate card, pale arrow,
-- the texts staying white. Flips back to yellow the moment they can.
local function updatePlaqueAffordability(plot: PlotRecord, slot: SlotRecord)
	local pad = slot.upgradePad
	local card = slot.upgradeCard
	if pad == nil or card == nil then
		return
	end
	local cost = Config.levelUpCost(slot.baseIncome, slot.rarity, slot.level)
	local money = tonumber(plot.player:GetAttribute("Money")) or 0
	local affordable = cost ~= nil and money >= cost

	-- Only the printed card is visible now (the board behind it is transparent),
	-- so the card and its arrow carry the whole affordable/not state.
	card.BackgroundColor3 = affordable and PLAQUE_YELLOW or PLAQUE_GREY
	local arrow = slot.upgradeArrow
	if arrow ~= nil then
		arrow.ImageColor3 = affordable and PLAQUE_ARROW or PLAQUE_ARROW_GREY
	end
end

-- Refreshes the squishy's own billboard and the upgrade pad's price line to
-- match its current level.
local function refreshSlotLevel(plot: PlotRecord, slot: SlotRecord)
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

	updatePlaqueAffordability(plot, slot)
end

-- One level, however it was asked for. Both the click and the walk-into path
-- land here so they share the debounce, the ownership check and the spend.
local function tryUpgrade(plot: PlotRecord, slot: SlotRecord, buyer: Player)
	if not slot.occupied or buyer ~= plot.player then
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
		return -- can't afford it; the board just does nothing
	end
	slot.level += 1
	refreshSlotLevel(plot, slot)
end

-- The yellow "upgrade" step in front of an occupied slot. Built once per slot
-- and then only shown/hidden, so replacing a squishy never stacks pads.
local function showUpgradePad(plot: PlotRecord, slot: SlotRecord)
	local pad = slot.upgradePad
	if pad == nil then
		-- The plaque is a real board standing just above the collect pad, not a
		-- BillboardGui: a billboard here kept losing its depth fight with the
		-- slot platform behind it, and printing on a surface is what already
		-- works for the money on the pad below.
		-- Mounted on the podium's front edge, standing just above its surface,
		-- the way the reference fixes the sign to the platform rather than
		-- leaving it floating between the podium and the pad.
		local platformTop = slot.floorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y
		pad = newPart(
			plot.model,
			"UpgradePad" .. tostring(slot.index),
			Vector3.new(UPGRADE_PLAQUE_SIZE.X, UPGRADE_PLAQUE_SIZE.Y, 0.35),
			slotRecordFrame(plot, slot)
				* CFrame.new(
					0,
					platformTop + UPGRADE_PLAQUE_SIZE.Y / 2 + PLAQUE_STAND_OFF,
					-(PLATFORM_SIZE.Z / 2 + PLAQUE_FRONT_OFFSET)
				),
			PLAQUE_YELLOW,
			Enum.Material.SmoothPlastic
		)
		pad.CanCollide = false
		-- The board itself is invisible: only the rounded card printed on its
		-- front should read, and the part's square edges were showing around
		-- and behind it. A SurfaceGui still draws on a fully transparent part,
		-- and the part stays for the ClickDetector and the surface to print on.
		pad.Transparency = 1
		pad.CastShadow = false
		local price, step, arrow, card = buildUpgradePlaque(pad)
		slot.upgradeLabel = price
		slot.upgradeStepLabel = step
		slot.upgradeArrow = arrow
		slot.upgradeCard = card
		slot.upgradePad = pad

		-- Click it from anywhere in the room, or just walk into it.
		local click = Instance.new("ClickDetector")
		click.Name = "UpgradeClick"
		click.MaxActivationDistance = 40
		click.Parent = pad
		table.insert(plot.connections, click.MouseClick:Connect(function(clicker: Player)
			tryUpgrade(plot, slot, clicker)
		end))
	end
	-- The board stays invisible; only the printed card is ever meant to show,
	-- so showing and hiding is the SurfaceGui's job now, not the part's.
	-- CanTouch stays off: the plaque is deliberately click-only, so brushing
	-- past a slot can never buy a level by accident.
	pad.CanTouch = false
	local gui = pad:FindFirstChild("UpgradeGui")
	if gui ~= nil and gui:IsA("SurfaceGui") then
		gui.Enabled = true
	end
	refreshSlotLevel(plot, slot)
end

-- Empties one slot: the squishy, its pending cash, its level and its plaque.
-- The slot itself stays unlocked and keeps its furniture, so it is ready to
-- take another squishy immediately.
local function clearSlot(plot: PlotRecord, slot: SlotRecord)
	if slot.squishy ~= nil then
		slot.squishy:Destroy()
	end
	slot.squishy = nil
	slot.occupied = false
	refreshPlacePrompt(slot)
	slot.pending = 0
	slot.income = 0
	slot.baseIncome = 0
	slot.level = 1
	local pad = slot.upgradePad
	if pad ~= nil then
		pad.CanTouch = false
		local gui = pad:FindFirstChild("UpgradeGui")
		if gui ~= nil and gui:IsA("SurfaceGui") then
			gui.Enabled = false
		end
	end
	updateCollectLabel(plot, slot)
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
	-- Stands on the pedestal's abacus, not the platform itself, and turned to
	-- face into the room rather than at the back wall.
	model:PivotTo(
		slot.platform.CFrame
			* CFrame.new(0, slot.platform.Size.Y / 2 + PEDESTAL_HEIGHT + height / 2, 0)
			* CFrame.Angles(0, math.pi, 0)
	)
	slot.occupied = true
	refreshPlacePrompt(slot)
	slot.pending = 0
	slot.level = 1
	slot.rarity = (model:GetAttribute("Rarity") :: string?) or "Common"
	-- A squishy that lands on the plot without ever being carried (a wheel
	-- prize, a steal) still counts as found, variant page and all.
	if servicesRef ~= nil and servicesRef.DiscoveryService ~= nil then
		pcall(function()
			servicesRef.DiscoveryService.MarkDiscovered(plot.player, def.name, def.variant)
		end)
	end
	-- Level 1 income is what the factory stamped (variant multiplier included);
	-- every level after that is derived from it.
	slot.baseIncome = (model:GetAttribute("Income") :: number?) or 0
	slot.income = slot.baseIncome
	slot.squishy = model
	updateCollectLabel(plot, slot)
	showUpgradePad(plot, slot)
end

-- ------------------------------------------------------------- placing --

-- Hold E at a pedestal to stand the carried squishy on that one.
local function onPlacePrompt(plot: PlotRecord, slot: SlotRecord, player: Player)
	if player ~= plot.player then
		return -- only the owner fills their own slots
	end
	if not slot.unlocked or slot.occupied then
		return
	end
	local def = servicesRef.SquishyService.TakeCarriedDef(player)
	if def == nil then
		return -- not carrying anything
	end
	local ok, err = pcall(placeSquishy, plot, slot, def)
	if not ok then
		warn(("[PlotService] failed to place squishy for %s: %s"):format(player.Name, tostring(err)))
	end
end

-- The prompt that puts a carried squishy on THIS pedestal. Lives on the abacus
-- so it reads at the height the squishy will stand, not down at floor level.
local function createPlacePrompt(plot: PlotRecord, slot: SlotRecord)
	local anchor = slot.pedestalTop or slot.platform
	if anchor == nil then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PlacePrompt"
	prompt.ActionText = "Place"
	prompt.ObjectText = "Pedestal"
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	slot.placePrompt = prompt
	refreshPlacePrompt(slot)

	table.insert(plot.connections, prompt.Triggered:Connect(function(player: Player)
		onPlacePrompt(plot, slot, player)
	end))
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

-- ------------------------------------------------------- hand-edited shells --
-- Saved base buildings live in Workspace.PlotShells, put there by
-- tools/build_plots_in_studio.luau and edited by hand in Studio. They are the
-- plot equivalent of Workspace.Map's HandEdited switch: when a shell is saved
-- for a spot, the generator stands down and the saved building is used instead.
--
-- Saved shells are the SOURCE; Workspace.Plots stays the runtime folder. Keeping
-- them apart means a live plot being built, rebuilt or destroyed never touches
-- the thing the owner has been editing.

local SHELL_FOLDER = "PlotShells"
local shellsMissingWarned = false
local shellFolder: Instance? = nil

-- The shells are a SOURCE, not scenery, and this moves them out of the world.
--
-- They have to be AUTHORED in Workspace — that is the only place you can edit
-- them — but they are built at the very coordinates the live plots occupy, so
-- left there at run time every base renders twice: a static shell z-fighting
-- the live one, its frozen "$0" sitting on top of the real collect-pad total.
-- Moving the folder to ServerStorage keeps it readable for cloning, stops it
-- replicating to anyone, and leaves the Studio copy exactly where it is.
local function claimShellFolder()
	local inWorld = workspace:FindFirstChild(SHELL_FOLDER)
	if inWorld ~= nil then
		inWorld.Parent = ServerStorage
		shellFolder = inWorld
		return
	end
	shellFolder = ServerStorage:FindFirstChild(SHELL_FOLDER)
end

-- The saved shell for a spot, or nil if there is not a usable one.
local function findSavedShell(spotIndex: number): Model?
	local folder = shellFolder
	if folder == nil or folder:GetAttribute("HandEdited") ~= true then
		return nil
	end
	local builder = getBaseBuilder()
	if builder == nil then
		return nil
	end
	local attrs = (builder :: any).ShellAttributes
	if attrs == nil then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and tonumber(child:GetAttribute(attrs.SpotIndex)) == spotIndex then
			return child
		end
	end
	return nil
end

-- Copies the saved shell for `spotIndex` into `model` and reads its shell data
-- back. Returns (false, nil) when there is nothing saved for this spot, or when
-- what is saved was built for a different floor count — the caller then
-- generates as usual.
--
-- Mirrors pcall's shape so the call site can fall through to builder.Build
-- without special-casing.
local function adoptSavedShell(builder: any, model: Model, spotIndex: number, floors: any): (boolean, any)
	if typeof(builder.Adopt) ~= "function" then
		return false, nil
	end
	local saved = findSavedShell(spotIndex)
	if saved == nil then
		return false, nil
	end

	local ok, shell = pcall(function()
		-- Copy in, rather than reparenting: the saved shell has to survive to
		-- serve the next player who claims this spot.
		local copy = saved:Clone()
		-- The tool's stamps (spot, floors, footprint, layout version) live on
		-- the shell MODEL itself, and only its children are transplanted — so
		-- the attributes must ride across too, or Adopt reads blanks. Reading
		-- blanks is what quietly kept any multi-storey shell from ever serving
		-- its owner (floors read 0/0) and refused every layout-version check.
		for name, value in copy:GetAttributes() do
			model:SetAttribute(name, value)
		end
		for _, child in copy:GetChildren() do
			child.Parent = model
		end
		copy:Destroy()
		return builder.Adopt(model, floors)
	end)

	if not ok then
		warn(("[PlotService] saved shell for spot %d failed to adopt: %s"):format(spotIndex, tostring(shell)))
		model:ClearAllChildren()
		return false, nil
	end
	if shell == nil then
		-- Saved at a different storey count, so its walls and stairs are cut for
		-- floors this owner does not have. Generating is the only correct move.
		if not shellsMissingWarned then
			shellsMissingWarned = true
			warn(
				("[PlotService] spot %d has a saved shell built for a different floor count, so it was generated instead. Re-run tools/build_plots_in_studio.luau to re-save the shells at the floor count you want to edit."):format(
					spotIndex
				)
			)
		end
		model:ClearAllChildren()
		return false, nil
	end
	return true, shell
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
		local floors = { above = above, below = below }
		-- A shell saved in the place wins over a generated one, exactly as a
		-- hand-edited Map wins over generated geometry.
		local ok, shell = adoptSavedShell(builder, model, spotIndex, floors)
		if ok then
			-- Shells are saved unowned, so a claimed plot swaps the vacant sign
			-- for the house marker and the owner's board.
			if typeof(builder.DressForOwner) == "function" then
				local dressed, dressErr = pcall(builder.DressForOwner, model, baseCFrame, player, floors)
				if not dressed then
					warn(("[PlotService] dressing saved shell for %s failed: %s"):format(player.Name, tostring(dressErr)))
				end
			end
		else
			ok, shell = pcall(builder.Build, player, model, baseCFrame, floors)
		end
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

	local plot: PlotRecord = {
		player = player,
		spotIndex = spotIndex,
		spotCFrame = spotCFrame,
		baseCFrame = baseCFrame,
		model = model,
		floorTop = floorTop,
		spawnPoint = spawnPoint,
		slots = {},
		connections = {},
	}

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
		local layout = slotLayout(index, floorTops, groundIndex, floorTop)
		local slotFloorTop = layout.floorTop
		local frame = slotFrame(baseCFrame, layout)
		local isItem = layout.isItemFloor
		-- Ground floor: the usual staged unlock. Any other floor was paid for
		-- as a whole, so every slot on it is open from the moment it exists —
		-- including the basement's item stands, which are "open" but never
		-- placeable (isItemSlot keeps them out of findFreeSlot).
		local unlocked = if layout.isGroundFloor
			then layout.slotOnFloor <= (Config.Plot.StartUnlocked :: number)
			else true
		-- Each slot reads as a tile: a darker border slab flat on the floor with
		-- the grey platform sitting on top of it. All three pieces are reused
		-- when they came in on a hand-edited shell, so what the owner saved is
		-- what the plot gets.
		local border = existingPart(model, "SlotBorder" .. tostring(index))
			or newPart(
				model,
				"SlotBorder" .. tostring(index),
				Vector3.new(
					PLATFORM_SIZE.X + PLATFORM_BORDER_OVERHANG,
					PLATFORM_BORDER_THICKNESS,
					PLATFORM_SIZE.Z + PLATFORM_BORDER_OVERHANG
				),
				frame * CFrame.new(0, slotFloorTop + PLATFORM_BORDER_THICKNESS / 2, 0),
				Palette.SlotBorder,
				Enum.Material.SmoothPlastic
			)
		border.CanCollide = false
		border.CanTouch = false
		border.CanQuery = false
		local platform = existingPart(model, "SlotPlatform" .. tostring(index))
			or newPart(
				model,
				"SlotPlatform" .. tostring(index),
				PLATFORM_SIZE,
				frame * CFrame.new(0, slotFloorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y / 2, 0),
				Palette.SlotPlatform,
				Enum.Material.SmoothPlastic
			)
		-- Colour always comes from code, edited shell or not: it is how a locked
		-- slot is told apart from an open one, which is gameplay, not decoration.
		-- Item stands take the cool pastel so the basement reads as a different
		-- kind of floor the moment you climb down into it.
		platform.Color = if isItem
			then Palette.SafeZone
			else (unlocked and Palette.SlotPlatform or Palette.SlotBorder)

		-- The column stands on every slot, taken or not: an empty one reads as
		-- a place a squishy belongs rather than a bare tile.
		local pedestalTop: BasePart? = existingPart(model, "PedestalAbacus" .. tostring(index))
		if pedestalTop == nil then
			local built, top = pcall(
				buildPedestal,
				model,
				frame * CFrame.new(0, slotFloorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y, 0),
				index
			)
			pedestalTop = if built then top else nil
		end

		-- A pad inherited for a slot that is still locked is parked out of
		-- sight rather than deleted: deleting would lose the owner's edit, and
		-- createCollectPad brings this one back the moment the slot opens.
		if not unlocked then
			local inherited = existingPart(model, "CollectPad" .. tostring(index))
			if inherited ~= nil then
				inherited.Transparency = 1
				inherited.CanTouch = false
				local rim = inherited:FindFirstChild("Rim")
				if rim ~= nil and rim:IsA("BasePart") then
					rim.Transparency = 1
				end
				local gui = inherited:FindFirstChild("PendingGui")
				if gui ~= nil and gui:IsA("SurfaceGui") then
					gui.Enabled = false
				end
			end
		end

		local slot: SlotRecord = {
			index = index,
			localX = layout.localX,
			localZ = layout.localZ,
			yaw = layout.yaw,
			floorTop = slotFloorTop,
			slotOnFloor = layout.slotOnFloor,
			isGroundFloor = layout.isGroundFloor,
			isItemSlot = isItem,
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
			upgradeArrow = nil,
			upgradeCard = nil,
			lastUpgradeTouch = 0,
			pending = 0,
			lastTouch = 0,
			platform = platform,
			collectPad = nil,
			collectLabel = nil,
			unlockPad = nil,
			unlockGui = nil,
			placePrompt = nil,
			pedestalTop = pedestalTop,
		}
		plot.slots[index] = slot
		if isItem then
			-- An item stand: the platform and pedestal, the gear standing on
			-- it and a pad in front that sells it. No place prompt, no collect
			-- pad, no unlock pad — a basement never holds squishies.
			dressGearStand(plot, slot)
		else
			createPlacePrompt(plot, slot)
			if unlocked then
				createCollectPad(plot, slot)
			else
				createUnlockPad(plot, slot)
			end
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

	-- Money moves constantly (collections, purchases); every change re-judges
	-- which plaques the owner can afford so they grey and un-grey live.
	table.insert(plot.connections, player:GetAttributeChangedSignal("Money"):Connect(function()
		for _, slot in plot.slots do
			if slot.occupied then
				pcall(updatePlaqueAffordability, plot, slot)
			end
		end
	end))
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
	-- Unclaimed spots show the saved shell too, so the street reads the same
	-- whether or not anyone is home.
	local zeroFloors = { above = 0, below = 0 }
	local ok, err = adoptSavedShell(builder, model, spotIndex, zeroFloors)
	if not ok then
		ok, err = pcall(builder.Build, nil, model, baseCFrame)
	end
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
		-- GROUND floor only. slotOnFloor is 1..SlotsPerFloor on every storey, so
		-- the old bound here was always true: a bought floor arrives with all ten
		-- slots open, which counted as ten ground-floor purchases and handed the
		-- player every remaining ground slot free on the next rebuild.
		if slot.unlocked and slot.isGroundFloor then
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
		if slot.isGroundFloor and not slot.unlocked and slot.slotOnFloor <= groundUnlocks then
			-- unlockSlot, not a bare flag. Setting `unlocked` alone leaves the
			-- padlock standing and never builds a collect pad, so a slot the
			-- player had already paid for came back looking locked and quietly
			-- accrued its income into a pad that does not exist.
			pcall(unlockSlot, fresh, slot)
		end
	end
	local index = 1
	for _, slot in fresh.slots do
		local entry = saved[index]
		if entry == nil then
			break
		end
		if slot.unlocked and not slot.occupied and not slot.isItemSlot and entry.squishyName ~= nil then
			local def = Config.SquishyByName[entry.squishyName]
			if def ~= nil then
				local defCopy = table.clone(def)
				defCopy.variant = entry.variant
				local placedOk = pcall(placeSquishy, fresh, slot, defCopy)
				if placedOk then
					slot.level = entry.level or 1
					slot.pending = entry.pending or 0
					refreshSlotLevel(fresh, slot)
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
		-- Beside the ladder at the back of the aisle: the wall lines took the
		-- old right-back corner, and next-floor belongs next to the way up.
		plot.baseCFrame * CFrame.new(8, plot.floorTop + 3, footprint.Y / 2 - 4),
		Palette.UnlockPad,
		Enum.Material.Neon
	)
	post.CanCollide = false
	post.CanTouch = true

	-- The prompt only shows its text once you are within 12 studs; the padlock
	-- floating over the post is what marks it from across the base.
	local postGui = newBillboard(post, "FloorIcon", 3.4, 3.4, 4.2, 120)
	newIcon(postGui, Config.Icons.Lock, 0, 1)

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
			-- The post goes invisible at the last floor; a billboard is not a
			-- face of the part, so it has to be switched off by hand or a
			-- padlock is left hanging in mid-air over nothing.
			postGui.Enabled = false
			return
		end
		prompt.Enabled = true
		post.Transparency = 0
		postGui.Enabled = true
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
	-- Before any plot is built: the shells must be out of the world by the time
	-- anything clones them, or the world shows two of every base.
	claimShellFolder()
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
	refreshSlotLevel(thiefPlot, target)
	updateCollectLabel(thiefPlot, target)

	-- Clear the victim's slot: the squishy, its pending cash and its pad.
	clearSlot(victimPlot, victimSlot)
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

-- Builds the static slot furniture for one base — tile borders, platforms,
-- pedestals and collect-pad discs — with no handlers and no state.
--
-- This is what tools/build_plots_in_studio.luau calls so a saved shell contains
-- the collectors and pillars, not just the building. At run time the slot loop
-- finds these by name and reuses them, so moving a pedestal in Studio moves it
-- in the live game.
--
-- Every slot gets a pad here, including ones that will start locked: the shell
-- has no idea whose plot it will become, and a locked slot's pad is hidden at
-- run time rather than deleted.
function PlotService.BuildSlotFurniture(model: Model, baseCFrame: CFrame, floorTops: { number }, groundIndex: number)
	local slotsPerRow = Config.Plot.SlotsPerRow :: number
	local rowsPerFloor = math.max(1, Config.Plot.RowsPerFloor :: number)
	local slotsPerFloor = slotsPerRow * rowsPerFloor
	local fallbackTop = floorTops[groundIndex] or DEFAULT_FLOOR_TOP

	for index = 1, slotsPerFloor * #floorTops do
		local layout = slotLayout(index, floorTops, groundIndex, fallbackTop)
		local frame = slotFrame(baseCFrame, layout)
		local tag = tostring(index)

		local border = newPart(
			model,
			"SlotBorder" .. tag,
			Vector3.new(
				PLATFORM_SIZE.X + PLATFORM_BORDER_OVERHANG,
				PLATFORM_BORDER_THICKNESS,
				PLATFORM_SIZE.Z + PLATFORM_BORDER_OVERHANG
			),
			frame * CFrame.new(0, layout.floorTop + PLATFORM_BORDER_THICKNESS / 2, 0),
			Palette.SlotBorder,
			Enum.Material.SmoothPlastic
		)
		border.CanCollide = false
		border.CanTouch = false
		border.CanQuery = false

		newPart(
			model,
			"SlotPlatform" .. tag,
			PLATFORM_SIZE,
			frame * CFrame.new(0, layout.floorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y / 2, 0),
			Palette.SlotPlatform,
			Enum.Material.SmoothPlastic
		)

		buildPedestal(
			model,
			frame * CFrame.new(0, layout.floorTop + PLATFORM_BORDER_THICKNESS + PLATFORM_SIZE.Y, 0),
			index
		)

		-- Item floors keep their stands bare: no collect pad to inherit.
		if not layout.isItemFloor then
			local pad = buildCollectPadGeometry(model, frame, index, layout.floorTop)
			ensurePendingLabel(pad)
		end
	end
end

-- ------------------------------------------------------------------- debug --
-- Entry points for DebugService (Studio only). Nothing in the shipped game
-- calls these; they exist so the dev panel can drive plot state without
-- reaching into the private tables of this module.

-- Opens every still-locked slot on the plot, free. Returns how many opened.
function PlotService.DebugUnlockAll(player: Player): number
	local plot = plots[player]
	if plot == nil then
		return 0
	end
	local opened = 0
	for _, slot in plot.slots do
		if not slot.unlocked then
			local ok, err = pcall(unlockSlot, plot, slot)
			if ok then
				opened += 1
			else
				warn(("[PlotService] debug unlock of slot %d failed: %s"):format(slot.index, tostring(err)))
			end
		end
	end
	return opened
end

-- Empties every occupied slot, binning the squishies and their pending cash.
function PlotService.DebugClearSlots(player: Player): number
	local plot = plots[player]
	if plot == nil then
		return 0
	end
	local cleared = 0
	for _, slot in plot.slots do
		if slot.occupied then
			local ok, err = pcall(clearSlot, plot, slot)
			if ok then
				cleared += 1
			else
				warn(("[PlotService] debug clear of slot %d failed: %s"):format(slot.index, tostring(err)))
			end
		end
	end
	return cleared
end

-- Sets the storey counts and rebuilds the base around them, exactly as buying
-- a floor does. Placed squishies and their levels ride through the rebuild;
-- shrinking past what is placed drops whatever no longer has a slot.
function PlotService.DebugSetFloors(player: Player, above: number, below: number): boolean
	if plots[player] == nil then
		return false
	end
	player:SetAttribute("FloorsAbove", math.clamp(math.floor(above), 0, Config.Plot.MaxAbove :: number))
	player:SetAttribute("FloorsBelow", math.clamp(math.floor(below), 0, Config.Plot.MaxBelow :: number))
	rebuildPlot(player)
	return true
end

-- What the dev panel prints in its status block.
function PlotService.DebugSnapshot(player: Player): any
	local plot = plots[player]
	if plot == nil then
		return nil
	end
	-- Item stands are counted apart: "open slots" means places a squishy can go.
	local slots, unlocked, occupied, income, pending, itemSlots = 0, 0, 0, 0, 0, 0
	for _, slot in plot.slots do
		if slot.isItemSlot then
			itemSlots += 1
			continue
		end
		slots += 1
		if slot.unlocked then
			unlocked += 1
		end
		if slot.occupied then
			occupied += 1
			income += slot.income
			pending += slot.pending
		end
	end
	local above, below = floorCounts(player)
	return {
		spotIndex = plot.spotIndex,
		slots = slots,
		itemSlots = itemSlots,
		unlocked = unlocked,
		occupied = occupied,
		income = income,
		pending = pending,
		floorsAbove = above,
		floorsBelow = below,
	}
end

return PlotService
