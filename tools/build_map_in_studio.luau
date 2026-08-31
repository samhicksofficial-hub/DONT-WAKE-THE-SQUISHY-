--!strict
-- RUN THIS IN STUDIO'S COMMAND BAR (Edit mode, not while playing).
--
--   1. Copy this whole file.
--   2. Paste it into View -> Command Bar, press Enter.
--   3. The arena appears in Workspace. Move, recolour and add whatever you like.
--   4. Ctrl+S to save the place. Your edits now survive every server start.
--
-- It generates the map, then ticks HandEdited on Workspace.Map, which tells
-- MapBuilder to stop generating and keep what is saved instead.
--
-- IMPORTANT — Studio caches scripts for the whole session. If you have already
-- pressed Play or run this once since opening the place, Studio may replay the
-- OLD code and build an out-of-date map. Close and reopen the place first, then
-- run this before anything else, and you will get the current design.

local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local server = ServerScriptService:FindFirstChild("Server")
assert(server, "ServerScriptService.Server is missing — is Rojo connected?")

-- Start from a clean slate so nothing from a previous run is left behind.
for _, name in { "Map", "Squishies", "Enemies", "Plots" } do
	local existing = Workspace:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end

local ok, err = pcall(function()
	require(server.LightingService).Apply()
	local map = require(server.MapBuilder).Build()

	-- Drop editable markers for the eight base positions. Move these parts and
	-- the bases follow — MapBuilder reads them in preference to its own layout.
	local spots = Instance.new("Folder")
	spots.Name = "PlotSpots"
	for index, cframe in map.plotSpots do
		local marker = Instance.new("Part")
		marker.Name = "PlotSpot" .. tostring(index)
		marker.Size = Vector3.new(6, 1, 10)
		marker.CFrame = cframe
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Transparency = 0.5
		marker.Color = Color3.fromRGB(255, 120, 190)
		marker.Parent = spots
	end
	spots.Parent = map.root

	-- The countdown sign. EventService normally builds this at server start,
	-- but then it only ever exists while the game is running and can never be
	-- moved or restyled. Built here it lands in the saved place, and the
	-- service adopts it instead of making its own.
	require(server.EventService).BuildBoard(map)

	-- The switch that protects your edits.
	map.root:SetAttribute("HandEdited", true)
end)

if ok then
	print("[MapTool] Map built and marked HandEdited. Edit it, then Ctrl+S to save.")
	print("[MapTool] Pink PlotSpot markers set where each base gets built — move them to move a base.")
	print("[MapTool] Workspace.Map.EventBoard is the countdown sign — move or restyle it freely.")
	print("[MapTool]   Keep its TextLabels named Event1..EventN; that is how the clocks find them.")
else
	warn("[MapTool] failed: " .. tostring(err))
end
