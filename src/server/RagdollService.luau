--!strict
-- RagdollService — a character goes limp when something hits it.
--
-- PlatformStand on its own only tips a character over as one rigid piece: it
-- stops the controller, but every limb stays welded in its standing pose, so a
-- slapped player slides across the field like a shop dummy. A real ragdoll needs
-- the Motor6Ds swapped for BallSocketConstraints so the joints actually swing,
-- then swapped back when the stun is over.
--
-- Server-side on purpose. A character's parts are owned by its own client, so
-- the physics run there and stay smooth for the player being thrown; disabling
-- a Motor6D and parenting a constraint both replicate, so everyone else sees
-- the same flop.
--
-- PlatformStand is still set alongside it, because EnemyService reads that flag
-- to tell a giant its target is already down and not worth chasing.

local Players = game:GetService("Players")

local RagdollService = {}

-- The joint holding the character to its own root. Breaking this detaches the
-- body from the part the Humanoid actually drives, which drops the character
-- through the floor. R6 calls it RootJoint, R15 calls it Root.
local KEEP_JOINT: { [string]: boolean } = { RootJoint = true, Root = true }

local MIN_SECONDS = 0.2
-- A stun longer than this is a bug somewhere upstream, not a design choice.
local MAX_SECONDS = 10
-- How far a joint may swing. Loose enough to flop, tight enough that limbs do
-- not fold through the torso.
local JOINT_ANGLE = 60

-- Two rig shapes have to be handled, and a live avatar can be either.
--
--   LEGACY: joints are Motor6Ds. Nothing else holds the limbs together, so a
--           BallSocketConstraint has to be built for each one before the motor
--           is switched off.
--   MODERN: joints are AnimationConstraints, and Roblox already ships a
--           BallSocketConstraint beside every one of them for exactly this
--           purpose. Switching the AnimationConstraint off hands the joint to
--           the socket that is already there; nothing needs building.
--
-- Both kinds are just things with an `Enabled` flag, so one list restores them.
type Entry = {
	generation: number,
	disabled: { any },
	added: { Instance },
}

-- character -> what was changed, so it can be put back exactly. Cleared on
-- restore, on death and on respawn, so nothing is held after the character goes.
local active: { [Model]: Entry } = {}

-- Lets every joint but the root swing, and remembers what to undo.
local function limp(character: Model, humanoid: Humanoid): Entry
	local entry: Entry = { generation = 0, disabled = {}, added = {} }

	-- MUST come before the neck motor is disabled: an R15 humanoid with
	-- RequiresNeck on dies the moment its neck joint stops holding, so a slap
	-- would kill the player rather than knock them over.
	humanoid.RequiresNeck = false
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true

	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("Motor6D") or KEEP_JOINT[descendant.Name] then
			continue
		end
		local motor = descendant :: Motor6D
		local part0, part1 = motor.Part0, motor.Part1
		if part0 == nil or part1 == nil then
			continue
		end

		-- The attachments inherit the motor's own C0/C1, so the socket pivots
		-- exactly where the joint did and the pose does not jump on the swap.
		local socketAt0 = Instance.new("Attachment")
		socketAt0.Name = "RagdollAttachment0"
		socketAt0.CFrame = motor.C0
		socketAt0.Parent = part0

		local socketAt1 = Instance.new("Attachment")
		socketAt1.Name = "RagdollAttachment1"
		socketAt1.CFrame = motor.C1
		socketAt1.Parent = part1

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "RagdollSocket"
		socket.Attachment0 = socketAt0
		socket.Attachment1 = socketAt1
		socket.LimitsEnabled = true
		socket.TwistLimitsEnabled = false
		socket.UpperAngle = JOINT_ANGLE
		socket.Parent = part0

		motor.Enabled = false
		table.insert(entry.disabled, motor)
		table.insert(entry.added, socketAt0)
		table.insert(entry.added, socketAt1)
		table.insert(entry.added, socket)
	end

	-- Modern rig: switch off the constraint that drives each joint and the
	-- ball socket sitting beside it takes over. A separate pass rather than an
	-- elseif, because an avatar may carry a mix — an accessory can still bring
	-- a Motor6D along on an otherwise constraint-driven body.
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("AnimationConstraint") and not KEEP_JOINT[descendant.Name] then
			descendant.Enabled = false
			table.insert(entry.disabled, descendant)
		end
	end

	return entry
