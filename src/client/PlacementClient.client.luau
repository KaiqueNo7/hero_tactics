--[[
	PlacementClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Draft alternado com cartas ilustradas: clique abre o detalhe do herói,
	arrastar solta ele numa casa de largada.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local function PlayUiSound(name)
	local template = ReplicatedStorage.Sounds:FindFirstChild(name)
	if not template then return end
	local sound = template:Clone()
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local SafeArea = require(ReplicatedStorage.Modules.SafeArea)
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local PlaceHero = ReplicatedStorage.Remotes:WaitForChild("PlaceHero")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local HIGHLIGHT_COLOR = Color3.fromRGB(120, 220, 130)
local HOVER_COLOR = Color3.fromRGB(190, 255, 190)
local DRAG_THRESHOLD = 8

local activeTweens = {}

-- cor base caso o attribute BaseColor não exista no hexágono (defensivo:
-- assim uma casa nunca fica travada numa cor errada por falta de attribute)
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

local function fallbackColor(tile)
	local col = string.byte(tile.Name, 1) - string.byte("A", 1)
	return (col % 2 == 0) and COLOR_A or COLOR_B
end

local function restoreTile(part)
	local tween = activeTweens[part]
	if tween then
		tween:Cancel()
		activeTweens[part] = nil
	end
	part.Color = part:GetAttribute("BaseColor") or fallbackColor(part)
end

local currentState = nil
local paintedTiles = {}
local heroCards = {}
local drag = nil
local hoveredHex = nil
local usedHeroIdSet = {} -- montado a partir do array que o servidor envia
local lockedHeroIdSet = {} -- heróis que este jogador ainda não liberou por nível

-- ===== UI BASE =====
local gui = Instance.new("ScreenGui")
gui.Name = "PlacementGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

-- Esta ScreenGui ignora o inset (a zona de largada precisa da tela toda), então
-- o que fica no topo desce na mão pra não cair embaixo dos botões do Roblox.
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 30)
title.Position = UDim2.new(0, 20, 0, SafeArea.Top())
title.BackgroundTransparency = 1
title.TextColor3 = Color3.new(1, 1, 1)
title.TextStrokeTransparency = 0.35
title.TextScaled = true
title.Font = Enum.Font.GothamBold
title.Parent = gui

-- ===== "ESPERE SUA VEZ" (mesmo flash da batalha) =====
local waitFlashLabel = Instance.new("TextLabel")
waitFlashLabel.AnchorPoint = Vector2.new(0.5, 0.5)
waitFlashLabel.Size = UDim2.new(0, 400, 0, 70)
waitFlashLabel.Position = UDim2.new(0.5, 0, 0.4, 0)
waitFlashLabel.BackgroundTransparency = 1
waitFlashLabel.TextColor3 = Color3.fromRGB(255, 150, 150)
waitFlashLabel.TextStrokeTransparency = 1
waitFlashLabel.TextScaled = true
waitFlashLabel.Font = Enum.Font.GothamBlack
waitFlashLabel.Text = "Espere sua vez"
waitFlashLabel.TextTransparency = 1
waitFlashLabel.ZIndex = 40
waitFlashLabel.Parent = gui

local waitFlashToken = 0

local function warnNotYourTurn()
	waitFlashToken += 1
	local token = waitFlashToken

	waitFlashLabel.TextTransparency = 1
	waitFlashLabel.TextStrokeTransparency = 1
	TweenService:Create(waitFlashLabel, TweenInfo.new(0.2), {
		TextTransparency = 0, TextStrokeTransparency = 0.3,
	}):Play()

	task.delay(1.1, function()
		if waitFlashToken ~= token then return end
		TweenService:Create(waitFlashLabel, TweenInfo.new(0.4), {
			TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()
	end)
end

-- ===== COLUNA DE HERÓIS (canto direito) =====
-- Era uma barra deitada no rodapé, ocupando a largura inteira da tela. O
-- tabuleiro é largo e baixo: a barra comia justamente a faixa onde ficam as
-- casas de largada, e no celular deitado sobrava pouquíssima altura de jogo.
-- Em pé, na lateral, ela usa o espaço vazio ao lado do tabuleiro — a tela do
-- jogo fica livre e ainda cabem mais cartas de uma vez.
--
-- À direita, e não à esquerda: é desse lado que o jogador entra no tabuleiro
-- (a câmera ancora na largada dele), e do lado esquerdo ficam o bonequinho do
-- jogador e o do adversário parados ao lado da arena.
local CARD_GAP = 4
local ARROW_HEIGHT = 24
local COLUMN_WIDTH = 92

local bar = Instance.new("Frame")
bar.Name = "HeroColumn"
bar.AnchorPoint = Vector2.new(1, 0.5)
bar.Position = UDim2.new(1, -12, 0.5, 0)
bar.Size = UDim2.new(0, COLUMN_WIDTH, 0.84, 0)
bar.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
bar.BackgroundTransparency = 0.15
bar.BorderSizePixel = 0
bar.Parent = gui

-- Nunca mais alta que a tela útil (descontada a faixa do Roblox no topo) nem
-- tão baixa a ponto de não caber carta nenhuma
local barSize = Instance.new("UISizeConstraint")
barSize.MinSize = Vector2.new(COLUMN_WIDTH, 180)
barSize.Parent = bar

-- Tudo que depende da faixa do Roblox mora aqui e é refeito quando ela muda —
-- inclusive na hora em que ela APARECE, depois da tela de carregamento sair.
--
-- Quem precisa disso é só o TÍTULO: ele começa em x=20, bem debaixo do menu e do
-- chat do Roblox. A coluna de heróis não precisa — ela está colada na direita, e
-- os botões do Roblox ficam todos na quina esquerda. Descontar a faixa dela só
-- roubava altura e mostrava menos cartas de uma vez.
local function layoutSafeArea()
	title.Position = UDim2.new(0, 20, 0, SafeArea.Top())

	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
	local usable = viewport and (viewport.Y - 24) or 0
	barSize.MaxSize = Vector2.new(COLUMN_WIDTH, math.max(180, usable))
	bar.Position = UDim2.new(1, -12, 0.5, 0)
end

layoutSafeArea()
SafeArea.OnChange(layoutSafeArea)
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layoutSafeArea)
end

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 10)
barCorner.Parent = bar

local barPadding = Instance.new("UIPadding")
barPadding.PaddingLeft = UDim.new(0, 6)
barPadding.PaddingRight = UDim.new(0, 6)
barPadding.PaddingTop = UDim.new(0, 6)
barPadding.PaddingBottom = UDim.new(0, 6)
barPadding.Parent = bar

-- ===== CARROSSEL =====
-- A altura da carta é constante e sai do espaço visível: cabem quantas couberem
-- e o resto fica na rolagem, então herói novo não encolhe os que já existem.
--
-- ScrollingFrame em vez de só setas porque no celular o arrasto já vem de
-- graça; as setas existem pro mouse, que não tem rolagem cômoda.
-- 66 e não 76: no celular deitado (tela baixa) a coluna só mostrava três cartas
-- de uma vez, e o jogador tinha que rolar pra ver metade do elenco
local CARD_HEIGHT = 66

-- Seta desenhada com duas barrinhas cruzadas em vez de um caractere. As setas
-- deitadas usavam "‹" e "›", que existem nas fontes do Roblox; as verticais
-- (⌃ ⌄, ▲ ▼) não existem em todas e saíram como quadradinho de "não reconhecido"
-- — o mesmo motivo pelo qual o X de fechar desta tela também é desenhado.
local function buildArrow(name, pointingUp, position, anchor)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = anchor
	button.Position = position
	button.Size = UDim2.new(1, 0, 0, ARROW_HEIGHT)
	button.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.ZIndex = 3
	button.Parent = bar

	local arrowCorner = Instance.new("UICorner")
	arrowCorner.CornerRadius = UDim.new(0, 8)
	arrowCorner.Parent = button

	-- duas barras em "V" (ou "Λ"), encostadas pela ponta
	for _, side in ipairs({ -1, 1 }) do
		local dash = Instance.new("Frame")
		dash.Name = "Dash"
		dash.AnchorPoint = Vector2.new(0.5, 0.5)
		dash.Position = UDim2.new(0.5, side * 5, 0.5, 0)
		dash.Size = UDim2.new(0, 13, 0, 3)
		dash.BackgroundColor3 = Color3.fromRGB(235, 240, 250)
		dash.BorderSizePixel = 0
		dash.Rotation = (pointingUp and 1 or -1) * side * 38
		dash.ZIndex = 4
		dash.Parent = button

		local dashCorner = Instance.new("UICorner")
		dashCorner.CornerRadius = UDim.new(1, 0)
		dashCorner.Parent = dash
	end

	return button
end

local leftArrow = buildArrow("ScrollUp", true, UDim2.new(0, 0, 0, 0), Vector2.new(0, 0))
local rightArrow = buildArrow("ScrollDown", false, UDim2.new(0, 0, 1, 0), Vector2.new(0, 1))

local scroller = Instance.new("ScrollingFrame")
scroller.Name = "HeroStrip"
scroller.Position = UDim2.new(0, 0, 0, ARROW_HEIGHT + CARD_GAP)
scroller.Size = UDim2.new(1, 0, 1, -2 * (ARROW_HEIGHT + CARD_GAP))
scroller.BackgroundTransparency = 1
scroller.BorderSizePixel = 0
scroller.ClipsDescendants = true
scroller.ScrollingDirection = Enum.ScrollingDirection.Y
scroller.CanvasSize = UDim2.new() -- calculado no layoutCards
-- Inset None é o que impede laço: com inset, a barra de rolagem encolheria a
-- janela, o layoutCards recalcularia e o tamanho oscilaria a cada quadro.
scroller.VerticalScrollBarInset = Enum.ScrollBarInset.None
scroller.ScrollBarThickness = 3
scroller.ScrollBarImageColor3 = Color3.fromRGB(120, 140, 180)
scroller.Parent = bar

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Vertical
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
barLayout.Padding = UDim.new(0, CARD_GAP)
barLayout.Parent = scroller

-- ===== CARTAS =====

local function buildHeroImage(parent, data, zIndex)
	local image = Instance.new("ImageLabel")
	image.Name = "Portrait"
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.ZIndex = zIndex or 1

	-- a folha vem do próprio herói: os criados depois moram numa folha separada
	local spriteId = HeroData.GetSpriteId(data)

	if spriteId then
		image.Image = spriteId
		image.ImageRectSize = HeroData.GetFrameSize(data)
		image.ImageRectOffset = HeroData.GetFrameOffset(data)
		image.ResampleMode = Enum.ResamplerMode.Pixelated
	else
		image.BackgroundTransparency = 0
		image.BackgroundColor3 = data.color
	end

	image.Parent = parent
	return image
end

for index, data in ipairs(HeroData.CATALOG) do
	local card = Instance.new("Frame")
	card.Name = data.name
	card.LayoutOrder = index
	card.Size = UDim2.new(1, 0, 0, CARD_HEIGHT) -- altura ajustada pelo layoutCards
	card.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
	card.BorderSizePixel = 0
	card.ClipsDescendants = true
	card.Parent = scroller

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Selection"
	stroke.Color = Color3.fromRGB(255, 235, 150)
	stroke.Thickness = 0
	stroke.Parent = card

	local portrait = buildHeroImage(card, data)
	portrait.Size = UDim2.new(1, -6, 1, -22)
	portrait.Position = UDim2.new(0, 3, 0, 1)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "HeroName"
	nameLabel.Size = UDim2.new(1, 0, 0, 18)
	nameLabel.Position = UDim2.new(0, 0, 1, -19)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = data.name
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.Parent = card

	local taken = Instance.new("Frame")
	taken.Name = "Taken"
	taken.Size = UDim2.fromScale(1, 1)
	taken.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	taken.BackgroundTransparency = 1
	taken.BorderSizePixel = 0
	taken.Visible = false
	taken.ZIndex = 5
	taken.Parent = card

	local takenCorner = Instance.new("UICorner")
	takenCorner.CornerRadius = UDim.new(0, 8)
	takenCorner.Parent = taken

	-- Cadeado de herói não comprado. Fica ACIMA do "Taken" (ZIndex maior) porque
	-- bloqueado e já escolhido pelo adversário podem valer ao mesmo tempo, e a
	-- informação útil pro jogador é a que ele consegue mudar: comprar.
	--
	-- Mostra o PREÇO, não mais um nível: o catálogo deixou de ser liberado por
	-- nível e virou compra na vitrine do lobby.
	local lock = Instance.new("TextLabel")
	lock.Name = "Lock"
	lock.Size = UDim2.fromScale(1, 1)
	lock.BackgroundColor3 = Color3.fromRGB(8, 9, 14)
	lock.BackgroundTransparency = 0.3
	lock.BorderSizePixel = 0
	lock.Visible = false
	lock.ZIndex = 6
	lock.Text = ("%d\nMOEDAS"):format(HeroData.GetCost(data))
	lock.TextColor3 = Color3.fromRGB(255, 220, 150)
	lock.TextSize = 13
	lock.Font = Enum.Font.GothamBold
	lock.Parent = card

	local lockCorner = Instance.new("UICorner")
	lockCorner.CornerRadius = UDim.new(0, 8)
	lockCorner.Parent = lock

	heroCards[data.id] = { card = card, stroke = stroke, taken = taken, lock = lock, data = data }
end

-- ===== ROLAGEM =====
-- heroCards é indexado por id e o pairs sai fora de ordem; aqui a sequência
-- precisa acompanhar o catálogo, que é a mesma do LayoutOrder das cartas.
local orderedCards = {}
for _, data in ipairs(HeroData.CATALOG) do
	table.insert(orderedCards, heroCards[data.id].card)
end

-- Refeito sempre que a janela muda de tamanho (rotação de celular, split
-- screen, redimensionar a janela no PC). Rodar só uma vez na abertura não
-- serve: no primeiro quadro a GUI pode ainda ter tamanho zero, e aí a conta
-- congelaria com carta de largura zero.
local function layoutCards()
	local viewport = scroller.AbsoluteWindowSize.Y
	if viewport <= 0 then return end

	local count = #orderedCards

	-- Quantas cartas INTEIRAS cabem na altura disponível. Arredondando pra baixo
	-- e depois dividindo o espaço entre elas, nunca sobra meia carta cortada no
	-- pé da coluna — que é o que faz o jogador achar que a lista acabou ali.
	local fit = math.max(2, math.floor((viewport + CARD_GAP) / (CARD_HEIGHT + CARD_GAP)))
	local visible = math.min(fit, count)
	local cardHeight = (viewport - (visible - 1) * CARD_GAP) / visible

	for _, card in ipairs(orderedCards) do
		card.Size = UDim2.new(1, 0, 0, cardHeight)
	end

	scroller.CanvasSize = UDim2.new(0, 0, 0, count * cardHeight + (count - 1) * CARD_GAP)
end

-- Rola de página inteira em vez de carta a carta: o jogador nunca fica olhando
-- pra uma fileira de cartas cortadas pela metade tentando decidir.
local function scrollBy(direction)
	local viewport = scroller.AbsoluteWindowSize.Y
	local maxY = math.max(0, scroller.AbsoluteCanvasSize.Y - viewport)
	local target = math.clamp(scroller.CanvasPosition.Y + direction * viewport, 0, maxY)

	TweenService:Create(scroller, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {
		CanvasPosition = Vector2.new(0, target),
	}):Play()
end

-- Seta apagada quando não há pra onde ir, pro jogador ver que chegou na ponta
-- sem precisar clicar pra descobrir
local function refreshArrows()
	local maxY = math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
	local atStart = scroller.CanvasPosition.Y <= 1
	local atEnd = scroller.CanvasPosition.Y >= maxY - 1

	-- as barrinhas é que apagam agora: a seta virou desenho, não texto
	local function fade(button, spent)
		button.BackgroundTransparency = spent and 0.5 or 0
		for _, dash in ipairs(button:GetChildren()) do
			if dash:IsA("Frame") then
				dash.BackgroundTransparency = spent and 0.6 or 0
			end
		end
	end

	fade(leftArrow, atStart)
	fade(rightArrow, atEnd)
end

leftArrow.Activated:Connect(function() scrollBy(-1) end)
rightArrow.Activated:Connect(function() scrollBy(1) end)

scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(refreshArrows)
scroller:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
	layoutCards()
	refreshArrows()
end)

