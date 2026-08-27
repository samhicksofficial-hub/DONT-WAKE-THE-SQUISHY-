--!strict
-- PlotService: claims a plot spot per player, builds the plot structure
-- (floor, low walls, owner sign, slot platforms, collect/unlock pads, deposit
-- pad), runs the income accrual loop, and handles deposit / collect / unlock
-- touches. See DESIGN.md gameplay rules 2, 3, 4 and 6.
--
-- Plot local space (the spot CFrame's LookVector faces the field, so -Z is
-- the plot FRONT toward the walkway and +Z is the BACK):
--   z = -14   deposit pad (front edge)
--   z =  -5   front-row collect pads    z =  1   front-row platforms (slots 1-5)
--   z =   7   back-row collect pads     z = 13   back-row platforms  (slots 6-10)
--   z = 17.5  back wall + owner sign
-- The front row is staggered +4 studs in X so the back row's pads stay
-- reachable between the front platforms.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local SquishyFactory = require(Shared:WaitForChild("SquishyFactory"))

local FLOOR_TOP = 1.2 -- slab top slightly above the walkway (y = 1)
local WALL_HEIGHT = 3
local WALL_THICKNESS = 1
local TOUCH_DEBOUNCE = 0.4

local SLOT_SPACING = 8
local FRONT_ROW_STAGGER = 4
local FRONT_ROW_Z = 1
local ROW_DEPTH = 12
local PLATFORM_SIZE = Vector3.new(6, 0.4, 6)
local PAD_DIAMETER = 5
local PAD_THICKNESS = 0.3
local PAD_FORWARD = 6 -- pad center sits this far in front of its platform center
local DEPOSIT_SIZE = Vector3.new(10, 0.4, 6)

local COLOR_FLOOR = Color3.fromRGB(184, 158, 122)
local COLOR_WALL = Color3.fromRGB(146, 120, 96)
local COLOR_SIGN = Color3.fromRGB(255, 214, 120)
local COLOR_PLATFORM = Color3.fromRGB(163, 162, 168)
local COLOR_PLATFORM_LOCKED = Color3.fromRGB(84, 84, 92)
local COLOR_COLLECT_PAD = Color3.fromRGB(85, 255, 85)
local COLOR_DEPOSIT_PAD = Color3.fromRGB(60, 235, 100)
local COLOR_UNLOCK_PAD = Color3.fromRGB(255, 170, 0)
local COLOR_MONEY = Color3.fromRGB(85, 255, 85)
local COLOR_REFUSE = Color3.fromRGB(255, 70, 70)
local COLOR_WHITE = Color3.new(1, 1, 1)

-- Cylinder parts extend along their X axis; this stands them upright.
local PAD_UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

