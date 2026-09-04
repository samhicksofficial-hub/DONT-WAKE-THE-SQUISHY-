--!strict
-- WheelUi — drives the pack's Frames.Wheel panel from Config.Wheel.
--
-- The pack authors six wedges as SpinWheel.Pattern.{1..6}. Their authored
-- Position/Rotation say wedge 1 sits at the top (under RedArrow) and the rest
-- run COUNTER-CLOCKWISE from there in 60 degree steps
-- (Pattern[i].Rotation = -(i - 1) * 60, wrapped: 0, 300, 240, 180, 120, 60).
-- GuiObject.Rotation is clockwise-positive, so parking wedge i under the arrow
-- means turning the wheel to +(i - 1) * (360 / wedgeCount) degrees. Nothing here
-- moves or resizes one of the pack's own wedges — we only set text and Rotation,
-- and draw the coloured slices in behind them.

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
-- the wheel is not inventing a second language for the same three words.
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

-- ---------------------------------------------------------------- slices --
--
-- The pack's wheel face is a flat black disc, and no tint can lift it: the
-- black is black pixels, and ImageColor3 multiplies, so black stays black. The
-- colour has to be drawn on top of it.
--
-- Clipping cannot cut the slices. Roblox does not clip a descendant that
-- carries a Rotation of its own — measured, a 45-degree 600x600 child of a
-- 200x200 ClipsDescendants frame renders at its full size — so the usual trick
-- of nesting two rotated half-plane clippers just draws six whole circles.
--
-- Masking by gradient does work, and needs no rotation at all. A UIGradient
-- whose Transparency steps from 1 to 0 at offset 0.5 cuts its object along a
-- straight line through the object's centre, at whatever angle the gradient is
-- set to. One of those on a circle leaves a half-disc. A second one, carried by
-- a CanvasGroup wrapped around the first (a CanvasGroup composites its children
-- to a texture, so a gradient on it masks the whole subtree), cuts that half
-- again. Two cuts (180 - span) degrees apart leave exactly one wedge.
local SLICES_NAME = "Slices"
-- Fraction of the wheel image the black face covers, inside the moulded rim.
local SLICE_SPAN = 0.88
-- HSV value every slice settles on. The rarity colours are authored bright for
-- text; straight onto a slice they glare, and darkening them far enough to sit
-- quietly turns the Legendary orange to mud. This is where they still read as
-- themselves next to the game's other panels.
local SLICE_VALUE = 0.78
-- Half-width of the gradient's step, in gradient offset. Not zero: a couple of
-- pixels of ramp is the only anti-aliasing a slice edge gets.
local SLICE_EDGE = 0.004
local SPOKE_WIDTH = 3
local SPOKE_TRANSPARENCY = 0.6
-- The slice behind a label now carries the reward's colour, so the label itself
-- goes white. A rarity's own blue on a blue slice is legible but muddy; white
-- over the pack's black stroke reads cleanly on all six.
local LABEL_COLOR = Color3.new(1, 1, 1)

local function sliceColour(colour: Color3): Color3
	local hue, saturation = colour:ToHSV()
	return Color3.fromHSV(hue, math.clamp(saturation * 1.1 + 0.08, 0, 1), SLICE_VALUE)
end

-- Masks `object` down to the half-plane on one side of a line through its
-- centre. `rotation` is the gradient's direction, and the half it points into is
-- the half that survives.
local function halfPlane(object: Instance, rotation: number)
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5 - SLICE_EDGE, 1),
		NumberSequenceKeypoint.new(0.5 + SLICE_EDGE, 0),
		NumberSequenceKeypoint.new(1, 0),
	})
	gradient.Parent = object
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

