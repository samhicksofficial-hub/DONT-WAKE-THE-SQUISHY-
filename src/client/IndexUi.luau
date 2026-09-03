--!strict
-- IndexUi — the squishy collection index, one PAGE PER VARIANT.
--
-- The pack's Frames.Index.Scrolling ships a UIGridLayout and no entry
-- template, so the cards are built here, sized from the grid's own CellSize
-- and styled to match the pack (dark rounded card, thick stroke, bubbly text).
-- One card per Config.Squishies entry, ordered by rarity then catalog order.
--
-- The tab column down the panel's side holds one button per Config.Variants
-- entry. Picking a tab repaints the SAME cards for that variant: the preview
-- wears the variant's coat, the name takes its prefix, the income takes its
-- multiplier, and discovery is judged per (squishy, variant) — finding a Gold
-- fills the Gold page, not the Normal one. The pack ships styled pills for
-- Normal/Golden/Diamond; the other variants clone the Normal pill and tint it.
--
-- Discovery arrives on the `Discovered` remote in two shapes (DESIGN.md): an
-- array of keys on join/respawn and a single key on each new find, each key
-- `variant .. "|" .. name` (a bare name with no "|" counts as Normal).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local SquishyModels = require(Shared:WaitForChild("SquishyModels"))
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

-- Preview framing. The camera looks slightly down and to one side so a squishy
-- reads as a solid object rather than a flat front-on sticker.
local PREVIEW_FOV = 40
local PREVIEW_DIR = Vector3.new(0.45, 0.34, 1).Unit
local PREVIEW_PADDING = 1.22 -- >1 leaves air around the model inside the card
local PREVIEW_AMBIENT = Color3.fromRGB(190, 190, 200)
local PREVIEW_LIGHT = Color3.fromRGB(255, 252, 245)
local PREVIEW_LIGHT_DIR = Vector3.new(-0.4, -1, -0.6)
-- An undiscovered squishy shows as a black cut-out: you get its silhouette
-- (and its rarity) as the hint, but not what it actually is.
local SILHOUETTE = Color3.new(0, 0, 0)
local REVEALED = Color3.new(1, 1, 1)