layoutCards()
refreshArrows()

-- ===== PAINEL DE DETALHE =====
local detail = Instance.new("Frame")
detail.Name = "HeroDetail"
detail.AnchorPoint = Vector2.new(0.5, 0.5)
detail.Position = UDim2.fromScale(0.5, 0.45)
detail.Size = UDim2.new(0, 460, 0, 260)
detail.BackgroundColor3 = Color3.fromRGB(16, 19, 28)
detail.BorderSizePixel = 0
detail.Visible = false
detail.Parent = gui

local detailCorner = Instance.new("UICorner")
detailCorner.CornerRadius = UDim.new(0, 14)
detailCorner.Parent = detail

local detailStroke = Instance.new("UIStroke")
detailStroke.Color = Color3.fromRGB(90, 130, 200)
detailStroke.Thickness = 2
detailStroke.Parent = detail

local detailPortraitHolder = Instance.new("Frame")
detailPortraitHolder.Size = UDim2.new(0, 150, 1, -24)
detailPortraitHolder.Position = UDim2.new(0, 14, 0, 12)
detailPortraitHolder.BackgroundColor3 = Color3.fromRGB(26, 31, 44)
detailPortraitHolder.BorderSizePixel = 0
detailPortraitHolder.Parent = detail

local holderCorner = Instance.new("UICorner")
holderCorner.CornerRadius = UDim.new(0, 10)
holderCorner.Parent = detailPortraitHolder

