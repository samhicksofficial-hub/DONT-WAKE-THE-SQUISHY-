--!strict
-- SpawnService — every character starts at its owner's base.
--
-- The world SpawnLocation still exists (Roblox needs one) but it is parked out
-- of the way: a character materialises there for an instant and this service
-- immediately pivots it onto the `SpawnPoint` inside that player's base, on the
-- first join and on every respawn (see the Map Design Contract in DESIGN.md).
--
-- The plot is claimed on PlayerAdded, but PlotService can finish building a
-- moment AFTER the character arrives, so the spawn CFrame is polled in a
-- bounded loop. If it never shows up the player is simply left at the world
-- spawn — a missing plot must never leave someone stuck in a yield forever.

local Players = game:GetService("Players")

local SpawnService = {}

-- Give up on the plot after this long and leave the player where they landed.
local PLOT_WAIT_SECONDS = 10
local PLOT_POLL_INTERVAL = 0.15
-- How long to wait for the character's parts to replicate in.
local ROOT_WAIT_SECONDS = 10
-- The spawn CFrame sits on the floor; lift the root so the character stands on
-- it rather than sinking into the slab.
local STAND_OFFSET = 3.5
-- Roblox can re-place a character just after it spawns, so check once more.
local RECHECK_DELAY = 0.4
-- Far enough that a player who simply walked away is never yanked back.
local RECHECK_DISTANCE = 40

local plotService: any = nil
-- Player -> its CharacterAdded connection, so PlayerRemoving can drop it.
local characterConns: { [Player]: RBXScriptConnection } = {}

-- The base spawn point, or nil while PlotService has yet to build the plot.
local function getSpawnCFrame(player: Player): CFrame?
	local service = plotService
	if service == nil then
		return nil
	end
	local getter = service.GetSpawnCFrame
	if typeof(getter) ~= "function" then
		return nil
	end
	local ok, result = pcall(getter, player)
	if ok and typeof(result) == "CFrame" then
		return result
	end
	return nil
end

-- Polls until the plot exists, the player leaves, or the budget runs out.
local function waitForSpawnCFrame(player: Player): CFrame?
	local deadline = os.clock() + PLOT_WAIT_SECONDS
	while true do
		if player.Parent == nil then
			return nil
		end
		local spawnCFrame = getSpawnCFrame(player)
		if spawnCFrame ~= nil then
			return spawnCFrame
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(PLOT_POLL_INTERVAL)
	end
end

-- True while this model is still the player's live, un-destroyed character.
local function isCurrent(player: Player, character: Model): boolean
	if character.Parent == nil or player.Character ~= character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function onCharacter(player: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", ROOT_WAIT_SECONDS) :: BasePart?
	if root == nil or not isCurrent(player, character) then
		return
	end

	local spawnCFrame = waitForSpawnCFrame(player)
	if spawnCFrame == nil then
		warn(("[SpawnService] no base spawn for %s; leaving at the world spawn"):format(player.Name))
		return
	end
	if not isCurrent(player, character) then
		return
	end

	local target = spawnCFrame + Vector3.new(0, STAND_OFFSET, 0)
	character:PivotTo(target)

	-- One correction pass only: the engine sometimes re-places a character just
	-- after it spawns. After this the player is free to walk wherever they like.
	task.wait(RECHECK_DELAY)
	if not isCurrent(player, character) or root.Parent == nil then
		return
	end
	if (root.Position - target.Position).Magnitude > RECHECK_DISTANCE then
		character:PivotTo(target)
	end
end

local function safeOnCharacter(player: Player, character: Model)
	task.spawn(function()
		local ok, err = pcall(onCharacter, player, character)
		if not ok then
			warn(("[SpawnService] spawn placement failed for %s: %s"):format(player.Name, tostring(err)))
		end
	end)
end

local function setupPlayer(player: Player)
	local existing = characterConns[player]
	if existing ~= nil then
		existing:Disconnect()
	end
	characterConns[player] = player.CharacterAdded:Connect(function(character)
		safeOnCharacter(player, character)
	end)

	local character = player.Character
	if character ~= nil then
		safeOnCharacter(player, character)
	end
end

local function safeSetup(player: Player)
	local ok, err = pcall(setupPlayer, player)
	if not ok then
		warn(("[SpawnService] setup failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

local function cleanupPlayer(player: Player)
	local conn = characterConns[player]
	if conn ~= nil then
		conn:Disconnect()
		characterConns[player] = nil
	end
end

function SpawnService.Start(services: any, _map: any)
	plotService = services ~= nil and services.PlotService or nil

	Players.PlayerAdded:Connect(safeSetup)
	Players.PlayerRemoving:Connect(cleanupPlayer)
	for _, player in Players:GetPlayers() do
		safeSetup(player)
	end
end

return SpawnService
