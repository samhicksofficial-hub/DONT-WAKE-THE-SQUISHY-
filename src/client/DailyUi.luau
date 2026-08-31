--!strict
-- DailyUi — the seven-day login reward panel.
--
-- The Essential UI Pack ships no daily-rewards frame, so this panel CLONES one
-- it does ship (Index) and swaps the contents out. Cloning rather than
-- rebuilding is the point: the frame, the nine-sliced blue title bar and the
-- Close button are then the pack's own art, not an approximation of it, which
-- is why this menu used to be the one that looked out of place.
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
local CARD_LOCKED = Color3.fromRGB(38, 44, 58)
local CARD_CLAIMED = Color3.fromRGB(40, 78, 52)
local CARD_READY = Color3.fromRGB(96, 200, 108)
local CLAIM_GREEN = Color3.fromRGB(96, 216, 104)
local TEXT = Color3.new(1, 1, 1)
local TEXT_DIM = Color3.fromRGB(168, 174, 188)
-- Wider than the pack's square panels: seven day cards in a row need the room.
local PANEL_ASPECT = 1.75
-- One source of truth for the open size: the shell sets it and the pop-open
-- tween returns to it, so the two cannot drift apart.
local PANEL_SIZE = UDim2.fromScale(0.62, 0.62)
local PANEL_SIZE_SMALL = UDim2.fromScale(0.5, 0.5)
-- Seconds the panel stays up after a successful claim before closing itself.
local AUTO_CLOSE = 3

-- One icon per reward kind in Config.DailyRewards. Anything unrecognised falls
-- back to the gift, so adding a reward kind never leaves a card blank.
local REWARD_ICON: { [string]: string } = {
	cash = Config.Icons.Cash,
	spins = Config.Icons.Wheel,
	squishy = Config.Icons.Gift,
}

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

-- The panel shell, CLONED from one the pack ships rather than approximated.
--
-- Every other menu is a pack frame: black at half transparency, a 3px stroke,
-- an aspect-ratio constraint, and a Title bar whose blue is a nine-sliced
-- ImageLabel with the pack's own Close button on it. Hand-building something
-- close to that is exactly why this panel never matched — so it now takes a
-- real one and swaps out the contents.
--
-- Returns the panel and its Close button, or nil if the pack is not there.
local function buildShell(refs: any): (Frame?, GuiButton?)
	local frames = refs.gui:FindFirstChild("Frames")
	if frames == nil then
		return nil, nil
	end
	-- Index is the closest donor: a plain content area with no bespoke art.
	local donor = frames:FindFirstChild("Index") or frames:FindFirstChild("Shop")
	if donor == nil or not donor:IsA("Frame") then
		return nil, nil
	end

	local panel = donor:Clone()
	panel.Name = "DailyRewards"
	panel.Visible = false
	panel.Parent = frames

	-- Keep the shell, drop the donor's content. Title carries the bar art and
	-- the Close button, so it stays.
	for _, child in panel:GetChildren() do
		if child.Name ~= "Stroke" and child.Name ~= "Ratio" and child.Name ~= "Title" then
			child:Destroy()
		end
	end

	-- Seven cards in a row need a wider frame than the square Index.
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
				-- The donor names this after itself ("Shop" holding "Index"),
				-- so retitle by role rather than by name.
				child.Text = "Daily Rewards"
			end
		end
	end
	return panel, closeButton
end

function DailyUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()

	-- ---------------------------------------------------------- the panel --

	local panel, close = buildShell(refs)
	if panel == nil then
		warn("[DailyUi] no pack panel to clone; daily rewards disabled")
		return
	end

	-- ------------------------------------------------------------- cards --

	-- The pack's panel is taller than the one this replaced, so the cards fill
	-- the band between the title bar and the claim button rather than sitting
	-- in a thin strip with dead space under them.
	local grid = Instance.new("Frame")
	grid.Name = "Days"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.02, 0.2)
	grid.Size = UDim2.fromScale(0.96, 0.53)
	grid.ZIndex = 31
	grid.Parent = panel

	-- Seven across: 7 cells + 6 gaps has to land under 1.0 of the grid width.
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromScale(0.13, 0.96)
	layout.CellPadding = UDim2.fromScale(0.008, 0.02)
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

		label(card, ("Day %d"):format(reward.day), UDim2.fromScale(0.9, 0.16), UDim2.fromScale(0.05, 0.03), TEXT_DIM).ZIndex = 33

		-- What the day actually pays, as a picture: seven cards of near-identical
		-- text is hard to read at a glance, and the icon carries at card size.
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.fromScale(0.5, 0.2)
		icon.Size = UDim2.fromScale(0.52, 0.3)
		icon.Image = REWARD_ICON[reward.kind] or Config.Icons.Gift
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 33
		icon.Parent = card

		label(card, reward.label, UDim2.fromScale(0.9, 0.24), UDim2.fromScale(0.05, 0.51), TEXT).ZIndex = 33
		local status = label(card, "Locked", UDim2.fromScale(0.9, 0.2), UDim2.fromScale(0.05, 0.76), TEXT_DIM)
		status.ZIndex = 33

		table.insert(cards, { frame = card, status = status })
	end

	-- ------------------------------------------------------ claim button --

	local claim = Instance.new("TextButton")
	claim.Name = "ClaimAll"
	claim.AnchorPoint = Vector2.new(0.5, 1)
	claim.Position = UDim2.fromScale(0.5, 0.95)
	claim.Size = UDim2.fromScale(0.38, 0.15)
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

	-- Shows the panel and cancels any pending auto-close. Every open bumps the
	-- token, so a player who reopens the panel inside the three seconds after a
	-- claim does not have it shut in their face by the previous claim's timer.
	local openToken = 0
	local function show()
		openToken += 1
		panel.Visible = true
		refresh()
	end

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
				-- Close itself once the claim has landed: the panel has nothing
				-- left to offer today, and the notification saying so is behind
				-- it. Long enough to watch the card flip to Claimed first.
				openToken += 1
				local mine = openToken
				task.delay(AUTO_CLOSE, function()
					if openToken == mine then
						panel.Visible = false
					end
				end)
			end
			refresh()
		end)
	end)

	if close ~= nil then
		UiRefs.bindButton(close, function()
			panel.Visible = false
		end)
	end

	player:GetAttributeChangedSignal("DailyClaimable"):Connect(refresh)
	player:GetAttributeChangedSignal("DailyStreak"):Connect(refresh)
	player:GetAttributeChangedSignal("DailyNextDay"):Connect(refresh)
	refresh()

	-- Opens itself once on join when there is something waiting — the whole
	-- point of a daily reward is that you see it.
	task.spawn(function()
		task.wait(2)
		if player:GetAttribute("DailyClaimable") == true then
			show()
			panel.Size = PANEL_SIZE_SMALL
			TweenService:Create(
				panel,
				TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = PANEL_SIZE }
			):Play()
		end
	end)

	DailyUi.Toggle = function()
		if panel.Visible then
			panel.Visible = false
		else
			show()
		end
	end
end

return DailyUi
