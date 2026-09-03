--!strict
-- Server entry point. Rojo maps this folder to ServerScriptService.Server.
-- Creates remotes, builds the map, then boots every service with a shared
-- `services` table (see DESIGN.md — services never require each other).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- Remotes the client talks to (see the UI Contract in DESIGN.md).
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, name in { "Popup", "Drop", "BuyUpgrade", "DoRebirth", "Discovered" } do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotes
end
for _, name in { "Spin", "DailyClaim" } do
	local fn = Instance.new("RemoteFunction")
	fn.Name = name
	fn.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local services = {} :: any
services.Config = Config
services.EconomyService = require(script.EconomyService) :: any
services.UpgradeService = require(script.UpgradeService) :: any
services.RebirthService = require(script.RebirthService) :: any
services.DiscoveryService = require(script.DiscoveryService) :: any
services.WheelService = require(script.WheelService) :: any
services.PlotService = require(script.PlotService) :: any
services.SquishyService = require(script.SquishyService) :: any
services.EnemyService = require(script.EnemyService) :: any
services.SpawnService = require(script.SpawnService) :: any
services.EventService = require(script.EventService) :: any
services.DailyService = require(script.DailyService) :: any
services.ShopService = require(script.ShopService) :: any
services.GearService = require(script.GearService) :: any
services.StealService = require(script.StealService) :: any
services.PortalService = require(script.PortalService) :: any
-- Studio only: its Start does nothing and publishes no remote elsewhere.
services.DebugService = require(script.DebugService) :: any

local map = (require(script.MapBuilder) :: any).Build()
require(script.LightingService).Apply()

-- Order matters: economy and progression own the attributes the gameplay
-- services read, so they start first.
for _, name in {
	"EconomyService",
	"UpgradeService",
	"RebirthService",
	"DiscoveryService",
	"WheelService",
	"PlotService",
	"SquishyService",
	"EnemyService",
	-- Last: it moves arriving characters onto the base PlotService just built.
	"SpawnService",
	"EventService",
	"DailyService",
	-- Owns the game's single ProcessReceipt; StealService registers into it,
	-- so the router must be standing first.
	"ShopService",
	-- Order-free: PlotService dresses the basement stands through the module
	-- table as it builds, and every entry point it calls reads only Config and
	-- ServerStorage. Start here just wires ownership and the purchase signal.
	"GearService",
	-- Last: it walks the finished plots to attach its prompts.
	"StealService",
	-- Needs the map root resolved and the saved props in place.
	"PortalService",
	-- Truly last: the dev panel drives every service above through the
	-- `services` table, so they all have to be up before it opens for business.
	"DebugService",
} do
	local ok, err = pcall(function()
		services[name].Start(services, map)
	end)
	if not ok then
		warn(("[%s] %s failed to start: %s"):format(Config.GameName, name, tostring(err)))
	end
end

print(("[%s] server up"):format(Config.GameName))