local detailName = Instance.new("TextLabel")
detailName.Size = UDim2.new(1, -190, 0, 34)
detailName.Position = UDim2.new(0, 176, 0, 14)
detailName.BackgroundTransparency = 1
detailName.TextColor3 = Color3.new(1, 1, 1)
detailName.TextXAlignment = Enum.TextXAlignment.Left
detailName.TextScaled = true
detailName.Font = Enum.Font.GothamBlack
detailName.Parent = detail

local detailStats = Instance.new("TextLabel")
detailStats.Size = UDim2.new(1, -190, 0, 22)
detailStats.Position = UDim2.new(0, 176, 0, 50)
detailStats.BackgroundTransparency = 1
detailStats.TextColor3 = Color3.fromRGB(215, 225, 240)
detailStats.TextXAlignment = Enum.TextXAlignment.Left
detailStats.TextScaled = true
detailStats.Font = Enum.Font.GothamBold
detailStats.Parent = detail

local detailAbilities = Instance.new("TextLabel")
detailAbilities.Size = UDim2.new(1, -196, 1, -130)
detailAbilities.Position = UDim2.new(0, 176, 0, 78)
detailAbilities.BackgroundTransparency = 1
detailAbilities.TextColor3 = Color3.fromRGB(185, 215, 255)
detailAbilities.TextXAlignment = Enum.TextXAlignment.Left
detailAbilities.TextYAlignment = Enum.TextYAlignment.Top
detailAbilities.TextWrapped = true
detailAbilities.TextSize = 14
detailAbilities.Font = Enum.Font.Gotham
detailAbilities.Parent = detail

