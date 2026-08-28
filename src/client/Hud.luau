--!strict
-- Hud — drives the Essential UI Pack's HUD strip. Builds nothing: every node
-- comes from UiRefs (see the UI Contract in DESIGN.md).
--
--   Labels.Money   the Money attribute, count-up tweened, with a pop on gain
--   Labels.Offline repurposed as the live income rate ("$1.2k/s")
--   Drop           visible only while carrying; fires Remotes.Drop
--   Right.Random   hidden while its Robux product id is parked

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))
local Config = require(Shared:WaitForChild("Config"))

local COUNT_DURATION = 0.3 -- seconds for the money count-up lerp
local POP_DURATION = 0.12
local POP_SCALE = 1.12
local INCOME_DEBOUNCE = 0.2 -- seconds to settle after plot tree churn

local Hud = {}

local function readMoney(player: Player): number
	local raw = player:GetAttribute("Money")
	if typeof(raw) == "number" then
		return raw :: number
	end
	return 0
end

-- $/s contributed by one instance: only placed squishy models count.
local function placedIncome(instance: Instance): number
	if not instance:IsA("Model") then
		return 0
	end
	if instance:GetAttribute("State") ~= "Placed" then
		return 0
	end
	local raw = instance:GetAttribute("Income")
	if typeof(raw) == "number" then
		return raw :: number
	end
	return 0
end

function Hud.Start()
	local player = Players.LocalPlayer
	local refs = UiRefs.get()
	local moneyLabel = refs.labels.money
	local incomeLabel = refs.labels.offline

	-- ---------------------------------------------------------------- money --

	-- Pop the whole Labels block rather than the Money label alone: the pack
	-- puts a UIListLayout inside Labels, and scaling a laid-out child would
	-- shove the income line around on every payout.
	local labelsFrame = moneyLabel.Parent :: any
	local existingScale = labelsFrame:FindFirstChildOfClass("UIScale")
	if existingScale == nil then
		local created = Instance.new("UIScale")
		created.Name = "MoneyPop"
		created.Parent = labelsFrame
		existingScale = created
	end
	local moneyScale = existingScale :: UIScale

	local displayed = readMoney(player)
	moneyLabel.Text = Util.formatMoney(displayed)

	local countConn: RBXScriptConnection? = nil
	local animFrom = displayed
	local animTarget = displayed
	local animStart = 0

	local function stopCount()
		local conn = countConn
		if conn ~= nil then
			conn:Disconnect()
			countConn = nil
		end
	end

	local function animateTo(target: number)
		animFrom = displayed
		animTarget = target
		animStart = os.clock()
		if countConn ~= nil then
			return
		end
		countConn = RunService.RenderStepped:Connect(function()
			local alpha = math.clamp((os.clock() - animStart) / COUNT_DURATION, 0, 1)
			displayed = animFrom + (animTarget - animFrom) * alpha
			moneyLabel.Text = Util.formatMoney(displayed)
			if alpha >= 1 then
				displayed = animTarget
				stopCount()
			end
		end)
	end

	local popInfo = TweenInfo.new(POP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
	local popTween = TweenService:Create(moneyScale, popInfo, { Scale = POP_SCALE })

	player:GetAttributeChangedSignal("Money"):Connect(function()
		local target = readMoney(player)
		if target == displayed and countConn == nil then
			return
		end
		local gained = target > displayed
		animateTo(target)
		if gained then
			popTween:Cancel()
			moneyScale.Scale = 1
			popTween:Play()
		end
	end)

	-- --------------------------------------------------------- income rate --

	-- Sum of the Income attribute over the player's own placed squishies.
	-- PlotService names each plot model after its owner and parents placed
	-- squishies (State = "Placed") inside it.
	local function computeIncome(): number
		local plotFolder = Workspace:FindFirstChild("Plots")
		if plotFolder == nil then
			return 0
		end
		local plot = plotFolder:FindFirstChild(player.Name)
		if plot == nil then
			return 0
		end
		local total = 0
		for _, descendant in plot:GetDescendants() do
			local ok, income = pcall(placedIncome, descendant)
			if ok and typeof(income) == "number" then
				total += income :: number
			end
		end
		-- EconomyService multiplies every payout by the rebirth multiplier, so
		-- the displayed rate has to match what the pads will actually pay.
		local rebirths = tonumber(player:GetAttribute("Rebirths")) or 0
		local tiers = Config.Rebirth.Multipliers
		local multiplier = tiers[math.clamp(math.floor(rebirths) + 1, 1, #tiers)] or 1
		return total * multiplier
	end

	local function refreshIncome()
		local total = computeIncome()
		if total <= 0 then
			incomeLabel.Visible = false
			return
		end
		incomeLabel.Text = Util.formatMoney(total) .. "/s"
		incomeLabel.Visible = true
	end

	incomeLabel.Visible = false

	local incomeQueued = false
	local function queueIncome()
		if incomeQueued then
			return
		end
		incomeQueued = true
		task.delay(INCOME_DEBOUNCE, function()
			incomeQueued = false
			local ok, err = pcall(refreshIncome)
			if not ok then
				warn(("[Hud] income refresh failed: %s"):format(tostring(err)))
			end
		end)
	end

	-- Spawned: Plots only appears once the server's MapBuilder has run.
	task.spawn(function()
		local plotFolder = Workspace:WaitForChild("Plots")
		plotFolder.DescendantAdded:Connect(queueIncome)
		plotFolder.DescendantRemoving:Connect(queueIncome)
		queueIncome()
	end)

	-- A rebirth changes the rate without touching the plot tree.
	player:GetAttributeChangedSignal("Rebirths"):Connect(queueIncome)

	-- ----------------------------------------------------------- drop button --

	local dropButton = refs.drop
	dropButton.Visible = false

	local dropRemote: RemoteEvent? = nil
	task.spawn(function()
		dropRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Drop") :: RemoteEvent
	end)

	UiRefs.bindButton(dropButton, function()
		local remote = dropRemote
		if remote ~= nil then
			remote:FireServer()
		end
	end)

	local function updateDrop()
		local carrying = player:GetAttribute("Carrying")
		if typeof(carrying) == "string" and (carrying :: string) ~= "" then
			UiRefs.setButtonText(dropButton, "Drop " .. (carrying :: string))
			dropButton.Visible = true
		else
			dropButton.Visible = false
		end
	end

	player:GetAttributeChangedSignal("Carrying"):Connect(updateDrop)
	updateDrop()

	-- --------------------------------------------------------- random button --

	-- Parked: the Robux developer product does not exist yet (DESIGN.md,
	-- Monetization). No id, no button.
	refs.random.Visible = false
end

return Hud
