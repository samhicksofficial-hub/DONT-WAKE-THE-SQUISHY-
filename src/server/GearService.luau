--!strict
-- GearService — the game-pass gear sold from the item stands in a base's
-- basement (Speed Coil, Slap Hand, Glock, the Knight).
--
-- Division of labour: PlotService owns the stand FURNITURE (it has the frames,
-- the pad geometry and the reuse rules for hand-edited shells) and calls in
-- here for the catalogue, the price and the prompt. This service owns the
-- SHOP half — who owns what, what a purchase hands over, and where the item
-- templates live.
--
-- Templates come from ServerStorage.GearItems, a folder in the place rather
-- than in this repo: they are imported art, not generated geometry. A missing
-- template costs that stand its display and nothing else.
--
-- Ownership is expressed as a player attribute per item ("OwnsSpeedCoil" and
-- friends) so the client and the gear's own scripts can read it without asking
-- MarketplaceService again.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local GearService = {}

local TEMPLATE_FOLDER = "GearItems"
-- Prompting again while Roblox's own dialog is still up does nothing but
-- queue a second one behind it.
local PROMPT_COOLDOWN = 2

-- pass id -> Robux price, filled the first time a stand asks. GetProductInfo is
-- a web call; eight plots' worth of stands must not each make their own.
local priceCache: { [number]: number } = {}
local lastPrompt: { [Player]: number } = {}

-- ------------------------------------------------------------- catalogue --

-- The gear shown on stand `slotOnFloor` of an item floor, or nil past the end
-- of the catalogue — those stands stay bare.
function GearService.ForStand(slotOnFloor: number): any
	return (Config.Gear :: { any })[slotOnFloor]
end

function GearService.PassId(gear: any): number
	if gear == nil then
		return 0
	end
	return tonumber((Config.Passes :: any)[gear.pass]) or 0
end

-- Robux price for a stand's label, or nil while the pass is parked or the
-- lookup has not come back yet. Never yields the caller: a stand renders
-- "Coming soon" now and is retexted when the price arrives.
function GearService.PriceAsync(gear: any): number?
	local passId = GearService.PassId(gear)
	if passId == 0 then
		return nil
	end
	local cached = priceCache[passId]
	if cached ~= nil then
		return cached
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(passId, Enum.InfoType.GamePass)
	end)
	if not ok or typeof(info) ~= "table" then
		return nil
	end
	local price = tonumber(info.PriceInRobux)
	if price == nil then
		return nil
	end
	priceCache[passId] = price
	return price
end

-- ------------------------------------------------------------- templates --

local function templateFolder(): Folder?
	local folder = ServerStorage:FindFirstChild(TEMPLATE_FOLDER)
	return if folder ~= nil and folder:IsA("Folder") then folder else nil
end

-- The source instance for a piece of gear, or nil when the place does not
-- carry it. Callers must cope with nil: a clean `rojo build` has no art.
function GearService.Template(gear: any): Instance?
	if gear == nil then
		return nil
	end
	local folder = templateFolder()
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(gear.template)
end

-- A display-only copy: every part anchored, inert, and stripped of the
-- original's scripts, joints and sounds.
--
-- Parts are copied one by one into a flat Model rather than cloning the whole
-- thing. A straight clone brings the item's own code with it, and eight plots'
-- worth of a slap tool's server script all running at once is not a display,
-- it is a swarm. Part CFrames are world-space, so a flat model keeps the shape.
function GearService.BuildDisplay(gear: any, name: string): Model?
	local template = GearService.Template(gear)
	if template == nil then
		return nil
	end
	local display = Instance.new("Model")
	display.Name = name

	local sources: { Instance } = if template:IsA("BasePart") then { template } else template:GetDescendants()
	local copied = 0
	for _, source in sources do
		if not source:IsA("BasePart") then
			continue
		end
		local copy = source:Clone()
		-- Keep decals, textures and surface appearances; drop anything that
		-- could run, move or make noise.
		for _, sub in copy:GetDescendants() do
			if
				sub:IsA("LuaSourceContainer")
				or sub:IsA("JointInstance")
				or sub:IsA("Constraint")
				or sub:IsA("Sound")
				or sub:IsA("ParticleEmitter")
			then
				sub:Destroy()
			end
		end
		copy.Anchored = true
		copy.CanCollide = false
		copy.CanTouch = false
		copy.CanQuery = false
		copy.Massless = true
		copy.Parent = display
		copied += 1
	end
	if copied == 0 then
		display:Destroy()
		return nil
	end
	return display
end

-- --------------------------------------------------------------- granting --

local function attributeName(gear: any): string
	return "Owns" .. tostring(gear.key)
end

-- Hands the item over. Tools go into the Backpack AND StarterGear so they
-- survive a respawn; a bodyguard is left to its own scripts, which read the
-- attribute this sets.
local function grant(player: Player, gear: any)
	player:SetAttribute(attributeName(gear), true)
	if gear.kind ~= "tool" then
		return
	end
	local template = GearService.Template(gear)
	if template == nil or not template:IsA("Tool") then
		return
	end
	local starter = player:FindFirstChildOfClass("StarterGear")
	if starter ~= nil and starter:FindFirstChild(template.Name) == nil then
		template:Clone().Parent = starter
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack ~= nil and backpack:FindFirstChild(template.Name) == nil then
		template:Clone().Parent = backpack
	end
end

local function ownsPass(player: Player, passId: number): boolean
	if passId == 0 then
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and owns == true
end

-- One web call per parked-or-owned pass on join, then the attributes carry it.
local function applyOwned(player: Player)
	for _, gear in Config.Gear :: { any } do
		if ownsPass(player, GearService.PassId(gear)) then
			grant(player, gear)
		end
	end
end

-- ---------------------------------------------------------------- prompt --

-- Called by the stand's pad. A parked pass prompts nothing — the stand is
-- already showing "Coming soon", and prompting id 0 is an error.
function GearService.PromptPurchase(player: Player, gear: any)
	local passId = GearService.PassId(gear)
	if passId == 0 then
		return
	end
	if player:GetAttribute(attributeName(gear)) == true then
		-- Already theirs: re-hand it instead, so someone who dropped a tool
		-- can walk back onto the pad to get another.
		grant(player, gear)
		return
	end
	local now = os.clock()
	if now - (lastPrompt[player] or 0) < PROMPT_COOLDOWN then
		return
	end
	lastPrompt[player] = now
	pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, passId)
	end)
end

function GearService.Start(_services: any, _map: any)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(applyOwned, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(applyOwned, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPrompt[player] = nil
	end)

	-- Granted the moment the dialog closes, rather than on the next join.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			if purchased ~= true or passId == 0 then
				return
			end
			for _, gear in Config.Gear :: { any } do
				if GearService.PassId(gear) == passId then
					grant(player, gear)
				end
			end
		end
	)

	local folder = templateFolder()
	if folder == nil then
		warn(
			("[GearService] no ServerStorage.%s in this place; the basement stands will build without their art"):format(
				TEMPLATE_FOLDER
			)
		)
	end
end

return GearService