local detailHint = Instance.new("TextLabel")
detailHint.Size = UDim2.new(1, -196, 0, 20)
detailHint.Position = UDim2.new(0, 176, 1, -46)
detailHint.BackgroundTransparency = 1
detailHint.Text = "Arraste a carta até uma casa verde para posicionar"
detailHint.TextColor3 = Color3.fromRGB(140, 155, 180)
detailHint.TextXAlignment = Enum.TextXAlignment.Left
detailHint.TextSize = 13
detailHint.Font = Enum.Font.SourceSansItalic
detailHint.Parent = detail

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0, 28, 0, 28)
closeButton.Position = UDim2.new(1, -36, 0, 8)
closeButton.BackgroundColor3 = Color3.fromRGB(48, 54, 70)
closeButton.Text = ""
closeButton.BorderSizePixel = 0
closeButton.Parent = detail

-- X desenhado com duas barras cruzadas em vez do glifo "✕": nem toda fonte do
-- Roblox tem esse caractere e ele saía como quadradinho de "não reconhecido"
for _, angle in ipairs({ 45, -45 }) do
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.5)
	bar.Size = UDim2.new(0, 14, 0, 2)
	bar.BackgroundColor3 = Color3.fromRGB(235, 240, 250)
	bar.BorderSizePixel = 0
	bar.Rotation = angle
	bar.Parent = closeButton
