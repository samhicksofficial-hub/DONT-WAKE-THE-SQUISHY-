--!strict
-- DailyUi — the seven-day login reward panel.
--
-- The Essential UI Pack ships no daily-rewards frame, so this one is built in
-- code and styled to match it: a rounded dark panel with a blue title bar, a
-- red X, a row of day cards and a claim button. It lives in the pack's own
-- ScreenGui so it shares the pack's layering and reset behaviour.
--
-- Server state arrives on attributes (DailyStreak, DailyClaimable,
-- DailyNextDay); claiming goes out on the DailyClaim RemoteFunction.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DailyUi = {}

local FONT = Enum.Font.FredokaOne
local PANEL_BG = Color3.fromRGB(24, 26, 34)
local TITLE_BG = Color3.fromRGB(58, 152, 235)
local CARD_LOCKED = Color3.fromRGB(38, 44, 58)
local CARD_CLAIMED = Color3.fromRGB(40, 78, 52)
local CARD_READY = Color3.fromRGB(96, 200, 108)
local CLAIM_GREEN = Color3.fromRGB(96, 216, 104)
local TEXT = Color3.new(1, 1, 1)
local TEXT_DIM = Color3.fromRGB(168, 174, 188)
local CLOSE_RED = Color3.fromRGB(232, 64, 82)

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
	item.Parent = parent
	return item
end

function DailyUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()

	-- ---------------------------------------------------------- the panel --

	local panel = Instance.new("Frame")
	panel.Name = "DailyRewards"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.62, 0.5)
	panel.BackgroundColor3 = PANEL_BG
	panel.BackgroundTransparency = 0.08
	panel.Visible = false
	panel.ZIndex = 30
	panel.Parent = refs.gui:FindFirstChild("Frames") or refs.gui
	corner(panel, 0.05)
	stroke(panel, 3, Color3.new(0, 0, 0))

	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1.9
	ratio.DominantAxis = Enum.DominantAxis.Width
	ratio.Parent = panel

	local title = Instance.new("Frame")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.16)
	title.BackgroundColor3 = TITLE_BG
	title.ZIndex = 31
	title.Parent = panel
	corner(title, 0.25)
	label(title, "Daily Rewards", UDim2.fromScale(0.7, 0.8), UDim2.fromScale(0.04, 0.1), TEXT).ZIndex = 32

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.fromScale(0.98, 0.5)
	close.Size = UDim2.fromScale(0.075, 0.7)
	close.BackgroundColor3 = CLOSE_RED
	close.Text = "X"
	close.Font = FONT
	close.TextScaled = true
	close.TextColor3 = TEXT
	close.ZIndex = 32
	close.Parent = title
	corner(close, 0.25)
	stroke(close, 2, Color3.new(0, 0, 0))

	-- ------------------------------------------------------------- cards --

	local grid = Instance.new("Frame")
	grid.Name = "Days"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.02, 0.19)
	grid.Size = UDim2.fromScale(0.96, 0.56)
	grid.ZIndex = 31
	grid.Parent = panel

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.132, 0.46)
	layout.CellPadding = UDim2.fromScale(0.008, 0.05)
	layout.FillDirectionMaxCells = 7
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	type Card = { frame: Frame, status: TextLabel }
	local cards: { Card } = {}

	for _, reward in Config.DailyRewards :: { any } do
		local card = Instance.new("Frame")
		card.Name = ("Day%d"):format(reward.day)
		card.LayoutOrder = reward.day
		card.BackgroundColor3 = CARD_LOCKED
		card.ZIndex = 32
		card.Parent = grid
		corner(card, 0.12)
		stroke(card, 2, Color3.new(0, 0, 0))

		label(card, ("Day %d"):format(reward.day), UDim2.fromScale(0.9, 0.2), UDim2.fromScale(0.05, 0.04), TEXT_DIM).ZIndex = 33
		label(card, reward.label, UDim2.fromScale(0.9, 0.34), UDim2.fromScale(0.05, 0.28), TEXT).ZIndex = 33
		local status = label(card, "Locked", UDim2.fromScale(0.9, 0.22), UDim2.fromScale(0.05, 0.7), TEXT_DIM)
		status.ZIndex = 33

		table.insert(cards, { frame = card, status = status })
	end

	-- ------------------------------------------------------ claim button --

	local claim = Instance.new("TextButton")
	claim.Name = "ClaimAll"
	claim.AnchorPoint = Vector2.new(0.5, 1)
	claim.Position = UDim2.fromScale(0.5, 0.97)
	claim.Size = UDim2.fromScale(0.4, 0.17)
	claim.BackgroundColor3 = CLAIM_GREEN
	claim.Text = "CLAIM"
	claim.Font = FONT
	claim.TextScaled = true
	claim.TextColor3 = TEXT
	claim.ZIndex = 32
	claim.Parent = panel
	corner(claim, 0.25)
	stroke(claim, 3, Color3.new(0, 0, 0))

	-- ------------------------------------------------------------- state --

	local function readNumber(attribute: string, fallback: number): number
		local raw = player:GetAttribute(attribute)
		return typeof(raw) == "number" and raw or fallback
	end

	local function refresh()
		local streak = readNumber("DailyStreak", 0)
		local nextDay = readNumber("DailyNextDay", 1)
		local claimable = player:GetAttribute("DailyClaimable") == true

		for index, card in cards do
			if index <= streak and not (claimable and index == nextDay) then
				card.frame.BackgroundColor3 = CARD_CLAIMED
				card.status.Text = "Claimed"
				card.status.TextColor3 = TEXT_DIM
			elseif claimable and index == nextDay then
				card.frame.BackgroundColor3 = CARD_READY
				card.status.Text = "Claim!"
				card.status.TextColor3 = TEXT
			else
				card.frame.BackgroundColor3 = CARD_LOCKED
				card.status.Text = "Locked"
				card.status.TextColor3 = TEXT_DIM
			end
		end

		claim.Text = claimable and ("CLAIM DAY %d"):format(nextDay) or "COME BACK TOMORROW"
		claim.BackgroundColor3 = claimable and CLAIM_GREEN or CARD_LOCKED
		claim.Active = claimable
		claim.AutoButtonColor = claimable
	end

	local claimRemote: RemoteFunction? = nil
	task.spawn(function()
		claimRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DailyClaim") :: RemoteFunction
	end)

	local busy = false
	UiRefs.bindButton(claim, function()
		if busy or player:GetAttribute("DailyClaimable") ~= true then
			return
		end
		local remote = claimRemote
		if remote == nil then
			return
		end
		busy = true
		-- A RemoteFunction can error or hang, so never block the button on it.
		task.spawn(function()
			local ok, day = pcall(function()
				return remote:InvokeServer()
			end)
			busy = false
			if ok and typeof(day) == "number" then
				UiRefs.notify(("Day %d reward claimed!"):format(day), 4)
			end
			refresh()
		end)
	end)

	UiRefs.bindButton(close, function()
		panel.Visible = false
	end)

	player:GetAttributeChangedSignal("DailyClaimable"):Connect(refresh)
	player:GetAttributeChangedSignal("DailyStreak"):Connect(refresh)
	player:GetAttributeChangedSignal("DailyNextDay"):Connect(refresh)
	refresh()

	-- Opens itself once on join when there is something waiting — the whole
	-- point of a daily reward is that you see it.
	task.spawn(function()
		task.wait(2)
		if player:GetAttribute("DailyClaimable") == true then
			panel.Visible = true
			panel.Size = UDim2.fromScale(0.5, 0.4)
			TweenService:Create(
				panel,
				TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(0.62, 0.5) }
			):Play()
		end
	end)

	DailyUi.Toggle = function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			refresh()
		end
	end
end

return DailyUi
