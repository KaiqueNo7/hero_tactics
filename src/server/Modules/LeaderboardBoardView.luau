--[[
	LeaderboardBoardView.lua
	ModuleScript — ServerScriptService/Modules/LeaderboardBoardView

	Monta e preenche o placar físico do ranking no lobby.

	A construção mora aqui (e não no Script) pra poder ser chamada no Studio em
	modo Edit — assim dá pra ver e personalizar o template sem dar play:

		require(game.ServerScriptService.Modules.LeaderboardBoardView).EnsureBoard()

	O que já existir no Workspace é reaproveitado: só as linhas do ranking são
	regeradas em runtime, então mover/repintar o quadro à mão sobrevive.
]]

local Workspace = game:GetService("Workspace")

local LeaderboardBoardView = {}

local BOARD_NAME = "LeaderboardBoard"
local BOARD_SIZE = Vector3.new(11, 7.5, 0.6)
local BOARD_HEIGHT = 10 -- studs acima do chão dos pads

local ROW_COUNT = 8
local ROW_HEIGHT = 32

local ROW_COLORS = {
	Color3.fromRGB(255, 214, 84),  -- ouro
	Color3.fromRGB(206, 212, 220), -- prata
	Color3.fromRGB(198, 140, 90),  -- bronze
}

-- Posição derivada dos pads: fica entre os dois, virado pra quem chega.
-- CFrame.new(pos, lookAt) precisa de um alvo em altura diferente de zero no
-- plano horizontal, senão o vetor fica vertical e a peça deita.
local function BoardCFrame()
	-- busca recursiva: os pads podem estar dentro de qualquer pasta do cenário
	-- (o lobby foi agrupado em Workspace.Base), e o caminho raso achava nada
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
	title.Text = "RANKING DE VITÓRIAS"
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

	-- linhas de exemplo pra dar pra enxergar o template no Edit; somem no
	-- primeiro Render, que roda assim que o servidor sobe
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

-- entries: { { name = string, wins = number }, ... }
function LeaderboardBoardView.Render(entries)
	local board = Workspace:FindFirstChild(BOARD_NAME, true)
	local sign = board and board:FindFirstChild("Sign")
	local background = sign and sign:FindFirstChild("Background")
	local list = background and background:FindFirstChild("List")
	if not list then return end

	local empty = list:FindFirstChild("Empty")

	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("TextLabel") and child ~= empty then
			child:Destroy()
		end
	end

	if empty then empty.Visible = #entries == 0 end

	for index, entry in ipairs(entries) do
		if index > ROW_COUNT then break end

		local row = Instance.new("TextLabel")
		row.Name = "Row" .. index
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
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

LeaderboardBoardView.ROW_COUNT = ROW_COUNT

return LeaderboardBoardView