-- Paints the pizza behind the pack's labels. `wheel` is the SpinWheel image, and
-- the slices go in as one more of its children so they turn with it on a spin.
local function buildSlices(wheel: any, rewards: { any }, wedgeCount: number)
	local span = 360 / wedgeCount
	if span > 180 then
		-- A wedge wider than a half-turn is not the overlap of two half-planes,
		-- so it cannot be drawn this way. Leave the pack's black face alone.
		return
	end

	-- Destroyed rather than reused, so a second Start() cannot stack a second
	-- set of slices over the first.
	local previous = child(wheel, SLICES_NAME)
	if previous then
		(previous :: Instance):Destroy()
	end

	local background = child(wheel, "Background")

	local pie = Instance.new("Frame")
	pie.Name = SLICES_NAME
	pie.Size = UDim2.fromScale(SLICE_SPAN, SLICE_SPAN)
	pie.AnchorPoint = Vector2.new(0.5, 0.5)
	pie.Position = UDim2.fromScale(0.5, 0.5)
	pie.BackgroundTransparency = 1
	-- Just above the pack's black face (ZIndex 0) and well below its labels
	-- (ZIndex 6), which is where the colour belongs.
	pie.ZIndex = (if background then background.ZIndex else 0) + 1
	pie.Parent = wheel

	for i = 1, wedgeCount do
		local reward = rewards[i]
		local colour = Color3.new(1, 1, 1)
		if reward then
			colour = (wedgeLook(reward))
		end
		-- Wedge i sits `span` degrees counter-clockwise of the one before it, so
		-- its middle is at -(i - 1) * span measured clockwise from the top.
		local middle = -(i - 1) * span

		local group = Instance.new("CanvasGroup")
		group.Name = ("Slice%d"):format(i)
		group.Size = UDim2.fromScale(1, 1)
		group.AnchorPoint = Vector2.new(0.5, 0.5)
		group.Position = UDim2.fromScale(0.5, 0.5)
		group.BackgroundTransparency = 1
		group.ZIndex = 1
		group.Parent = pie
		halfPlane(group, middle + span / 2 - 180)

		local disc = Instance.new("Frame")
		disc.Name = "Disc"
		disc.Size = UDim2.fromScale(1, 1)
		disc.BackgroundColor3 = sliceColour(colour)
		disc.BorderSizePixel = 0
		disc.Parent = group
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0) -- a square frame, rounded into a circle
		corner.Parent = disc
		halfPlane(disc, middle - span / 2)
	end

	-- A hairline down every seam, so neighbouring slices read as cut rather than
	-- merely touching.
	local spokes = Instance.new("Frame")
	spokes.Name = "Spokes"
	spokes.Size = UDim2.fromScale(1, 1)
	spokes.BackgroundTransparency = 1
	spokes.ZIndex = 2
	spokes.Parent = pie
	for i = 1, wedgeCount do
		local spoke = Instance.new("Frame")
		spoke.Name = ("Spoke%d"):format(i)
		spoke.Size = UDim2.new(0, SPOKE_WIDTH, 0.5, 0)
		spoke.AnchorPoint = Vector2.new(0.5, 1)
		spoke.Position = UDim2.fromScale(0.5, 0.5)
		spoke.Rotation = -(i - 1) * span + span / 2
		spoke.BackgroundColor3 = Color3.new(1, 1, 1)
		spoke.BackgroundTransparency = SPOKE_TRANSPARENCY
		spoke.BorderSizePixel = 0
		spoke.ZIndex = 2
		spoke.Parent = spokes
	end
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

	local sliced, sliceErr = pcall(buildSlices, wheel, rewards, wedgeCount)
	if not sliced then
		-- Only the colour behind the labels is lost; the wheel still spins.
		warn(("[WheelUi] slices failed: %s"):format(tostring(sliceErr)))
	end

	for i = 1, wedgeCount do
		local ok, err = pcall(function()
			local node = child(pattern, tostring(i))
			local reward = rewards[i]
			if not (node and reward) then
				return
			end
			node.Text = reward.label
			local _, icon = wedgeLook(reward)
			node.TextColor3 = LABEL_COLOR
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
				chance.TextColor3 = LABEL_COLOR
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
