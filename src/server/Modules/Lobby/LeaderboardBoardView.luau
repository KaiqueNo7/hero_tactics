--[[
	LeaderboardBoardView.lua
	ModuleScript — ServerScriptService/Modules/LeaderboardBoardView

	Monta e preenche o placar físico do ranking no lobby.

	A construção mora aqui (e não no Script) pra poder ser chamada no Studio em
	modo Edit — assim dá pra ver e personalizar o template sem dar play:

		require(game.ServerScriptService.Modules.Lobby.LeaderboardBoardView).EnsureBoard()

	O que já existir no Workspace é reaproveitado: só as linhas do ranking são
	regeradas em runtime, então mover/repintar o quadro à mão sobrevive.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HeroData = require(ReplicatedStorage.Modules.HeroData)

local LeaderboardBoardView = {}

local BOARD_NAME = "LeaderboardBoard"
local BOARD_SIZE = Vector3.new(11, 7.5, 0.6)
local BOARD_HEIGHT = 10

local ROW_COUNT = 5
local ROW_HEIGHT = 42
local ROW_GAP = 3
local HERO_SLOTS = 3

local ROW_COLORS = {
	Color3.fromRGB(255, 214, 84),  -- ouro
	Color3.fromRGB(206, 212, 220), -- prata
	Color3.fromRGB(198, 140, 90),  -- bronze
}

local function BoardCFrame()
	local botPad = Workspace:FindFirstChild("StartBotMatch", true)
	local pvpPad = Workspace:FindFirstChild("StartPvpMatch", true)
	if not (botPad and pvpPad) then return nil end

	local midpoint = (botPad.Position + pvpPad.Position) / 2
	local boardPos = midpoint + Vector3.new(0, BOARD_HEIGHT, 0)

	local padDelta = pvpPad.Position - botPad.Position
	local sideways = Vector3.new(-padDelta.Z, 0, padDelta.X)
	if sideways.Magnitude < 0.01 then sideways = Vector3.new(0, 0, 1) end

	return CFrame.new(boardPos, boardPos + sideways.Unit)
end

function LeaderboardBoardView.EnsureBoard()
	local existing = Workspace:FindFirstChild(BOARD_NAME, true)
	if existing and existing:FindFirstChild("Sign") then
		return existing
	end
	if existing then existing:Destroy() end

	local cframe = BoardCFrame()
	if not cframe then
		warn("LeaderboardBoardView: pads do lobby não encontrados, placar não montado.")
		return nil
	end

	local board = Instance.new("Part")
	board.Name = BOARD_NAME
	board.Size = BOARD_SIZE
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false
	board.Material = Enum.Material.Wood
	board.Color = Color3.fromRGB(64, 42, 26)
	board.CFrame = cframe
	board.Parent = Workspace

	local sign = Instance.new("SurfaceGui")
	sign.Name = "Sign"
	sign.Face = Enum.NormalId.Front
	sign.LightInfluence = 0
	sign.PixelsPerStud = 40
	sign.Parent = board

	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
	background.BorderSizePixel = 0
	background.Parent = sign

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 16)
	padding.PaddingRight = UDim.new(0, 16)
	padding.Parent = background

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 46)
	title.BackgroundTransparency = 1
	title.Text = "RANKING — VITÓRIAS PVP"
	title.TextColor3 = Color3.fromRGB(255, 214, 120)
	title.TextStrokeTransparency = 0.5
	title.TextScaled = true
	title.Font = Enum.Font.GothamBlack
	title.Parent = background

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Size = UDim2.new(1, 0, 1, -50)
	list.Position = UDim2.new(0, 0, 0, 50)
	list.BackgroundTransparency = 1
	list.Parent = background

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local empty = Instance.new("TextLabel")
	empty.Name = "Empty"
	empty.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	empty.BackgroundTransparency = 1
	empty.Text = "Ninguém venceu ainda — seja o primeiro!"
	empty.TextColor3 = Color3.fromRGB(170, 178, 195)
	empty.TextScaled = true
	empty.Font = Enum.Font.GothamBold
	empty.Parent = list

	for index = 1, 3 do
		local preview = Instance.new("TextLabel")
		preview.Name = "PreviewRow" .. index
		preview.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		preview.LayoutOrder = index
		preview.BackgroundTransparency = 1
		preview.Text = ("%d.  —"):format(index)
		preview.TextColor3 = ROW_COLORS[index]
		preview.TextStrokeTransparency = 0.6
		preview.TextXAlignment = Enum.TextXAlignment.Left
		preview.TextScaled = true
		preview.Font = Enum.Font.GothamBold
		preview.Parent = list
	end

	return board
end

local function BuildLabel(name, text, color, alignment, size, maxTextSize)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.6
	label.TextXAlignment = alignment
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Size = size

	if maxTextSize then
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = math.floor(maxTextSize)
		limit.Parent = label
	end

	return label
