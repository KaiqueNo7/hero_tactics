local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local PixelIcons = require(ReplicatedStorage.Modules.PixelIcons)

local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local LEATHER = Color3.fromRGB(74, 48, 30)
local LEATHER_DARK = Color3.fromRGB(42, 26, 16)
local PAGE = Color3.fromRGB(232, 219, 190)
local INK = Color3.fromRGB(62, 48, 33)
local INK_FADED = Color3.fromRGB(126, 104, 76)
local SIDE_ONE = Color3.fromRGB(38, 68, 128)
local SIDE_TWO = Color3.fromRGB(140, 44, 38)
local GOLD = Color3.fromRGB(226, 206, 170)

local gui = Instance.new("ScreenGui")
gui.Name = "MatchLogGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 12
gui.Enabled = false
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local button = Instance.new("TextButton")
button.Name = "OpenLog"
button.AnchorPoint = Vector2.new(0, 1)
button.Position = UDim2.new(0, 12, 1, -62)
button.Size = UDim2.new(0, 42, 0, 42)
button.BackgroundColor3 = Color3.fromRGB(26, 23, 30)
button.BackgroundTransparency = 0.25
button.Text = ""
button.BorderSizePixel = 0
button.AutoButtonColor = true
button.Parent = gui

local panel = Instance.new("Frame")
panel.Name = "Book"
panel.AnchorPoint = Vector2.new(0, 1)
panel.Position = UDim2.new(0, 62, 1, -12)
panel.Size = UDim2.new(0, 320, 0, 330)
panel.BackgroundColor3 = LEATHER
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui

local page = Instance.new("ScrollingFrame")
page.Name = "Page"
page.Position = UDim2.new(0, 20, 0, 34)
page.Size = UDim2.new(1, -30, 1, -44)
page.BackgroundColor3 = PAGE
page.BorderSizePixel = 0
page.CanvasSize = UDim2.new()
page.AutomaticCanvasSize = Enum.AutomaticSize.Y
page.ScrollBarThickness = 4
page.ScrollBarImageColor3 = LEATHER_DARK
page.ScrollingDirection = Enum.ScrollingDirection.Y
page.Parent = panel

local empty = Instance.new("TextLabel")
empty.Name = "Empty"
empty.Size = UDim2.new(1, 0, 0, 40)
empty.BackgroundTransparency = 1
empty.Text = "Nada aconteceu ainda."
empty.TextColor3 = INK_FADED
empty.TextSize = 12
empty.Font = GameConfig.UI_FONT_BODY
empty.LayoutOrder = 0
empty.Parent = page

do
	local slot = Instance.new("Frame")
	slot.AnchorPoint = Vector2.new(0.5, 0.5)
	slot.Position = UDim2.fromScale(0.5, 0.5)
	slot.Size = UDim2.new(0, 21, 0, 21)
	slot.BackgroundTransparency = 1
	slot.Parent = button
	PixelIcons.Build("book", slot, GOLD, 2)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(150, 122, 84)
	stroke.Thickness = 1.2
	stroke.Transparency = 0.35
	stroke.Parent = button
end

do
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = LEATHER_DARK
	stroke.Thickness = 3
	stroke.Parent = panel

	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.Size = UDim2.new(0, 10, 1, -10)
	spine.Position = UDim2.new(0, 5, 0, 5)
	spine.BackgroundColor3 = LEATHER_DARK
	spine.BorderSizePixel = 0
	spine.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -62, 0, 22)
	title.Position = UDim2.new(0, 22, 0, 8)
	title.BackgroundTransparency = 1
	title.Text = "DIÁRIO DA PARTIDA"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = GOLD
	title.TextSize = 13
	title.Font = Enum.Font.GothamBlack
	title.Parent = panel

	local pageCorner = Instance.new("UICorner")
	pageCorner.CornerRadius = UDim.new(0, 3)
	pageCorner.Parent = page

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 9)
	padding.PaddingRight = UDim.new(0, 9)
	padding.Parent = page

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 3)
	list.Parent = page
end

local function close()
	panel.Visible = false
end

do
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 24, 0, 24)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -8, 0, 7)
	closeButton.BackgroundTransparency = 1
	closeButton.Text = "X"
	closeButton.TextColor3 = GOLD
	closeButton.TextSize = 15
	closeButton.Font = Enum.Font.GothamBold
	closeButton.Parent = panel
	closeButton.Activated:Connect(close)
end

local function render(entries)
	for _, child in ipairs(page:GetChildren()) do
		if child.Name == "Entry" then
			child:Destroy()
		end
	end

	empty.Visible = #entries == 0

	for index, entry in ipairs(entries) do
		local row = Instance.new("TextLabel")
		row.Name = "Entry"
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.BackgroundColor3 = LEATHER
		row.BackgroundTransparency = entry.kind == "turn" and 0.82 or 1
		row.BorderSizePixel = 0
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextWrapped = true
		row.LayoutOrder = index

		if entry.kind == "turn" then
			row.Text = " " .. tostring(entry.text)
			row.TextColor3 = INK
			row.TextSize = 12
			row.Font = Enum.Font.GothamBlack
		else
			row.Text = "• " .. tostring(entry.text)
			row.TextSize = 12
			row.Font = GameConfig.UI_FONT_BODY

			if entry.kind == "death" then
				row.TextColor3 = INK
				row.Font = Enum.Font.GothamBold
			elseif entry.side == 1 then
				row.TextColor3 = SIDE_ONE
			elseif entry.side == 2 then
				row.TextColor3 = SIDE_TWO
			else
				row.TextColor3 = INK_FADED
			end
		end

		row.Parent = page
	end

	task.defer(function()
		page.CanvasPosition = Vector2.new(0, page.AbsoluteCanvasSize.Y)
	end)
end

button.Activated:Connect(function()
	if panel.Visible then
		close()
		return
	end

	panel.Visible = true
	GameAction:FireServer("matchLog")
end)

GameAction.OnClientEvent:Connect(function(kind, payload)
	if kind ~= "matchLog" then return end
	render(type(payload) == "table" and payload or {})
end)

MatchUpdate.OnClientEvent:Connect(function(state)
	local live = state ~= nil and state.phase == "battle"
	gui.Enabled = live

	if not live then
		close()
	elseif panel.Visible then
		GameAction:FireServer("matchLog")
	end
end)
