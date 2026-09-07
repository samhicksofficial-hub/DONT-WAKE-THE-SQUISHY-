--!strict
-- ShopService — the Robux shop's server half, and the game's ONE ProcessReceipt.
--
-- MarketplaceService.ProcessReceipt is a single write-only callback, so two
-- writers silently clobber each other — StealService and the donation board
-- model in the place were already racing for it. This service owns the
-- callback and routes receipts by product id; anything else that sells a
-- product registers a handler here instead (StealService does).
--
-- Developer products are the CONSUMABLES (cash bundles, the 2x boost, wheel
-- spins, the starter bundle). The PERMANENT purchases are game passes
-- (Config.Passes): checked once on join, granted live through
-- PromptGamePassPurchaseFinished, and expressed as player attributes the
-- gameplay services read —
--   VipActive: boolean      -> EconomyService multiplies all income
--   BoostUntil: number      -> EconomyService, double income until then (os.time)
--   PermSpeedBonus: number  -> SquishyService adds it to walkspeed
--
-- Ids are 0 until created in the Creator Dashboard. A receipt with no handler
-- is left NotProcessedYet so Roblox retries or refunds it, rather than the
-- game swallowing someone's Robux for nothing.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local ShopService = {}

local servicesRef: any = nil
local rng = Random.new()

-- product id -> handler(receipt, buyer) -> true when granted
local handlers: { [number]: (any, Player) -> boolean } = {}

-- ------------------------------------------------------------------- grants --

-- Set, not Add: a bought bundle is worth exactly the number on its card —
-- rebirth and boost multipliers have no business inflating a Robux purchase.
local function grantCash(player: Player, amount: number)
	local economy = servicesRef.EconomyService
	economy.SetMoney(player, economy.GetMoney(player) + amount)
end

local function grantSpins(player: Player, count: number)
	local current = tonumber(player:GetAttribute("Spins")) or 0
	player:SetAttribute("Spins", current + count)
end

-- Stacked purchases extend from whichever end is later, so no minute is lost.
local function grantBoost(player: Player, minutes: number)
	local current = tonumber(player:GetAttribute("BoostUntil")) or 0
	player:SetAttribute("BoostUntil", math.max(os.time(), current) + minutes * 60)
end