type SlotRecord = {
	index: number,
	localX: number,
	localZ: number,
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

local function updateCollectLabel(slot: SlotRecord)
	local label = slot.collectLabel
	if label == nil then
		return
	end
	local shown = math.floor(slot.pending)
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
	servicesRef.EconomyService.AddMoney(plot.player, amount)
	local pad = slot.collectPad
	if pad ~= nil then
		popupRemote:FireClient(plot.player, amount, pad.Position)
	end
	updateCollectLabel(slot)
end

local function createCollectPad(plot: PlotRecord, slot: SlotRecord)
	local cf = plot.baseCFrame
		* CFrame.new(slot.localX, FLOOR_TOP + PAD_THICKNESS / 2, slot.localZ - PAD_FORWARD)
		* PAD_UPRIGHT
	local pad = newPart(
		plot.model,
		"CollectPad" .. tostring(slot.index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		cf,
		COLOR_COLLECT_PAD,
		Enum.Material.Neon
	)
	pad.Shape = Enum.PartType.Cylinder
	pad.CanCollide = false
	local gui = newBillboard(pad, "PendingGui", 4.5, 1.8, 2.2, 90)
	slot.collectPad = pad
	slot.collectLabel = newLabel(gui, "$0", COLOR_MONEY, 1, 1)
	updateCollectLabel(slot)
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
	slot.platform.Color = COLOR_PLATFORM
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
		* CFrame.new(slot.localX, FLOOR_TOP + PAD_THICKNESS / 2, slot.localZ - PAD_FORWARD)
		* PAD_UPRIGHT
	local pad = newPart(
		plot.model,
		"UnlockPad" .. tostring(slot.index),
		Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
		cf,
		COLOR_UNLOCK_PAD,
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
	local model = SquishyFactory.create(def.name)
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
	updateCollectLabel(slot)
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
			pad.Color = COLOR_DEPOSIT_PAD
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

-- ---------------------------------------------------------------- plot build --

-- Returns true once the plot is registered.
local function buildPlot(player: Player, spotIndex: number): boolean
	local spotCFrame = mapRef.plotSpots[spotIndex] :: CFrame
	local spotPos = spotCFrame.Position
	local baseCFrame = CFrame.new(spotPos.X, 0, spotPos.Z) * spotCFrame.Rotation

	local footprint = Config.Plot.BaseSize :: Vector2
	local halfWidth = footprint.X / 2
	local halfDepth = footprint.Y / 2

	local model = Instance.new("Model")
	model.Name = player.Name

	-- Floor slab, top at FLOOR_TOP.
	newPart(
		model,
		"Floor",
		Vector3.new(footprint.X, FLOOR_TOP, footprint.Y),
		baseCFrame * CFrame.new(0, FLOOR_TOP / 2, 0),
		COLOR_FLOOR,
		Enum.Material.SmoothPlastic
	)

	-- Low back wall and side walls; the front stays open toward the walkway.
	newPart(
		model,
		"BackWall",
		Vector3.new(footprint.X, WALL_HEIGHT, WALL_THICKNESS),
		baseCFrame * CFrame.new(0, FLOOR_TOP + WALL_HEIGHT / 2, halfDepth - WALL_THICKNESS / 2),
		COLOR_WALL,
		Enum.Material.SmoothPlastic
	)
	for _, sideOffset in { -1, 1 } do
		newPart(
			model,
			sideOffset < 0 and "LeftWall" or "RightWall",
			Vector3.new(WALL_THICKNESS, WALL_HEIGHT, footprint.Y),
			baseCFrame * CFrame.new(sideOffset * (halfWidth - WALL_THICKNESS / 2), FLOOR_TOP + WALL_HEIGHT / 2, 0),
			COLOR_WALL,
			Enum.Material.SmoothPlastic
		)
	end

	-- Owner sign above the back wall.
	local signPart = newPart(
		model,
		"OwnerSign",
		Vector3.new(2, 2, 1),
		baseCFrame * CFrame.new(0, FLOOR_TOP + WALL_HEIGHT + 2.5, halfDepth - WALL_THICKNESS / 2),
		COLOR_SIGN,
		Enum.Material.SmoothPlastic
	)
	signPart.CanCollide = false
	local signGui = newBillboard(signPart, "OwnerGui", 13, 3, 2.2, 160)
	newLabel(signGui, ("%s's Plot"):format(player.DisplayName), COLOR_WHITE, 1, 1)

	-- Deposit pad at the front edge, facing the walkway.
	local depositPad = newPart(
		model,
		"DepositPad",
		DEPOSIT_SIZE,
		baseCFrame * CFrame.new(0, FLOOR_TOP + DEPOSIT_SIZE.Y / 2, -(halfDepth - 4)),
		COLOR_DEPOSIT_PAD,
		Enum.Material.Neon
	)
	depositPad.CanCollide = false
	local depositGui = newBillboard(depositPad, "DepositGui", 6, 2, 2.8, 110)
	newLabel(depositGui, "Deposit", COLOR_WHITE, 1, 1)

	local plot: PlotRecord = {
		player = player,
		spotIndex = spotIndex,
		spotCFrame = spotCFrame,
		baseCFrame = baseCFrame,
		model = model,
		slots = {},
		depositPad = depositPad,
		depositFlashing = false,
		lastDepositTouch = 0,
		connections = {},
	}

	table.insert(plot.connections, depositPad.Touched:Connect(function(hitPart: BasePart)
		onDepositTouched(plot, hitPart)
	end))

	-- Slot platforms in two staggered rows toward the back of the plot.
	local slotsPerRow = Config.Plot.SlotsPerRow :: number
	for index = 1, Config.Plot.SlotCount :: number do
		local row = math.floor((index - 1) / slotsPerRow)
		local col = (index - 1) % slotsPerRow
		local localX = (col - (slotsPerRow - 1) / 2) * SLOT_SPACING
			+ (row == 0 and FRONT_ROW_STAGGER or 0)
		local localZ = FRONT_ROW_Z + row * ROW_DEPTH
		local unlocked = index <= (Config.Plot.StartUnlocked :: number)
		local platform = newPart(
			model,
			"SlotPlatform" .. tostring(index),
			PLATFORM_SIZE,
			baseCFrame * CFrame.new(localX, FLOOR_TOP + PLATFORM_SIZE.Y / 2, localZ),
			unlocked and COLOR_PLATFORM or COLOR_PLATFORM_LOCKED,
			Enum.Material.SmoothPlastic
		)
		local slot: SlotRecord = {
			index = index,
			localX = localX,
			localZ = localZ,
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
	local ok, result = pcall(buildPlot, player, spotIndex)
	if not ok or result ~= true then
		spotUsed[spotIndex] = false
		if not ok then
			warn(("[PlotService] failed to build plot for %s: %s"):format(player.Name, tostring(result)))
		end
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
end

-- ------------------------------------------------------------------ accrual --

local function accruePlot(plot: PlotRecord, elapsed: number)
	for _, slot in plot.slots do
		if slot.occupied then
			slot.pending += slot.income * elapsed
			updateCollectLabel(slot)
		end
	end
end

-- -------------------------------------------------------------------- public --

function PlotService.Start(services: any, map: any)
	servicesRef = services
	mapRef = map
	popupRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Popup") :: RemoteEvent
	spotUsed = table.create(#(map.plotSpots :: { CFrame }), false)

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

return PlotService
