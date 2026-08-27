--!strict
-- Floating "+$X" world popups, driven by the server's Popup RemoteEvent.
-- Each popup is a BillboardGui in PlayerGui adorned to a tiny invisible
-- anchored part at the collect position; it drifts up ~4 studs and fades.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"))

local MAX_POPUPS = 12
local LIFETIME = 1
local RISE_STUDS = 4

type PopupEntry = {
	gui: BillboardGui,
	part: BasePart,
	dead: boolean,
}

local Popups = {}

function Popups.Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local active: { PopupEntry } = {}

	local function destroyEntry(entry: PopupEntry)
		if entry.dead then
			return
		end
		entry.dead = true
		local index = table.find(active, entry)
		if index then
			table.remove(active, index)
		end
		entry.gui:Destroy()
		entry.part:Destroy()
	end

	local function spawnPopup(amount: number, worldPos: Vector3)
		local part = Instance.new("Part")
		part.Name = "PopupAnchor"
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CFrame = CFrame.new(worldPos)
		part.Parent = workspace

		local gui = Instance.new("BillboardGui")
		gui.Name = "MoneyPopup"
		gui.Adornee = part
		gui.Size = UDim2.fromScale(6, 1.6)
		gui.StudsOffset = Vector3.new(0, 1, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 250
		gui.Parent = playerGui

		local label = Instance.new("TextLabel")
		label.Name = "Amount"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = "+" .. Util.formatMoney(amount)
		label.TextColor3 = Color3.fromRGB(85, 255, 85)
		label.TextStrokeTransparency = 0
		label.TextStrokeColor3 = Color3.new(0, 0, 0)
		label.TextScaled = true
		label.Parent = gui

		local entry: PopupEntry = { gui = gui, part = part, dead = false }
		table.insert(active, entry)
		while #active > MAX_POPUPS do
			destroyEntry(active[1])
		end

		local driftInfo = TweenInfo.new(LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(gui, driftInfo, {
			StudsOffset = Vector3.new(0, 1 + RISE_STUDS, 0),
		}):Play()
		TweenService:Create(label, driftInfo, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()

		task.delay(LIFETIME + 0.1, function()
			destroyEntry(entry)
		end)
	end

	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Popup") :: RemoteEvent
		remote.OnClientEvent:Connect(function(amount: unknown, worldPos: unknown)
			local ok, err = pcall(function()
				if typeof(amount) == "number" and typeof(worldPos) == "Vector3" then
					spawnPopup(amount :: number, worldPos :: Vector3)
				end
			end)
			if not ok then
				warn("[Popups] " .. tostring(err))
			end
		end)
	end)
end

return Popups