end

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeButton

local function hideDetail()
	if not detail.Visible then return end
	local tween = TweenService:Create(detail, TweenInfo.new(0.12), { Size = UDim2.new(0, 420, 0, 236) })
	tween:Play()
	tween.Completed:Once(function()
		detail.Visible = false
	end)
end

closeButton.MouseButton1Click:Connect(hideDetail)

local function showDetail(data)
	for _, child in ipairs(detailPortraitHolder:GetChildren()) do
		if child:IsA("ImageLabel") then child:Destroy() end
	end

	local portrait = buildHeroImage(detailPortraitHolder, data, 2)
	portrait.Size = UDim2.new(1, -12, 1, -12)
	portrait.Position = UDim2.new(0, 6, 0, 6)

	detailName.Text = data.name
	detailStats.Text = ("%d ATK   •   %d HP   •   %s")
		:format(data.attack, data.hp, data.ability or "sem passiva")

	local lines = {}
	-- "•" em vez de "▸": o triângulo não existe nas fontes do Roblox e saía
	-- como quadradinho de caractere desconhecido, igual ao "✕" do botão fechar.
	-- O "•" já é usado no painel de batalha e renderiza normal.
	if data.ability and HeroData.ABILITY_INFO[data.ability] then
		table.insert(lines, ("•  %s — %s"):format(data.ability, HeroData.ABILITY_INFO[data.ability]))
	end
	for _, key in ipairs(data.abilities) do
		local info = HeroData.SKILL_INFO[key]
		if info then
			table.insert(lines, ("•  %s — %s"):format(info.name, info.desc))
		end
	end
	detailAbilities.Text = table.concat(lines, "\n\n")

	detail.Size = UDim2.new(0, 420, 0, 236)
	detail.Visible = true
	TweenService:Create(detail, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, 460, 0, 260),
	}):Play()
