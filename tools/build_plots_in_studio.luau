--!strict
-- RUN THIS IN STUDIO'S COMMAND BAR (Edit mode, not while playing).
--
--   1. Copy this whole file.
--   2. Paste it into View -> Command Bar, press Enter.
--   3. Workspace.PlotShells appears with all eight base buildings in it.
--      Move, recolour, add props, delete walls — whatever you like.
--   4. Ctrl+S to save the place. Your edits now survive every server start.
--
-- WHY A SEPARATE FOLDER. Workspace.Plots is the RUNTIME folder: the server
-- fills it with live plots as players join and empties it as they leave, so
-- anything left there by hand is thrown away within seconds of pressing Play.
-- PlotShells is the SOURCE. The server copies from it and never writes to it,
-- so what you edit is what every player gets.
--
-- The furniture is built into the shells too, so a re-run is needed after this
-- change: delete Workspace.PlotShells and run the tool again to get the
-- pedestals and collect pads into them.
--
-- WHAT THE SERVER TAKES FROM A SHELL. Everything you see: floor, walls, roof,
-- windows, ceiling lights, the ladder, the spawn point, AND the slot furniture —
-- the tile borders, platforms, pedestals and collect pads. Move a pillar or a
-- collect pad here and it moves in the live game.
--
-- What is still built at run time: the upgrade plaques, the unlock pads on
-- locked slots. Those are wired to live per-player state.
--
-- Every slot gets a collect pad here, including ones that start locked. A shell
-- does not know whose plot it will become, so the server hides the pads of
-- still-locked slots rather than deleting them, and brings them back on unlock.
--
--   * Keep the part named SpawnPoint. It is where the owner spawns, and a
--     shell without one is ignored.
--   * The vacant sign is swapped for the house marker and the owner's name
--     board automatically when someone claims the plot.
--
-- FLOORS ARE THE ONE CATCH. Shells are saved at a fixed storey count (one
-- floor unless you pass a different one below). When a player buys a floor the
-- building has to be re-cut for the new height, so that plot goes back to the
-- generator and your edits do not apply to it. Everything at the saved floor
-- count keeps using your version.
--
-- IMPORTANT — Studio caches scripts for the whole session. If you have already
-- pressed Play or run this once since opening the place, close and reopen the
-- place first, or you may rebuild from stale code.

local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

-- Storeys to save the shells at. Leave both 0 to edit the starting building,
-- which is what every player has until they buy their first floor.
local FLOORS = { above = 0, below = 0 }

local server = ServerScriptService:FindFirstChild("Server")
assert(server, "ServerScriptService.Server is missing — is Rojo connected?")

local BaseBuilder = require(server.BaseBuilder) :: any
local MapBuilder = require(server.MapBuilder) :: any
local PlotService = require(server.PlotService) :: any

-- Rebuilt from scratch so a re-run never leaves half of an old design behind.
local existing = Workspace:FindFirstChild("PlotShells")
if existing then
	existing:Destroy()
end

local ok, err = pcall(function()
	-- Build() is what knows where the eight spots are, including any PlotSpot
	-- markers you have moved by hand. On a HandEdited map it generates nothing
	-- into the world, so calling it here is safe.
	local map = MapBuilder.Build()

	local folder = Instance.new("Folder")
	folder.Name = "PlotShells"

	local built = 0
	for index, spotCFrame in map.plotSpots do
		local spotPos = spotCFrame.Position
		local baseCFrame = CFrame.new(spotPos.X, 0, spotPos.Z) * spotCFrame.Rotation

		local model = Instance.new("Model")
		model.Name = ("PlotShell%d"):format(index)
		-- nil player: shells are saved unowned and wear the vacant sign. The
		-- server swaps that for the house marker and name board on claim.
		local shell = BaseBuilder.Build(nil, model, baseCFrame, FLOORS)
		-- ...then the furniture that stands on its floors: tile borders,
		-- platforms, pedestals and collect pads. The server finds these by name
		-- and reuses them, so moving a pillar here moves it in the live game.
		PlotService.BuildSlotFurniture(model, baseCFrame, shell.floorTops, shell.groundIndex)
		BaseBuilder.TagShell(model, index, FLOORS)
		model.Parent = folder
		built += 1
	end

	-- The switch that protects your edits. Without it the server generates as
	-- before and PlotShells is ignored entirely, so you can flip this off to
	-- compare against the generated version without deleting your work.
	folder:SetAttribute("HandEdited", true)
	folder.Parent = Workspace

	print(("[PlotTool] Built %d shells into Workspace.PlotShells."):format(built))
end)

if ok then
	print("[PlotTool] Edit them, then Ctrl+S to save. The server copies from PlotShells at run time.")
	print("[PlotTool] Untick HandEdited on the folder to go back to generated bases without losing your edits.")
else
	warn(("[PlotTool] Failed: %s"):format(tostring(err)))
end
