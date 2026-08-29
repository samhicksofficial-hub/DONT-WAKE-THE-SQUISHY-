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
	unlocked: boolean,
	occupied: boolean,
	income: number,
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
	local price = Config.Plot.UnlockPrices[slot.index] or 0
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
	local price = Config.Plot.UnlockPrices[slot.index] or 0
	newLabel(gui, Util.formatMoney(price), COLOR_MONEY, 1, 0.55)
	newLabel(gui, "Unlock", COLOR_WHITE, 2, 0.45)
	slot.unlockPad = pad
	slot.unlockGui = gui
	table.insert(plot.connections, pad.Touched:Connect(function(hitPart: BasePart)
		onUnlockTouched(plot, slot, hitPart)
	end))
end

-- ---------------------------------------------------------------- depositing --

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
	slot.income = (model:GetAttribute("Income") :: number?) or 0
	updateCollectLabel(plot, slot)
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
	local spawnPoint: BasePart? = nil
	local shellBuilt = false
	local builder = getBaseBuilder()
	if builder ~= nil then
		local ok, shell = pcall(builder.Build, player, model, baseCFrame)
		if ok and typeof(shell) == "table" then
			shellBuilt = true
			if typeof(shell.floorTop) == "number" then
				floorTop = shell.floorTop
			end
			-- One entry per storey; slots above the ground floor stand on these.
			if typeof(shell.floorTops) == "table" and #shell.floorTops > 0 then
				floorTops = shell.floorTops
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
	for index = 1, Config.Plot.SlotCount :: number do
		local floorIndex = math.floor((index - 1) / slotsPerFloor)
		local withinFloor = (index - 1) % slotsPerFloor
		local row = math.floor(withinFloor / slotsPerRow)
		local col = withinFloor % slotsPerRow
		-- Upper storeys stand on their own slab; fall back to the ground floor
		-- if the shell reported fewer floors than the config asks for.
		local slotFloorTop = floorTops[floorIndex + 1] or floorTop
		local localX = (col - (slotsPerRow - 1) / 2) * SLOT_SPACING
			+ (row == 0 and FRONT_ROW_STAGGER or 0)
		local localZ = FRONT_ROW_Z + row * ROW_DEPTH
		local unlocked = index <= (Config.Plot.StartUnlocked :: number)
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
			unlocked = unlocked,
			occupied = false,
			income = 0,
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
