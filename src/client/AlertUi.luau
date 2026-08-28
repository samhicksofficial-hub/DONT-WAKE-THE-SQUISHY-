--!strict
-- AlertUi — drives the Essential UI Pack's Effect vignette and the
-- Notifications hint line. Builds nothing: every node comes from UiRefs.
--
--   Effect.Image1..4  pulse red while any enemy is chasing YOU
--   Notifications     one hint line, priority: chase > carrying > welcome

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UiRefs = require(script.Parent.UiRefs)

local ALERT_COLOR = Color3.fromRGB(255, 45, 45)
local PULSE_MIN = 0.15 -- most opaque point of the pulse
local PULSE_MAX = 0.55 -- faintest point
local PULSE_TIME = 0.45
local COLOR_TIME = 0.2

local WELCOME_TEXT = "Sneak into the field and hold E to grab a squishy"
local WELCOME_SECONDS = 8

local PULSE_INFO = TweenInfo.new(PULSE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local COLOR_INFO = TweenInfo.new(COLOR_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type ImageState = {
	image: ImageLabel,
	color: Color3,
	transparency: number,
	colorTween: Tween,
	pulseTween: Tween,
}

local AlertUi = {}

function AlertUi.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()
	local effect = refs.effect

	-- ------------------------------------------------------------- vignette --

	-- The vignette is decoration only: it must never eat a click.
	effect.Active = false

	local states: { ImageState } = {}
	for _, image in refs.effectImages do
		local ok, err = pcall(function()
			image.Active = false
			table.insert(states, {
				image = image,
				color = image.ImageColor3,
				transparency = image.ImageTransparency,
				colorTween = TweenService:Create(image, COLOR_INFO, { ImageColor3 = ALERT_COLOR }),
				pulseTween = TweenService:Create(image, PULSE_INFO, { ImageTransparency = PULSE_MIN }),
			})
		end)
		if not ok then
			warn(("[AlertUi] could not prepare %s: %s"):format(image.Name, tostring(err)))
		end
	end

	-- The pack ships Effect hidden with fully opaque images, so the frame's
	-- Visible is the on/off switch; the images' own Visible is never touched.
	local pulsing = false
	local function setPulse(on: boolean)
		if on == pulsing then
			return
		end
		pulsing = on
		if on then
			effect.Visible = true
		end
		for _, state in states do
			local ok, err = pcall(function()
				if on then
					state.image.ImageTransparency = PULSE_MAX
					state.colorTween:Play()
					state.pulseTween:Play()
				else
					state.colorTween:Cancel()
					state.pulseTween:Cancel()
					state.image.ImageColor3 = state.color
					state.image.ImageTransparency = state.transparency
				end
			end)
			if not ok then
				warn(("[AlertUi] pulse failed on %s: %s"):format(state.image.Name, tostring(err)))
			end
		end
		if not on then
			effect.Visible = false
		end
	end

	effect.Visible = false

	-- ----------------------------------------------------------------- hints --

	local chaseText: string? = nil
	local carryText: string? = nil
	local welcomeActive = false

	-- One line, three sources: the loudest wins. Anything louder than the
	-- welcome hint retires it for good.
	local function refreshHint()
		local chase = chaseText
		local carry = carryText
		if chase ~= nil then
			welcomeActive = false
			UiRefs.notify(chase)
		elseif carry ~= nil then
			welcomeActive = false
			UiRefs.notify(carry)
		elseif not welcomeActive then
			UiRefs.clearNotify()
		end
	end

	local function updateCarry()
		local carrying = player:GetAttribute("Carrying")
		if typeof(carrying) == "string" and (carrying :: string) ~= "" then
			local rawMult = player:GetAttribute("CarrySpeedMult")
			local mult = if typeof(rawMult) == "number" then rawMult :: number else 1
			local slower = math.floor((1 - mult) * 100 + 0.5)
			carryText = ("Carrying %s — %d%% slower. Get to your plot!"):format(carrying :: string, slower)
		else
			carryText = nil
		end
		refreshHint()
	end

	player:GetAttributeChangedSignal("Carrying"):Connect(updateCarry)
	player:GetAttributeChangedSignal("CarrySpeedMult"):Connect(updateCarry)
	updateCarry()

	if carryText == nil then
		welcomeActive = true
		UiRefs.notify(WELCOME_TEXT, WELCOME_SECONDS)
		task.delay(WELCOME_SECONDS, function()
			welcomeActive = false
		end)
	end

	-- --------------------------------------------------------------- enemies --

	-- Spawned so Start never blocks: Enemies appears only once MapBuilder ran.
	task.spawn(function()
		local enemiesFolder = Workspace:WaitForChild("Enemies")
		local enemyConns: { [Instance]: { RBXScriptConnection } } = {}

		-- Name of the enemy currently chasing the local player, if any.
		local function threatName(enemy: Instance): string?
			if enemy:GetAttribute("State") ~= "Chasing" then
				return nil
			end
			if enemy:GetAttribute("TargetUserId") ~= player.UserId then
				return nil
			end
			local named = enemy:GetAttribute("EnemyName")
			if typeof(named) == "string" then
				return named :: string
			end
			return enemy.Name
		end

		local function evaluate()
			local hunter: string? = nil
			for _, enemy in enemiesFolder:GetChildren() do
				local ok, name = pcall(threatName, enemy)
				if ok and typeof(name) == "string" then
					hunter = name :: string
					break
				end
			end
			if hunter ~= nil then
				chaseText = ("RUN! %s woke up!"):format(hunter)
				setPulse(true)
			else
				chaseText = nil
				setPulse(false)
			end
			refreshHint()
		end

		local function safeEvaluate()
			local ok, err = pcall(evaluate)
			if not ok then
				warn(("[AlertUi] chase check failed: %s"):format(tostring(err)))
			end
		end

		local function watchEnemy(enemy: Instance)
			local ok, err = pcall(function()
				enemyConns[enemy] = {
					enemy:GetAttributeChangedSignal("State"):Connect(safeEvaluate),
					enemy:GetAttributeChangedSignal("TargetUserId"):Connect(safeEvaluate),
				}
			end)
			if not ok then
				warn(("[AlertUi] could not watch %s: %s"):format(enemy.Name, tostring(err)))
			end
		end

		for _, enemy in enemiesFolder:GetChildren() do
			watchEnemy(enemy)
		end

		enemiesFolder.ChildAdded:Connect(function(child)
			watchEnemy(child)
			safeEvaluate()
		end)

		enemiesFolder.ChildRemoved:Connect(function(child)
			local conns = enemyConns[child]
			if conns ~= nil then
				enemyConns[child] = nil
				for _, conn in conns do
					conn:Disconnect()
				end
			end
			safeEvaluate()
		end)

		safeEvaluate()
	end)
end

return AlertUi
