--!strict
-- EventService — the guaranteed-rarity countdowns and the big board that
-- advertises them.
--
-- Each entry in Config.Events runs its own clock. When one lands, a squishy of
-- that rarity is forced into the field regardless of the normal spawn cap, and
-- the clock re-arms. The board stands over the arena so the whole server can
-- see how long is left and be waiting when a Mythical drops.
--
-- Every player reads the same countdown because the board is one part in the
-- world, not per-player UI: no remotes, no drift.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local EventService = {}

local Palette = Config.Palette :: any

local TICK = 1 -- the board only ever shows whole seconds
-- The one name both the builder and the adopter agree on.
local BOARD_NAME = "EventBoard"
local FLASH_SECONDS = 6 -- how long the "NOW!" banner stays up after a spawn

-- One clock per Config.Events entry, plus every board label showing it.
type EventState = {
	cfg: any,
	nextAt: number,
	labels: { TextLabel },
}

local states: { EventState } = {}
local squishyService: any = nil

-- "09:44", or "0:07" under a minute — the reference board's format.
local function formatClock(seconds: number): string
	local whole = math.max(0, math.floor(seconds + 0.5))
	return ("%02d:%02d"):format(math.floor(whole / 60), whole % 60)
end

-- The board: a dark panel on two legs with one line per event.
local function buildBoard(map: any): { TextLabel }
	local board = Instance.new("Model")
	board.Name = BOARD_NAME

	local fieldSize = Config.Field.Size :: Vector2
	local spec = Config.EventBoard
	local size = spec.Size :: Vector2
	local offset = spec.Offset :: Vector3
	local centre = Vector3.new(
		fieldSize.X * offset.X,
		spec.Height :: number,
		fieldSize.Y * offset.Z
	)

	local panel = Instance.new("Part")
	panel.Name = "Panel"
	panel.Size = Vector3.new(size.X, size.Y, 1)
	panel.CFrame = CFrame.new(centre)
	panel.Color = Palette.BoundaryWall
	panel.Material = Enum.Material.SmoothPlastic
	panel.Anchored = true
	panel.CanCollide = false
	panel.CanQuery = false
	panel.CanTouch = false
	panel.Parent = board

	-- Legs down to the ground so it reads as a structure, not a floating sign.
	for _, side in { -1, 1 } do
		local leg = Instance.new("Part")
		leg.Name = "Leg"
		leg.Size = Vector3.new(1.4, centre.Y - size.Y / 2, 1.4)
		leg.CFrame = CFrame.new(
			centre.X + side * (size.X / 2 - 3),
			(centre.Y - size.Y / 2) / 2,
			centre.Z
		)
		leg.Color = Palette.BoundaryWall
		leg.Material = Enum.Material.SmoothPlastic
		leg.Anchored = true
		leg.CanCollide = false
		leg.CanQuery = false
		leg.CanTouch = false
		leg.Parent = board
	end

	local labels: { TextLabel } = {}
	-- One SurfaceGui per face so the board reads from both sides of the field.
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Display" .. face.Name
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 26
		gui.LightInfluence = 0
		gui.Adornee = panel
		gui.Parent = panel

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0.02, 0)
		layout.Parent = gui

		for index, cfg in Config.Events :: { any } do
			local label = Instance.new("TextLabel")
			label.Name = ("Event%d"):format(index)
			label.LayoutOrder = index
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(0.94, 0.4)
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = cfg.color
			label.TextStrokeTransparency = 0
			label.TextStrokeColor3 = Color3.new(0, 0, 0)
			label.Text = ("Guaranteed %s in --:--"):format(cfg.name)
			label.Parent = gui
			table.insert(labels, label)
		end
	end

	board.Parent = map.root
	return labels
end

-- Public so tools/build_map_in_studio.luau can put the board into the SAVED
-- place, the same way the plot tool saves the bases. Returns the model.
function EventService.BuildBoard(map: any): Model
	local existing = map.root:FindFirstChild(BOARD_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
	buildBoard(map)
	return map.root:FindFirstChild(BOARD_NAME) :: Model
end

-- Every label for each event, keyed by event index.
--
-- Collected by NAME rather than by position in a flat list, because a board
-- saved in the place may have been moved, re-parented or had a face's gui
-- rebuilt by hand — and "every label at stride #Config.Events" only holds for
-- one this service built itself moments ago.
local function collectLabels(board: Instance): { { TextLabel } }
	local byEvent: { { TextLabel } } = {}
	for index = 1, #(Config.Events :: { any }) do
		byEvent[index] = {}
	end
	for _, descendant in board:GetDescendants() do
		if descendant:IsA("TextLabel") then
			local index = tonumber(descendant.Name:match("^Event(%d+)$"))
			if index ~= nil and byEvent[index] ~= nil then
				table.insert(byEvent[index], descendant)
			end
		end
	end
	return byEvent
end

function EventService.Start(services: any, map: any)
	squishyService = services.SquishyService

	-- A board saved in the place WINS, exactly as a hand-edited map does: the
	-- owner may have moved or restyled it, and regenerating would undo that.
	-- Only a place without one gets a freshly built board.
	local board = map.root:FindFirstChild(BOARD_NAME)
	if board == nil then
		local ok, err = pcall(buildBoard, map)
		if not ok then
			warn(("[EventService] board failed: %s"):format(tostring(err)))
			return
		end
		board = map.root:FindFirstChild(BOARD_NAME)
	end
	if board == nil then
		warn("[EventService] no event board to drive")
		return
	end

	local byEvent = collectLabels(board)
	local now = os.clock()
	for index, cfg in Config.Events :: { any } do
		local own = byEvent[index] or {}
		if #own == 0 then
			warn(
				("[EventService] the saved event board has no TextLabel named 'Event%d', so the %s countdown has nowhere to show. Keep one label per event named Event1..EventN on each face, or delete Workspace.Map.%s to have it rebuilt."):format(
					index,
					tostring(cfg.name),
					BOARD_NAME
				)
			)
		end
		-- Every face's label for this event travels together.
		local state: any = {
			cfg = cfg,
			nextAt = now + cfg.interval,
			labels = own,
		}
		table.insert(states, state)
	end

	task.spawn(function()
		while true do
			task.wait(TICK)
			local clock = os.clock()
			for _, state in states do
				local okTick, err = pcall(function()
					local remaining = state.nextAt - clock
					local text
					if remaining <= 0 then
						-- Land it, re-arm, and shout about it for a few seconds.
						if remaining > -FLASH_SECONDS then
							text = ("%s SPAWNED!"):format(state.cfg.name:upper())
						end
						if remaining > -TICK then
							if squishyService ~= nil then
								squishyService.SpawnRarity(state.cfg.rarity)
							end
						end
						if remaining <= -FLASH_SECONDS then
							state.nextAt = clock + state.cfg.interval
							text = ("Guaranteed %s in %s"):format(state.cfg.name, formatClock(state.cfg.interval))
						end
					else
						text = ("Guaranteed %s in %s"):format(state.cfg.name, formatClock(remaining))
					end
					if text ~= nil then
						for _, label in state.labels do
							label.Text = text
						end
					end
				end)
				if not okTick then
					warn(("[EventService] tick failed: %s"):format(tostring(err)))
				end
			end
		end
	end)
end

return EventService
