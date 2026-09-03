--!strict
-- Panels — the router that opens and closes the Essential UI Pack's panels.
--
-- Owns: the HUD Left column buttons, every panel's Close button, the Invite
-- button (SocialService), the Wheel button's "Spin (N)" caption + badge, and
-- the Rebirth button's "you can afford it" badge.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UiRefs = require(script.Parent.UiRefs)

-- HUD button name -> panel name. The Shop button opens the actual Robux shop
-- (ShopUi drives its cards); the cash upgrade tracks it used to stand in for
-- are gone from the game.
local BUTTON_PANELS = {
	{ "Index", "Index" },
	{ "Rebirth", "Rebirth" },
	{ "Shop", "Shop" },
	{ "Wheel", "Wheel" },
}

local INVITE_FAILED = "Invites are not available right now."

local Panels = {}

local function readNumber(player: Player, attribute: string): number
	local raw = player:GetAttribute(attribute)
	if typeof(raw) == "number" then
		return raw
	end
	return 0
end

function Panels.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()

	-- ---------- HUD buttons -> panels ----------

	for _, pair in BUTTON_PANELS do
		local ok, err = pcall(function()
			local buttonName = pair[1]
			local panelName = pair[2]
			local button = refs.buttons[buttonName]
			if button then
				UiRefs.bindButton(button, function()
					UiRefs.togglePanel(panelName)
				end)
			end
		end)
		if not ok then
			warn(("[Panels] could not bind %s: %s"):format(pair[1], tostring(err)))
		end
	end

	-- ---------- close buttons ----------

	for panelName, panel in refs.panels do
		local ok, err = pcall(function()
			local close = UiRefs.findClose(panel)
			if close then
				UiRefs.bindButton(close, function()
					UiRefs.closePanel(panelName)
				end)
			else
				warn(("[Panels] panel %s has no Close button"):format(panelName))
			end
		end)
		if not ok then
			warn(("[Panels] could not bind %s Close: %s"):format(panelName, tostring(err)))
		end
	end

	-- ---------- invite ----------

	local inviteButton = refs.buttons.Invite
	if inviteButton then
		UiRefs.bindButton(inviteButton, function()
			local canAsk, canInvite = pcall(function()
				return SocialService:CanSendGameInviteAsync(player)
			end)
			if not canAsk or canInvite ~= true then
				UiRefs.notify(INVITE_FAILED, 4)
				return
			end
			local prompted = pcall(function()
				SocialService:PromptGameInvite(player)
			end)
			if not prompted then
				UiRefs.notify(INVITE_FAILED, 4)
			end
		end)
	end

	-- ---------- wheel caption + badge ----------

	local wheelButton = refs.buttons.Wheel
	local function refreshWheel()
		local spins = math.max(0, math.floor(readNumber(player, "Spins")))
		UiRefs.setButtonText(wheelButton, ("Spin (%d)"):format(spins))
		UiRefs.setBadge(wheelButton, spins > 0)
	end

	-- ---------- rebirth badge ----------

	local rebirthButton = refs.buttons.Rebirth
	local function refreshRebirth()
		local rebirths = math.max(0, math.floor(readNumber(player, "Rebirths")))
		local cost = Config.Rebirth.Costs[rebirths + 1]
		local affordable = typeof(cost) == "number" and readNumber(player, "Money") >= cost
		UiRefs.setBadge(rebirthButton, affordable)
	end

	player:GetAttributeChangedSignal("Spins"):Connect(refreshWheel)
	player:GetAttributeChangedSignal("Money"):Connect(refreshRebirth)
	player:GetAttributeChangedSignal("Rebirths"):Connect(refreshRebirth)
	refreshWheel()
	refreshRebirth()

	-- The Shop never nags: its cards speak for themselves (ShopUi owns them).
	UiRefs.setBadge(refs.buttons.Shop, false)
end

return Panels
