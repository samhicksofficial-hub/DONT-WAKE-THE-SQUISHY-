--!strict
-- StealService — take a squishy off someone else's plot and carry it home.
--
-- Stealing is free gameplay, not a purchase: every placed squishy wears a
-- "Steal" ProximityPrompt (hidden from its owner client-side by StealPrompts).
-- Holding it lifts a copy — name, variant AND level — onto the thief's head as
-- an ordinary carry, and clears the victim's pedestal. The thief then has to
-- run it home past everything the game can throw at them: the owner's slap
-- knocks it loose (SquishyService watches LastSlappedAt), the giants notice
-- rare cargo from further away, and a dropped squishy is anyone's to grab.
--
-- The defences are what make it fair rather than free money:
--   * Base Lock (DefenseService): a locked base refuses the steal outright —
--     the laser wall keeps most thieves out physically, but a prompt can
--     reach through geometry, so the lock is checked here too.
--   * Slap Protection guards the THIEF from the counter-slap; the owner's
--     recourse is the lock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local StealService = {}

local PROMPT_NAME = "StealPrompt"
-- Long enough that the owner standing right there can react, short enough
-- that a sleeping owner does not make theft impossible.
local HOLD_SECONDS = 1.5

local servicesRef: any = nil

-- One steal of a given squishy at a time: the grab is atomic today (no yields
-- between the describe and the clear), but this keeps it honest if either
-- half ever learns to wait.
local busy: { [Model]: boolean } = {}

local function tryGrab(model: Model, thief: Player)
	if busy[model] then
		return
	end
	busy[model] = true
	local ok, err = pcall(function()
		local info = servicesRef.PlotService.DescribePlaced(model)
		if info == nil or info.owner == thief then
			return
		end
		local lockedUntil = tonumber(info.owner:GetAttribute("BaseLockedUntil")) or 0
		if os.time() < lockedUntil then
			return
		end
		if servicesRef.SquishyService.IsCarrying(thief) then
			return
		end
		-- Hand the thief their carry FIRST, clear the victim only once it
		-- exists: a failed hand-over then costs the victim nothing.
		local carried = servicesRef.SquishyService.GiveCarried(thief, info.squishyName, info.variant, info.level)
		if carried ~= true then
			return
		end
		if not servicesRef.PlotService.ClearPlaced(model) then
			-- Should be unreachable (the model was placed a moment ago); shout
			-- because this branch would mean a duplicated squishy.
			warn(("[StealService] cleared nothing after handing %s a carry of %s"):format(thief.Name, tostring(info.squishyName)))
		end
	end)
	busy[model] = nil
	if not ok then
		warn(("[StealService] steal failed: %s"):format(tostring(err)))
	end
end

-- Adds (or refreshes) the Steal prompt on one placed squishy.
local function attachPrompt(model: Model)
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
	if servicesRef.PlotService.DescribePlaced(model) == nil then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Steal"
	prompt.ObjectText = ("%s  (%s/s)"):format(
		tostring(model:GetAttribute("DisplayName") or model.Name),
		Util.formatMoney(tonumber(model:GetAttribute("Income")) or 0)
	)
	prompt.HoldDuration = HOLD_SECONDS
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	-- A prompt is one instance shared by every client, so "owners see no
	-- prompt" cannot live here: the client's StealPrompts module hides it on
	-- the local player's own plot, and tryGrab refuses an owner regardless.
	prompt.Enabled = true
	prompt.Parent = body

	prompt.Triggered:Connect(function(thief: Player)
		tryGrab(model, thief)
	end)
end

local function refreshPrompts(plotFolder: Instance)
	for _, descendant in plotFolder:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("State") == "Placed" then
			pcall(attachPrompt, descendant)
		end
	end
end

function StealService.Start(services: any, map: any)
	servicesRef = services

	local plotFolder = map.plotFolder
	plotFolder.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("Model") then
			-- Deferred: the placer sets State/attributes right after parenting.
			task.defer(function()
				pcall(attachPrompt, descendant)
			end)
		end
	end)
	refreshPrompts(plotFolder)
end

return StealService
