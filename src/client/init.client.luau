--!strict
-- Client entry point. Rojo maps this folder to
-- StarterPlayer.StarterPlayerScripts.Client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

for _, moduleName in { "Hud", "AlertUi", "Popups" } do
	local module = script:FindFirstChild(moduleName)
	if module then
		local ok, err = pcall(function()
			(require(module) :: any).Start()
		end)
		if not ok then
			warn(("[%s] %s failed to start: %s"):format(Config.GameName, moduleName, tostring(err)))
		end
	end
end

print(("[%s] client up"):format(Config.GameName))
