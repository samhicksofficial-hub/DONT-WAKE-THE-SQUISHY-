--!strict
-- DefenseService — the two Robux defences sold from pads at a plot's front
-- door: Slap Protection and Lock Base.
--
--   Slap Protection  the buyer cannot be slapped BY OTHER PLAYERS for
--                    Config.Defense.SlapProtectionMinutes. It reads as a
--                    classic blue ForceField on the character, and the place's
--                    slap tool checks the SlapProtectedUntil attribute before
--                    it flings anyone. The GIANTS ignore it on purpose: they
--                    are the game's core threat, and a defence you can buy
--                    against them would sell the game out from under itself.
--
--   Lock Base        a wall of red lasers across the plot's front opening for
--                    Config.Defense.BaseLockMinutes. Solid to everyone but
--                    the owner — collision groups let the owner walk through
--                    their own bars — and anyone else caught inside when it
--                    switches on is walked out the front first, so a laser
--                    wall can never take a prisoner.
--
-- Both are developer products (Config.Products), registered into ShopService's
-- single ProcessReceipt. While the ids are 0 the pads stand there saying
-- "Coming soon" and prompt nothing, the same as the gear stands.
--
-- The pads stand at EVERY plot spot, claimed or not, exactly like the
-- reference game's — only the spot's current owner gets a prompt out of one.
-- They are also buildable in Edit mode (tools/build scripts call EnsurePads
-- with the marker CFrames) so they show while editing; the server rebuilds
-- them identically at startup either way.
--
-- Everything lives in workspace.PlotDefense rather than in the plot model:
-- buying a floor rebuilds the plot's children, and the pads must not die with
-- them.

