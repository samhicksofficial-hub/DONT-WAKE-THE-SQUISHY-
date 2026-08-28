--!strict
-- IndexUi — the squishy collection index.
--
-- The pack's Frames.Index.Scrolling ships a UIGridLayout and no entry
-- template, so the cards are built here, sized from the grid's own CellSize
-- and styled to match the pack (dark rounded card, thick stroke, bubbly text).
-- One card per Config.Squishies entry, ordered by rarity then catalog order.
--
-- Discovery arrives on the `Discovered` remote in two shapes (DESIGN.md):
-- an array of names on join/respawn, and a single name on each new find.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local UiRefs = require(script.Parent.UiRefs)

-- Card styling, matched to the pack's own item cards.
local CARD_COLOR = Color3.new(0, 0, 0)
local CARD_STROKE = Color3.fromRGB(0, 53, 80)
local CARD_TRANSPARENCY = 0.35
local CARD_TRANSPARENCY_LOCKED = 0.65
local STROKE_THICKNESS = 3
local CORNER_RADIUS = UDim.new(0.1, 0)

local MONEY_GREEN = Color3.fromRGB(85, 255, 85)
local NAME_COLOR = Color3.new(1, 1, 1)
local LOCKED_COLOR = Color3.fromRGB(125, 125, 125)
local LOCKED_TRANSPARENCY = 0.25
local LOCKED_RARITY_FADE = 0.5 -- how far the rarity colour is pulled to black
local UNKNOWN = "???"

type Entry = {
	frame: Frame,
	nameLabel: TextLabel,
	rarityLabel: TextLabel,
	incomeLabel: TextLabel,
	squishyName: string,
	incomeText: string,
	rarityName: string,
	rarityColor: Color3,
}

local IndexUi = {}

-- A card line: bubbly, scaled, black-stroked, centred on its own row.
local function addLabel(parent: Frame, name: string, height: number, y: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, y, 0)
	label.Size = UDim2.new(0.88, 0, height, 0)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.Text = ""
	label.Parent = parent
	return label
end

local function buildEntry(def: any, rarity: any, cellSize: UDim2, order: number): Entry
	local frame = Instance.new("Frame")
	frame.Name = "Entry" .. order
	frame.Size = cellSize
	frame.BackgroundColor3 = CARD_COLOR
	frame.BackgroundTransparency = CARD_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.LayoutOrder = order

	local corner = Instance.new("UICorner")
	corner.CornerRadius = CORNER_RADIUS
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Color = CARD_STROKE
	stroke.Thickness = STROKE_THICKNESS
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = frame

	return {
		frame = frame,
		nameLabel = addLabel(frame, "SquishyName", 0.24, 0.24),
		rarityLabel = addLabel(frame, "Rarity", 0.17, 0.53),
		incomeLabel = addLabel(frame, "Income", 0.2, 0.79),
		squishyName = def.name,
		incomeText = Util.formatMoney(rarity.income) .. "/s",
		rarityName = def.rarity,
		rarityColor = rarity.color,
	}
end

-- Discovered cards read out in full; the rest keep their rarity (it is the
-- only hint you get) and go grey and "???" everywhere else.
local function paintEntry(entry: Entry, discovered: boolean)
	-- The rarity shows on every card, discovered or not: it is the only hint
	-- an undiscovered squishy gives you.
	entry.rarityLabel.Text = entry.rarityName
	entry.rarityLabel.TextColor3 = if discovered
		then entry.rarityColor
		else entry.rarityColor:Lerp(Color3.new(0, 0, 0), LOCKED_RARITY_FADE)

	if discovered then
		entry.frame.BackgroundTransparency = CARD_TRANSPARENCY
		entry.nameLabel.Text = entry.squishyName
		entry.nameLabel.TextColor3 = NAME_COLOR
		entry.incomeLabel.Text = entry.incomeText
		entry.incomeLabel.TextColor3 = MONEY_GREEN
		entry.nameLabel.TextTransparency = 0
		entry.rarityLabel.TextTransparency = 0
		entry.incomeLabel.TextTransparency = 0
	else
		entry.frame.BackgroundTransparency = CARD_TRANSPARENCY_LOCKED
		entry.nameLabel.Text = UNKNOWN
		entry.nameLabel.TextColor3 = LOCKED_COLOR
		entry.incomeLabel.Text = UNKNOWN
		entry.incomeLabel.TextColor3 = LOCKED_COLOR
		entry.nameLabel.TextTransparency = LOCKED_TRANSPARENCY
		entry.rarityLabel.TextTransparency = LOCKED_TRANSPARENCY
		entry.incomeLabel.TextTransparency = LOCKED_TRANSPARENCY
	end
end

-- Catalog order, re-sorted rarest-last: Config.Rarities order first, then the
-- order the squishies appear in Config (table.sort is not stable, so the
-- catalog index is part of the comparison).
local function orderedCatalog(): { any }
	local rank: { [string]: number } = {}
	for position, rarity in Config.Rarities do
		rank[rarity.name] = position
	end

	local rows: { { index: number, def: any } } = {}
	for index, def in (Config.Squishies :: { any }) do
		table.insert(rows, { index = index, def = def })
	end

	table.sort(rows, function(a, b)
		local rankA = rank[a.def.rarity] or math.huge
		local rankB = rank[b.def.rarity] or math.huge
		if rankA ~= rankB then
			return rankA < rankB
		end
		return a.index < b.index
	end)

	local defs: { any } = {}
	for _, row in rows do
		table.insert(defs, row.def)
	end
	return defs
