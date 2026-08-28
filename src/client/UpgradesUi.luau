--!strict
-- UpgradesUi — drives Frames.Upgrades in the Essential UI Pack.
--
--   PowerScrolling     the "Speed" track  (Config.Upgrades.Speed)
--   DistanceScrolling  the "Stealth" track (Config.Upgrades.Stealth)
--   CarryUpgrade       the wide card at the bottom (Config.Upgrades.Carry)
--
-- The two ScrollingFrames ship empty (a UIListLayout and nothing else), so the
-- level rows are built here once and then only restyled: levels below the
-- player's are "owned", the next level is the single clickable row, the rest
-- read as locked. Every purchase goes out on Remotes.BuyUpgrade; the server
-- answers by moving the Upgrade_* attribute, which is what refreshes this
-- panel. See the UI Contract in DESIGN.md.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local PANEL = "Upgrades"

-- Row skin. The pack itself is black-at-half-transparency panels with a fat
-- black UIStroke and Fredoka One text, so the rows copy that.
local FONT = Enum.Font.FredokaOne
local ROW_HEIGHT = 0.18
local ROW_WIDTH = 0.92
local CORNER = UDim.new(0.3, 0)
local STROKE_THICKNESS = 3

local COLOR_OWNED = Color3.fromRGB(44, 112, 62)
local COLOR_NEXT = Color3.fromRGB(250, 194, 66)
local COLOR_LOCKED = Color3.fromRGB(26, 26, 34)

local TEXT_BRIGHT = Color3.fromRGB(255, 255, 255)
local TEXT_DIM = Color3.fromRGB(196, 200, 208)
local TEXT_DARK = Color3.fromRGB(38, 26, 0)
local TEXT_BROKE = Color3.fromRGB(255, 116, 116)
local TEXT_BROKE_DARK = Color3.fromRGB(142, 26, 26)
local DIM_IMAGE = Color3.fromRGB(120, 120, 128)

type RowRefs = {
	button: TextButton,
	level: TextLabel,
	value: TextLabel,
	price: TextLabel,
}

type TrackState = {
	name: string,
	scroll: ScrollingFrame,
	layout: UIListLayout,
	values: { number },
	prices: { number },
	suffix: string,
	rows: { RowRefs },
	syncCanvas: (() -> ())?,
}

local UpgradesUi = {}

-- ---------------------------------------------------------------- helpers --

-- "16.00" -> "16", "1.50" -> "1.5". Same trim Util.formatMoney uses.
local function trimNumber(value: number): string
	local text = string.format("%.2f", value)
	return (text:gsub("%.?0+$", ""))
end

-- Config suffixes that start with "%" describe a fraction, so 0.92 reads as
-- "92% notice" rather than the nonsense "0.92% notice".
local function formatValue(value: number, suffix: string): string
	if string.sub(suffix, 1, 1) == "%" then
		return ("%d%s"):format(math.round(value * 100), suffix)
	end
	return trimNumber(value) .. suffix
end

local function formatPercent(value: number): string
	return ("%d%%"):format(math.round(value * 100))
end

local function readNumber(player: Player, attribute: string, fallback: number): number
	local raw = player:GetAttribute(attribute)
	if typeof(raw) == "number" then
		return raw :: number
	end
	return fallback
end

local function makeLabel(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2, align: Enum.TextXAlignment): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.AnchorPoint = anchor
	label.Position = position
	label.Size = size
	label.Font = FONT
	label.TextScaled = true
	label.TextXAlignment = align
	label.TextColor3 = TEXT_BRIGHT
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 2
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label

	return label
end

-- One level row: level number on the left, the value at that level in the
-- middle, the price (or its owned/locked stand-in) on the right.
local function buildRow(track: TrackState, index: number): RowRefs
	local button = Instance.new("TextButton")
	button.Name = ("Level%d"):format(index)
	button.LayoutOrder = index
	button.AutoButtonColor = false
	button.Text = ""
	button.TextTransparency = 1
	button.BorderSizePixel = 0
	button.Size = UDim2.fromScale(ROW_WIDTH, ROW_HEIGHT)
	button.BackgroundColor3 = COLOR_LOCKED
	button.BackgroundTransparency = 0.3

	local corner = Instance.new("UICorner")
	corner.CornerRadius = CORNER
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = STROKE_THICKNESS
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = button

	local row: RowRefs = {
		button = button,
		level = makeLabel(button, "Level", UDim2.fromScale(0.2, 0.5), UDim2.fromScale(0.05, 0.5), Vector2.new(0, 0.5), Enum.TextXAlignment.Left),
		value = makeLabel(button, "Value", UDim2.fromScale(0.4, 0.52), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5), Enum.TextXAlignment.Center),
		price = makeLabel(button, "Price", UDim2.fromScale(0.3, 0.46), UDim2.fromScale(0.95, 0.5), Vector2.new(1, 0.5), Enum.TextXAlignment.Right),
	}

	row.level.Text = ("Lv %d"):format(index)
	row.value.Text = formatValue(track.values[index], track.suffix)
	button.Parent = track.scroll
	return row
