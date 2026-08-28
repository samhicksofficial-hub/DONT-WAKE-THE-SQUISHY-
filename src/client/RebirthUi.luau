--!strict
-- RebirthUi — drives Frames.Rebirth in the Essential UI Pack.
--
--   Frame.Bar.{Progress,Text}   cash progress toward the next rebirth cost
--   Frame.Stats.{Before,After}  income multiplier now vs. after the rebirth
--   Frame.RebirthBoost          the one-line "what rebirth costs you" warning
--   Rebirth / Skip              the two TextButtons under the card
--
-- Numbers come from Config.Rebirth (Costs are 1-indexed by rebirth number,
-- Multipliers are indexed by rebirth count + 1). The panel is a pure mirror of
-- the Money and Rebirths attributes; the only thing it sends is DoRebirth.
-- See the UI Contract in DESIGN.md.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local PANEL = "Rebirth"

local BOOST_TEXT = "Rebirth resets your cash and upgrades — placed squishies stay!"

local TEXT_BRIGHT = Color3.fromRGB(255, 255, 255)
local TEXT_BROKE = Color3.fromRGB(255, 116, 116)
local MONEY_GREEN = Color3.fromRGB(85, 255, 85)
local DIM_IMAGE = Color3.fromRGB(120, 120, 128)

local RebirthUi = {}

-- ---------------------------------------------------------------- helpers --

-- 1 -> "x1", 1.5 -> "x1.5", 2.25 -> "x2.25".
local function formatMultiplier(value: number): string
	local text = string.format("%.2f", value)
	return "x" .. (text:gsub("%.?0+$", ""))
end

local function readNumber(player: Player, attribute: string, fallback: number): number
	local raw = player:GetAttribute(attribute)
	if typeof(raw) == "number" then
		return raw :: number
	end
	return fallback
end

-- The pack nests each Stats column as `Before.Text` (the caption) plus a
-- `Before.Money.Text` value card. Prefer the value card when it exists so the
-- caption keeps reading "Before"/"After"; fall back to the caption otherwise.
local function statLabels(column: Instance?): (TextLabel?, TextLabel?)
	if column == nil then
		return nil, nil
	end
	local caption = column:FindFirstChild("Text") :: TextLabel?
	local money = column:FindFirstChild("Money")
	local value = if money ~= nil then money:FindFirstChild("Text") :: TextLabel? else nil
	if value == nil then
		return nil, caption
	end
	return caption, value
end

-- ---------------------------------------------------------------- panel --

function RebirthUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()
	local panel = refs.panels[PANEL]

	local costs = (Config.Rebirth :: any).Costs :: { number }
	local multipliers = (Config.Rebirth :: any).Multipliers :: { number }
	local maxRebirths = #costs

	local rebirthRemote: RemoteEvent? = nil
	task.spawn(function()
		rebirthRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DoRebirth") :: RemoteEvent
	end)

	-- ------------------------------------------------------------- nodes --

	local card = panel:FindFirstChild("Frame")
	local bar = if card ~= nil then card:FindFirstChild("Bar") else nil
	local barFill = if bar ~= nil then bar:FindFirstChild("Progress") :: Frame? else nil
	local barText = if bar ~= nil then bar:FindFirstChild("Text") :: TextLabel? else nil
	local boost = if card ~= nil then card:FindFirstChild("RebirthBoost") :: TextLabel? else nil

	local stats = if card ~= nil then card:FindFirstChild("Stats") else nil
	local beforeCaption, beforeValue = statLabels(if stats ~= nil then stats:FindFirstChild("Before") else nil)
	local afterCaption, afterValue = statLabels(if stats ~= nil then stats:FindFirstChild("After") else nil)

	local button = panel:FindFirstChild("Rebirth") :: TextButton?
	local buttonText = if button ~= nil then button:FindFirstChild("Text") :: TextLabel? else nil
	local buttonBacking = if button ~= nil then button:FindFirstChild("Background") :: ImageLabel? else nil

	if card == nil or bar == nil or button == nil then
		warn("[RebirthUi] Frames.Rebirth is missing Frame/Bar/Rebirth — panel will be inert")
	end

	-- Parked monetization: no developer product id for a paid skip yet.
	local skip = panel:FindFirstChild("Skip")
	if skip ~= nil and skip:IsA("GuiObject") then
		skip.Visible = false
	end

	-- Keep the bar's authored height; only its width is ours to drive.
	local fillHeight = if barFill ~= nil then barFill.Size.Y else UDim.new(1, 0)

	if boost ~= nil then
		boost.Text = BOOST_TEXT
	end
	if beforeCaption ~= nil then
		beforeCaption.Text = "Before"
	end
	if afterCaption ~= nil then
		afterCaption.Text = "After"
	end

	-- ----------------------------------------------------------- refresh --

	local function refresh()
		local money = readNumber(player, "Money", 0)
		local count = math.clamp(math.floor(readNumber(player, "Rebirths", 0)), 0, maxRebirths)
		local maxed = count >= maxRebirths
		local cost = if maxed then 0 else costs[count + 1]
		local affordable = not maxed and money >= cost

		local current = multipliers[math.min(count + 1, #multipliers)] or 1
		local nextMult = multipliers[math.min(count + 2, #multipliers)] or current

		if barText ~= nil then
			if maxed then
				barText.Text = ("Rebirth %d  -  MAX"):format(count)
			else
				barText.Text = ("Rebirth %d  -  %s / %s"):format(count + 1, Util.formatMoney(money), Util.formatMoney(cost))
			end
		end
		if barFill ~= nil then
			local ratio = if maxed then 1 else math.clamp(money / math.max(cost, 1), 0, 1)
			barFill.Size = UDim2.new(ratio, 0, fillHeight.Scale, fillHeight.Offset)
		end

		if beforeValue ~= nil then
			beforeValue.Text = formatMultiplier(current)
		end
		if afterValue ~= nil then
			afterValue.Text = if maxed then "MAX" else formatMultiplier(nextMult)
		end

		if buttonText ~= nil then
			buttonText.Text = if maxed then "MAX" else "Rebirth"
			buttonText.TextColor3 = if maxed then TEXT_BRIGHT elseif affordable then MONEY_GREEN else TEXT_BROKE
			buttonText.TextTransparency = if maxed or affordable then 0 else 0.35
		end
		if buttonBacking ~= nil then
			buttonBacking.ImageColor3 = if affordable then Color3.new(1, 1, 1) else DIM_IMAGE
		end
		if button ~= nil then
			button.Active = affordable
			button.Selectable = affordable
		end
	end

	if button ~= nil then
		UiRefs.bindButton(button, function()
			local count = math.floor(readNumber(player, "Rebirths", 0))
			if count >= maxRebirths then
				UiRefs.notify("You have every rebirth already!", 2.5)
				return
			end
			local cost = costs[count + 1]
			if readNumber(player, "Money", 0) < cost then
				UiRefs.notify(("Rebirth needs %s."):format(Util.formatMoney(cost)), 2.5)
				return
			end
			local remote = rebirthRemote
			if remote ~= nil then
				remote:FireServer()
			end
		end)
	end

	-- The Close button is bound once, by Panels.luau's loop over every panel.
	-- Binding it a second time here would double the hover/press tweens.

	local function refreshIfOpen()
		if UiRefs.isPanelOpen(PANEL) then
			local ok, err = pcall(refresh)
			if not ok then
				warn(("[RebirthUi] refresh failed: %s"):format(tostring(err)))
			end
		end
	end

	for _, attribute in { "Money", "Rebirths" } do
		player:GetAttributeChangedSignal(attribute):Connect(refreshIfOpen)
	end
	panel:GetPropertyChangedSignal("Visible"):Connect(refreshIfOpen)

	local startOk, startErr = pcall(refresh)
	if not startOk then
		warn(("[RebirthUi] initial refresh failed: %s"):format(tostring(startErr)))
	end
end

return RebirthUi
