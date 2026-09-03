--!strict
-- ShopUi — drives Frames.Shop in the Essential UI Pack: the Robux store.
--
-- The cash upgrade tracks are gone from the game (the Shop button used to
-- open the Upgrades panel while the Robux packs were parked); everything in
-- the shop is now a developer product or a game pass, using the pack's own
-- shipped cards:
--   StarterPack card  -> Products.StarterPack (cash + a Rare squishy + spins)
--   ProPack card      -> the VIP pass (permanent income multiplier)
--   ItemsOnly row     -> the 2x cash boost product + the Permanent Speed pass
--   CashOnly row      -> the three cash bundles
--
-- A card whose id is still 0 stays VISIBLE but greyed with "?" for a price,
-- and clicking it says the item is not on sale yet — the shop reads as a shop
-- before the ids exist in the Creator Dashboard, and comes alive one card at
-- a time as they are filled in.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local UiRefs = require(script.Parent.UiRefs)

local ShopUi = {}

local player = Players.LocalPlayer

local NOT_ON_SALE = "Not on sale yet!"
local PROMPT_FAILED = "The purchase window could not open."
local PARKED_GREY = Color3.fromRGB(150, 150, 150)

-- Sets the Text of a named child label, if both exist. The pack's cards are
-- hand-authored, so every touch is find-first and forgiving.
local function setText(parent: Instance?, childName: string, text: string)
	if parent == nil then
		return
	end
	local label = parent:FindFirstChild(childName)
	if label ~= nil and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function hide(instance: Instance?)
	if instance ~= nil and instance:IsA("GuiObject") then
		instance.Visible = false
	end
end

-- The pack authors Recive and Background at the same ZIndex, and under the
-- ScreenGui's Sibling behaviour the LATER child wins the tie — which is the
-- Background, so it painted over the whole tile row. One step up fixes it.
local function liftReceive(card: Instance?): Instance?
	if card == nil then
		return nil
	end
	local receive = card:FindFirstChild("Recive")
	if receive ~= nil and receive:IsA("GuiObject") then
		receive.ZIndex += 1
	end
	return receive
end

-- Prices the Buy button and wires the purchase prompt. A parked id (0) greys
-- the button and turns the click into a "not on sale yet" notice instead.
local function bindBuy(buy: Instance?, id: number, isPass: boolean)
	if buy == nil or not buy:IsA("GuiButton") then
		return
	end
	local text = buy:FindFirstChild("Text")
	if id == 0 then
		if text ~= nil and text:IsA("TextLabel") then
			text.Text = "?"
		end
		local background = buy:FindFirstChild("Background")
		if background ~= nil and background:IsA("ImageLabel") then
			background.ImageColor3 = PARKED_GREY
		end
	else
		-- The real Robux price, fetched off the main thread; the authored
		-- placeholder stays up if the lookup fails.
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(
					id,
					if isPass then Enum.InfoType.GamePass else Enum.InfoType.Product
				)
			end)
			if ok and typeof(info) == "table" and text ~= nil and text:IsA("TextLabel") then
				local price = (info :: any).PriceInRobux
				if price ~= nil then
					text.Text = tostring(price)
				end
			end
		end)
	end

	UiRefs.bindButton(buy :: GuiButton, function()
		if id == 0 then
			UiRefs.notify(NOT_ON_SALE, 3)
			return
		end
		local prompted = pcall(function()
			if isPass then
				MarketplaceService:PromptGamePassPurchase(player, id)
			else
				MarketplaceService:PromptProductPurchase(player, id)
			end
		end)
		if not prompted then
			UiRefs.notify(PROMPT_FAILED, 3)
		end
	end)
end

function ShopUi.Start()
	local refs = UiRefs.get()
	local panel = refs.panels.Shop
	local scrolling = panel:FindFirstChild("Scrolling")
	if scrolling == nil then
		warn("[ShopUi] Frames.Shop.Scrolling is missing; shop disabled")
		return
	end

	local products = Config.Products :: any
	local passes = Config.Passes :: any
	local shop = Config.Shop :: any

	-- ---------- Starter Pack (developer product) ----------

	local starter = scrolling:FindFirstChild("StarterPack")
	if starter ~= nil then
		setText(starter, "Text", "One-time bundle")
		local receive = liftReceive(starter)
		if receive ~= nil then
			local squishy = receive:FindFirstChild("Item1")
			setText(squishy, "Name", ("%s Squishy"):format(shop.StarterPackRarity))
			setText(squishy, "Income", "")
			local spins = receive:FindFirstChild("Item2")
			setText(spins, "Name", ("%d Spins"):format(shop.StarterPackSpins))
			setText(spins, "Income", "")
			setText(receive:FindFirstChild("Cash1"), "Amount", "+" .. Util.formatMoney(shop.StarterPackCash))
		end
		bindBuy(starter:FindFirstChild("Buy"), tonumber(products.StarterPack) or 0, false)
	end

	-- ---------- VIP Pack (game pass, permanent) ----------

	local vip = scrolling:FindFirstChild("ProPack")
	if vip ~= nil then
		setText(vip, "Name", "VIP Pack")
		setText(vip, "Text", "Permanent")
		local receive = liftReceive(vip)
		if receive ~= nil then
			local perk = receive:FindFirstChild("Item1")
			setText(perk, "Name", "VIP")
			setText(perk, "Income", ("x%s cash"):format(tostring(shop.VipIncomeMult)))
			-- VIP grants one big thing, not a spread of tiles.
			hide(receive:FindFirstChild("Item2"))
			hide(receive:FindFirstChild("Cash1"))
		end
		bindBuy(vip:FindFirstChild("Buy"), tonumber(passes.VIP) or 0, true)
	end

	-- ---------- boosts: 2x cash (product) + permanent speed (pass) ----------

	local boosts = scrolling:FindFirstChild("ItemsOnly")
	if boosts ~= nil then
		local receive = liftReceive(boosts)
		if receive ~= nil then
			local boost = receive:FindFirstChild("Item1")
			setText(boost, "Name", ("x%d Cash"):format(shop.Boost2xMult))
			setText(boost, "Income", ("%d min"):format(shop.Boost2xMinutes))
			bindBuy(if boost ~= nil then boost:FindFirstChild("Buy") else nil, tonumber(products.Boost2x) or 0, false)

			local speed = receive:FindFirstChild("Item2")
			setText(speed, "Name", "+Speed")
			setText(speed, "Income", "forever")
			bindBuy(if speed ~= nil then speed:FindFirstChild("Buy") else nil, tonumber(passes.PermanentSpeed) or 0, true)

			hide(receive:FindFirstChild("Item3"))
		end
	end

	-- ---------- cash bundles (developer products) ----------

	local bundles = scrolling:FindFirstChild("CashOnly")
	if bundles ~= nil then
		local receive = liftReceive(bundles)
		if receive ~= nil then
			for _, tier in {
				{ "Cash1", "CashSmall", shop.CashAmounts.Small },
				{ "Cash2", "CashMedium", shop.CashAmounts.Medium },
				{ "Cash3", "CashLarge", shop.CashAmounts.Large },
			} do
				local tile = receive:FindFirstChild(tier[1] :: string)
				setText(tile, "Amount", "+" .. Util.formatMoney(tier[3] :: number))
				bindBuy(
					if tile ~= nil then tile:FindFirstChild("Buy") else nil,
					tonumber(products[tier[2]]) or 0,
					false
				)
			end
		end
	end
end

return ShopUi
