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
local spin = Instance.new("RemoteFunction")
spin.Name = "Spin"
spin.Parent = remotes
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
} do
	local ok, err = pcall(function()
		services[name].Start(services, map)
	end)
	if not ok then
		warn(("[%s] %s failed to start: %s"):format(Config.GameName, name, tostring(err)))
	end
end

print(("[%s] server up"):format(Config.GameName))
