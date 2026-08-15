--[[
	LeaderboardBoard.server.lua
	Script — ServerScriptService

	Placar físico no lobby com o ranking de vitórias. Flutua acima do espaço
	entre os dois pads (bot e PvP) — posição calculada a partir deles, não
	fixa, então continua certo se algum dia os pads forem movidos.

	Atualiza na hora após cada vitória (LeaderboardService.Updated) e também
	num timer, pra pegar vitórias registradas em OUTROS servidores (o
	OrderedDataStore é eventualmente consistente entre servidores).
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local LeaderboardService = require(ServerScriptService.Modules.LeaderboardService)

local REFRESH_INTERVAL = 60
local TOP_COUNT = 8

local BOARD_SIZE = Vector3.new(11, 7.5, 0.6)
local BOARD_HEIGHT = 10 -- studs acima do chão dos pads

local ROW_COLORS = {
	Color3.fromRGB(255, 214, 84),  -- ouro
	Color3.fromRGB(206, 212, 220), -- prata
	Color3.fromRGB(198, 140, 90),  -- bronze
}

local botPad = Workspace:WaitForChild("StartBotMatch")
local pvpPad = Workspace:WaitForChild("StartPvpMatch")

-- ===== MONTAGEM =====
-- CFrame.new(pos, lookAt) trava quando o vetor de mira é puramente vertical
-- (não dá pra calcular um "up" estável) — foi o que deixou o placar deitado
-- ao mirar num ponto logo abaixo dele. A mira agora fica na MESMA altura do
-- placar, olhando perpendicular à linha entre os dois pads, então o vetor é
-- sempre horizontal e a peça fica em pé.
local midpoint = (botPad.Position + pvpPad.Position) / 2
local boardPos = midpoint + Vector3.new(0, BOARD_HEIGHT, 0)

local padDelta = pvpPad.Position - botPad.Position
local sideways = Vector3.new(-padDelta.Z, 0, padDelta.X)
if sideways.Magnitude < 0.01 then sideways = Vector3.new(0, 0, 1) end

local lookAt = boardPos + sideways.Unit

local board = Instance.new("Part")
board.Name = "LeaderboardBoard"
board.Size = BOARD_SIZE
board.Anchored = true
board.CanCollide = false
board.CanQuery = false
board.Material = Enum.Material.Wood
board.Color = Color3.fromRGB(64, 42, 26)
board.CFrame = CFrame.new(boardPos, lookAt)
board.Parent = Workspace

local frame = Instance.new("SurfaceGui")
frame.Name = "Sign"
frame.Face = Enum.NormalId.Front
frame.LightInfluence = 0
frame.PixelsPerStud = 40
frame.Parent = board

local background = Instance.new("Frame")
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
background.BorderSizePixel = 0
background.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 12)
padding.PaddingBottom = UDim.new(0, 12)
padding.PaddingLeft = UDim.new(0, 16)
padding.PaddingRight = UDim.new(0, 16)
padding.Parent = background

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 46)
title.BackgroundTransparency = 1
title.Text = "🏆 RANKING DE VITÓRIAS"
title.TextColor3 = Color3.fromRGB(255, 214, 120)
title.TextStrokeTransparency = 0.5
title.TextScaled = true
title.Font = Enum.Font.GothamBlack
title.Parent = background

local list = Instance.new("Frame")
list.Size = UDim2.new(1, 0, 1, -50)
list.Position = UDim2.new(0, 0, 0, 50)
list.BackgroundTransparency = 1
list.Parent = background

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 3)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = list

local emptyLabel = Instance.new("TextLabel")
emptyLabel.Name = "Empty"
emptyLabel.Size = UDim2.new(1, 0, 0, 32)
emptyLabel.BackgroundTransparency = 1
emptyLabel.Text = "Ninguém venceu ainda — seja o primeiro!"
emptyLabel.TextColor3 = Color3.fromRGB(170, 178, 195)
emptyLabel.TextScaled = true
emptyLabel.Font = Enum.Font.GothamBold
emptyLabel.Parent = list

-- ===== ATUALIZAÇÃO =====
local function Refresh()
	local top = LeaderboardService.GetTop(TOP_COUNT)

	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") and child ~= emptyLabel then
			child:Destroy()
		end
	end

	emptyLabel.Visible = #top == 0

	for index, entry in ipairs(top) do
		local row = Instance.new("TextLabel")
		row.Name = "Row" .. index
		row.Size = UDim2.new(1, 0, 0, 32)
		row.LayoutOrder = index
		row.BackgroundTransparency = 1
		row.Text = ("%d.  %s   —   %d"):format(index, entry.name, entry.wins)
		row.TextColor3 = ROW_COLORS[index] or Color3.new(1, 1, 1)
		row.TextStrokeTransparency = 0.6
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextScaled = true
		row.Font = Enum.Font.GothamBold
		row.Parent = list
	end
end

Refresh()
LeaderboardService.Updated:Connect(Refresh)

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		Refresh()
	end
end)
