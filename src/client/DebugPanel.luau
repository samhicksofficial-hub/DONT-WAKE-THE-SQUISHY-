--!strict
-- DebugPanel — the Studio-only dev overlay. F4 toggles it.
--
-- DELIBERATE EXCEPTION to the UI Contract: every other client module drives
-- the Essential UI Pack through UiRefs and builds no ScreenGui of its own.
-- This one builds its own, on purpose. It is a developer tool rather than game
-- UI: it is not in the pack, it has to keep working when the pack does not
-- (a broken pack is exactly when you want the panel), and it must never be
-- able to disturb the tree the real UI depends on.
--
-- The panel changes NOTHING itself. Every button sends a command name and a
-- payload to DebugService, which does the work server-side and sends back a
-- message plus a fresh snapshot. Outside Studio there is no remote to talk to
-- and Start bails, so nothing here ever builds in a published game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local DebugPanel = {}

local TOGGLE_KEY = Enum.KeyCode.F4
local REMOTE_NAME = "DebugCommand"
local PANEL_WIDTH = 322
local ROW_HEIGHT = 24
local HEADER_HEIGHT = 20
local GAP = 4
local POLL_SECONDS = 1

-- Deliberately NOT the FredokaOne the game UI uses: this is a wall of numbers
-- a developer reads, so it gets a monospace readout and a plain UI face.
local FONT_VALUE = Enum.Font.Code
local FONT_UI = Enum.Font.SourceSansBold

local COLOR_BG = Color3.fromRGB(16, 18, 24)
local COLOR_PANEL = Color3.fromRGB(26, 30, 38)
local COLOR_BUTTON = Color3.fromRGB(52, 60, 78)
local COLOR_TEXT = Color3.fromRGB(232, 236, 244)
local COLOR_DIM = Color3.fromRGB(148, 156, 172)
local COLOR_OK = Color3.fromRGB(120, 226, 140)
local COLOR_BAD = Color3.fromRGB(240, 124, 124)

local player = Players.LocalPlayer

local remote: RemoteFunction? = nil
local gui: ScreenGui? = nil
local statusLabel: TextLabel? = nil
local resultLabel: TextLabel? = nil
-- Labels the refresh writes into, keyed by what they show.
local dynamic: { [string]: TextLabel } = {}
-- The last snapshot DebugService sent back (plot summary, giants frozen).
local latest: any = nil
local rarityIndex = 1
local variantIndex = 1
local layoutOrder = 0

local rarityNames: { string } = {}
for _, rarity in Config.Rarities :: { any } do
	table.insert(rarityNames, rarity.name)
end
local variantNames: { string } = {}
for _, variant in Config.Variants :: { any } do
	table.insert(variantNames, variant.name)
end

local function nextOrder(): number
	layoutOrder += 1
	return layoutOrder
end

-- ------------------------------------------------------------------- widgets --

local function corner(instance: Instance, radius: number)
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, radius)
	round.Parent = instance
end

-- One full-width strip that lays its children out left to right.
local function newRow(parent: Instance, height: number): Frame
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, height)
	row.LayoutOrder = nextOrder()
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = row

	return row
end

local function newHeader(parent: Instance, text: string)
	local label = Instance.new("TextLabel")
	label.Name = "Header"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	label.LayoutOrder = nextOrder()
	label.Font = FONT_UI
	label.Text = text:upper()
	label.TextSize = 12
	label.TextColor3 = COLOR_DIM
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
end

-- `width` is a fraction of the row; the widths in one row should sum to 1.
local function newButton(row: Frame, text: string, width: number, onClick: () -> ()): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.AutoButtonColor = true
	button.BackgroundColor3 = COLOR_BUTTON
	button.BorderSizePixel = 0
	button.Size = UDim2.new(width, -GAP, 1, 0)
	button.LayoutOrder = nextOrder()
	button.Font = FONT_UI
	button.Text = text
	button.TextSize = 13
	button.TextColor3 = COLOR_TEXT
	button.Parent = row
	corner(button, 4)
	button.Activated:Connect(onClick)
	return button
end