local function grantStarterPack(player: Player)
	local shop = Config.Shop :: any
	grantCash(player, shop.StarterPackCash)
	grantSpins(player, shop.StarterPackSpins)

	-- The guaranteed squishy goes straight onto the plot, like a wheel prize;
	-- with no free slot it pays out as cash instead (same consolation rule).
	local pool = {}
	for _, def in Config.Squishies :: { any } do
		if def.rarity == shop.StarterPackRarity then
			table.insert(pool, def)
		end
	end
	local def = pool[rng:NextInteger(1, math.max(1, #pool))]
	local placed = false
	if def ~= nil then
		local defCopy = table.clone(def)
		defCopy.variant = shop.StarterPackVariant
		local ok, result = pcall(servicesRef.PlotService.TryPlaceSquishy, player, defCopy)
		placed = ok and result == true
	end
	if not placed then
		local rarity = Config.RarityByName[shop.StarterPackRarity]
		local variant = (Config.VariantByName :: any)[shop.StarterPackVariant]
		local perSecond = (if rarity ~= nil then rarity.income else 0) * ((variant and variant.income) or 1)
		grantCash(player, perSecond * 120)
	end
	-- One per player. The prompt paths check this; the receipt path does NOT
	-- — a receipt means Robux changed hands, so it always grants — and
	-- SaveService carries the flag between sessions.
	player:SetAttribute("StarterPackOwned", true)
end

-- The dev panel's way to hand the bundle over while the product id is still
-- parked at 0 — without an id there is no receipt to arrive.
function ShopService.DebugGrantStarterPack(player: Player)
	grantStarterPack(player)
end

-- The starter pack's shop window in the WORLD: any instance named
-- StarterPackDisplay in the workspace gets a purchase prompt hung off it. The
-- prop itself is the mapper's art — a shield, a crate, whatever stands there —
-- and it can be dragged or restyled freely; only the name is the contract.
local DISPLAY_NAME = "StarterPackDisplay"

local function wireStarterDisplay()
	local display = workspace:FindFirstChild(DISPLAY_NAME, true)
	if display == nil then
		print(
			("[%s] no %s in the workspace — the starter pack sells from the shop panel only. Name any prop that to give it a counter."):format(
				Config.GameName,
				DISPLAY_NAME
			)
		)
		return
	end
	local anchor: BasePart? = nil
	if display:IsA("BasePart") then
		anchor = display
	elseif display:IsA("Model") then
		anchor = display.PrimaryPart or display:FindFirstChildWhichIsA("BasePart", true)
	end
	if anchor == nil then
		warn(("[ShopService] %s has no BasePart to hang a prompt on"):format(DISPLAY_NAME))
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StarterPackPrompt"
	prompt.ActionText = "Buy Starter Pack"
	prompt.ObjectText = "One-time bundle"
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	prompt.Triggered:Connect(function(player)
		-- Owners get a shrug, not a prompt: there is nothing left to sell
		-- them. (The prompt itself stays visible — prompt visibility is
		-- global, not per player.)
		if player:GetAttribute("StarterPackOwned") == true then
			return
		end
		local productId = tonumber((Config.Products :: any).StarterPack) or 0
		if productId == 0 then
			return
		end
		pcall(function()
			MarketplaceService:PromptProductPurchase(player, productId)
		end)
	end)
end

-- ------------------------------------------------------------------- passes --

local function ownsPass(player: Player, passId: number): boolean
	if passId == 0 then
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and owns == true
end

local function applyPasses(player: Player)
	local passes = Config.Passes :: any
	local shop = Config.Shop :: any
	if ownsPass(player, tonumber(passes.VIP) or 0) then
		player:SetAttribute("VipActive", true)
	end
	if ownsPass(player, tonumber(passes.PermanentSpeed) or 0) then
		player:SetAttribute("PermSpeedBonus", shop.PermanentSpeedBonus)
	end
end

-- ----------------------------------------------------------------- receipts --

-- Other services sell products too (StealService): they register here rather
-- than setting MarketplaceService.ProcessReceipt themselves. An id of 0 is a
-- parked product and registers nothing.
function ShopService.RegisterProductHandler(productId: number, handler: (any, Player) -> boolean)
	if typeof(productId) == "number" and productId ~= 0 then
		handlers[productId] = handler
	end
end

local function onReceipt(receipt: any): Enum.ProductPurchaseDecision
	local handler = handlers[receipt.ProductId]
	if handler == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local buyer = Players:GetPlayerByUserId(receipt.PlayerId)
	if buyer == nil then
		-- They left before the receipt landed; Roblox retries next join.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, granted = pcall(handler, receipt, buyer)
	if not ok then
		warn(("[ShopService] receipt for product %d failed: %s"):format(receipt.ProductId, tostring(granted)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return if granted == true
		then Enum.ProductPurchaseDecision.PurchaseGranted
		else Enum.ProductPurchaseDecision.NotProcessedYet
end

function ShopService.Start(services: any, _map: any)
	servicesRef = services
	local products = Config.Products :: any
	local shop = Config.Shop :: any

	ShopService.RegisterProductHandler(tonumber(products.StarterPack) or 0, function(_receipt, buyer)
		grantStarterPack(buyer)
		return true
	end)
	ShopService.RegisterProductHandler(tonumber(products.Boost2x) or 0, function(_receipt, buyer)
		grantBoost(buyer, shop.Boost2xMinutes)
		return true
	end)
	for sizeName, productKey in { Small = "CashSmall", Medium = "CashMedium", Large = "CashLarge" } do
		local amount = tonumber(shop.CashAmounts[sizeName]) or 0
		ShopService.RegisterProductHandler(tonumber(products[productKey]) or 0, function(_receipt, buyer)
			grantCash(buyer, amount)
			return true
		end)
	end
	ShopService.RegisterProductHandler(tonumber(products.WheelSpins3) or 0, function(_receipt, buyer)
		grantSpins(buyer, 3)
		return true
	end)
	ShopService.RegisterProductHandler(tonumber(products.WheelSpins9) or 0, function(_receipt, buyer)
		grantSpins(buyer, 9)
		return true
	end)

	-- The one and only assignment of the callback in this codebase (the
	-- donation board model in the place also assigns it; whichever runs last
	-- wins, exactly as before this service existed — see the file header).
	MarketplaceService.ProcessReceipt = onReceipt

	wireStarterDisplay()

	Players.PlayerAdded:Connect(function(player)
		task.spawn(applyPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(applyPasses, player)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		if purchased ~= true or passId == 0 then
			return
		end
		local passes = Config.Passes :: any
		if passId == passes.VIP then
			player:SetAttribute("VipActive", true)
		elseif passId == passes.PermanentSpeed then
			player:SetAttribute("PermSpeedBonus", shop.PermanentSpeedBonus)
		end
	end)
end

return ShopService