end

function IndexUi.Start()
	local refs = UiRefs.get()
	local panel = refs.panels.Index

	local scrolling = panel:FindFirstChild("Scrolling")
	if scrolling == nil or not scrolling:IsA("ScrollingFrame") then
		warn("[IndexUi] Frames.Index.Scrolling is missing; index disabled")
		return
	end
	local grid = scrolling:FindFirstChildOfClass("UIGridLayout")
	if grid == nil then
		warn("[IndexUi] Index.Scrolling has no UIGridLayout; index disabled")
		return
	end

	-- ---------- cards ----------

	local entries: { [string]: Entry } = {}
	local cellSize = grid.CellSize
	local entryCount = 0

	for order, def in orderedCatalog() do
		local ok, err = pcall(function()
			local rarity = Config.RarityByName[def.rarity]
			if rarity == nil then
				error(("unknown rarity %q"):format(tostring(def.rarity)), 0)
			end
			local entry = buildEntry(def, rarity, cellSize, order)
			paintEntry(entry, false)
			entry.frame.Parent = scrolling
			entries[def.name] = entry
			entryCount += 1
		end)
		if not ok then
			warn(("[IndexUi] could not build %s: %s"):format(tostring(def.name), tostring(err)))
		end
	end

	-- ---------- canvas ----------

	-- The pack authors CellSize in SCALE, which is measured against the CANVAS:
	-- growing the canvas would grow the cells, which grows the content, which
	-- grows the canvas — a runaway that overflows CanvasSize. So the cells are
	-- pinned to pixels derived from the frame's own visible size (which the
	-- canvas never feeds back into), and the canvas is then driven from rows.
	scrolling.AutomaticCanvasSize = Enum.AutomaticSize.None
	scrolling.ScrollingDirection = Enum.ScrollingDirection.Y

	local cellScale = grid.CellSize
	local padScale = grid.CellPadding

	local function refreshCanvas()
		local view = scrolling.AbsoluteSize
		if view.X <= 0 or view.Y <= 0 then
			return
		end
		local cellW = cellScale.X.Scale * view.X + cellScale.X.Offset
		local cellH = cellScale.Y.Scale * view.Y + cellScale.Y.Offset
		local padW = padScale.X.Scale * view.X + padScale.X.Offset
		local padH = padScale.Y.Scale * view.Y + padScale.Y.Offset
		if cellW <= 0 or cellH <= 0 then
			return
		end

		local pixelCell = UDim2.fromOffset(math.floor(cellW), math.floor(cellH))
		if grid.CellSize ~= pixelCell then
			grid.CellSize = pixelCell
			grid.CellPadding = UDim2.fromOffset(math.floor(padW), math.floor(padH))
		end

		local perRow = math.max(1, math.floor((view.X + padW) / (cellW + padW)))
		local rows = math.ceil(entryCount / perRow)
		local height = math.ceil(rows * cellH + math.max(0, rows - 1) * padH)
		local target = UDim2.fromOffset(0, height)
		if scrolling.CanvasSize ~= target then
			scrolling.CanvasSize = target
		end
	end

	-- Only the frame's own size matters now, so this cannot feed back.
	scrolling:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshCanvas)
	refreshCanvas()

	-- ---------- tabs ----------

	-- Golden / Diamond variants do not exist in this game yet, so only the
	-- "Normal" tab is shown; it scrolls the grid back to the top.
	local tabs = panel:FindFirstChild("Buttons")
	if tabs ~= nil then
		for _, tabName in { "Golden", "Diamond" } do
			local tab = tabs:FindFirstChild(tabName)
			if tab ~= nil and tab:IsA("GuiObject") then
				tab.Visible = false
			end
		end
		local normal = tabs:FindFirstChild("Normal")
		if normal ~= nil and normal:IsA("GuiButton") then
			normal.Visible = true
			UiRefs.bindButton(normal, function()
				scrolling.CanvasPosition = Vector2.zero
			end)
		end
	end

	-- ---------- discovery ----------

	local function markDiscovered(squishyName: string)
		local entry = entries[squishyName]
		if entry == nil then
			return
		end
		local ok, err = pcall(paintEntry, entry, true)
		if not ok then
			warn(("[IndexUi] could not reveal %s: %s"):format(squishyName, tostring(err)))
		end
	end

	-- Spawned so Start never blocks on Remotes; the server re-sends the full
	-- set on every spawn, so a late listener still catches up.
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Discovered") :: RemoteEvent
		remote.OnClientEvent:Connect(function(payload: any)
			if typeof(payload) == "string" then
				markDiscovered(payload :: string)
			elseif typeof(payload) == "table" then
				for _, entryName in (payload :: { any }) do
					if typeof(entryName) == "string" then
						markDiscovered(entryName :: string)
					end
				end
			end
		end)
	end)
end

return IndexUi