-- A `key` makes the label one the refresh writes into (and draws it as a value
-- rather than a caption).
local function newLabel(row: Frame, text: string, width: number, key: string?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = key or "Caption"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(width, -GAP, 1, 0)
	label.LayoutOrder = nextOrder()
	label.Font = if key ~= nil then FONT_VALUE else FONT_UI
	label.Text = text
	label.TextSize = 13
	label.TextColor3 = if key ~= nil then COLOR_TEXT else COLOR_DIM
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row
	if key ~= nil then
		dynamic[key] = label
	end
	return label
end

-- ------------------------------------------------------------------ plumbing --

local function setResult(ok: boolean, message: string)
	local label = resultLabel
	if label == nil or message == "" then
		return
	end
	label.Text = message
	label.TextColor3 = if ok then COLOR_OK else COLOR_BAD
end

local function trackLevel(track: string): (number, number)
	local values = (Config.Upgrades :: any)[track].values
	local current = tonumber(player:GetAttribute("Upgrade_" .. track)) or 1
	return math.clamp(math.floor(current), 1, #values), #values
end

local function floorCounts(): (number, number)
	local above = tonumber(player:GetAttribute("FloorsAbove")) or 0
	local below = tonumber(player:GetAttribute("FloorsBelow")) or 0
	return math.floor(above), math.floor(below)
end

local function refresh()
	local status = statusLabel
	if status == nil then
		return
	end

	local money = tonumber(player:GetAttribute("Money")) or 0
	local rebirths = math.floor(tonumber(player:GetAttribute("Rebirths")) or 0)
	local multipliers = Config.Rebirth.Multipliers :: { number }
	local mult = multipliers[math.clamp(rebirths + 1, 1, #multipliers)]
	local spins = math.floor(tonumber(player:GetAttribute("Spins")) or 0)

	local speed, speedMax = trackLevel("Speed")
	local stealth, stealthMax = trackLevel("Stealth")
	local carry, carryMax = trackLevel("Carry")
	local above, below = floorCounts()

	local carrying = player:GetAttribute("Carrying")
	local carryLine = if typeof(carrying) == "string"
		then ("carrying %s (x%.2f speed)"):format(
			carrying,
			tonumber(player:GetAttribute("CarrySpeedMult")) or 1
		)
		else "carrying nothing"

	-- Two short lines rather than one long one: a maxed plot puts six-figure
	-- numbers in here, and a single line ran off the edge of the panel.
	local plot = if latest ~= nil then latest.plot else nil
	local plotLine = if plot ~= nil
		then ("plot %d   %d/%d open   %d filled"):format(
			plot.spotIndex,
			plot.unlocked,
			plot.slots,
			plot.occupied
		)
		else "no plot claimed yet"
	local incomeLine = if plot ~= nil
		then ("income %s/s   pending %s"):format(
			Util.formatMoney(plot.income),
			Util.formatMoney(plot.pending)
		)
		else "-"

	status.Text = table.concat({
		("%s   rebirth %d (x%s)   %d spin%s"):format(
			Util.formatMoney(money),
			rebirths,
			tostring(mult),
			spins,
			if spins == 1 then "" else "s"
		),
		("speed %d/%d   stealth %d/%d   carry %d/%d"):format(
			speed,
			speedMax,
			stealth,
			stealthMax,
			carry,
			carryMax
		),
		plotLine,
		incomeLine,
		("floors %d up / %d down   giants %s"):format(
			above,
			below,
			if latest ~= nil and latest.frozen then "FROZEN" else "running"
		),
		carryLine,
	}, "\n")

	if dynamic.Speed ~= nil then
		dynamic.Speed.Text = ("%d/%d"):format(speed, speedMax)
	end
	if dynamic.Stealth ~= nil then
		dynamic.Stealth.Text = ("%d/%d"):format(stealth, stealthMax)
	end
	if dynamic.Carry ~= nil then
		dynamic.Carry.Text = ("%d/%d"):format(carry, carryMax)
	end
	if dynamic.Rebirths ~= nil then
		dynamic.Rebirths.Text = tostring(rebirths)
	end
	if dynamic.Floors ~= nil then
		dynamic.Floors.Text = ("%d / %d"):format(above, below)
	end
	if dynamic.Rarity ~= nil then
		dynamic.Rarity.Text = rarityNames[rarityIndex]
	end
	if dynamic.Variant ~= nil then
		dynamic.Variant.Text = variantNames[variantIndex]
	end
end

local function send(command: string, payload: any?)
	local fn = remote
	if fn == nil then
		return
	end
	task.spawn(function()
		local ok, response = pcall(function()
			return fn:InvokeServer(command, payload)
		end)
		if not ok then
			setResult(false, tostring(response))
			return
		end
		if typeof(response) ~= "table" then
			setResult(false, "no response from DebugService")
			return
		end
		if response.snapshot ~= nil then
			latest = response.snapshot
		end
		-- The status poll would otherwise blank whatever the last button printed.
		if command ~= "status" then
			setResult(response.ok == true, tostring(response.message))
		end
		refresh()
	end)
end

-- What the rarity and variant cyclers currently point at.
local function selection(): any
	return { rarity = rarityNames[rarityIndex], variant = variantNames[variantIndex] }
end

-- Grows or shrinks the base the way buying a floor does: up, down, up, down.
local function stepFloors(delta: number)
	local above, below = floorCounts()
	local maxAbove = Config.Plot.MaxAbove :: number
	local maxBelow = Config.Plot.MaxBelow :: number
	if delta > 0 then
		if above <= below and above < maxAbove then
			above += 1
		elseif below < maxBelow then
			below += 1
		elseif above < maxAbove then
			above += 1
		end
	elseif delta < 0 then
		if below >= above and below > 0 then
			below -= 1
		elseif above > 0 then
			above -= 1
		end
	end
	send("floors", { above = above, below = below })
end

-- ---------------------------------------------------------------------- build --

local function buildUpgradeRow(parent: Instance, track: string)
	local row = newRow(parent, ROW_HEIGHT)
	newLabel(row, track, 0.3)
	newButton(row, "-", 0.14, function()
		send("upgrade", { track = track, delta = -1 })
	end)
	newLabel(row, "1/1", 0.22, track)
	newButton(row, "+", 0.14, function()
		send("upgrade", { track = track, delta = 1 })
	end)
	-- Clamped server-side to the length of the track, so any big number maxes it.
	newButton(row, "MAX", 0.2, function()
		send("upgrade", { track = track, level = 999 })
	end)
end

local function buildBody(parent: Instance)
	newHeader(parent, "cash")
	local cash = newRow(parent, ROW_HEIGHT)
	for _, entry in { { "+1k", 1e3 }, { "+100k", 1e5 }, { "+10M", 1e7 }, { "+1B", 1e9 } } do
		newButton(cash, entry[1] :: string, 0.2, function()
			send("cash", { delta = entry[2] })
		end)
	end
	newButton(cash, "ZERO", 0.2, function()
		send("cash", { set = 0 })
	end)

	newHeader(parent, "progress")
	buildUpgradeRow(parent, "Speed")
	buildUpgradeRow(parent, "Stealth")
	buildUpgradeRow(parent, "Carry")

	local progress = newRow(parent, ROW_HEIGHT)
	newButton(progress, "Max all", 0.34, function()
		send("upgrade", { maxAll = true })
	end)
	newLabel(progress, "Rebirth", 0.26)
	newButton(progress, "-", 0.12, function()
		send("rebirth", { delta = -1 })
	end)
	newLabel(progress, "0", 0.14, "Rebirths")
	newButton(progress, "+", 0.12, function()
		send("rebirth", { delta = 1 })
	end)

	newHeader(parent, "squishy")
	local rarityRow = newRow(parent, ROW_HEIGHT)
	newLabel(rarityRow, "Rarity", 0.24)
	newButton(rarityRow, "<", 0.14, function()
		rarityIndex = (rarityIndex - 2) % #rarityNames + 1
		refresh()
	end)
	newLabel(rarityRow, rarityNames[1], 0.48, "Rarity")
	newButton(rarityRow, ">", 0.14, function()
		rarityIndex = rarityIndex % #rarityNames + 1
		refresh()
	end)

	local variantRow = newRow(parent, ROW_HEIGHT)
	newLabel(variantRow, "Variant", 0.24)
	newButton(variantRow, "<", 0.14, function()
		variantIndex = (variantIndex - 2) % #variantNames + 1
		refresh()
	end)
	newLabel(variantRow, variantNames[1], 0.48, "Variant")
	newButton(variantRow, ">", 0.14, function()
		variantIndex = variantIndex % #variantNames + 1
		refresh()
	end)

	local squishyRow = newRow(parent, ROW_HEIGHT)
	newButton(squishyRow, "Give to hands", 0.4, function()
		send("give", selection())
	end)
	newButton(squishyRow, "Drop", 0.22, function()
		send("drop")
	end)
	newButton(squishyRow, "Spawn in field", 0.38, function()
		send("spawnField", selection())
	end)

	newHeader(parent, "plot")
	local plotRow = newRow(parent, ROW_HEIGHT)
	newButton(plotRow, "Place 1", 0.28, function()
		local payload = selection()
		payload.count = 1
		send("place", payload)
	end)
	newButton(plotRow, "Fill every slot", 0.44, function()
		local payload = selection()
		payload.count = 120
		send("place", payload)
	end)
	newButton(plotRow, "Clear", 0.28, function()
		send("clearPlot")
	end)

	local slotRow = newRow(parent, ROW_HEIGHT)
	newButton(slotRow, "Unlock all slots", 0.4, function()
		send("unlockAll")
	end)
	newLabel(slotRow, "Floors", 0.16)
	newButton(slotRow, "-", 0.12, function()
		stepFloors(-1)
	end)
	newLabel(slotRow, "0 / 0", 0.2, "Floors")
	newButton(slotRow, "+", 0.12, function()
		stepFloors(1)
	end)

	newHeader(parent, "giants")
	local enemyRow = newRow(parent, ROW_HEIGHT)
	newButton(enemyRow, "Freeze", 0.25, function()
		send("enemies", { action = "freeze" })
	end)
	newButton(enemyRow, "Unfreeze", 0.25, function()
		send("enemies", { action = "thaw" })
	end)
	newButton(enemyRow, "Aggro me", 0.25, function()
		send("enemies", { action = "wake" })
	end)
	newButton(enemyRow, "Calm", 0.25, function()
		send("enemies", { action = "calm" })
	end)

	newHeader(parent, "world")
	local tpRow = newRow(parent, ROW_HEIGHT)
	for _, where in { "field", "plot", "board" } do
		newButton(tpRow, "TP " .. where, 1 / 3, function()
			send("teleport", { where = where })
		end)
	end

	local eventRow = newRow(parent, ROW_HEIGHT)
	local eventWidth = 1 / math.max(1, #(Config.Events :: { any }))
	for index, event in Config.Events :: { any } do
		newButton(eventRow, event.name .. " in 3s", eventWidth, function()
			send("event", { index = index, seconds = 3 })
		end)
	end

	local extrasRow = newRow(parent, ROW_HEIGHT)
	newButton(extrasRow, "+1 spin", 0.3, function()
		send("spins", { delta = 1 })
	end)
	newButton(extrasRow, "Claim daily", 0.36, function()
		send("daily")
	end)
	newButton(extrasRow, "Fill index", 0.34, function()
		send("discoverAll")
	end)
end

local function build(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "DebugPanel"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 1000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -12, 0, 12)
	root.Size = UDim2.new(0, PANEL_WIDTH, 0.88, 0)
	root.BackgroundColor3 = COLOR_BG
	root.BackgroundTransparency = 0.06
	root.BorderSizePixel = 0
	root.Parent = screen
	corner(root, 8)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = root

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Font = FONT_UI
	title.Text = "DEV PANEL  ·  F4"
	title.TextSize = 13
	title.TextColor3 = COLOR_DIM
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = root

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundColor3 = COLOR_PANEL
	status.BorderSizePixel = 0
	status.Position = UDim2.new(0, 0, 0, 22)
	status.Size = UDim2.new(1, 0, 0, 104)
	status.Font = FONT_VALUE
	status.Text = "connecting..."
	status.TextSize = 12
	status.TextColor3 = COLOR_TEXT
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextYAlignment = Enum.TextYAlignment.Top
	-- A carried Rainbow Giant Opal Dumpling is a long line: let it wrap rather
	-- than run off the right edge of the panel.
	status.TextWrapped = true
	status.Parent = root
	corner(status, 5)

	local statusPad = Instance.new("UIPadding")
	statusPad.PaddingTop = UDim.new(0, 6)
	statusPad.PaddingLeft = UDim.new(0, 6)
	statusPad.Parent = status

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.new(0, 0, 0, 132)
	body.Size = UDim2.new(1, 0, 1, -156)
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.ScrollBarThickness = 4
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body

	local result = Instance.new("TextLabel")
	result.Name = "Result"
	result.BackgroundTransparency = 1
	result.AnchorPoint = Vector2.new(0, 1)
	result.Position = UDim2.new(0, 0, 1, 0)
	result.Size = UDim2.new(1, 0, 0, 18)
	result.Font = FONT_VALUE
	result.Text = ""
	result.TextSize = 12
	result.TextColor3 = COLOR_OK
	result.TextXAlignment = Enum.TextXAlignment.Left
	result.TextTruncate = Enum.TextTruncate.AtEnd
	result.Parent = root

	statusLabel = status
	resultLabel = result
	buildBody(body)

	screen.Parent = player:WaitForChild("PlayerGui")
	return screen
end

function DebugPanel.Start()
	-- The panel is Studio-only, and so is the remote it drives. Outside Studio
	-- there is nothing to talk to, so nothing gets built.
	if not RunService:IsStudio() then
		return
	end
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local found = remotes:WaitForChild(REMOTE_NAME, 10)
	if found == nil or not found:IsA("RemoteFunction") then
		warn("[DebugPanel] DebugService never published its remote — panel disabled.")
		return
	end
	remote = found

	gui = build()
	refresh()

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= TOGGLE_KEY then
			return
		end
		local screen = gui
		if screen == nil then
			return
		end
		screen.Enabled = not screen.Enabled
		if screen.Enabled then
			send("status")
		end
	end)

	-- Keeps the status block honest while the panel is open (income ticks up,
	-- the giants change state) without polling a closed panel.
	task.spawn(function()
		local screen = gui
		while screen ~= nil and screen.Parent ~= nil do
			if screen.Enabled then
				send("status")
			end
			task.wait(POLL_SECONDS)
		end
	end)
end

return DebugPanel
