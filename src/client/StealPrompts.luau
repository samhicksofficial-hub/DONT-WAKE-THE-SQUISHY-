--!strict
-- StealPrompts — hides the Steal prompt on the local player's OWN squishies.
--
-- A ProximityPrompt is one server instance shared by every client, so there is
-- no server-side way to show it to thieves and not the owner. The server
-- (StealService.tryGrab) refuses an owner regardless; this just trims the
-- confusing "Steal" offer out of the owner's view. Enabled set from a local
-- script never replicates back, so the prompt stays live for everyone else.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace = game:GetService("Workspace")

local StealPrompts = {}

-- True when `instance` sits inside the local player's plot model. PlotService
-- names each plot model in Workspace.Plots after its owner.
local function onOwnPlot(instance: Instance): boolean
	local plotFolder = Workspace:FindFirstChild("Plots")
	if plotFolder == nil then
		return false
	end
	local node: Instance? = instance
	while node ~= nil and node ~= Workspace do
		if node.Parent == plotFolder then
			return node.Name == Players.LocalPlayer.Name
		end
		node = node.Parent
	end
	return false
end

function StealPrompts.Start()
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == "StealPrompt" and onOwnPlot(prompt) then
			prompt.Enabled = false
		end
	end)
end

return StealPrompts
