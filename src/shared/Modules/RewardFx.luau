local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Monetization = require(script.Parent.Monetization)
local Progression = require(script.Parent.Progression)

local XP_COLOR = Color3.fromRGB(120, 180, 255)
local GOLD = Color3.fromRGB(255, 214, 120)
local LEVEL_COLOR = Color3.fromRGB(255, 226, 150)

local HOLD = 0.5
local TRAVEL = 0.42
local GAP = 0.18

local RewardFx = {}

local queue = {}
local pumping = false

local xpTarget, coinTarget = nil, nil
local realXp, realCoins = 0, 0
local animatingXp, animatingCoins = false, false

local root = nil

local function GetRoot()
	if root and root.Parent then return root end

	local player = Players.LocalPlayer
	if not player then return nil end

	local gui = Instance.new("ScreenGui")
	gui.Name = "RewardFxGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 65
	gui.Parent = player:WaitForChild("PlayerGui")

	root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	return root
end

local function OnScreen(gui)
	if not (gui and gui.Parent) then return false end
	local screen = gui:FindFirstAncestorWhichIsA("ScreenGui")
	return screen ~= nil and screen.Enabled and gui.Visible and gui.AbsoluteSize.X > 0
end

local function CenterOf(gui, parent)
	return gui.AbsolutePosition + gui.AbsoluteSize / 2 - parent.AbsolutePosition
end

local function ScaleOf(gui)
	local scale = gui:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = gui
	end
	return scale
end

local function Punch(gui, peak)
	local scale = ScaleOf(gui)
	local up = TweenService:Create(scale, TweenInfo.new(0.09), { Scale = peak })
	up.Completed:Once(function()
		TweenService:Create(scale,
			TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()
	end)
	up:Play()
end

local function Glow(gui, color)
	local stroke = gui:FindFirstChild("RewardFxGlow")
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.Name = "RewardFxGlow"
		stroke.Thickness = 2
		stroke.Parent = gui
	end
	stroke.Color = color
	stroke.Transparency = 0.1
	TweenService:Create(stroke, TweenInfo.new(0.5), { Transparency = 1 }):Play()
end

local function Spin(gui)
	TweenService:Create(gui,
		TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Rotation = 24 }):Play()
	task.delay(0.24, function()
		if gui.Parent then
			TweenService:Create(gui, TweenInfo.new(0.22), { Rotation = 0 }):Play()
		end
	end)
end

local function Burst(parent, center, color)
	for i = 1, 6 do
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(center.X, center.Y)
		dot.Size = UDim2.fromOffset(6, 6)
		dot.BackgroundColor3 = color
		dot.BorderSizePixel = 0
		dot.ZIndex = 6

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		dot.Parent = parent

		local angle = (i / 6) * math.pi * 2
		local distance = 30 + math.random() * 18

		TweenService:Create(dot,
			TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.fromOffset(
					center.X + math.cos(angle) * distance,
					center.Y + math.sin(angle) * distance),
				Size = UDim2.fromOffset(2, 2),
				BackgroundTransparency = 1,
			}):Play()

		Debris:AddItem(dot, 0.6)
	end
end