type Entry = {
	frame: Frame,
	nameLabel: TextLabel,
	rarityLabel: TextLabel,
	incomeLabel: TextLabel,
	viewport: ViewportFrame?,
	viewportVariant: string, -- which variant the preview model is wearing
	def: any,
	squishyName: string,
	baseIncome: number, -- level-1 Normal income; variants multiply it
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

-- A live 3D preview of the squishy, framed to fill the card.
--
-- The model comes from SquishyModels rather than SquishyFactory: the factory
-- also hangs a pickup prompt and two billboards off the body, which are
-- gameplay furniture with no business inside a menu.
--
-- Returns nil if the model cannot be built, so a single bad catalog entry
-- costs that card its picture rather than taking the whole index down.
local function buildPreview(parent: Frame, def: any, variantName: string?): ViewportFrame?
	-- build() returns (Model, height); only the model matters here.
	local ok, result = pcall(function()
		return (SquishyModels.build :: any)({
			shape = def.shape,
			color = def.color,
			sparkle = def.sparkle,
			scale = def.scale,
			-- The preview wears the page's coat, so the Gold page shows gold.
			variant = variantName,
		})
	end)
	if not ok or typeof(result) ~= "Instance" then
		warn(("[IndexUi] preview build failed for %s: %s"):format(tostring(def.name), tostring(result)))
		return nil
	end
	local model = result :: Model

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.AnchorPoint = Vector2.new(0.5, 0)
	viewport.Position = UDim2.fromScale(0.5, 0.02)
	viewport.Size = UDim2.fromScale(0.88, 0.48)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Ambient = PREVIEW_AMBIENT
	viewport.LightColor = PREVIEW_LIGHT
	viewport.LightDirection = PREVIEW_LIGHT_DIR
	viewport.Parent = parent

	-- The body is an invisible collision box sized to the visual. Leaving it in
	-- would pad the bounding box with empty space and shrink the squishy.
	local body = model:FindFirstChild("Body")
	if body ~= nil then
		body:Destroy()
	end
	model.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = PREVIEW_FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- Frame on the model's widest face, not its bounding sphere. A sphere fitted
	-- around a box is ~1.7x the box's side, which parks every squishy small and
	-- lost in the middle of its card. Depth counts for less than width/height
	-- because the camera is off to one side, hence the fraction on Z.
	local okExtents, centre, size = pcall(function()
		local cf, extents = model:GetBoundingBox()
		return cf.Position, extents
	end)
	if okExtents and typeof(size) == "Vector3" and size.Magnitude > 0 then
		local extent = math.max(size.X, size.Y, size.Z * 0.7)
		local distance = (extent * PREVIEW_PADDING) / (2 * math.tan(math.rad(PREVIEW_FOV * 0.5)))
		camera.CFrame = CFrame.lookAt(centre + PREVIEW_DIR * distance, centre)
	else
		camera.CFrame = CFrame.lookAt(PREVIEW_DIR * 8, Vector3.zero)
	end

	return viewport
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

	-- The picture takes the top half of the card, so the three lines move down
	-- and tighten up to share what is left.
	local viewport = buildPreview(frame, def)

	return {
		frame = frame,
		nameLabel = addLabel(frame, "SquishyName", 0.16, 0.58),
		rarityLabel = addLabel(frame, "Rarity", 0.13, 0.73),
		incomeLabel = addLabel(frame, "Income", 0.15, 0.88),
		viewport = viewport,
		viewportVariant = "Normal",
		def = def,
		squishyName = def.name,
		baseIncome = rarity.income,
		rarityName = def.rarity,
		rarityColor = rarity.color,
	}
end

-- Discovered cards read out in full for the page's variant; the rest keep
-- their rarity (it is the only hint you get) and go grey and "???" everywhere
-- else — but the silhouette still wears the variant's SHAPE, because the
-- preview model is rebuilt per page.
local function paintEntry(entry: Entry, variant: any, discovered: boolean)
	-- The preview model changes coat with the page. Rebuilt only when the page
	-- actually changed, so repainting for discovery is cheap.
	if entry.viewportVariant ~= variant.name then
		entry.viewportVariant = variant.name
		local old = entry.viewport
		if old ~= nil then
			old:Destroy()
		end
		entry.viewport = buildPreview(
			entry.frame,
			entry.def,
			if variant.name == "Normal" then nil else variant.name
		)
	end

	-- The rarity shows on every card, discovered or not: it is the only hint
	-- an undiscovered squishy gives you.
	entry.rarityLabel.Text = entry.rarityName
	entry.rarityLabel.TextColor3 = if discovered
		then entry.rarityColor
		else entry.rarityColor:Lerp(Color3.new(0, 0, 0), LOCKED_RARITY_FADE)

	-- ImageColor3 tints the whole rendered viewport, so one property turns the
	-- model into a black cut-out and back without touching the model itself.
	local viewport = entry.viewport
	if viewport ~= nil then
		viewport.ImageColor3 = if discovered then REVEALED else SILHOUETTE
	end

	if discovered then
		entry.frame.BackgroundTransparency = CARD_TRANSPARENCY
		entry.nameLabel.Text = (variant.prefix or "") .. entry.squishyName
		entry.nameLabel.TextColor3 = (variant.color :: Color3?) or NAME_COLOR
		entry.incomeLabel.Text = Util.formatMoney(entry.baseIncome * (variant.income or 1)) .. "/s"
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
			paintEntry(entry, Config.VariantByName.Normal, false)
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

	-- ---------- variant pages ----------

	-- Discovery keys, exactly as the server sends them: `variant .. "|" .. name`.
	local discovered: { [string]: boolean } = {}
	local selectedVariant: any = Config.VariantByName.Normal

	local function repaintAll()
		for _, entry in entries do
			local key = selectedVariant.name .. "|" .. entry.squishyName
			local ok, err = pcall(paintEntry, entry, selectedVariant, discovered[key] == true)
			if not ok then
				warn(("[IndexUi] could not paint %s: %s"):format(entry.squishyName, tostring(err)))
			end
		end
	end

	-- ---------- tabs ----------

	-- One button per variant. The pack ships styled pills for Normal, Golden
	-- and Diamond; every other variant clones the Normal pill and tints it
	-- (Rainbow wears a gradient instead — it has no single colour).
	local tabButtons: { [string]: GuiButton } = {}
	-- Each pill's full-strength tint, so highlightTabs can dim the others.
	local fullColor: { [string]: Color3 } = {}

	local function highlightTabs()
		for name, button in tabButtons do
			local background = button:FindFirstChild("Background")
			if background ~= nil and background:IsA("ImageLabel") then
				local full = fullColor[name] or Color3.new(1, 1, 1)
				background.ImageColor3 = if name == selectedVariant.name
					then full
					else full:Lerp(Color3.new(0, 0, 0), 0.45)
			end
		end
	end

	local function selectTab(variant: any)
		if selectedVariant ~= variant then
			selectedVariant = variant
			highlightTabs()
			repaintAll()
		end
		scrolling.CanvasPosition = Vector2.zero
	end

	local tabs = panel:FindFirstChild("Buttons")
	if tabs ~= nil then
		-- The pack's own pill for a variant, where it ships one.
		local packNames: { [string]: string } = { Normal = "Normal", Gold = "Golden", Diamond = "Diamond" }
		local template = tabs:FindFirstChild("Normal")
		for order, variant in Config.Variants :: { any } do
			local button: Instance? = nil
			local packName = packNames[variant.name]
			if packName ~= nil then
				button = tabs:FindFirstChild(packName)
			elseif template ~= nil then
				local clone = template:Clone()
				clone.Name = variant.name
				local background = clone:FindFirstChild("Background")
				if background ~= nil and background:IsA("ImageLabel") then
					if variant.name == "Rainbow" then
						local gradient = Instance.new("UIGradient")
						gradient.Color = ColorSequence.new({
							ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 118, 118)),
							ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 224, 110)),
							ColorSequenceKeypoint.new(0.66, Color3.fromRGB(120, 235, 160)),
							ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 160, 255)),
						})
						gradient.Parent = background
					elseif typeof(variant.color) == "Color3" then
						background.ImageColor3 = variant.color
					end
				end
				clone.Parent = tabs
				button = clone
			end
			if button ~= nil and button:IsA("GuiButton") then
				button.Visible = true
				button.LayoutOrder = order
				local text = button:FindFirstChild("Text")
				if text ~= nil and text:IsA("TextLabel") then
					text.Text = variant.name
				end
				local background = button:FindFirstChild("Background")
				fullColor[variant.name] = if background ~= nil and background:IsA("ImageLabel")
					then background.ImageColor3
					else Color3.new(1, 1, 1)
				tabButtons[variant.name] = button
				UiRefs.bindButton(button :: GuiButton, function()
					selectTab(variant)
				end)
			end
		end
		-- The pack authored its three pills in tree order; LayoutOrder now runs
		-- the pages in catalog order instead.
		local list = tabs:FindFirstChildOfClass("UIListLayout")
		if list ~= nil then
			list.SortOrder = Enum.SortOrder.LayoutOrder
			-- Seven pills where the pack had three: a fixed 6px gap instead of
			-- the authored scale padding, or the stack runs off the screen.
			list.Padding = UDim.new(0, 6)
		end
		-- Stretch the pill column over the panel's full height and shrink each
		-- pill a touch; the layout's Center alignment then keeps all seven on
		-- screen where the pack's three-pill sizing pushed them past the top.
		-- The container is centre-anchored (like the rest of the pack), so its
		-- centre goes to the panel's middle.
		if tabs:IsA("GuiObject") then
			local tabsFrame = tabs :: GuiObject
			tabsFrame.Position = UDim2.new(tabsFrame.Position.X.Scale, tabsFrame.Position.X.Offset, 0.5, 0)
			tabsFrame.Size = UDim2.new(tabsFrame.Size.X.Scale, 0, 1, 0)
		end
		for _, button in tabButtons do
			button.Size = UDim2.new(0.86, 0, 0.86, 0)
		end
		highlightTabs()
	end

	-- ---------- discovery ----------

	local function markDiscovered(key: string)
		-- A bare name with no "|" is old-shape traffic: it means Normal.
		if string.find(key, "|", 1, true) == nil then
			key = "Normal|" .. key
		end
		if discovered[key] then
			return
		end
		discovered[key] = true

		local sep = string.find(key, "|", 1, true) :: number
		local variantName = string.sub(key, 1, sep - 1)
		if variantName ~= selectedVariant.name then
			return -- it will show when that page is opened
		end
		local entry = entries[string.sub(key, sep + 1)]
		if entry == nil then
			return
		end
		local ok, err = pcall(paintEntry, entry, selectedVariant, true)
		if not ok then
			warn(("[IndexUi] could not reveal %s: %s"):format(key, tostring(err)))
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
				for _, key in (payload :: { any }) do
					if typeof(key) == "string" then
						markDiscovered(key :: string)
					end
				end
			end
		end)
	end)
end

return IndexUi
