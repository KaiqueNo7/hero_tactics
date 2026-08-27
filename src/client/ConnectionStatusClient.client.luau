--[[
	ConnectionStatusClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local SafeArea = require(ReplicatedStorage.Modules.SafeArea)

local player = Players.LocalPlayer

local WARN_COLOR = Color3.fromRGB(226, 186, 60)
local BAD_COLOR = Color3.fromRGB(220, 70, 70)

local gui = Instance.new("ScreenGui")
gui.Name = "ConnectionStatusGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 20
gui.Parent = player:WaitForChild("PlayerGui")

local icon = Instance.new("TextButton")
icon.Name = "ConnectionIcon"
icon.Size = UDim2.new(0, 26, 0, 26)
icon.BackgroundColor3 = BAD_COLOR
icon.BorderSizePixel = 0
icon.AutoButtonColor = false
icon.Text = ""
icon.Visible = false
icon.Parent = gui

local iconCorner = Instance.new("UICorner")
iconCorner.CornerRadius = UDim.new(1, 0)
iconCorner.Parent = icon

local iconStroke = Instance.new("UIStroke")
iconStroke.Color = Color3.new(0, 0, 0)
iconStroke.Transparency = 0.5
iconStroke.Thickness = 1.2
iconStroke.Parent = icon

local tooltip = Instance.new("TextLabel")
tooltip.Name = "Tooltip"
tooltip.AnchorPoint = Vector2.new(0, 0)
tooltip.Position = UDim2.new(0, 0, 1, 6)
tooltip.Size = UDim2.new(0, 190, 0, 22)
tooltip.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
tooltip.BackgroundTransparency = 0.15
tooltip.BorderSizePixel = 0
tooltip.TextColor3 = Color3.new(1, 1, 1)
tooltip.TextSize = 12
tooltip.Font = GameConfig.UI_FONT_BODY
tooltip.Visible = false
tooltip.Parent = icon

local tooltipCorner = Instance.new("UICorner")
tooltipCorner.CornerRadius = UDim.new(0, 4)
tooltipCorner.Parent = tooltip

local function reposition()
	icon.Position = UDim2.new(0, SafeArea.Left(), 0, SafeArea.Top())
end
reposition()
SafeArea.OnChange(reposition)

local pulseTween = nil
local function setPulsing(on)
	if on and not pulseTween then
		pulseTween = TweenService:Create(icon,
			TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.55 })
		pulseTween:Play()
	elseif not on and pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
		icon.BackgroundTransparency = 0
	end
end

local function refresh()
	local ok, pingSeconds = pcall(function() return player:GetNetworkPing() end)
	local pingMs = (ok and pingSeconds) and math.floor(pingSeconds * 1000) or nil

	if not pingMs or pingMs >= GameConfig.PING_BAD_MS then
		icon.Visible = true
		icon.BackgroundColor3 = BAD_COLOR
		setPulsing(true)
		tooltip.Text = pingMs
			and ("Ping alto: %dms — reconectando"):format(pingMs)
			or "Sem conexão — reconectando"
	elseif pingMs >= GameConfig.PING_WARN_MS then
		icon.Visible = true
		icon.BackgroundColor3 = WARN_COLOR
		setPulsing(false)
		tooltip.Text = ("Conexão instável: %dms"):format(pingMs)
	else
		icon.Visible = false
		tooltip.Visible = false
		setPulsing(false)
	end
end

icon.Activated:Connect(function()
	tooltip.Visible = not tooltip.Visible
end)

task.spawn(function()
	while true do
		refresh()
		task.wait(1)
	end
end)
