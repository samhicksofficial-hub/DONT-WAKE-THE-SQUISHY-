--!strict
-- Client entry point. Rojo maps this folder to
-- StarterPlayer.StarterPlayerScripts.Client.
--
-- Every module drives the Essential UI Pack tree via UiRefs; none of them
-- build their own ScreenGui. See the UI Contract in DESIGN.md.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- UiRefs resolves the pack tree first so the rest can assume it exists. Guarded:
-- one renamed/missing pack node makes get() error after a 20s wait, and
-- unprotected here that would abort the whole client — no HUD, no shop, no
-- purchases, and even the pack-independent modules below never start. On failure
-- we warn (so the missing path is diagnosable) and press on; the pack-dependent
-- modules fail individually in the pcall loop, the rest still run.
do
	local okUi, errUi = pcall(function()
		require(script:WaitForChild("UiRefs")).get()
	end)
	if not okUi then
		warn(("[%s] UI pack failed to resolve: %s"):format(Config.GameName, tostring(errUi)))
	end
end

-- DebugPanel is last and Studio-only: it builds its own overlay rather than
-- driving the pack, so it must never delay the real UI coming up.
for _, moduleName in { "Hud", "AlertUi", "Panels", "IndexUi", "ShopUi", "RebirthUi", "WheelUi", "OfflineUi", "DailyUi", "BoostUi", "Popups", "EnemyBounce", "StealPrompts", "DebugPanel" } do
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
