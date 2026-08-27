--!strict
-- Server entry point. Rojo maps this folder to ServerScriptService.Server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

print(("[%s] server up"):format(Config.GameName))
