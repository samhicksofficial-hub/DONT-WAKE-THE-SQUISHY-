--!strict
-- UiRefs — the single place that knows the Essential UI Pack's tree.
--
-- Every other client module asks this module for nodes and for panel
-- open/close; none of them search PlayerGui themselves. See the UI Contract
-- in DESIGN.md for the paths this resolves.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UiRefs = {}

local player = Players.LocalPlayer

export type Refs = {
	gui: ScreenGui,
	hud: Frame,
	labels: { money: TextLabel, offline: TextLabel },
	drop: TextButton,
	random: TextButton,
	buttons: { [string]: TextButton },   -- Index, Rebirth, Shop, Invite, Wheel
	panels: { [string]: Frame },         -- Upgrades, Shop, Rebirth, Index, Wheel
	notifications: Frame,
	instructions: TextLabel,
	effect: Frame,
	effectImages: { ImageLabel },
}

local refs: Refs? = nil
local openPanelName: string? = nil

local function waitFor(parent: Instance, name: string): Instance
	return parent:WaitForChild(name, 20) or error(("UiRefs: missing %s.%s"):format(parent:GetFullName(), name))
end

-- Resolves the whole tree once. Safe to call from every module; later calls
-- return the cached table.
function UiRefs.get(): Refs
	if refs then
		return refs
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local gui = waitFor(playerGui, "MainUi") :: ScreenGui
	local hud = waitFor(gui, "HUD") :: Frame
	local frames = waitFor(gui, "Frames") :: Frame
	local left = waitFor(hud, "Left") :: Frame
	local buttons1 = waitFor(left, "Buttons1") :: Frame
	local buttons2 = waitFor(left, "Buttons2") :: Frame
	local labels = waitFor(hud, "Labels") :: Frame
	local notifications = waitFor(frames, "Notifications") :: Frame
	local effect = waitFor(gui, "Effect") :: Frame

	local effectImages: { ImageLabel } = {}
	for _, child in effect:GetChildren() do
		if child:IsA("ImageLabel") then
			table.insert(effectImages, child)
		end
	end

	refs = {
		gui = gui,
		hud = hud,
		labels = {
			money = waitFor(labels, "Money") :: TextLabel,
			offline = waitFor(labels, "Offline") :: TextLabel,
		},
		drop = waitFor(hud, "Drop") :: TextButton,
		random = waitFor(waitFor(hud, "Right"), "Random") :: TextButton,
		buttons = {
			Index = waitFor(buttons1, "Index") :: TextButton,
			Rebirth = waitFor(buttons1, "Rebirth") :: TextButton,
			Shop = waitFor(buttons1, "Shop") :: TextButton,
			Invite = waitFor(buttons2, "Invite") :: TextButton,
			Wheel = waitFor(buttons2, "Wheel") :: TextButton,
		},
		panels = {
			Upgrades = waitFor(frames, "Upgrades") :: Frame,
			Shop = waitFor(frames, "Shop") :: Frame,
			Rebirth = waitFor(frames, "Rebirth") :: Frame,
			Index = waitFor(frames, "Index") :: Frame,
			Wheel = waitFor(frames, "Wheel") :: Frame,
		},
		notifications = notifications,
		instructions = waitFor(notifications, "Instructions") :: TextLabel,
		effect = effect,
		effectImages = effectImages,
	}
	return refs
end

-- ---------- panels ----------

local POP_IN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT = TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Panels are sized in scale; remember each one's authored size so the pop
-- tween always returns to the pack's layout.
local authoredSize: { [string]: UDim2 } = {}

