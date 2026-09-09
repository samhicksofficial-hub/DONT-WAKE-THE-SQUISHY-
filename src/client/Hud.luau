--!strict
-- Hud — drives the Essential UI Pack's HUD strip. Builds nothing: every node
-- comes from UiRefs (see the UI Contract in DESIGN.md).
--
--   Labels.Money   the Money attribute, count-up tweened, with a pop on gain
--   Labels.Offline repurposed as the live income rate ("$1.2k/s")
--   Drop           visible only while carrying; fires Remotes.Drop
--   Right.Random   the starter pack's shield button — ShopUi owns it

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UiRefs = require(script.Parent.UiRefs)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local COUNT_DURATION = 0.3 -- seconds for the money count-up lerp
local POP_DURATION = 0.12
local POP_SCALE = 1.12

local Hud = {}

local function readMoney(player: Player): number
	local raw = player:GetAttribute("Money")
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

	-- The pack parks the money in the bottom-left corner. Move it to the top
	-- centre, big — where the genre puts it, and where a phone player can
	-- actually read it without it fighting the left-hand button column.
	labelsFrame.AnchorPoint = Vector2.new(0.5, 0)
	labelsFrame.Position = UDim2.fromScale(0.5, 0.018)
	labelsFrame.Size = UDim2.fromScale(0.3, 0.15)
	labelsFrame.ZIndex = 20
	local layout = labelsFrame:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Top
		layout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	-- Balance to the SCREEN centre, not the left edge of the label.
	--
	-- Both labels are full-width rows, so the list layout was already centring
	-- their boxes — but the pack leaves the text itself Left-aligned inside
	-- those boxes, which pins both strings to the same left edge and lets the
	-- shorter one hang off-centre. Centring the text is what actually makes
	-- "$48.74k" and "$5/s" share a midline.
	moneyLabel.TextXAlignment = Enum.TextXAlignment.Center
	incomeLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- Total on top, rate underneath. The heights sum to exactly 1: the pack
	-- shipped 1.0 + 0.75, which overflowed the frame by three quarters of a
	-- line and let the stack drift as the rate appeared and disappeared.
	-- Money takes the larger share because it is the number being read.
	moneyLabel.LayoutOrder = 1
	moneyLabel.Size = UDim2.fromScale(1, 0.62)
	incomeLabel.LayoutOrder = 2
	incomeLabel.Size = UDim2.fromScale(1, 0.38)
	-- Keep it legible on very wide screens without letting it swell on phones.
	local ratio = labelsFrame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if ratio == nil then
		local created = Instance.new("UIAspectRatioConstraint")
		created.AspectRatio = 3.4
		created.DominantAxis = Enum.DominantAxis.Height
		created.Parent = labelsFrame
	end
	moneyLabel.ZIndex = 21
	incomeLabel.ZIndex = 21
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

	-- The server publishes the effective rate as the `IncomeRate` attribute
	-- (PlotService, every accrual tick): raw slot income scaled by the same
	-- multipliers a collect pays with. This label used to re-derive the number
	-- by walking the plot tree, and went stale the moment a squishy levelled
	-- up — an attribute changing under a model the walk never re-read.
	local function refreshIncome()
		local total = tonumber(player:GetAttribute("IncomeRate")) or 0
		if total <= 0 then
			incomeLabel.Visible = false
			return
		end
		incomeLabel.Text = Util.formatMoney(total) .. "/s"
		incomeLabel.Visible = true
	end

	incomeLabel.Visible = false
	player:GetAttributeChangedSignal("IncomeRate"):Connect(refreshIncome)
	refreshIncome()

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

	-- --------------------------------------------------------- shield button --

	-- Not hidden here any more: the pack's spare Right.Random button is the
	-- starter pack's storefront, and ShopUi owns its text, price and
	-- visibility (it goes for good once the pack is owned).
end

return Hud