end

-- ===== DESTAQUE DAS CASAS =====
local function clearHighlights()
	for part in pairs(paintedTiles) do
		if part.Parent then restoreTile(part) end
	end
	paintedTiles = {}
	hoveredHex = nil
end

-- O tabuleiro vem no snapshot: com várias partidas rodando, procurar "Board"
-- pelo nome no Workspace acharia a arena de outra dupla.
local function paint(hexId, color)
	local board = currentState and currentState.boardFolder
	local tile = board and board:FindFirstChild(hexId)
	if tile and tile:IsA("BasePart") then
		paintedTiles[tile] = true
		if activeTweens[tile] then
			activeTweens[tile]:Cancel()
		end
		local tween = TweenService:Create(tile, TweenInfo.new(0.15), { Color = color })
		activeTweens[tile] = tween
		tween:Play()
	end
	return tile
end

-- O Board é replicado de forma assíncrona: nas primeiras atualizações ele (ou
-- algumas casas) ainda não existe no cliente, e o paint falhava calado — era
-- por isso que a zona de largada às vezes não ficava verde. Agora espera as
-- casas aparecerem; o token cancela a espera se um estado novo chegar antes.
local highlightToken = 0

local function waitForTile(board, hexId, token)
	local tile = board:FindFirstChild(hexId)
	local waited = 0

	while not tile and waited < 3 and highlightToken == token do
		task.wait(0.05)
		waited += 0.05
		tile = board:FindFirstChild(hexId)
	end

	return tile
