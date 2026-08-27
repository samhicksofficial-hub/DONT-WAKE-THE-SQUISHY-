--!strict
-- Top-center money HUD. Mirrors the local player's Money attribute with a
-- short count-up tween and a scale "pop" whenever the value changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"))

local COUNT_DURATION = 0.3

local Hud = {}

local function readMoney(player: Player): number
	local raw = player:GetAttribute("Money")
	if typeof(raw) == "number" then
		return raw
	end
	return 0
end

function Hud.Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SquishyHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local holder = Instance.new("Frame")
	holder.Name = "MoneyHolder"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, 10)
	holder.Size = UDim2.fromOffset(300, 56)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local popScale = Instance.new("UIScale")
	popScale.Name = "PopScale"
	popScale.Parent = holder

	local label = Instance.new("TextLabel")
	label.Name = "MoneyLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.fromRGB(85, 255, 85)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.Parent = holder

	local outline = Instance.new("UIStroke")
	outline.Name = "TextOutline"
	outline.Color = Color3.new(0, 0, 0)
	outline.Thickness = 3
	outline.Parent = label

	local displayed = readMoney(player)
	label.Text = Util.formatMoney(displayed)

	local countConn: RBXScriptConnection? = nil
	local animFrom = displayed
	local animTarget = displayed
	local animStart = 0

	local function stopCount()
		if countConn then
			countConn:Disconnect()
			countConn = nil
		end
	end

	local function animateTo(target: number)
		animFrom = displayed
		animTarget = target
		animStart = os.clock()
		if countConn then
			return
		end
		countConn = RunService.RenderStepped:Connect(function()
			local alpha = math.clamp((os.clock() - animStart) / COUNT_DURATION, 0, 1)
			displayed = animFrom + (animTarget - animFrom) * alpha
			label.Text = Util.formatMoney(displayed)
			if alpha >= 1 then
				displayed = animTarget
				stopCount()
			end
		end)
	end

	local popInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
	local popTween = TweenService:Create(popScale, popInfo, { Scale = 1.15 })

	player:GetAttributeChangedSignal("Money"):Connect(function()
		local target = readMoney(player)
		if target == displayed and countConn == nil then
			return
		end
		animateTo(target)
		popTween:Cancel()
		popScale.Scale = 1
		popTween:Play()
	end)
end

return Hud
