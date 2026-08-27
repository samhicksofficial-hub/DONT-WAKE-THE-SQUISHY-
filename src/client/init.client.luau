--!strict
-- Client entry point. Rojo maps this folder to
-- StarterPlayer.StarterPlayerScripts.Client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

print(("[%s] client up"):format(Config.GameName))
