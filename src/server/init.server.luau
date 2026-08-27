--!strict
-- Server entry point. Rojo maps this folder to ServerScriptService.Server.
-- Creates remotes, builds the map, then boots every service with a shared
-- `services` table (see DESIGN.md — services never require each other).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- Remotes the client listens to.
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
local popup = Instance.new("RemoteEvent")
popup.Name = "Popup"
popup.Parent = remotes
remotes.Parent = ReplicatedStorage

local services = {} :: any
services.Config = Config
services.EconomyService = require(script.EconomyService) :: any
services.PlotService = require(script.PlotService) :: any
services.SquishyService = require(script.SquishyService) :: any
services.EnemyService = require(script.EnemyService) :: any

local map = (require(script.MapBuilder) :: any).Build()

services.EconomyService.Start(services, map)
services.PlotService.Start(services, map)
services.SquishyService.Start(services, map)
services.EnemyService.Start(services, map)

print(("[%s] server up"):format(Config.GameName))
