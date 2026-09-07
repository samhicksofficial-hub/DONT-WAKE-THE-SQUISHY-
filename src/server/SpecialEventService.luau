--!strict
-- SpecialEventService — the world-changing events and the big board floating
-- above the wall that counts them down.
--
-- Every Config.SpecialEvents.IntervalSeconds one event fires, chosen at random
-- but NAMED on the board the whole time, so the server knows what is coming.
-- For DurationSeconds the field belongs to it: SquishyService.SetFieldVariant
-- re-dresses every fresh field squishy in the event's coat (Undead for the
-- Zombie Apocalypse, Frozen for the Snow Storm) and dresses them back when the
-- clock runs out. Carried and plot squishies are property and are left alone.
--
-- Same shape as EventService on purpose: one board part in the world rather
-- than per-player UI (no remotes, no drift), a saved board WINS over a
-- generated one, and BuildBoard is public so the map tool can put the board
-- into the saved place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local SpecialEventService = {}

local Palette = Config.Palette :: any

local TICK = 1
local BOARD_NAME = "SpecialEventBoard"
local LABEL_NAME = "Special"

local rng = Random.new()
local squishyService: any = nil
local labels: { TextLabel } = {}

-- The running clock. `pending` is the event the board is promising; while one
-- is LIVE, `active` holds it and `activeUntil` its end.
local nextAt = 0
local pending: any = nil
local active: any = nil
local activeUntil = 0

-- "1:57:03" over an hour, "04:32" under one.
local function formatClock(seconds: number): string
	local whole = math.max(0, math.floor(seconds + 0.5))
	if whole >= 3600 then
		return ("%d:%02d:%02d"):format(whole // 3600, (whole % 3600) // 60, whole % 60)
	end
	return ("%02d:%02d"):format(whole // 60, whole % 60)
end

local function pick(): any
	local events = (Config.SpecialEvents :: any).Events :: { any }
	return events[rng:NextInteger(1, #events)]
end

-- The board: one wide panel floating above the wall, a single line per face.
local function buildBoard(map: any): ()
	local board = Instance.new("Model")
	board.Name = BOARD_NAME

	local fieldSize = Config.Field.Size :: Vector2
	local spec = (Config.SpecialEvents :: any).Board
	local size = spec.Size :: Vector2
	local offset = spec.Offset :: Vector3
	local centre = Vector3.new(
		fieldSize.X * offset.X,
		spec.Height :: number,
		fieldSize.Y * offset.Z
	)

	local panel = Instance.new("Part")
	panel.Name = "Panel"
	panel.Size = Vector3.new(size.X, size.Y, 1.4)
	panel.CFrame = CFrame.new(centre)
	panel.Color = Palette.BoundaryWall
	panel.Material = Enum.Material.SmoothPlastic
	panel.Anchored = true
	panel.CanCollide = false
	panel.CanQuery = false
	panel.CanTouch = false
	panel.Parent = board

	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Display" .. face.Name
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 26
		gui.LightInfluence = 0
		gui.Adornee = panel
		gui.Parent = panel

		-- The black rim, same as the mapper drew by hand on the saved board.
		local rim = Instance.new("Frame")
		rim.Name = "Rim"
		rim.AnchorPoint = Vector2.new(0.5, 0.5)
		rim.Position = UDim2.fromScale(0.5, 0.5)
		rim.Size = UDim2.fromScale(1, 1)
		rim.BackgroundTransparency = 1
		rim.Parent = gui
		local rimStroke = Instance.new("UIStroke")
		rimStroke.Thickness = 6
		rimStroke.Color = Color3.fromRGB(25, 26, 31)
		rimStroke.Parent = rim

		local label = Instance.new("TextLabel")
		label.Name = LABEL_NAME
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.Size = UDim2.fromScale(0.95, 0.8)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.Text = "Special event in --:--"
		label.Parent = gui
	end

	board.Parent = map.root
end

-- Public so the map tool can save the board into the place, like EventService.
function SpecialEventService.BuildBoard(map: any): Model
	local existing = map.root:FindFirstChild(BOARD_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
	buildBoard(map)
	return map.root:FindFirstChild(BOARD_NAME) :: Model
end

local function collectLabels(board: Instance): { TextLabel }
	local found: { TextLabel } = {}
	for _, descendant in board:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant.Name == LABEL_NAME then
			table.insert(found, descendant)
		end
	end
	return found
end

local function show(text: string, color: Color3)
	for _, label in labels do
		label.Text = text
		label.TextColor3 = color
	end
end

-- Starts `cfg` this instant, for `seconds` (the config duration when nil).
local function begin(cfg: any, seconds: number?)
	local duration = tonumber(seconds) or tonumber((Config.SpecialEvents :: any).DurationSeconds) or 300
	active = cfg
	activeUntil = os.clock() + duration
	if squishyService ~= nil then
		pcall(squishyService.SetFieldVariant, cfg.variant)
	end
	print(("[%s] %s! The field turns %s for %ds"):format(Config.GameName, cfg.name, tostring(cfg.variant), duration))
end

-- Ends the running event and promises the next one.
local function finish()
	if squishyService ~= nil then
		pcall(squishyService.SetFieldVariant, nil)
	end
	active = nil
	pending = pick()
	nextAt = os.clock() + (tonumber((Config.SpecialEvents :: any).IntervalSeconds) or 7200)
end

function SpecialEventService.Start(services: any, map: any)
	squishyService = services.SquishyService

	-- A board saved in the place WINS, exactly like the rarity board.
	local board = map.root:FindFirstChild(BOARD_NAME)
	if board == nil then
		local ok, err = pcall(buildBoard, map)
		if not ok then
			warn(("[SpecialEventService] board failed: %s"):format(tostring(err)))
		end
		board = map.root:FindFirstChild(BOARD_NAME)
	end
	if board ~= nil then
		labels = collectLabels(board)
		if #labels == 0 then
			warn(
				("[SpecialEventService] the saved special board has no TextLabel named %q; delete Workspace.Map.%s to have it rebuilt."):format(
					LABEL_NAME,
					BOARD_NAME
				)
			)
		end
	end

	pending = pick()
	nextAt = os.clock() + (tonumber((Config.SpecialEvents :: any).IntervalSeconds) or 7200)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(function()
				local clock = os.clock()
				if active ~= nil then
					local remaining = activeUntil - clock
					if remaining <= 0 then
						finish()
						show(("%s in %s"):format(pending.name, formatClock(nextAt - clock)), pending.color)
					else
						show(("%s! %s left"):format(active.name:upper(), formatClock(remaining)), active.color)
					end
				else
					local remaining = nextAt - clock
					if remaining <= 0 then
						begin(pending)
					else
						show(("%s in %s"):format(pending.name, formatClock(remaining)), pending.color)
					end
				end
			end)
			if not ok then
				warn(("[SpecialEventService] tick failed: %s"):format(tostring(err)))
			end
		end
	end)
end

-- ------------------------------------------------------------------- debug --

-- Fires event `index` right now for `seconds` (config duration when nil).
function SpecialEventService.Trigger(index: number?, seconds: number?): boolean
	local events = (Config.SpecialEvents :: any).Events :: { any }
	local cfg = events[tonumber(index) or rng:NextInteger(1, #events)]
	if cfg == nil then
		return false
	end
	begin(cfg, seconds)
	return true
end

-- Pushes the next landing to `seconds` from now, to watch a full real cycle.
function SpecialEventService.SetCountdown(seconds: number)
	nextAt = os.clock() + math.max(0, seconds)
end

return SpecialEventService
