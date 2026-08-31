--!strict
-- EnemyBounce — the giants' hop animation, rendered on this client.
--
-- The server drives the giants' MOVEMENT (Humanoid, server-owned physics) and
-- leaves each one's BodyWeld at identity; this module writes the weld's C0
-- locally, every render frame. Client-side on purpose: physics replication
-- interpolates the root's walk smoothly, but a server-written Weld.C0 arrives
-- as ~20Hz property snaps with no interpolation — a judder no amount of
-- server-side care can fix. A locally written C0 never replicates anywhere;
-- every client renders its own perfectly smooth copy of the same motion.
--
-- The bounce keys off MOVEMENT, not awake-ness, because the giants patrol in
-- their sleep — that is the game. A sleep-walking giant gets the drowsy
-- patrol-cadence hop (Zzz still overhead); one actually standing still
-- breathes instead, and an awake giant standing still (winding up a slap)
-- eases down to the ground.
--
-- The phase advances with the giant's ACTUAL horizontal displacement, not
-- with any velocity property, so cadence is distance-based: a chasing giant
-- naturally hops about twice as often as a patrolling one, and a giant pinned
-- against a wall stops bouncing instead of jogging on the spot. |sin| gives
-- the hop its shape — a smooth arc up and a sharp landing.

local RunService = game:GetService("RunService")

local EnemyBounce = {}

local HOP_LENGTH = 8 -- studs of ground each hop covers
local HOP_HEIGHT_FRACTION = 0.12 -- of the giant's own visual height
local CHASE_HOP_MULT = 1.3 -- chase hops ride a little higher as well as faster
-- The chase amplitude BLENDS in and out rather than switching: a state flip
-- mid-hop would otherwise pop the body by the whole multiplier in one frame.
local CHASE_BLEND_RATE = 6
local MOVING_SPEED = 0.5 -- studs/s; below this the giant counts as still
local SPEED_CAP = 40 -- a lag spike or teleport must not slingshot the phase
-- The measured speed is smoothed over ~0.1s before use: replicated roots get
-- one-frame position corrections, and a raw spike would kick the phase (and
-- flap the moving/still branches right at the threshold).
local SPEED_SMOOTH_RATE = 10
local SETTLE_RATE = 8 -- how quickly the body eases toward rest after stopping
local BREATH_HEIGHT_FRACTION = 0.02
local BREATH_RATE = 0.8 -- radians per second of sleeping swell

type Entry = {
	model: Model,
	root: BasePart,
	weld: Weld,
	height: number,
	phase: number,
	offset: number,
	hopScale: number,
	stagger: number,
	lastPos: Vector3,
	smoothSpeed: number,
}

local entries: { [Model]: Entry } = {}
local nextStagger = 0

-- Adopts one giant once its parts have replicated. Quietly gives up on a
-- model that never grows them (a half-replicated corpse mid-leave).
local function watchEnemy(model: Model)
	task.spawn(function()
		local root = model:WaitForChild("HumanoidRootPart", 10)
		local body = model:WaitForChild("Body", 10)
		local weld = body ~= nil and body:WaitForChild("BodyWeld", 10) or nil
		if root == nil or body == nil or weld == nil then
			return
		end
		if not (root:IsA("BasePart") and body:IsA("BasePart") and weld:IsA("Weld")) then
			return
		end
		nextStagger += 2.1
		entries[model] = {
			model = model,
			root = root,
			weld = weld,
			height = body.Size.Y,
			phase = 0,
			offset = 0,
			hopScale = 1,
			stagger = nextStagger,
			lastPos = root.Position,
			smoothSpeed = 0,
		}
	end)
end

local function step(dt: number)
	local clock = os.clock()
	for model, entry in entries do
		if model.Parent == nil then
			entries[model] = nil
			continue
		end
		local rootPos = entry.root.Position
		local delta = rootPos - entry.lastPos
		entry.lastPos = rootPos
		local rawSpeed = if dt > 0
			then math.min(Vector3.new(delta.X, 0, delta.Z).Magnitude / dt, SPEED_CAP)
			else 0
		entry.smoothSpeed += (rawSpeed - entry.smoothSpeed) * math.min(1, dt * SPEED_SMOOTH_RATE)
		local speed = entry.smoothSpeed
		local state = model:GetAttribute("State")

		local targetScale = if state == "Chasing" then CHASE_HOP_MULT else 1
		entry.hopScale += (targetScale - entry.hopScale) * math.min(1, dt * CHASE_BLEND_RATE)

		local offset: number
		if speed > MOVING_SPEED then
			entry.phase += speed * dt * math.pi / HOP_LENGTH
			offset = entry.height * HOP_HEIGHT_FRACTION * entry.hopScale * math.abs(math.sin(entry.phase))
		else
			-- Standing still. The offset EASES toward its resting target
			-- rather than being assigned it: a giant that decelerates to a
			-- stop mid-hop (the beat between a MoveTo completing and the next
			-- one being issued) would otherwise snap from hop height to the
			-- target in a single frame. Asleep the target is the breathing
			-- swell (staggered per giant so the three never rise in
			-- lockstep); awake — winding up a slap — it is the ground.
			entry.phase = 0
			local target = 0
			if state == "Sleeping" then
				target = entry.height
					* BREATH_HEIGHT_FRACTION
					* (0.5 + 0.5 * math.sin(clock * BREATH_RATE + entry.stagger))
			end
			offset = entry.offset + (target - entry.offset) * math.min(1, dt * SETTLE_RATE)
		end
		entry.offset = offset
		entry.weld.C0 = CFrame.new(0, offset, 0)
	end
end

function EnemyBounce.Start()
	local enemyFolder = workspace:WaitForChild("Enemies", 30)
	if enemyFolder == nil then
		warn("[EnemyBounce] no Workspace.Enemies folder; giants will not bounce")
		return
	end

	enemyFolder.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			watchEnemy(child)
		end
	end)
	for _, child in enemyFolder:GetChildren() do
		if child:IsA("Model") then
			watchEnemy(child)
		end
	end

	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn(("[EnemyBounce] step failed: %s"):format(tostring(err)))
		end
	end)
end

return EnemyBounce