end

local function BuildPortrait(dataId, slot, side, gap)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local holder = Instance.new("Frame")
	holder.Name = "Hero" .. slot
	holder.Size = UDim2.fromOffset(side, side)
	holder.Position = UDim2.new(1, -(side + gap) * (HERO_SLOTS - slot) - side, 0.5, -side / 2)
	holder.BackgroundColor3 = data.color
	holder.BackgroundTransparency = 0.55
	holder.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, math.max(3, side * 0.12))
	corner.Parent = holder

	local sprite = HeroData.GetSpriteId(data)
	if sprite then
		local image = Instance.new("ImageLabel")
		image.Name = "Art"
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = sprite
		image.ImageRectSize = HeroData.GetFrameSize(data)
		image.ImageRectOffset = HeroData.GetFrameOffset(data)
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = holder
	end

	return holder
end

local function BuildRow(index, entry, rowHeight)
	local row = Instance.new("Frame")
	row.Name = "Row" .. index
	row.Size = UDim2.new(1, 0, 0, rowHeight)
	row.LayoutOrder = index
	row.BackgroundTransparency = 1

	local tint = ROW_COLORS[index] or Color3.new(1, 1, 1)
	local face = math.floor(rowHeight * 0.86)
	local portrait = math.floor(rowHeight * 0.72)
	local gap = math.max(3, math.floor(rowHeight * 0.1))
	local rank = math.floor(rowHeight * 0.7)
	local wins = math.floor(rowHeight * 0.9)
	local heroesWidth = (portrait + gap) * HERO_SLOTS

	BuildLabel("Rank", index .. ".", tint, Enum.TextXAlignment.Left,
		UDim2.fromOffset(rank, rowHeight), rowHeight * 0.72).Parent = row

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Face"
	avatar.Size = UDim2.fromOffset(face, face)
	avatar.Position = UDim2.new(0, rank, 0.5, -face / 2)
	avatar.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
	avatar.BorderSizePixel = 0
	avatar.Image = entry.avatar or ""
	avatar.Parent = row

	local avatarCorner = Instance.new("UICorner")
	avatarCorner.CornerRadius = UDim.new(1, 0)
	avatarCorner.Parent = avatar

	local avatarStroke = Instance.new("UIStroke")
	avatarStroke.Color = tint
	avatarStroke.Thickness = math.max(1, rowHeight * 0.04)
	avatarStroke.Parent = avatar

	local nameStart = rank + face + gap
	local nameLabel = BuildLabel("Name", entry.name, tint, Enum.TextXAlignment.Left,
		UDim2.new(1, -(nameStart + wins + heroesWidth + gap), 0, rowHeight), rowHeight * 0.42)
	nameLabel.Position = UDim2.fromOffset(nameStart, 0)
	nameLabel.TextScaled = false
	nameLabel.TextSize = math.floor(rowHeight * 0.3)
	nameLabel.TextWrapped = false
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = row

	local winsLabel = BuildLabel("Wins", tostring(entry.wins), Color3.fromRGB(235, 240, 250),
		Enum.TextXAlignment.Right, UDim2.fromOffset(wins, rowHeight), rowHeight * 0.62)
	winsLabel.Position = UDim2.new(1, -(heroesWidth + wins + gap), 0, 0)
	winsLabel.Parent = row

	for slot, used in ipairs(entry.heroes or {}) do
		if slot > HERO_SLOTS then break end
		local built = BuildPortrait(used.dataId, slot, portrait, gap)
		if built then built.Parent = row end
	end

	return row
end

local function RowHeightFor(board, sign, list)
	local canvas = board.Size.Y * (sign.PixelsPerStud > 0 and sign.PixelsPerStud or 40)
	local available = canvas * math.max(list.Size.Y.Scale, 0.1) + list.Size.Y.Offset

	return math.clamp(math.floor(available / ROW_COUNT) - ROW_GAP, 26, 120)
end

function LeaderboardBoardView.Render(entries)
	local board = Workspace:FindFirstChild(BOARD_NAME, true)
	local sign = board and board:FindFirstChild("Sign")
	local background = sign and sign:FindFirstChild("Background")
	local list = background and background:FindFirstChild("List")
	if not list then return end

	local empty = list:FindFirstChild("Empty")
	local rowHeight = RowHeightFor(board, sign, list)

	for _, child in ipairs(list:GetChildren()) do
		if child ~= empty and (child:IsA("TextLabel") or child:IsA("Frame")) then
			child:Destroy()
		end
	end

	if empty then
		empty.Visible = #entries == 0
		empty.Size = UDim2.new(1, 0, 0, rowHeight)
	end

	for index, entry in ipairs(entries) do
		if index > ROW_COUNT then break end
		BuildRow(index, entry, rowHeight).Parent = list
	end
end

LeaderboardBoardView.ROW_COUNT = ROW_COUNT

return LeaderboardBoardView