local MarketplaceService = game:GetService("MarketplaceService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DefenseService = {}

local Palette = Config.Palette :: any

local FOLDER_NAME = "PlotDefense"
-- How often the world is reconciled: pads built for fresh plots, owner
-- characters put in their collision group, expired timers noticed.
local POLL_SECONDS = 2
local TOUCH_DEBOUNCE = 2
local PAD_DIAMETER = 6
local PAD_THICKNESS = 0.35
-- Outside the front opening, flanking the doorway, where the reference pads
-- sit — and where they survive a floors rebuild untouched.
local PAD_OUT = 4
local PAD_SIDE = 7
local WALL_HEIGHT = 14
local BAR_SPACING = 3.4
local BAR_DIAMETER = 0.55
local PROTECT_COLOR = Color3.fromRGB(80, 200, 255)
local LOCK_COLOR = Color3.fromRGB(235, 70, 70)
local COLOR_WHITE = Color3.new(1, 1, 1)
local COLOR_MONEY = Color3.fromRGB(85, 255, 85)

local servicesRef: any = nil

-- Per-player defence state. Timers carry a stamp so a rebuy extends rather
-- than being cut short by the first purchase's timer.
type State = {
	wall: Model?,
	lockStamp: number,
	protectStamp: number,
	lastTouch: number,
}
local states: { [Player]: State } = {}

-- product price cache: one GetProductInfo per product, not one per pad.
local priceCache: { [number]: number } = {}

local function stateFor(player: Player): State
	local state = states[player]
	if state == nil then
		state = { wall = nil, lockStamp = 0, protectStamp = 0, lastTouch = 0 }
		states[player] = state
	end
	return state
end

local function folder(): Folder
	local found = workspace:FindFirstChild(FOLDER_NAME)
	if found ~= nil and found:IsA("Folder") then
		return found
	end
	local fresh = Instance.new("Folder")
	fresh.Name = FOLDER_NAME
	fresh.Parent = workspace
	return fresh
end

-- ------------------------------------------------------- collision groups --

-- One pair of groups per plot spot: the owner's character rides in
-- PlotOwnerN, the lock wall in PlotLockN, and only that one pairing is
-- non-collidable — everyone else hits the bars like a wall.
local function groupNames(spotIndex: number): (string, string)
	return ("PlotOwner%d"):format(spotIndex), ("PlotLock%d"):format(spotIndex)
end

local function registerGroups()
	for spotIndex = 1, (Config.Plot :: any).Count do
		local owner, lock = groupNames(spotIndex)
		pcall(function()
			PhysicsService:RegisterCollisionGroup(owner)
			PhysicsService:RegisterCollisionGroup(lock)
			PhysicsService:CollisionGroupSetCollidable(owner, lock, false)
		end)
	end
end

-- Puts the owner's whole character in their spot's group, so their own laser
-- wall was never solid to them in the first place.
local function assignCharacterGroup(player: Player, spotIndex: number)
	local character = player.Character
	if character == nil then
		return
	end
	local owner = (groupNames(spotIndex))
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") and root.CollisionGroup == owner then
		return -- already done this character
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = owner
		end
	end
end

-- ------------------------------------------------------------- plot maths --

local function plotService(): any
	return servicesRef ~= nil and servicesRef.PlotService or nil
end

local function originFor(player: Player): CFrame?
	local plots = plotService()
	if plots == nil then
		return nil
	end
	local ok, origin = pcall(plots.GetPlotOrigin, player)
	return if ok then origin :: CFrame? else nil
end

local function spotIndexFor(player: Player): number?
	local plots = plotService()
	if plots == nil then
		return nil
	end
	local ok, index = pcall(plots.GetPlotSpotIndex, player)
	return if ok then index :: number? else nil
end

local function halfBase(): (number, number)
	local base = (Config.Plot :: any).BaseSize :: Vector2
	return base.X / 2, base.Y / 2
end

local function isInsidePlot(origin: CFrame, position: Vector3): boolean
	local halfW, halfD = halfBase()
	local local_ = origin:PointToObjectSpace(position)
	return math.abs(local_.X) <= halfW
		and math.abs(local_.Z) <= halfD
		and local_.Y >= -40
		and local_.Y <= 70
end

-- --------------------------------------------------------------- building --

local function newLabel(parent: Instance, text: string, color: Color3, order: number, heightScale: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Label" .. tostring(order)
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, heightScale)
	label.LayoutOrder = order
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.Parent = parent
	return label
end

local function priceLine(gui: Instance, productId: number)
	local label = newLabel(gui, "Coming soon", COLOR_WHITE, 2, 0.32)
	if productId == 0 then
		return
	end
	task.spawn(function()
		local price = priceCache[productId]
		if price == nil then
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if ok and typeof(info) == "table" then
				price = tonumber((info :: any).PriceInRobux)
				if price ~= nil then
					priceCache[productId] = price
				end
			end
		end
		if price ~= nil and label.Parent ~= nil then
			label.Text = ("R$ %d"):format(price)
			label.TextColor3 = COLOR_MONEY
		end
	end)
end

local function buildPad(
	parent: Model,
	origin: CFrame,
	side: number,
	color: Color3,
	title: string,
	productId: number,
	onTouch: (Player) -> ()
)
	local _, halfD = halfBase()
	local pad = Instance.new("Part")
	pad.Name = title:gsub("%s", "") .. "Pad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER)
	pad.CFrame = origin
		* CFrame.new(side * PAD_SIDE, PAD_THICKNESS / 2 + 0.1, -(halfD + PAD_OUT))
		* CFrame.Angles(0, 0, math.rad(90))
	pad.Color = color
	pad.Material = Enum.Material.Neon
	pad.Anchored = true
	pad.CanCollide = false
	pad.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Name = "PadGui"
	gui.Size = UDim2.fromScale(6.5, 2.6)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.4, 0)
	gui.MaxDistance = 80
	gui.Parent = pad
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = gui
	newLabel(gui, title, COLOR_WHITE, 1, 0.44)
	priceLine(gui, productId)
	newLabel(gui, "owner steps on to buy", (Palette and Palette.SafeZone) or COLOR_WHITE, 3, 0.24)

	pad.Touched:Connect(function(hit: BasePart)
		local character = hit.Parent
		if character == nil then
			return
		end
		local toucher = Players:GetPlayerFromCharacter(character)
		if toucher ~= nil then
			onTouch(toucher)
		end
	end)
end

