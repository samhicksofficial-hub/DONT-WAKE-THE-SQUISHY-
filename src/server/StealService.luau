--!strict
-- StealService — pay Robux to take a squishy off someone else's plot.
--
-- Every placed squishy carries a "Steal" ProximityPrompt. It shows only to
-- players who do NOT own it; triggering it opens the Robux purchase for
-- Config.Products.Steal, and the squishy moves — level, variant and all —
-- when the receipt comes back.
--
-- The product id is 0 until it is created in the Creator Dashboard (see
-- ASSETS_NEEDED.md). While it is 0 the prompts stay hidden rather than
-- offering a purchase that cannot complete, which is the same rule the rest of
-- the parked monetization follows.
--
-- Robux flow, in order:
--   prompt triggered -> remember who wants what -> PromptProductPurchase
--   -> ProcessReceipt -> move the squishy -> PurchaseGranted
-- The pending record is what lets ProcessReceipt know WHICH squishy was being
-- bought, since a receipt only carries the product and the buyer.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local StealService = {}

local PROMPT_NAME = "StealPrompt"
local PENDING_TIMEOUT = 120 -- seconds a pending steal stays valid

local servicesRef: any = nil
local productId = 0

-- buyer UserId -> what they were trying to steal
local pending: { [number]: { model: Model, at: number } } = {}

local function stealProductId(): number
	local products = (Config :: any).Products
	local id = products ~= nil and tonumber(products.Steal) or 0
	return id or 0
end

-- Adds (or refreshes) the Steal prompt on one placed squishy.
local function attachPrompt(model: Model)
	if productId == 0 then
		return -- parked: no product, no prompt
	end
	if model:GetAttribute("State") ~= "Placed" then
		return
	end
	local body = model:FindFirstChild("Body")
	if body == nil or not body:IsA("BasePart") then
		return
	end
	if body:FindFirstChild(PROMPT_NAME) ~= nil then
		return
	end

	local info = servicesRef.PlotService.DescribePlaced(model)
	if info == nil then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Steal"
	prompt.ObjectText = ("%s  (%s/s)"):format(
		tostring(model:GetAttribute("DisplayName") or model.Name),
		Util.formatMoney(tonumber(model:GetAttribute("Income")) or 0)
	)
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	-- Only non-owners are offered the steal; the owner never sees it.
	prompt.Enabled = true
	prompt.Parent = body

	prompt.Triggered:Connect(function(thief: Player)
		local current = servicesRef.PlotService.DescribePlaced(model)
		if current == nil or current.owner == thief then
			return
		end
		pending[thief.UserId] = { model = model, at = os.clock() }
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(thief, productId)
		end)
		if not ok then
			pending[thief.UserId] = nil
			warn(("[StealService] purchase prompt failed: %s"):format(tostring(err)))
		end
	end)
end

-- Owners should not see a Steal prompt on their own squishies. A prompt is one
-- instance shared by everyone, so ownership is enforced in Triggered (above);
-- this just keeps the prompt off a squishy nobody can steal.
local function refreshPrompts(plotFolder: Instance)
	for _, descendant in plotFolder:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("State") == "Placed" then
			pcall(attachPrompt, descendant)
		end
	end
end

function StealService.Start(services: any, map: any)
	servicesRef = services
	productId = stealProductId()

	if productId == 0 then
		-- Parked until the developer product exists. Say so once, clearly.
		warn("[StealService] Config.Products.Steal is 0 — stealing is off until that developer product id is filled in (see ASSETS_NEEDED.md).")
		return
	end

	local plotFolder = map.plotFolder
	plotFolder.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("Model") then
			task.defer(function()
				pcall(attachPrompt, descendant)
			end)
		end
	end)
	refreshPrompts(plotFolder)

	Players.PlayerRemoving:Connect(function(player)
		pending[player.UserId] = nil
	end)

	-- ShopService owns the game's single ProcessReceipt; steals register a
	-- handler into its router rather than clobbering the callback (which is
	-- write-only, so two owners can never coexist).
	servicesRef.ShopService.RegisterProductHandler(productId, function(receipt: any, buyer: Player)
		local want = pending[receipt.PlayerId]
		pending[receipt.PlayerId] = nil
		if want == nil or os.clock() - want.at > PENDING_TIMEOUT or want.model.Parent == nil then
			-- The target is gone. Granting anyway would take their Robux for
			-- nothing, so refuse and let Roblox refund.
			return false
		end
		local ok, moved = pcall(servicesRef.PlotService.StealSquishy, want.model, buyer)
		return ok and moved == true
	end)
end

return StealService
