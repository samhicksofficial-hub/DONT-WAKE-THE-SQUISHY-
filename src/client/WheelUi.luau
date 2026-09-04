--!strict
-- WheelUi — drives the pack's Frames.Wheel panel from Config.Wheel.
--
-- The pack authors six wedges as SpinWheel.Pattern.{1..6}. Their authored
-- Position/Rotation say wedge 1 sits at the top (under RedArrow) and the rest
-- run COUNTER-CLOCKWISE from there in 60 degree steps
-- (Pattern[i].Rotation = -(i - 1) * 60, wrapped: 0, 300, 240, 180, 120, 60).
-- GuiObject.Rotation is clockwise-positive, so parking wedge i under the arrow
-- means turning the wheel to +(i - 1) * (360 / wedgeCount) degrees. Nothing here
-- moves or resizes a wedge — we only set text, Visible and Rotation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local UiRefs = require(script.Parent.UiRefs)

local PANEL_NAME = "Wheel"
local SPIN_TURNS = 5                      -- full revolutions before the landing angle
local SPIN_INFO = TweenInfo.new(3.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local INVOKE_TIMEOUT = 10                 -- seconds before we give up on the RemoteFunction
local DIM_COLOR = Color3.fromRGB(120, 120, 120)
local DIM_TEXT = 0.35

-- Every wedge shipped white, with the SAME cash-stack icon on all six, so a
-- Legendary and a $500 read identically until you stopped to read the words.
-- Each reward now wears its own colour and its own icon.
--
-- The squishy wedges borrow the rarity colours the game already uses for those
-- names everywhere else — the index, the pickup labels, the collect pads — so
-- the wheel is not inventing a second language for the same three words. The
-- wheel face is one flat image, so a wedge cannot be filled; the colour has to
-- come from the label, its odds caption and the icon above them.
local WHEEL_CASH = Color3.fromRGB(85, 255, 85)
local WHEEL_SPEED = Color3.fromRGB(96, 210, 255)

-- The colour and icon a reward wears on its wedge.
local function wedgeLook(reward: any): (Color3, string)
	if reward.kind == "squishy" then
		local rarity = (Config.RarityByName :: any)[reward.rarity]
		return (rarity and rarity.color) or Color3.new(1, 1, 1), Config.Icons.Gift
	elseif reward.kind == "speed" then
		return WHEEL_SPEED, Config.Icons.Coil
	end
	return WHEEL_CASH, Config.Icons.Cash
end

local WheelUi = {}

local player = Players.LocalPlayer

local function readNumber(name: string): number
	local raw = player:GetAttribute(name)
	if typeof(raw) == "number" then
		return raw
	end
	return 0
end

-- Safe FindFirstChild that tolerates a nil parent; results are used as `any`
-- because the pack's tree is data, not a typed API.
local function child(parent: any, name: string): any
	if not parent then
		return nil
	end
	return (parent :: Instance):FindFirstChild(name)
end

local function formatCountdown(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	return ("Next in %d:%02d"):format(math.floor(total / 60), total % 60)
end

function WheelUi.Start()
	local refs = UiRefs.get()
	local panel = refs.panels[PANEL_NAME]
	if not panel then
		warn("[WheelUi] Frames.Wheel is missing")
		return
	end

	local wheel = child(panel, "SpinWheel")
	local buttonsFrame = child(panel, "Buttons")
	local spinButton = child(buttonsFrame, "SpinButton")
	if not (wheel and spinButton) then
		warn("[WheelUi] Wheel.SpinWheel / Wheel.Buttons.SpinButton missing — panel not wired")
		return
	end

	local rewards = (Config.Wheel.Rewards :: any) :: { any }
	local pattern = child(wheel, "Pattern")

	-- Wedge count comes from the pack's own numbered Pattern children.
	local wedgeCount = 0
	if pattern then
		for _, node in (pattern :: Instance):GetChildren() do
			if tonumber(node.Name) then
				wedgeCount += 1
			end
		end
	end
	if wedgeCount <= 0 then
		wedgeCount = #rewards
	end

	local totalWeight = 0
	for _, reward in rewards do
		totalWeight += (reward.weight or 0)
	end

	-- ---------- static labelling ----------

	for i = 1, wedgeCount do
		local ok, err = pcall(function()
			local node = child(pattern, tostring(i))
			local reward = rewards[i]
			if not (node and reward) then
				return
			end
			node.Text = reward.label
			local color, icon = wedgeLook(reward)
			node.TextColor3 = color
			-- The pack nests an icon (Image) with a "Chance" caption on each
			-- wedge; fill it with the reward's odds so no placeholder shows.
			local image = child(node, "Image")
			if image and image:IsA("ImageLabel") then
				-- Swapped, not tinted: these icons carry their own colours, and
				-- multiplying a gift or a coil down to one hue only muddies it.
				image.Image = icon
			end
			local chance = child(image, "Chance")
			if chance and totalWeight > 0 then
				chance.Text = ("%d%%"):format(math.round((reward.weight or 0) / totalWeight * 100))
				chance.TextColor3 = color
			end
		end)
		if not ok then
			warn(("[WheelUi] wedge %d failed: %s"):format(i, tostring(err)))
		end
	end

	-- Robux spin packs are parked until Config.Products carries real ids.
	for _, name in { "RobuxButton1", "RobuxButton2" } do
		local ok, err = pcall(function()
			local node = child(buttonsFrame, name)
			if node then
				node.Visible = false
			end
		end)
		if not ok then
			warn(("[WheelUi] hiding %s failed: %s"):format(name, tostring(err)))
		end
	end

	-- ---------- spin button state ----------

	local buttonBackground = child(spinButton, "Background")
	local buttonCaption = child(spinButton, "Text")
	local authoredColor = Color3.new(1, 1, 1)
	if buttonBackground then
		authoredColor = buttonBackground.ImageColor3
	end

	local function setInteractive(enabled: boolean)
		spinButton.Interactable = enabled
		spinButton.Active = enabled
		if buttonBackground then
			buttonBackground.ImageColor3 = if enabled then authoredColor else DIM_COLOR
		end
		if buttonCaption then
			buttonCaption.TextTransparency = if enabled then 0 else DIM_TEXT
		end
	end

	local spinning = false
	local spinToken = 0
	local activeTween: Tween? = nil
	local pendingRotation: number? = nil

	local function refresh()
		if spinning then
			return
		end
		local spins = readNumber("Spins")
		if spins > 0 then
			setInteractive(true)
			UiRefs.setButtonText(spinButton, ("Spin (%d)"):format(spins))
			return
		end
		setInteractive(false)
		local nextAt = readNumber("NextSpinAt")
		if nextAt > 0 then
			UiRefs.setButtonText(spinButton, formatCountdown(nextAt - os.time()))
		else
			UiRefs.setButtonText(spinButton, "Spin (0)")
		end
	end

	-- Panel closed mid-spin: jump the wheel to where it was going and let the
	-- next spin start clean.
	local function snapToFinal()
		spinToken += 1
		local tween = activeTween
		activeTween = nil
		if tween then
			tween:Cancel()
		end
		local target = pendingRotation
		pendingRotation = nil
		if target then
			wheel.Rotation = target % 360
		end
		spinning = false
	end

	-- ---------- spinning ----------

	local step = 360 / wedgeCount

	local function landingRotation(index: number): number
		local target = ((index - 1) * step) % 360
		local current = wheel.Rotation
		local delta = (target - (current % 360)) % 360
		-- A little slop so the pointer does not park dead-centre every time,
		-- while staying comfortably inside the wedge.
		local jitter = (math.random() - 0.5) * step * 0.6
		return current + SPIN_TURNS * 360 + delta + jitter
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local spinRemote = remotes:WaitForChild("Spin") :: any

	local function doSpin()
		if spinning then
			return
		end
		if readNumber("Spins") <= 0 then
			UiRefs.notify("No spins left!", 3)
			refresh()
			return
		end

		spinning = true
		spinToken += 1
		local token = spinToken
		setInteractive(false)
		UiRefs.setButtonText(spinButton, "Spinning...")

		-- A RemoteFunction can error *or* never come back, so the invoke runs
		-- on its own thread behind a deadline.
		local answered = false
		local wonIndex: number? = nil
		task.spawn(function()
			local ok, result = pcall(function()
				return spinRemote:InvokeServer()
			end)
			if not ok then
				warn(("[WheelUi] Spin invoke failed: %s"):format(tostring(result)))
			elseif typeof(result) == "number" then
				wonIndex = result
			end
			answered = true
		end)

		local deadline = os.clock() + INVOKE_TIMEOUT
		while not answered and os.clock() < deadline do
			task.wait(0.1)
		end

		if token ~= spinToken then
			return -- superseded (panel closed mid-spin)
		end

		if not answered then
			spinning = false
			UiRefs.notify("The wheel did not respond — try again.", 4)
			refresh()
			return
		end

		local index = wonIndex
		if not index then
			spinning = false
			UiRefs.notify("No spins left!", 3)
			refresh()
			return
		end

		local finalRotation = landingRotation(index)
		pendingRotation = finalRotation
		local tween = TweenService:Create(wheel, SPIN_INFO, { Rotation = finalRotation })
		activeTween = tween
		tween:Play()
		tween.Completed:Wait()

		if token == spinToken then
			activeTween = nil
			pendingRotation = nil
			wheel.Rotation = finalRotation % 360
			spinning = false
		end

		local reward = rewards[index]
		UiRefs.notify(if reward then ("You won %s!"):format(reward.label) else "You won a prize!", 4)
		refresh()
	end

	UiRefs.bindButton(spinButton, function()
		task.spawn(doSpin)
	end)

	-- ---------- live state ----------

	player:GetAttributeChangedSignal("Spins"):Connect(refresh)
	player:GetAttributeChangedSignal("NextSpinAt"):Connect(refresh)

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if panel.Visible then
			refresh()
		elseif spinning then
			snapToFinal()
			refresh()
		end
	end)

	-- The cooldown caption ticks once a second, but only while the panel is up.
	task.spawn(function()
		while true do
			task.wait(1)
			if panel.Visible then
				refresh()
			end
		end
	end)

	refresh()
end

return WheelUi