function UiRefs.closePanel(name: string)
	local panel = UiRefs.get().panels[name]
	if not panel or not panel.Visible then
		return
	end
	if openPanelName == name then
		openPanelName = nil
	end
	local target = authoredSize[name] or panel.Size
	local tween = TweenService:Create(panel, POP_OUT, { Size = UDim2.new(target.X.Scale * 0.8, 0, target.Y.Scale * 0.8, 0) })
	tween.Completed:Once(function(state)
		-- A cancelled tween still fires Completed (openPanel starting its own
		-- tween cancels this one), so only hide when this close really finished
		-- and the panel was not reopened in the meantime.
		if state ~= Enum.PlaybackState.Completed or openPanelName == name then
			return
		end
		panel.Visible = false
		panel.Size = target
	end)
	tween:Play()
end

function UiRefs.openPanel(name: string)
	local self = UiRefs.get()
	local panel = self.panels[name]
	if not panel then
		return
	end
	if openPanelName and openPanelName ~= name then
		UiRefs.closePanel(openPanelName)
	end
	if not authoredSize[name] then
		authoredSize[name] = panel.Size
	end
	local target = authoredSize[name]
	openPanelName = name
	panel.Size = UDim2.new(target.X.Scale * 0.8, 0, target.Y.Scale * 0.8, 0)
	panel.Visible = true
	TweenService:Create(panel, POP_IN, { Size = target }):Play()
end

function UiRefs.togglePanel(name: string)
	local panel = UiRefs.get().panels[name]
	if panel and panel.Visible then
		UiRefs.closePanel(name)
	else
		UiRefs.openPanel(name)
	end
end

function UiRefs.isPanelOpen(name: string): boolean
	local panel = UiRefs.get().panels[name]
	return panel ~= nil and panel.Visible
end

-- Finds a panel's Close button (the pack nests it under Title, except Wheel).
function UiRefs.findClose(panel: Frame): GuiButton?
	local direct = panel:FindFirstChild("Close")
	if direct and direct:IsA("GuiButton") then
		return direct
	end
	local title = panel:FindFirstChild("Title")
	if title then
		local nested = title:FindFirstChild("Close")
		if nested and nested:IsA("GuiButton") then
			return nested
		end
	end
	return nil
end

-- ---------- buttons ----------

local HOVER_IN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Click handler plus a small hover/press pop, using a UIScale so the pack's
-- own sizing (aspect ratios, list layouts) is never touched.
function UiRefs.bindButton(button: GuiButton, onClick: () -> ())
	local scale = button:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = button
	end
	local uiScale = scale :: UIScale

	button.MouseEnter:Connect(function()
		TweenService:Create(uiScale, HOVER_IN, { Scale = 1.07 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(uiScale, HOVER_IN, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(uiScale, HOVER_IN, { Scale = 0.93 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(uiScale, HOVER_IN, { Scale = 1.07 }):Play()
	end)
	button.Activated:Connect(function()
		local ok, err = pcall(onClick)
		if not ok then
			warn(("[UiRefs] button %s handler failed: %s"):format(button.Name, tostring(err)))
		end
	end)
end

-- The pack ships a "Notification" badge frame on some buttons; show or hide it.
function UiRefs.setBadge(button: GuiButton, shown: boolean)
	local badge = button:FindFirstChild("Notification")
	if badge and badge:IsA("GuiObject") then
		badge.Visible = shown
	end
end

-- Sets a button's caption (the pack nests a "Text" TextLabel inside).
function UiRefs.setButtonText(button: GuiButton, text: string)
	local label = button:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text
	elseif button:IsA("TextButton") then
		button.Text = text
	end
end

-- ---------- notifications ----------

local notifyToken = 0

-- One-line contextual hint in the pack's Notifications strip.
function UiRefs.notify(text: string, seconds: number?)
	local self = UiRefs.get()
	notifyToken += 1
	local token = notifyToken
	self.instructions.Text = text
	self.instructions.Visible = true
	if seconds then
		task.delay(seconds, function()
			if notifyToken == token then
				self.instructions.Visible = false
			end
		end)
	end
end

function UiRefs.clearNotify()
	notifyToken += 1
	UiRefs.get().instructions.Visible = false
end

return UiRefs