-- Stands the pair of pads at one plot spot, wiping any pair already there.
-- Rebuilt rather than adopted: cheaper to reason about, identical to look at,
-- and a marker nudged in the editor is followed automatically. Callable from
-- Edit mode with a marker's CFrame, which is how the pads get into the saved
-- place where they can be SEEN while editing.
function DefenseService.EnsurePads(spotIndex: number, origin: CFrame)
	local parent = folder()
	local name = ("Pads_Spot%d"):format(spotIndex)
	local previous = parent:FindFirstChild(name)
	if previous ~= nil then
		previous:Destroy()
	end
	local pads = Instance.new("Model")
	pads.Name = name
	pads.Parent = parent

	-- Only the spot's CURRENT owner gets a prompt: the pad asks PlotService
	-- which spot the toucher holds and matches it against its own.
	local function prompt(productId: number)
		return function(toucher: Player)
			if productId == 0 then
				return
			end
			local plots = plotService()
			if plots == nil then
				return
			end
			local ok, spot = pcall(plots.GetPlotSpotIndex, toucher)
			if not ok or spot ~= spotIndex then
				return -- someone else's front door
			end
			local state = stateFor(toucher)
			local now = os.clock()
			if now - state.lastTouch < TOUCH_DEBOUNCE then
				return
			end
			state.lastTouch = now
			pcall(function()
				MarketplaceService:PromptProductPurchase(toucher, productId)
			end)
		end
	end

	local products = Config.Products :: any
	buildPad(pads, origin, -1, PROTECT_COLOR, "Slap Protection",
		tonumber(products.SlapProtection) or 0, prompt(tonumber(products.SlapProtection) or 0))
	buildPad(pads, origin, 1, LOCK_COLOR, "Lock Base",
		tonumber(products.BaseLock) or 0, prompt(tonumber(products.BaseLock) or 0))
end

-- The laser wall: a rank of glowing bars for the eyes, one invisible slab for
-- the physics, both across the front opening.
local function buildWall(player: Player, origin: CFrame, spotIndex: number): Model
	local halfW, halfD = halfBase()
	local _, lockGroup = groupNames(spotIndex)

	local wall = Instance.new("Model")
	wall.Name = ("LockWall_%d"):format(player.UserId)

	local slab = Instance.new("Part")
	slab.Name = "Barrier"
	slab.Size = Vector3.new(halfW * 2, WALL_HEIGHT, 1)
	slab.CFrame = origin * CFrame.new(0, WALL_HEIGHT / 2, -(halfD - 0.5))
	slab.Transparency = 1
	slab.Anchored = true
	slab.CanCollide = true
	slab.CollisionGroup = lockGroup
	slab.Parent = wall

	local bars = math.max(2, math.floor((halfW * 2) / BAR_SPACING))
	for barIndex = 0, bars do
		local x = -halfW + (halfW * 2) * (barIndex / bars)
		local bar = Instance.new("Part")
		bar.Name = "Laser"
		bar.Shape = Enum.PartType.Cylinder
		bar.Size = Vector3.new(WALL_HEIGHT, BAR_DIAMETER, BAR_DIAMETER)
		bar.CFrame = origin * CFrame.new(x, WALL_HEIGHT / 2, -(halfD - 0.5)) * CFrame.Angles(0, 0, math.rad(90))
		bar.Color = LOCK_COLOR
		bar.Material = Enum.Material.Neon
		bar.Transparency = 0.15
		bar.Anchored = true
		bar.CanCollide = false
		bar.CanQuery = false
		bar.CanTouch = false
		bar.Parent = wall
	end

	wall.Parent = folder()
	return wall
end

-- Walks every non-owner out the front before the bars go solid. A laser wall
-- that traps a visitor inside an enemy base for a quarter of an hour is a
-- griefing tool, not a defence.
local function evictIntruders(player: Player, origin: CFrame)
	local _, halfD = halfBase()
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") and isInsidePlot(origin, root.Position) then
				character:PivotTo(origin * CFrame.new(0, 4, -(halfD + 8)))
			end
		end
	end
end

-- ---------------------------------------------------------------- granting --

-- Both grants stack the way the shop's income boost does: a rebuy extends
-- from whichever is later, now or the current expiry.
local function extendedUntil(player: Player, attribute: string, minutes: number): number
	local current = tonumber(player:GetAttribute(attribute)) or 0
	local expiry = math.max(os.time(), current) + minutes * 60
	player:SetAttribute(attribute, expiry)
	return expiry
end