end

-- Undoes limp(). Safe on a character that has since been destroyed: every
-- instance is checked for a parent first.
local function stand(character: Model, entry: Entry)
	for _, instance in entry.added do
		if instance.Parent ~= nil then
			instance:Destroy()
		end
	end
	for _, joint in entry.disabled do
		if joint.Parent ~= nil then
			joint.Enabled = true
		end
	end
	-- Physics back to whoever should have it, which for a live character is its
	-- own player. Auto rather than SetNetworkOwner(player), because the engine
	-- already knows the answer and the character may be gone by now.
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			pcall(function()
				part:SetNetworkOwnershipAuto()
			end)
		end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.Health > 0 then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

-- Throws the whole body, having first taken its physics off the client.
--
-- A character's parts are owned by its own player, and the OWNER's state wins:
-- measured, a velocity the server writes reads 82 studs/s on the frame it is
-- written and 0 on the very next one. Owning the assemblies for the duration of
-- the knockdown is what makes a knockback actually land. Ownership goes back on
-- the way up, in stand().
--
-- Every part, not just the root: a ragdoll is many assemblies now, and throwing
-- only the root would yank it out from under limbs that stayed put.
local function throwBody(character: Model, impulse: Vector3)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
		end
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = impulse
		end
	end
end

-- Knocks `player` down for `seconds`, optionally throwing them with `impulse`.
-- Returns false when there is nothing to knock down (no character, or already
-- dead), so callers can fall back.
function RagdollService.Ragdoll(player: Player, seconds: number?, impulse: Vector3?): boolean
	local character = player.Character
	if character == nil or character.Parent == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return false
	end
	local duration = math.clamp(tonumber(seconds) or 1.5, MIN_SECONDS, MAX_SECONDS)

	local entry = active[character]
	if entry == nil then
		local ok, built = pcall(limp, character, humanoid)
		if not ok then
			warn(("[RagdollService] could not ragdoll %s: %s"):format(player.Name, tostring(built)))
			return false
		end
		entry = built
		active[character] = entry
	end

	-- Thrown AFTER going limp, never before: releasing the joints re-splits the
	-- character into a fresh set of assemblies, and a velocity written to the
	-- old one goes with it. Deferred once more because the split does not
	-- necessarily finish inside this frame.
	if impulse ~= nil then
		pcall(throwBody, character, impulse)
		task.defer(function()
			if active[character] ~= nil then
				pcall(throwBody, character, impulse)
			end
		end)
	end

	-- A second hit while already down EXTENDS the stay rather than starting a
	-- fresh one: without the generation check, being juggled between the two
	-- giants would have the first slap's timer stand the player up mid-flight.
	entry.generation += 1
	local mine = entry.generation
	task.delay(duration, function()
		local current = active[character]
		if current == nil or current ~= entry or current.generation ~= mine then
			return
		end
		active[character] = nil
		pcall(stand, character, entry)
	end)
	return true
end

function RagdollService.Start(_services: any, _map: any)
	local function watch(player: Player)
		player.CharacterRemoving:Connect(function(character)
			active[character] = nil
		end)
		player.CharacterAdded:Connect(function(character)
			-- A character that dies mid-ragdoll is about to be replaced, so the
			-- entry is dropped rather than restored onto a corpse.
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid ~= nil and humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					active[character] = nil
				end)
			end
		end)
	end

	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

return RagdollService
