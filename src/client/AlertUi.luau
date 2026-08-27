--!strict
-- Screen alerts: a pulsing red edge vignette + "RUN!!!" banner while an enemy
-- is chasing the local player, and a bottom-center carry-slowdown indicator.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local EDGE_THICKNESS = 10

local AlertUi = {}

function AlertUi.Start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "SquishyAlerts"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	-- Chase warning ---------------------------------------------------------

	local warning = Instance.new("Frame")
	warning.Name = "ChaseWarning"
	warning.BackgroundTransparency = 1
	warning.Size = UDim2.fromScale(1, 1)
	warning.Visible = false
	warning.Parent = gui

	local pulseTweens: { Tween } = {}
	local edgeInfo = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local edgeDefs = {
		{ UDim2.fromScale(0, 0), UDim2.new(1, 0, 0, EDGE_THICKNESS) },
		{ UDim2.new(0, 0, 1, -EDGE_THICKNESS), UDim2.new(1, 0, 0, EDGE_THICKNESS) },
		{ UDim2.fromScale(0, 0), UDim2.new(0, EDGE_THICKNESS, 1, 0) },
		{ UDim2.new(1, -EDGE_THICKNESS, 0, 0), UDim2.new(0, EDGE_THICKNESS, 1, 0) },
	}
	for index, def in edgeDefs do
		local edge = Instance.new("Frame")
		edge.Name = "Edge" .. index
		edge.Position = def[1]
		edge.Size = def[2]
		edge.BackgroundColor3 = Color3.fromRGB(255, 45, 45)
		edge.BackgroundTransparency = 0.1
		edge.BorderSizePixel = 0
		edge.Parent = warning
		table.insert(pulseTweens, TweenService:Create(edge, edgeInfo, { BackgroundTransparency = 0.75 }))
	end

	local runHolder = Instance.new("Frame")
	runHolder.Name = "RunHolder"
	runHolder.AnchorPoint = Vector2.new(0.5, 0)
	runHolder.Position = UDim2.new(0.5, 0, 0, 90)
	runHolder.Size = UDim2.fromOffset(340, 76)
	runHolder.BackgroundTransparency = 1
	runHolder.Parent = warning

	local runScale = Instance.new("UIScale")
	runScale.Name = "PulseScale"
	runScale.Parent = runHolder

	local runLabel = Instance.new("TextLabel")
	runLabel.Name = "RunLabel"
	runLabel.BackgroundTransparency = 1
	runLabel.Size = UDim2.fromScale(1, 1)
	runLabel.Font = Enum.Font.FredokaOne
	runLabel.Text = "RUN!!!"
	runLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
	runLabel.TextStrokeTransparency = 0
	runLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	runLabel.TextScaled = true
	runLabel.Parent = runHolder

	table.insert(pulseTweens, TweenService:Create(
		runScale,
		TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.18 }
	))

	local warningShown = false
	local function setWarning(shown: boolean)
		if shown == warningShown then
			return
		end
		warningShown = shown
		warning.Visible = shown
		for _, tween in pulseTweens do
			if shown then
				tween:Play()
			else
				tween:Cancel()
			end
		end
	end

	-- Carry indicator -------------------------------------------------------

	local carryLabel = Instance.new("TextLabel")
	carryLabel.Name = "CarryLabel"
	carryLabel.AnchorPoint = Vector2.new(0.5, 1)
	carryLabel.Position = UDim2.new(0.5, 0, 1, -28)
	carryLabel.Size = UDim2.fromOffset(520, 36)
	carryLabel.BackgroundTransparency = 1
	carryLabel.Font = Enum.Font.FredokaOne
	carryLabel.TextColor3 = Color3.fromRGB(255, 225, 120)
	carryLabel.TextStrokeTransparency = 0
	carryLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	carryLabel.TextScaled = true
	carryLabel.Visible = false
	carryLabel.Parent = gui

	local function updateCarry()
		local carrying = player:GetAttribute("Carrying")
		if typeof(carrying) == "string" and carrying ~= "" then
			local rawMult = player:GetAttribute("CarrySpeedMult")
			local mult = if typeof(rawMult) == "number" then rawMult :: number else 1
			local slow = math.floor((1 - mult) * 100 + 0.5)
			carryLabel.Text = ("Carrying %s  (%d%% slower)"):format(carrying :: string, slow)
			carryLabel.Visible = true
		else
			carryLabel.Visible = false
		end
	end

	player:GetAttributeChangedSignal("Carrying"):Connect(updateCarry)
	player:GetAttributeChangedSignal("CarrySpeedMult"):Connect(updateCarry)
	updateCarry()

	-- Enemy watching (spawned so Start never blocks the other UI modules) ----

	task.spawn(function()
		local enemiesFolder = workspace:WaitForChild("Enemies")
		local enemyConns: { [Instance]: { RBXScriptConnection } } = {}

		local function refresh()
			local threat = false
			for _, enemy in enemiesFolder:GetChildren() do
				local ok, isThreat = pcall(function()
					return enemy:GetAttribute("State") == "Chasing"
						and enemy:GetAttribute("TargetUserId") == player.UserId
				end)
				if ok and isThreat == true then
					threat = true
					break
				end
			end
			setWarning(threat)
		end

		local function watchEnemy(enemy: Instance)
			local conns = {
				enemy:GetAttributeChangedSignal("State"):Connect(refresh),
				enemy:GetAttributeChangedSignal("TargetUserId"):Connect(refresh),
			}
			enemyConns[enemy] = conns
		end

		for _, enemy in enemiesFolder:GetChildren() do
			watchEnemy(enemy)
		end
		enemiesFolder.ChildAdded:Connect(function(child)
			watchEnemy(child)
			refresh()
		end)
		enemiesFolder.ChildRemoved:Connect(function(child)
			local conns = enemyConns[child]
			if conns then
				for _, conn in conns do
					conn:Disconnect()
				end
				enemyConns[child] = nil
			end
			refresh()
		end)
		refresh()
	end)
end

return AlertUi