end

local function highlightDeployZone()
	clearHighlights()
	if not currentState or not currentState.isMyPlacement then return end

	highlightToken += 1
	local token = highlightToken
	local state = currentState

	task.spawn(function()
		local board = state.boardFolder
		local waited = 0
		while (not board or not board.Parent) and waited < 10 and highlightToken == token do
			task.wait(0.1)
			waited += 0.1
			board = currentState and currentState.boardFolder
		end

		if not board or highlightToken ~= token then return end

		local occupied = {}
		for _, hero in ipairs(state.heroes) do
			occupied[hero.position] = true
		end

		for _, hexId in ipairs(state.deployZone) do
			if highlightToken ~= token then return end
			if not occupied[hexId] and waitForTile(board, hexId, token) then
				paint(hexId, HIGHLIGHT_COLOR)
			end
		end
	end)
end

local function isFreeDeployHex(hexId)
	if not currentState or not hexId then return false end
	if not table.find(currentState.deployZone, hexId) then return false end
	for _, hero in ipairs(currentState.heroes) do
		if hero.position == hexId then return false end
	end
	return true
end

-- ===== DRAG & DROP =====
local function makeGhost(data)
	local ghost = Instance.new("Frame")
	ghost.Name = "DragGhost"
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Size = UDim2.new(0, 76, 0, 100)
	ghost.BackgroundTransparency = 1
	ghost.ZIndex = 50
	ghost.Parent = gui

	local portrait = buildHeroImage(ghost, data, 51)
	portrait.Size = UDim2.fromScale(1, 1)
	portrait.ImageTransparency = 0.15

	return ghost
end

local function updateDrag(screenPosition)
	if not drag then return end
	drag.ghost.Position = UDim2.fromOffset(screenPosition.X, screenPosition.Y)

	local hexId = mouse.Target and mouse.Target:GetAttribute("HexId")
	if hexId == hoveredHex then return end

	if hoveredHex then
		paint(hoveredHex, HIGHLIGHT_COLOR)
	end

	hoveredHex = isFreeDeployHex(hexId) and hexId or nil
	if hoveredHex then
		paint(hoveredHex, HOVER_COLOR)
	end
end

-- Rede de segurança: no mobile dava pra encostar em várias cartas ao mesmo
-- tempo, cada toque criava um ghost novo e só o último ficava em `drag` —
-- os anteriores viravam sprites órfãos espalhados pela tela.
local function destroyStrayGhosts()
	for _, child in ipairs(gui:GetChildren()) do
		if child.Name == "DragGhost" then
			child:Destroy()
		end
	end
end

local function finishDrag()
	if not drag then return end

	local dropHex = hoveredHex
	local dataId = drag.data.id
	local moved = drag.moved

	drag.ghost:Destroy()
	drag = nil
	destroyStrayGhosts()

	if dropHex and isFreeDeployHex(dropHex) then
		PlaceHero:FireServer(dataId, dropHex)
	elseif not moved then
		showDetail(HeroData.GetById(dataId))
	end

	highlightDeployZone()
end