local function Fly(text, color, withCoin, badge)
	local parent = GetRoot()
	if not parent then return end

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.68)
	card.AutomaticSize = Enum.AutomaticSize.XY
	card.Size = UDim2.fromOffset(0, 0)
	card.BackgroundTransparency = 1
	card.ZIndex = 5
	card.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = card

	if withCoin then
		local dot = Instance.new("Frame")
		dot.LayoutOrder = 2
		dot.Size = UDim2.fromOffset(20, 20)
		dot.BackgroundColor3 = GOLD
		dot.BorderSizePixel = 0
		dot.ZIndex = 5
		dot.Parent = card

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot
	end

	local label = Instance.new("TextLabel")
	label.LayoutOrder = 1
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 34)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextSize = 30
	label.Font = Enum.Font.GothamBlack
	label.TextStrokeColor3 = Color3.fromRGB(6, 8, 12)
	label.TextStrokeTransparency = 0.35
	label.TextTransparency = 1
	label.ZIndex = 5
	label.Parent = card

	local scale = Instance.new("UIScale")
	scale.Scale = 0.55
	scale.Parent = card

	TweenService:Create(label, TweenInfo.new(0.16), { TextTransparency = 0 }):Play()

	local pop = TweenService:Create(scale,
		TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1.12 })
	pop:Play()
	pop.Completed:Wait()
	TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()

	task.wait(HOLD)

	if not (card.Parent and OnScreen(badge)) then
		card:Destroy()
		return
	end

	local destination = CenterOf(badge, parent)
	local info = TweenInfo.new(TRAVEL, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	TweenService:Create(card, info, {
		Position = UDim2.fromOffset(destination.X, destination.Y),
	}):Play()

	local shrink = TweenService:Create(scale, info, { Scale = 0.3 })
	shrink:Play()
	shrink.Completed:Wait()

	TweenService:Create(label, TweenInfo.new(0.1), { TextTransparency = 1 }):Play()
	Debris:AddItem(card, 0.15)
end

local function CountTo(from, to, render)
	local span = math.abs(to - from)
	local seconds = math.clamp(0.6 + span / 350, 0.6, 1.2)
	local start = os.clock()

	while true do
		local alpha = math.min((os.clock() - start) / seconds, 1)
		local eased = 1 - (1 - alpha) ^ 3
		render(math.floor(from + (to - from) * eased + 0.5))
		if alpha >= 1 then break end
		RunService.Heartbeat:Wait()
	end
end

local function LevelUpFeedback(badge)
	local parent = GetRoot()
	if not parent then return end

	local center = CenterOf(badge, parent)
	Burst(parent, center, LEVEL_COLOR)

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromOffset(center.X, center.Y + 46)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 22)
	label.BackgroundTransparency = 1
	label.Text = "SUBIU DE NÍVEL!"
	label.TextColor3 = LEVEL_COLOR
	label.TextSize = 20
	label.Font = Enum.Font.GothamBlack
	label.TextStrokeColor3 = Color3.fromRGB(6, 8, 12)
	label.TextStrokeTransparency = 0.3
	label.ZIndex = 6
	label.Parent = parent

	local scale = Instance.new("UIScale")
	scale.Scale = 0.5
	scale.Parent = label

	TweenService:Create(scale,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	task.delay(0.9, function()
		if not label.Parent then return end
		TweenService:Create(label, TweenInfo.new(0.35), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
			Position = UDim2.fromOffset(center.X, center.Y + 30),
		}):Play()
	end)

	Debris:AddItem(label, 1.4)
	Glow(badge, LEVEL_COLOR)
	Punch(badge, 1.16)
end

local function Pump()
	if pumping then return end
	pumping = true

	task.spawn(function()
		while #queue > 0 do
			local job = table.remove(queue, 1)
			local ok, err = pcall(job)
			if not ok then
				warn(("RewardFx: animação falhou — %s"):format(tostring(err)))
			end
			task.wait(GAP)
		end

		pumping = false
		animatingXp, animatingCoins = false, false

		if xpTarget then xpTarget.render(realXp) end
		if coinTarget then coinTarget.render(realCoins) end
	end)
end

function RewardFx.BindXp(badge, render)
	xpTarget = { badge = badge, render = render }
	render(realXp)
end

function RewardFx.BindCoins(badge, icon, render)
	coinTarget = { badge = badge, icon = icon, render = render }
	render(realCoins)
end

function RewardFx.SetXp(total)
	realXp = math.max(0, math.floor(tonumber(total) or 0))
	if xpTarget and not animatingXp then xpTarget.render(realXp) end
end

function RewardFx.SetCoins(total)
	realCoins = math.max(0, math.floor(tonumber(total) or 0))
	if coinTarget and not animatingCoins then coinTarget.render(realCoins) end
end

function RewardFx.QueueXp(from, to)
	from = math.max(0, math.floor(tonumber(from) or 0))
	to = math.max(from, math.floor(tonumber(to) or 0))
	if to <= from then return end

	table.insert(queue, function()
		local target = xpTarget
		if not (target and OnScreen(target.badge)) then return end

		animatingXp = true
		target.render(from)

		Fly(("+%d XP"):format(to - from), XP_COLOR, false, target.badge)

		if OnScreen(target.badge) then
			Punch(target.badge, 1.12)
			Glow(target.badge, XP_COLOR)
		end

		local level = Progression.FromTotalXp(from).level
		local leveled = false

		CountTo(from, to, function(value)
			target.render(value)

			local reached = Progression.FromTotalXp(value).level
			if reached > level then
				level = reached
				leveled = true
				LevelUpFeedback(target.badge)
			end
		end)

		animatingXp = false
		target.render(realXp)

		if leveled then task.wait(0.45) end
	end)

	Pump()
end

function RewardFx.QueueCoins(from, to)
	from = math.max(0, math.floor(tonumber(from) or 0))
	to = math.max(from, math.floor(tonumber(to) or 0))
	if to <= from then return end

	table.insert(queue, function()
		local target = coinTarget
		if not (target and OnScreen(target.badge)) then return end

		animatingCoins = true
		target.render(from)

		Fly(("+%s"):format(Monetization.FormatCoins(to - from)), GOLD, true, target.badge)

		if OnScreen(target.badge) then
			Punch(target.badge, 1.12)
			Glow(target.badge, GOLD)
			if target.icon then Spin(target.icon) end
		end

		CountTo(from, to, target.render)

		animatingCoins = false
		target.render(realCoins)
	end)

	Pump()
end

return RewardFx