function DefenseService.GrantSlapProtection(player: Player): boolean
	local minutes = tonumber((Config.Defense :: any).SlapProtectionMinutes) or 15
	local expiry = extendedUntil(player, "SlapProtectedUntil", minutes)
	local state = stateFor(player)
	state.protectStamp += 1
	local stamp = state.protectStamp

	-- The classic blue shield, so both sides can SEE the protection.
	local character = player.Character
	if character ~= nil and character:FindFirstChildOfClass("ForceField") == nil then
		local field = Instance.new("ForceField")
		field.Name = "SlapProtection"
		field.Parent = character
	end

	task.delay(expiry - os.time(), function()
		local current = states[player]
		if current == nil or current.protectStamp ~= stamp then
			return
		end
		player:SetAttribute("SlapProtectedUntil", nil)
		local held = player.Character
		local field = held and held:FindFirstChild("SlapProtection")
		if field ~= nil then
			field:Destroy()
		end
	end)
	return true
end

function DefenseService.GrantBaseLock(player: Player): boolean
	local origin = originFor(player)
	local spotIndex = spotIndexFor(player)
	if origin == nil or spotIndex == nil then
		return false -- no plot yet; the receipt stays unprocessed and retries
	end
	local minutes = tonumber((Config.Defense :: any).BaseLockMinutes) or 15
	local expiry = extendedUntil(player, "BaseLockedUntil", minutes)
	local state = stateFor(player)
	state.lockStamp += 1
	local stamp = state.lockStamp

	assignCharacterGroup(player, spotIndex)
	evictIntruders(player, origin)
	if state.wall == nil or state.wall.Parent == nil then
		state.wall = buildWall(player, origin, spotIndex)
	end

	task.delay(expiry - os.time(), function()
		local current = states[player]
		if current == nil or current.lockStamp ~= stamp then
			return
		end
		player:SetAttribute("BaseLockedUntil", nil)
		if current.wall ~= nil then
			current.wall:Destroy()
			current.wall = nil
		end
	end)
	return true
end

-- True while `player` may not be slapped by another player. The place's slap
-- tool asks this (via the attribute) before flinging anyone.
function DefenseService.IsSlapProtected(player: Player): boolean
	local until_ = tonumber(player:GetAttribute("SlapProtectedUntil")) or 0
	return os.time() < until_
end

-- ------------------------------------------------------------------ start --

function DefenseService.Start(services: any, map: any)
	servicesRef = services
	registerGroups()

	-- A pair of pads at every spot, claimed or not — freshly rebuilt, so any
	-- copies saved into the place for editing are replaced with wired ones.
	local spots = map ~= nil and map.plotSpots or nil
	if typeof(spots) == "table" then
		for spotIndex, origin in spots :: { CFrame } do
			local ok, err = pcall(DefenseService.EnsurePads, spotIndex, origin)
			if not ok then
				warn(("[DefenseService] pads for spot %d failed: %s"):format(spotIndex, tostring(err)))
			end
		end
	end

	-- Receipts route through the game's one ProcessReceipt.
	local shop = services.ShopService
	local products = Config.Products :: any
	if shop ~= nil then
		pcall(function()
			shop.RegisterProductHandler(tonumber(products.SlapProtection) or 0, function(_receipt, buyer)
				return DefenseService.GrantSlapProtection(buyer)
			end)
			shop.RegisterProductHandler(tonumber(products.BaseLock) or 0, function(_receipt, buyer)
				return DefenseService.GrantBaseLock(buyer)
			end)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		states[player] = nil
		if state ~= nil and state.wall ~= nil then
			state.wall:Destroy()
		end
	end)

	-- The reconcile loop: the owner's character kept in its collision group
	-- (a respawn hands out factory-default parts), and a shield restored to a
	-- character that respawned mid-protection.
	task.spawn(function()
		while true do
			task.wait(POLL_SECONDS)
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(function()
					local spotIndex = spotIndexFor(player)
					if spotIndex ~= nil then
						assignCharacterGroup(player, spotIndex)
					end
					if DefenseService.IsSlapProtected(player) then
						local character = player.Character
						if character ~= nil and character:FindFirstChildOfClass("ForceField") == nil then
							local field = Instance.new("ForceField")
							field.Name = "SlapProtection"
							field.Parent = character
						end
					end
				end)
				if not ok then
					warn(("[DefenseService] reconcile failed for %s: %s"):format(player.Name, tostring(err)))
				end
			end
		end
	end)
end

return DefenseService
