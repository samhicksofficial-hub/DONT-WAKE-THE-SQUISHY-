--!strict
-- Client entry point. Rojo maps this folder to
-- StarterPlayer.StarterPlayerScripts.Client.
--
-- Every module drives the Essential UI Pack tree via UiRefs; none of them
-- build their own ScreenGui. See the UI Contract in DESIGN.md.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- UiRefs resolves the pack tree first so the rest can assume it exists.
require(script:WaitForChild("UiRefs")).get()

-- DebugPanel is last and Studio-only: it builds its own overlay rather than
-- driving the pack, so it must never delay the real UI coming up.
for _, moduleName in { "Hud", "AlertUi", "Panels", "IndexUi", "UpgradesUi", "RebirthUi", "WheelUi", "DailyUi", "Popups", "EnemyBounce", "DebugPanel" } do
	local module = script:FindFirstChild(moduleName)
	if module then
		local ok, err = pcall(function()
			(require(module) :: any).Start()
		end)
		if not ok then
			warn(("[%s] %s failed to start: %s"):format(Config.GameName, moduleName, tostring(err)))
		end
	else
		warn(("[%s] missing client module %s"):format(Config.GameName, moduleName))
	end
end

print(("[%s] client up"):format(Config.GameName))