end

-- --------------------------------------------------------------- the panel --

function UpgradesUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()
	local panel = refs.panels[PANEL]

	local buyRemote: RemoteEvent? = nil
	task.spawn(function()
		buyRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuyUpgrade") :: RemoteEvent
	end)

	local function buy(trackName: string, price: number)
		if readNumber(player, "Money", 0) < price then
			UiRefs.notify(("You need %s for that upgrade."):format(Util.formatMoney(price)), 2.5)
			return
		end
		local remote = buyRemote
		if remote ~= nil then
			remote:FireServer(trackName)
		end
	end

	-- ------------------------------------------------------------- tracks --

	local tracks: { TrackState } = {}

	local function addTrack(trackName: string, scrollName: string)
		local found = panel:FindFirstChild(scrollName)
		if found == nil or not found:IsA("ScrollingFrame") then
			warn(("[UpgradesUi] Frames.Upgrades.%s is missing"):format(scrollName))
			return
		end
		local scroll = found :: ScrollingFrame
		local foundLayout = scroll:FindFirstChildOfClass("UIListLayout")
		if foundLayout == nil then
			warn(("[UpgradesUi] %s has no UIListLayout"):format(scrollName))
			return
		end
		local layout = foundLayout :: UIListLayout
		local tuning = (Config.Upgrades :: any)[trackName]

		local track: TrackState = {
			name = trackName,
			scroll = scroll,
			layout = layout,
			values = tuning.values,
			prices = tuning.prices,
			suffix = tuning.suffix,
			rows = {},
		}

		for index = 1, #track.values do
			local ok, result = pcall(buildRow, track, index)
			if ok then
				local row = result :: RowRefs
				table.insert(track.rows, row)
				-- Level 1 is the free starting level and can never be bought.
				if index > 1 then
					UiRefs.bindButton(row.button, function()
						local level = readNumber(player, "Upgrade_" .. trackName, 1)
						if index == level + 1 then
							buy(trackName, track.prices[level] or 0)
						end
					end)
				end
			else
				warn(("[UpgradesUi] %s row %d failed: %s"):format(trackName, index, tostring(result)))
			end
		end

		-- The pack leaves these on AutomaticCanvasSize; drive the canvas from
		-- the layout instead so the rows we add always fit.
		scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
		scroll.ScrollingDirection = Enum.ScrollingDirection.Y

		-- Rows authored in SCALE are measured against the CANVAS, so driving
		-- the canvas from content size feeds back on itself (rows grow, content
		-- grows, canvas grows...) until Roblox aborts the event chain. Pin the
		-- rows to pixels off the frame's own visible size instead — that never
		-- depends on the canvas — then size the canvas from the row count.
		local function syncCanvas()
			local view = scroll.AbsoluteSize
			if view.X <= 0 or view.Y <= 0 then
				return
			end
			local rowH = math.floor(ROW_HEIGHT * view.Y)
			local rowW = math.floor(ROW_WIDTH * view.X)
			if rowH <= 0 or rowW <= 0 then
				return
			end

			local rows = 0
			for _, child in scroll:GetChildren() do
				if child:IsA("GuiObject") then
					rows += 1
					local pixel = UDim2.fromOffset(rowW, rowH)
					if child.Size ~= pixel then
						child.Size = pixel
					end
				end
			end

			local padding = layout.Padding.Offset + layout.Padding.Scale * view.Y
			local height = math.ceil(rows * rowH + math.max(0, rows - 1) * padding)
			local target = UDim2.fromOffset(0, height)
			if scroll.CanvasSize ~= target then
				scroll.CanvasSize = target
			end
		end

		scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncCanvas)
		track.syncCanvas = syncCanvas
		syncCanvas()

		table.insert(tracks, track)
	end

	addTrack("Speed", "PowerScrolling")
	addTrack("Stealth", "DistanceScrolling")

	local function refreshTrack(track: TrackState, money: number)
		local maxLevel = #track.values
		local level = math.clamp(readNumber(player, "Upgrade_" .. track.name, 1), 1, maxLevel)

		for index, row in track.rows do
			local ok, err = pcall(function()
				local button = row.button
				if index <= level then
					button.BackgroundColor3 = COLOR_OWNED
					button.BackgroundTransparency = 0.25
					button.Active = false
					button.Selectable = false
					row.level.TextColor3 = TEXT_BRIGHT
					row.value.TextColor3 = TEXT_BRIGHT
					row.price.TextColor3 = TEXT_BRIGHT
					if index < level then
						row.price.Text = "OWNED"
					elseif level >= maxLevel then
						row.price.Text = "MAX"
					else
						row.price.Text = "CURRENT"
					end
				elseif index == level + 1 then
					local price = track.prices[level] or 0
					button.BackgroundColor3 = COLOR_NEXT
					button.BackgroundTransparency = 0
					button.Active = true
					button.Selectable = true
					row.level.TextColor3 = TEXT_DARK
					row.value.TextColor3 = TEXT_DARK
					row.price.TextColor3 = if money >= price then TEXT_DARK else TEXT_BROKE_DARK
					row.price.Text = Util.formatMoney(price)
				else
					button.BackgroundColor3 = COLOR_LOCKED
					button.BackgroundTransparency = 0.35
					button.Active = false
					button.Selectable = false
					row.level.TextColor3 = TEXT_DIM
					row.value.TextColor3 = TEXT_DIM
					row.price.TextColor3 = TEXT_DIM
					row.price.Text = Util.formatMoney(track.prices[index - 1] or 0)
				end
			end)
			if not ok then
				warn(("[UpgradesUi] %s row %d refresh failed: %s"):format(track.name, index, tostring(err)))
			end
		end
	end

	-- -------------------------------------------------------- carry card --

	local carryTuning = (Config.Upgrades :: any).Carry
	local carryCard = panel:FindFirstChild("CarryUpgrade")
	local carryTitle: TextLabel? = nil
	local carryBefore: TextLabel? = nil
	local carryAfter: TextLabel? = nil
	local carryButton: TextButton? = nil
	local carryPrice: TextLabel? = nil
	local carryBacking: ImageLabel? = nil

	if carryCard ~= nil then
		local image = carryCard:FindFirstChild("Image")
		if image ~= nil then
			carryTitle = image:FindFirstChild("Text") :: TextLabel?
		end
		local stats = carryCard:FindFirstChild("Stats")
		if stats ~= nil then
			local before = stats:FindFirstChild("Before")
			local after = stats:FindFirstChild("After")
			carryBefore = if before ~= nil then before:FindFirstChild("Text") :: TextLabel? else nil
			carryAfter = if after ~= nil then after:FindFirstChild("Text") :: TextLabel? else nil
		end
		local buttons = carryCard:FindFirstChild("Buttons")
		if buttons ~= nil then
			carryButton = buttons:FindFirstChild("Money") :: TextButton?
			-- Parked monetization: no developer product id exists yet.
			local robux = buttons:FindFirstChild("Robux")
			if robux ~= nil and robux:IsA("GuiObject") then
				robux.Visible = false
			end
		end
		if carryButton ~= nil then
			carryPrice = carryButton:FindFirstChild("Text") :: TextLabel?
			carryBacking = carryButton:FindFirstChild("Background") :: ImageLabel?
		end
	else
		warn("[UpgradesUi] Frames.Upgrades.CarryUpgrade is missing")
	end

	if carryTitle ~= nil then
		carryTitle.Text = carryTuning.title
	end

	if carryButton ~= nil then
		UiRefs.bindButton(carryButton, function()
			local level = readNumber(player, "Upgrade_Carry", 1)
			local price = carryTuning.prices[level]
			if price == nil then
				return
			end
			buy("Carry", price)
		end)
	end

	local function refreshCarry(money: number)
		local values = carryTuning.values :: { number }
		local maxLevel = #values
		local level = math.clamp(readNumber(player, "Upgrade_Carry", 1), 1, maxLevel)
		local maxed = level >= maxLevel

		if carryBefore ~= nil then
			carryBefore.Text = formatPercent(values[level])
		end
		if carryAfter ~= nil then
			carryAfter.Text = if maxed then "MAX" else formatPercent(values[level + 1])
		end

		local price = (carryTuning.prices :: { number })[level]
		local affordable = not maxed and price ~= nil and money >= price
		if carryPrice ~= nil then
			carryPrice.Text = if maxed then "MAX" else Util.formatMoney(price or 0)
			carryPrice.TextColor3 = if maxed or affordable then TEXT_BRIGHT else TEXT_BROKE
		end
		if carryBacking ~= nil then
			carryBacking.ImageColor3 = if maxed then DIM_IMAGE else Color3.new(1, 1, 1)
		end
		if carryButton ~= nil then
			carryButton.Active = not maxed
			carryButton.Selectable = not maxed
		end
	end

	-- ------------------------------------------------------------ refresh --

	local function refresh()
		local money = readNumber(player, "Money", 0)
		for _, track in tracks do
			local ok, err = pcall(refreshTrack, track, money)
			if not ok then
				warn(("[UpgradesUi] %s refresh failed: %s"):format(track.name, tostring(err)))
			end
		end
		local carryOk, carryErr = pcall(refreshCarry, money)
		if not carryOk then
			warn(("[UpgradesUi] carry refresh failed: %s"):format(tostring(carryErr)))
		end
	end

	-- Attribute churn is cheap to ignore while the panel is shut; opening it
	-- always repaints from scratch.
	local function refreshIfOpen()
		if UiRefs.isPanelOpen(PANEL) then
			refresh()
		end
	end

	for _, attribute in { "Money", "Upgrade_Speed", "Upgrade_Stealth", "Upgrade_Carry", "Rebirths" } do
		player:GetAttributeChangedSignal(attribute):Connect(refreshIfOpen)
	end
	panel:GetPropertyChangedSignal("Visible"):Connect(refreshIfOpen)

	refresh()
end

return UpgradesUi
