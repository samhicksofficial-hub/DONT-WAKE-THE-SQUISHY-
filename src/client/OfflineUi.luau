--!strict
-- OfflineUi — the "while you were away" popup.
--
-- SaveService prices what the plot earned since the last save and parks it on
-- the OfflinePending attribute; this panel shows the figure and hands it over
-- through the OfflineClaim RemoteFunction. It deliberately opens BEFORE the
-- daily-rewards panel (DailyUi waits for OfflineChecked/OfflinePending), so a
-- returning player reads their earnings first and their streak second.
--
-- The shell is CLONED from a pack frame, exactly as DailyUi does it: the
-- frame, the nine-sliced title bar and the Close button are then the pack's
-- own art rather than an approximation of it.
--
-- There is no way to decline the money. Collect claims it, and so does the
-- title bar's X — a popup must never be able to eat a player's earnings just
-- because they clicked the wrong corner of it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local OfflineUi = {}

local FONT = Enum.Font.FredokaOne
local TEXT = Color3.new(1, 1, 1)
local TEXT_DIM = Color3.fromRGB(168, 174, 188)
local MONEY_GREEN = Color3.fromRGB(85, 255, 85)
local CLAIM_GREEN = Color3.fromRGB(96, 216, 104)
local PANEL_SIZE = UDim2.fromScale(0.4, 0.4)
local PANEL_SIZE_SMALL = UDim2.fromScale(0.3, 0.3)
local PANEL_ASPECT = 1.25

local function corner(parent: Instance, scale: number)
	local ui = Instance.new("UICorner")
	ui.CornerRadius = UDim.new(scale, 0)
	ui.Parent = parent
end

local function stroke(parent: Instance, thickness: number, color: Color3)
	local ui = Instance.new("UIStroke")
	ui.Thickness = thickness
	ui.Color = color
	ui.Parent = parent
end

local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3): TextLabel
	local item = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Size = size
	item.Position = pos
	item.Font = FONT
	item.Text = text
	item.TextColor3 = color
	item.TextScaled = true
	item.TextStrokeTransparency = 0.4
	item.TextStrokeColor3 = Color3.new(0, 0, 0)
	item.ZIndex = 32
	item.Parent = parent
	return item
end

-- Same donor-cloning trick as DailyUi, so this panel wears the pack's art.
local function buildShell(refs: any): (Frame?, GuiButton?)
	local frames = refs.gui:FindFirstChild("Frames")
	if frames == nil then
		return nil, nil
	end
	local donor = frames:FindFirstChild("Index") or frames:FindFirstChild("Shop")
	if donor == nil or not donor:IsA("Frame") then
		return nil, nil
	end

	local panel = donor:Clone()
	panel.Name = "OfflineEarnings"
	panel.Visible = false
	panel.Parent = frames

	for _, child in panel:GetChildren() do
		if child.Name ~= "Stroke" and child.Name ~= "Ratio" and child.Name ~= "Title" then
			child:Destroy()
		end
	end

	local ratio = panel:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio then
		ratio.AspectRatio = PANEL_ASPECT
	end
	panel.Size = PANEL_SIZE

	local title = panel:FindFirstChild("Title")
	local closeButton: GuiButton? = nil
	if title then
		for _, child in title:GetChildren() do
			if child:IsA("GuiButton") then
				closeButton = child
			elseif child:IsA("TextLabel") then
				child.Text = "While You Were Away"
			end
		end
	end
	return panel, closeButton
end

function OfflineUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()

	local panel, close = buildShell(refs)
	if panel == nil then
		warn("[OfflineUi] no pack panel to clone; offline earnings popup disabled")
		return
	end

	-- ----------------------------------------------------------- contents --

	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0.17)
	icon.Size = UDim2.fromScale(0.24, 0.26)
	icon.Image = Config.Icons.Cash
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 32
	icon.Parent = panel

	label(panel, "Your plot kept earning:", UDim2.fromScale(0.9, 0.1), UDim2.fromScale(0.05, 0.45), TEXT_DIM)
	local amountLabel = label(panel, "$0", UDim2.fromScale(0.9, 0.17), UDim2.fromScale(0.05, 0.55), MONEY_GREEN)

	local collect = Instance.new("TextButton")
	collect.Name = "Collect"
	collect.AnchorPoint = Vector2.new(0.5, 1)
	collect.Position = UDim2.fromScale(0.5, 0.94)
	collect.Size = UDim2.fromScale(0.42, 0.15)
	collect.BackgroundColor3 = CLAIM_GREEN
	collect.Text = "COLLECT"
	collect.Font = FONT
	collect.TextScaled = true
	collect.TextColor3 = TEXT
	collect.ZIndex = 32
	collect.Parent = panel
	corner(collect, 0.25)
	stroke(collect, 3, Color3.new(0, 0, 0))

	-- ----------------------------------------------------------- claiming --

	local claimRemote: RemoteFunction? = nil
	task.spawn(function()
		claimRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("OfflineClaim") :: RemoteFunction
	end)

	local claiming = false
	local function claim()
		if claiming then
			return
		end
		claiming = true
		task.spawn(function()
			local remote = claimRemote
			local amount: number? = nil
			if remote ~= nil then
				local ok, result = pcall(function()
					return remote:InvokeServer()
				end)
				if ok and typeof(result) == "number" then
					amount = result
				end
			end
			if amount ~= nil then
				UiRefs.notify(("+%s collected!"):format(Util.formatMoney(amount)), 4)
			end
			panel.Visible = false
			claiming = false
		end)
	end

	UiRefs.bindButton(collect, claim)
	if close ~= nil then
		-- The X collects too: closing the popup must never cost the money.
		UiRefs.bindButton(close, claim)
	end

	-- ------------------------------------------------------------ showing --

	local function maybeShow()
		local pending = player:GetAttribute("OfflinePending")
		if typeof(pending) ~= "number" or pending <= 0 or panel.Visible then
			return
		end
		amountLabel.Text = Util.formatMoney(pending)
		panel.Visible = true
		panel.Size = PANEL_SIZE_SMALL
		TweenService:Create(
			panel,
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = PANEL_SIZE }
		):Play()
	end

	player:GetAttributeChangedSignal("OfflinePending"):Connect(maybeShow)
	maybeShow()
end

return OfflineUi
