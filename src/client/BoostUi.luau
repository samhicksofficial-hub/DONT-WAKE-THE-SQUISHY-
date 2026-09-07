--!strict
-- BoostUi — the two server-wide boost buttons on the right edge of the screen,
-- after the reference game's side stack: a picture, a line of what it does,
-- and the price under it.
--
--   Make Evil Squishies Sleep  -> Products.SleepAll   (EnemyService.SleepAll)
--   Server Luck                -> Products.ServerLuck (SquishyService.LuckBoost)
--
-- Both effects are SERVER-WIDE, whoever pays. The buttons read their state
-- from two ReplicatedStorage attributes the server maintains
-- (SquishiesAsleepUntil / ServerLuckUntil, os.time based): while a boost runs,
-- the price line becomes its countdown, and buying again extends it.
--
-- Button art comes from Config.Boosts.SleepImage / LuckImage — uploaded
-- through Studio, 0 until then — and falls back to the pack's stock icons so
-- the buttons never render blank.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local UiRefs = require(script.Parent.UiRefs)

local BoostUi = {}

local FONT = Enum.Font.FredokaOne
local SLEEP_GREEN = Color3.fromRGB(126, 226, 66)
local LUCK_BLUE = Color3.fromRGB(150, 190, 255)
local PRICE_WHITE = Color3.new(1, 1, 1)
local ACTIVE_YELLOW = Color3.fromRGB(255, 214, 96)
local DIM = Color3.fromRGB(190, 195, 205)
local IMAGE_SIZE = 92
local BUTTON_WIDTH = 170

local function countdown(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	if total >= 60 then
		return ("%d:%02d left"):format(math.floor(total / 60), total % 60)
	end
	return ("%ds left"):format(total)
end

local function label(parent: Instance, text: string, height: number, color: Color3, order: number): TextLabel
	local item = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Size = UDim2.new(1, 0, 0, height)
	item.LayoutOrder = order
	item.Font = FONT
	item.Text = text
	item.TextColor3 = color
	item.TextScaled = true
	item.TextWrapped = true
	item.TextStrokeTransparency = 0
	item.TextStrokeColor3 = Color3.new(0, 0, 0)
	item.Parent = parent
	return item
end

type Spec = {
	name: string,
	title: string,
	titleColor: Color3,
	imageId: number,
	fallbackIcon: string,
	productId: number,
	untilAttribute: string,
}

local function buildButton(stack: Frame, spec: Spec)
	local item = Instance.new("Frame")
	item.Name = spec.name
	item.BackgroundTransparency = 1
	item.Size = UDim2.fromOffset(BUTTON_WIDTH, IMAGE_SIZE + 78)
	item.Parent = stack
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = item

	local art = Instance.new("ImageButton")
	art.Name = "Buy"
	art.BackgroundTransparency = 1
	art.Size = UDim2.fromOffset(IMAGE_SIZE, IMAGE_SIZE)
	art.LayoutOrder = 1
	art.Image = if spec.imageId ~= 0 then ("rbxassetid://%d"):format(spec.imageId) else spec.fallbackIcon
	art.ScaleType = Enum.ScaleType.Fit
	art.Parent = item

	label(item, spec.title, 40, spec.titleColor, 2)
	local price = label(item, "", 24, PRICE_WHITE, 3)

	-- The price is a web call; fetched once and remembered, and the button
	-- says "Coming soon" for as long as the product id is parked at 0.
	local priceText: string? = nil
	if spec.productId ~= 0 then
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(spec.productId, Enum.InfoType.Product)
			end)
			local robux = ok and typeof(info) == "table" and tonumber((info :: any).PriceInRobux) or nil
			if robux ~= nil then
				priceText = ("R$ %d"):format(robux)
			end
		end)
	end

	local function refresh()
		local until_ = tonumber(ReplicatedStorage:GetAttribute(spec.untilAttribute)) or 0
		local remaining = until_ - os.time()
		if remaining > 0 then
			price.Text = countdown(remaining)
			price.TextColor3 = ACTIVE_YELLOW
		elseif spec.productId == 0 then
			price.Text = "Coming soon"
			price.TextColor3 = DIM
		else
			price.Text = priceText or "R$ ..."
			price.TextColor3 = PRICE_WHITE
		end
	end

	UiRefs.bindButton(art, function()
		if spec.productId == 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptProductPurchase(Players.LocalPlayer, spec.productId)
		end)
	end)

	ReplicatedStorage:GetAttributeChangedSignal(spec.untilAttribute):Connect(refresh)
	-- The countdown has to tick on its own; a second's drift is invisible.
	task.spawn(function()
		while item.Parent ~= nil do
			refresh()
			task.wait(1)
		end
	end)
	refresh()
end

function BoostUi.Start()
	local player = Players.LocalPlayer
	local boosts = Config.Boosts :: any
	local products = Config.Products :: any

	local gui = Instance.new("ScreenGui")
	gui.Name = "BoostButtons"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")

	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.AnchorPoint = Vector2.new(1, 0.5)
	-- Below centre on purpose: the pack's own HUD.Right (now the starter pack
	-- shield) holds the right-middle, and these must not sit on top of it.
	stack.Position = UDim2.new(1, -8, 0.74, 0)
	stack.Size = UDim2.fromOffset(BUTTON_WIDTH, (IMAGE_SIZE + 78) * 2 + 18)
	stack.BackgroundTransparency = 1
	stack.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 18)
	layout.Parent = stack

	buildButton(stack, {
		name = "SleepAll",
		title = ("Make Evil Squishies\nSleep for %ds"):format(tonumber(boosts.SleepSeconds) or 60),
		titleColor = SLEEP_GREEN,
		imageId = tonumber(boosts.SleepImage) or 0,
		fallbackIcon = Config.Icons.Gift,
		productId = tonumber(products.SleepAll) or 0,
		untilAttribute = "SquishiesAsleepUntil",
	})
	buildButton(stack, {
		name = "ServerLuck",
		title = ("Server Luck (%d min)"):format(tonumber(boosts.LuckMinutes) or 15),
		titleColor = LUCK_BLUE,
		imageId = tonumber(boosts.LuckImage) or 0,
		fallbackIcon = Config.Icons.Wheel,
		productId = tonumber(products.ServerLuck) or 0,
		untilAttribute = "ServerLuckUntil",
	})
end

return BoostUi