local function startDrag(data, input)
	if drag then return end -- um arraste por vez
	if not currentState then return end

	-- mexer nas cartas na vez do adversário não fazia nada e nem avisava
	if not currentState.isMyPlacement then
		warnNotYourTurn()
		return
	end

	if usedHeroIdSet[data.id] then return end

	local startPosition = Vector2.new(input.Position.X, input.Position.Y)

	destroyStrayGhosts()
	PlayUiSound("HeroSelect")

	drag = {
		data = data,
		ghost = makeGhost(data),
		origin = startPosition,
		moved = false,
		input = input,
		isTouch = input.UserInputType == Enum.UserInputType.Touch,
	}
	updateDrag(startPosition)
end

for id, entry in pairs(heroCards) do
	entry.card.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			-- herói bloqueado não arrasta, mas ainda abre o detalhe: ver o que
			-- vem no próximo nível é justamente o que dá vontade de subir
			if lockedHeroIdSet[entry.data.id] then
				showDetail(entry.data)
				return
			end
			startDrag(entry.data, input)
		end
	end)
end

-- No toque, o mesmo InputObject atravessa Began/Changed/Ended, então dá pra
-- casar exatamente o dedo que iniciou o arraste. No mouse não: o movimento
-- vem como MouseMovement, um objeto diferente do MouseButton1.
local function belongsToDrag(input, endedPhase)
	if not drag then return false end

	if drag.isTouch then
		return input == drag.input
	end

	if endedPhase then
		return input.UserInputType == Enum.UserInputType.MouseButton1
	end
	return input.UserInputType == Enum.UserInputType.MouseMovement
end

UserInputService.InputChanged:Connect(function(input)
	if not belongsToDrag(input, false) then return end

	local position = Vector2.new(input.Position.X, input.Position.Y)
	if (position - drag.origin).Magnitude > DRAG_THRESHOLD then
		drag.moved = true
	end
	updateDrag(position)
end)

UserInputService.InputEnded:Connect(function(input)
	if not belongsToDrag(input, true) then return end
	finishDrag()
end)

-- tocar direto no tabuleiro enquanto o adversário escolhe também recebe o aviso
mouse.Button1Down:Connect(function()
	if not currentState or currentState.phase ~= "placement" then return end
	if currentState.isMyPlacement then return end

	local target = mouse.Target
	if target and (target:GetAttribute("HexId") or target:GetAttribute("HeroUid")) then
		warnNotYourTurn()
	end
end)

-- ===== ESTADO =====
MatchUpdate.OnClientEvent:Connect(function(state)
	currentState = state

	-- o servidor manda um array de ids; vira set aqui pra consulta direta
	usedHeroIdSet = {}
	for _, dataId in ipairs(state.usedHeroIds or {}) do
		usedHeroIdSet[dataId] = true
	end

	lockedHeroIdSet = {}
	for _, dataId in ipairs(state.lockedHeroIds or {}) do
		lockedHeroIdSet[dataId] = true
	end

	if state.phase ~= "placement" then
		gui.Enabled = false
		clearHighlights()
		hideDetail()
		if drag then
			drag.ghost:Destroy()
			drag = nil
		end
		destroyStrayGhosts()
		return
	end

	gui.Enabled = true

	local myTurn = state.isMyPlacement
	if myTurn then
		title.Text = ("Sua vez  —  %d/%d posicionados"):format(state.placedCount, state.heroesPerPlayer)
		title.TextColor3 = Color3.new(1, 1, 1)
	else
		title.Text = ("%s escolhendo..."):format(state.opponentName or "Adversário")
		title.TextColor3 = Color3.fromRGB(255, 175, 175)
	end

	for id, entry in pairs(heroCards) do
		local used = usedHeroIdSet[id] == true
		local locked = lockedHeroIdSet[id] == true

		entry.lock.Visible = locked
		-- bloqueado já cobre a carta inteira; marcar "usado" por cima só
		-- empilharia dois véus escuros e apagaria o nível que falta
		entry.taken.Visible = used and not locked
		entry.taken.BackgroundTransparency = used and 0.55 or 1
		entry.card.BackgroundTransparency = myTurn and 0 or 0.45
		entry.stroke.Thickness = 0
	end

	highlightDeployZone()
end)
