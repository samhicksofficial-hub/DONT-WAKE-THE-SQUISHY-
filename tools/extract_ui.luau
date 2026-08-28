--!strict
-- Extract the Essential UI Pack's ScreenGui and Lighting rig into .rbxm files
-- the repo can own and Rojo can sync.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local PLACE = "C:/Users/crocs/Downloads/Essential UI Pack - Swarve Studios.rbxl"
local REPO = "C:/Users/crocs/OneDrive/Documents/GitHub/DONT WAKE THE SQUISHY!"

local game = roblox.deserializePlace(fs.readFile(PLACE))

-- ---- the GUI ----
local gui = game:GetService("StarterGui"):FindFirstChild("GUI")
assert(gui, "no StarterGui.GUI in the pack")
gui.Name = "MainUi";
-- Survive respawns, use the full screen, and let ZIndex nest sanely.
(gui :: any).ResetOnSpawn = false;
(gui :: any).IgnoreGuiInset = true;
(gui :: any).ZIndexBehavior = roblox.Enum.ZIndexBehavior.Sibling

-- Panels start hidden; the client shows them on demand.
local frames = gui:FindFirstChild("Frames")
if frames then
	for _, panel in frames:GetChildren() do
		if panel:IsA("Frame") and panel.Name ~= "Notifications" then
			panel.Visible = false
		end
	end
end

fs.writeFile(REPO .. "/Assets/MainUi.rbxm", roblox.serializeModel({ gui }))
print("wrote Assets/MainUi.rbxm")

-- ---- the lighting rig ----
local lighting = game:GetService("Lighting")
local rig = {}
-- (lighting rig now built in code; see src/server/LightingService.luau)
for _, child in lighting:GetChildren() do
	table.insert(rig, child)
end
fs.writeFile(REPO .. "/Assets/LightingRig.rbxm", roblox.serializeModel(rig))
print("wrote Assets/LightingRig.rbxm with " .. #rig .. " effects")

-- Report the scalar Lighting properties so they can be set in project.json.
for _, name in { "Ambient", "OutdoorAmbient", "Brightness", "ClockTime", "GeographicLatitude", "FogEnd", "GlobalShadows", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ExposureCompensation", "Technology" } do
	local ok, value = pcall(function()
		return (lighting :: any)[name]
	end)
	if ok then
		print(("  %s = %s"):format(name, tostring(value)))
	end
end
