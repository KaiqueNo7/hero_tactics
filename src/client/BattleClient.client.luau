--[[
	BattleClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local PixelIcons = require(ReplicatedStorage.Modules.PixelIcons)
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local MOVE_COLOR = Color3.fromRGB(110, 220, 130)
local ATTACK_COLOR = Color3.fromRGB(230, 90, 90)
local BARREL_COLOR = Color3.fromRGB(232, 172, 74) -- alvo neutro: nem inimigo, nem passagem

-- Lápide inimiga: roxo, não o vermelho de herói vivo — mesma cor da moldura que
-- o HeroView desenha na lápide no servidor. Quebrar isto não é um ataque comum
-- (não sofre contra-ataque, não revida), e a cor avisa isso antes do clique,
-- igual o âmbar do barril avisa "isto também não é gente".
local GRAVE_ATTACK_COLOR = Color3.fromRGB(178, 140, 210)

-- cor base caso o attribute BaseColor não exista (defensivo)
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

-- ===== CASAS DE PROMOÇÃO (cores por estado) =====
-- Inativa: escura, quase apagada — ainda não é nada. Liberada: dourado quente,
-- o mesmo tom da moldura dos crachás (BADGE_GOLD no HeroView), com um pulso
-- entre os dois tons pra "quase brilhando". Usada: volta pro checkerboard
-- comum da própria coluna — ela cumpriu o papel e se mistura de novo ao
-- tabuleiro normal, sem chamar mais atenção.
local PROMOTION_INACTIVE_COLOR = Color3.fromRGB(38, 38, 46)
local PROMOTION_ACTIVE_COLOR_LOW = Color3.fromRGB(158, 122, 40)
local PROMOTION_ACTIVE_COLOR_HIGH = Color3.fromRGB(255, 214, 120)

local function fallbackColor(tile)
	local col = string.byte(tile.Name, 1) - string.byte("A", 1)
	return (col % 2 == 0) and COLOR_A or COLOR_B
end

local state = nil

-- Declarado AQUI, e nao junto da implementacao la embaixo, porque o modal da
-- Casa de Promocao (renderPromotionChoice) precisa dele umas 600 linhas antes.
-- Com `local function` no ponto da implementacao o nome virava global nil aqui
-- em cima: o modal abria, criava o primeiro cartao e estourava no meio, deixando
-- um card sem nome ("Label") e a escolha travada sem como resolver. Forward
-- declaration resolve sem ter que mover funcao nenhuma de lugar.
local heroByUid

local selectedUid = nil
local moveTargets, attackTargets, savedColors = {}, {}, {}
local secondsLeft = nil
local wasMyTurn = false
local resultPlayed = false

local function PlayUiSound(name)
	local template = ReplicatedStorage.Sounds:FindFirstChild(name)
	if not template then return end
	local sound = template:Clone()
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- ===== UI =====
local gui = Instance.new("ScreenGui")
gui.Name = "BattleGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

-- ===== TOPO DA TELA =====
-- Aqui NÃO entra margem de segurança contra a barra do Roblox, e é de propósito:
-- os botões dela ficam na quina esquerda (o TopbarInset mede isso), enquanto
-- este bloco é centralizado ou colado na direita — nunca chega perto deles.
-- Descer tudo pra baixo da faixa só empurrava a coluna de heróis contra os
-- botões de desistir e de passar turno, no rodapé.

-- ===== INDICADOR DE TURNO (centralizado) =====
local turnPanel = Instance.new("Frame")
turnPanel.AnchorPoint = Vector2.new(0.5, 0)
turnPanel.Size = UDim2.new(0, 220, 0, 40)
turnPanel.Position = UDim2.new(0.5, 0, 0, 10)
turnPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
turnPanel.BackgroundTransparency = 0.2
turnPanel.BorderSizePixel = 0
turnPanel.Parent = gui

local turnCorner = Instance.new("UICorner")
turnCorner.CornerRadius = UDim.new(0, 8)
turnCorner.Parent = turnPanel

local turnLabel = Instance.new("TextLabel")
turnLabel.Size = UDim2.fromScale(1, 1)
turnLabel.BackgroundTransparency = 1
turnLabel.TextColor3 = Color3.new(1, 1, 1)
turnLabel.TextXAlignment = Enum.TextXAlignment.Center
turnLabel.TextScaled = true
turnLabel.Font = Enum.Font.GothamBold
turnLabel.Parent = turnPanel

-- ===== TIMER (só aparece com <10s, canto superior direito) =====
local timerLabel = Instance.new("TextLabel")
timerLabel.AnchorPoint = Vector2.new(1, 0)
timerLabel.Size = UDim2.new(0, 70, 0, 28)
timerLabel.Position = UDim2.new(1, 0, 0, 20)
timerLabel.BackgroundTransparency = 1
timerLabel.TextColor3 = Color3.fromRGB(255, 110, 110)
timerLabel.TextStrokeTransparency = 0.4
timerLabel.TextScaled = true
timerLabel.Font = Enum.Font.GothamBlack
timerLabel.Text = ""
timerLabel.Visible = false
timerLabel.Parent = gui

-- ===== SELO DE CONTRA-ATAQUE (logo abaixo do timer) =====
-- O contra-ataque é UM por turno e vale pros dois lados: quem apanha primeiro no
-- turno revida sozinho, e daí em diante ninguém mais revida até o turno virar.
-- Isso decidia trocas inteiras sem aparecer em lugar nenhum da tela — quem
-- atacava segundo levava um golpe de graça sem entender por quê.
local COUNTER_READY_COLOR = Color3.fromRGB(120, 230, 150)
local COUNTER_USED_COLOR = Color3.fromRGB(96, 102, 116)

local counterBadge = Instance.new("Frame")
counterBadge.Name = "CounterBadge"
counterBadge.AnchorPoint = Vector2.new(1, 0)
counterBadge.Position = UDim2.new(1, -8, 0, 50)
counterBadge.Size = UDim2.new(0, 172, 0, 24)
counterBadge.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
counterBadge.BackgroundTransparency = 0.25
counterBadge.BorderSizePixel = 0
counterBadge.Visible = false
counterBadge.Parent = gui

local counterCorner = Instance.new("UICorner")
counterCorner.CornerRadius = UDim.new(0, 6)
counterCorner.Parent = counterBadge

local counterStroke = Instance.new("UIStroke")
counterStroke.Color = COUNTER_READY_COLOR
counterStroke.Transparency = 0.55
counterStroke.Thickness = 1
counterStroke.Parent = counterBadge

-- bolinha em vez de glifo: os símbolos de espada não existem nas fontes do
-- Roblox e sairiam como quadradinho, igual ao "✕" que já foi trocado por barras
local counterDot = Instance.new("Frame")
counterDot.Name = "Dot"
counterDot.AnchorPoint = Vector2.new(0, 0.5)
counterDot.Position = UDim2.new(0, 8, 0.5, 0)
counterDot.Size = UDim2.new(0, 10, 0, 10)
counterDot.BackgroundColor3 = COUNTER_READY_COLOR
counterDot.BorderSizePixel = 0
counterDot.Parent = counterBadge

local counterDotCorner = Instance.new("UICorner")
counterDotCorner.CornerRadius = UDim.new(1, 0)
counterDotCorner.Parent = counterDot

local counterLabel = Instance.new("TextLabel")
counterLabel.Name = "Label"
counterLabel.AnchorPoint = Vector2.new(0, 0.5)
counterLabel.Position = UDim2.new(0, 24, 0.5, 0)
counterLabel.Size = UDim2.new(1, -32, 1, 0)
counterLabel.BackgroundTransparency = 1
counterLabel.TextColor3 = Color3.fromRGB(214, 232, 220)
counterLabel.TextXAlignment = Enum.TextXAlignment.Left
counterLabel.TextSize = 13
counterLabel.Font = Enum.Font.GothamBold
counterLabel.Text = "Contra-ataque pronto"
counterLabel.Parent = counterBadge

local counterShown = nil

local function renderCounterBadge(used)
	-- mesma razão da guarda das fichas: sem isso é um tween por transmissão
	if counterShown == used then return end
	counterShown = used

	local color = used and COUNTER_USED_COLOR or COUNTER_READY_COLOR
	counterLabel.Text = used and "Contra-ataque usado" or "Contra-ataque pronto"
	counterLabel.TextColor3 = used
		and Color3.fromRGB(146, 152, 166) or Color3.fromRGB(214, 232, 220)
	counterStroke.Color = color
	TweenService:Create(counterDot, TweenInfo.new(0.2), { BackgroundColor3 = color }):Play()
end

-- ===== RETRATOS DOS DOIS TIMES (colunas nas laterais) =====
-- Uma coluna por jogador, com o nome dele em cima. O retrato apaga quando o
-- herói morre — dá pra saber quem ainda está de pé sem varrer o tabuleiro.
-- 54 e não 48: o nome do herói entra numa faixa no pé do card, e com 48 sobrava
-- retrato de menos pra dar pra reconhecer quem é.
local CARD_SIZE = 54
local CARD_GAP = 5
local NAME_STRIP = 12
local COLUMN_HEADER = 18
-- Começa abaixo do selo de contra-ataque e termina acima do rodapé, onde ficam
-- os botões de desistir e de passar turno. É pouco espaço: descer estas colunas
-- encosta uma coisa na outra.
local COLUMN_TOP = 78

local SIDE_ONE_COLOR = Color3.fromRGB(70, 150, 255)
local SIDE_TWO_COLOR = Color3.fromRGB(230, 70, 70)

-- Cinza claro, e não chumbo: ImageColor3 MULTIPLICA o sprite, então um tom
-- escuro demais apagava o retrato inteiro e não dava mais pra saber QUEM tinha
-- morrido — que é justamente a informação que a coluna existe pra dar.
local DEAD_TINT = Color3.fromRGB(138, 141, 150)
local DEAD_CARD = Color3.fromRGB(18, 19, 23)

-- ATK espelha a vida (canto oposto, mesmo tamanho) — o pedido era "perfeitamente
-- alinhados e do mesmo tamanho", então os dois números usam literalmente o mesmo
-- Size/TextSize/Font, só o AnchorPoint/Position viram de lado.
local STAT_LABEL_SIZE = UDim2.new(0, 26, 0, 13)
local ATK_TEXT_COLOR = Color3.fromRGB(150, 200, 255)

-- Atribuída lá embaixo, junto com o modal — o clique do card precisa dela
-- antes dela existir, então o forward declare mora aqui.
local showHeroDetail

local function buildPortrait(parent)
	local image = Instance.new("ImageLabel")
	image.Name = "Portrait"
	-- deixa livre a faixa do nome no pé do card
	image.Size = UDim2.new(1, -6, 1, -(6 + NAME_STRIP))
	image.Position = UDim2.new(0, 3, 0, 3)
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.Parent = parent
	return image
end

local function buildTeamColumn(alignLeft)
	local column = Instance.new("Frame")
	column.Name = alignLeft and "MyTeam" or "TheirTeam"
	column.AnchorPoint = Vector2.new(alignLeft and 0 or 1, 0)
	column.Position = UDim2.new(alignLeft and 0 or 1, alignLeft and 10 or -10, 0, COLUMN_TOP)
	column.Size = UDim2.new(0, CARD_SIZE, 0,
		COLUMN_HEADER + GameConfig.HEROES_PER_PLAYER * (CARD_SIZE + CARD_GAP))
	column.BackgroundTransparency = 1
	column.Visible = false
	column.Parent = gui

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "PlayerName"
	-- solta pra fora da coluna: o nome é mais largo que o retrato e ficaria
	-- espremido a três letras se respeitasse os 48px do card
	nameLabel.AnchorPoint = Vector2.new(alignLeft and 0 or 1, 0)
	nameLabel.Position = UDim2.new(alignLeft and 0 or 1, 0, 0, 0)
	nameLabel.Size = UDim2.new(0, 150, 0, COLUMN_HEADER - 2)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.fromRGB(228, 236, 250)
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.TextXAlignment = alignLeft and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.TextSize = 13
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.Text = ""
	nameLabel.Parent = column

	local rows = {}
	for index = 1, GameConfig.HEROES_PER_PLAYER do
		local card = Instance.new("Frame")
		card.Name = "Slot" .. index
		card.Position = UDim2.new(0, 0, 0, COLUMN_HEADER + (index - 1) * (CARD_SIZE + CARD_GAP))
		card.Size = UDim2.new(0, CARD_SIZE, 0, CARD_SIZE)
		card.BackgroundColor3 = Color3.fromRGB(24, 27, 37)
		card.BackgroundTransparency = 0.15
		card.BorderSizePixel = 0
		card.ClipsDescendants = true
		card.Visible = false
		card.Parent = column

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 7)
		corner.Parent = card

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.6
		stroke.Parent = card

		local portrait = buildPortrait(card)

		-- barrinha de vida colada no pé do card
		local hpTrack = Instance.new("Frame")
		hpTrack.Name = "HpTrack"
		hpTrack.Position = UDim2.new(0, 0, 1, -4)
		hpTrack.Size = UDim2.new(1, 0, 0, 4)
		hpTrack.BackgroundColor3 = Color3.fromRGB(40, 44, 56)
		hpTrack.BorderSizePixel = 0
		hpTrack.ZIndex = 3
		hpTrack.Parent = card

		local hpFill = Instance.new("Frame")
		hpFill.Name = "HpFill"
		hpFill.Size = UDim2.fromScale(1, 1)
		hpFill.BackgroundColor3 = Color3.fromRGB(80, 200, 110)
		hpFill.BorderSizePixel = 0
		hpFill.ZIndex = 4
		hpFill.Parent = hpTrack

		-- Faixa do nome no pé do card, logo acima da barra de vida.
		local heroName = Instance.new("TextLabel")
		heroName.Name = "HeroName"
		heroName.AnchorPoint = Vector2.new(0, 1)
		heroName.Position = UDim2.new(0, 0, 1, -4)
		heroName.Size = UDim2.new(1, 0, 0, NAME_STRIP)
		heroName.BackgroundColor3 = Color3.fromRGB(10, 11, 16)
		heroName.BackgroundTransparency = 0.25
		heroName.BorderSizePixel = 0
		heroName.TextColor3 = Color3.fromRGB(232, 238, 250)
		heroName.TextScaled = true
		heroName.Font = Enum.Font.GothamBold
		heroName.Text = ""
		heroName.ZIndex = 4
		heroName.Parent = card

		-- Vida no canto de cima à direita, ataque espelhado à esquerda — mesmo
		-- Size/TextSize/Font dos dois, só o AnchorPoint/Position viram de lado.
		-- Embaixo agora é o nome, e os dois disputando a mesma faixa de 54px
		-- deixava tudo ilegível.
		local hpLabel = Instance.new("TextLabel")
		hpLabel.Name = "Hp"
		hpLabel.AnchorPoint = Vector2.new(1, 0)
		hpLabel.Position = UDim2.new(1, -3, 0, 2)
		hpLabel.Size = STAT_LABEL_SIZE
		hpLabel.BackgroundTransparency = 1
		hpLabel.TextColor3 = Color3.new(1, 1, 1)
		hpLabel.TextStrokeTransparency = 0.15
		hpLabel.TextXAlignment = Enum.TextXAlignment.Right
		hpLabel.TextSize = 12
		hpLabel.Font = Enum.Font.GothamBlack
		hpLabel.ZIndex = 5
		hpLabel.Parent = card

		local atkLabel = Instance.new("TextLabel")
		atkLabel.Name = "Atk"
		atkLabel.AnchorPoint = Vector2.new(0, 0)
		atkLabel.Position = UDim2.new(0, 3, 0, 2)
		atkLabel.Size = STAT_LABEL_SIZE
		atkLabel.BackgroundTransparency = 1
		atkLabel.TextColor3 = ATK_TEXT_COLOR
		atkLabel.TextStrokeTransparency = 0.15
		atkLabel.TextXAlignment = Enum.TextXAlignment.Left
		atkLabel.TextSize = 12
		atkLabel.Font = Enum.Font.GothamBlack
		atkLabel.ZIndex = 5
		atkLabel.Parent = card

		-- Sem selos de passiva/veneno/gelo aqui: eles moram no crachá do herói no
		-- tabuleiro (ver HeroView). Já estiveram nos dois lugares e ficou
		-- redundante — num card de 54px o selo é pequeno demais pra ser lido de
		-- relance, que é justamente o que ele precisa ser.

		-- Botão invisível cobrindo o card inteiro: acima da cruz de morte (Z 6),
		-- pra abrir o detalhe mesmo com o herói morto.
		local clickCatcher = Instance.new("TextButton")
		clickCatcher.Name = "ClickCatcher"
		clickCatcher.Size = UDim2.fromScale(1, 1)
		clickCatcher.BackgroundTransparency = 1
		clickCatcher.AutoButtonColor = false
		clickCatcher.Text = ""
		clickCatcher.ZIndex = 10
		clickCatcher.Parent = card

		-- `rows[index]` só é preenchido no fim do loop, mas o clique só acontece
		-- bem depois (é um jogador clicando) — por lá o showHeroDetail já existe.
		clickCatcher.MouseButton1Click:Connect(function()
			local hero = rows[index] and rows[index].hero
			if hero and showHeroDetail then showHeroDetail(hero) end
		end)

		-- ✕ desenhado com duas barras cruzadas, mesmo motivo do botão fechar do
		-- draft: o glifo não existe nas fontes do Roblox
		local cross = {}
		for _, angle in ipairs({ 45, -45 }) do
			local dash = Instance.new("Frame")
			dash.Name = "CrossBar"
			dash.AnchorPoint = Vector2.new(0.5, 0.5)
			dash.Position = UDim2.fromScale(0.5, 0.5)
			dash.Size = UDim2.new(0, CARD_SIZE - 14, 0, 3)
			dash.BackgroundColor3 = Color3.fromRGB(228, 96, 96)
			dash.BackgroundTransparency = 0.15
			dash.BorderSizePixel = 0
			dash.Rotation = angle
			dash.ZIndex = 6
			dash.Visible = false
			dash.Parent = card
			table.insert(cross, dash)
		end

		rows[index] = {
			card = card,
			stroke = stroke,
			portrait = portrait,
			heroName = heroName,
			hpTrack = hpTrack,
			hpFill = hpFill,
			hpLabel = hpLabel,
			atkLabel = atkLabel,
			clickCatcher = clickCatcher,
			cross = cross,
			hero = nil,
		}
	end

	return { frame = column, nameLabel = nameLabel, rows = rows }
end

local myTeam = buildTeamColumn(true)
local theirTeam = buildTeamColumn(false)

-- O retrato vem do próprio herói: os criados depois da folha original moram em
-- assets separados, então não dá pra guardar um id só pro catálogo inteiro.
local function spriteOf(data)
	return data and HeroData.GetSpriteId(data) or nil
end

-- ===== MODAL DE DETALHE DO HERÓI =====
-- Mesmo painel da tela de seleção de heróis (ver PlacementClient), sem a dica
-- de arrastar — aqui não tem carta pra soltar, só informação pra ler. Abre ao
-- clicar em qualquer retrato das colunas laterais, vivo ou morto, seu ou do
-- adversário; fecha pelo X ou clicando fora.
local detailBackdrop = Instance.new("TextButton")
detailBackdrop.Name = "HeroDetailBackdrop"
detailBackdrop.Size = UDim2.fromScale(1, 1)
detailBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
detailBackdrop.BackgroundTransparency = 0.45
detailBackdrop.AutoButtonColor = false
detailBackdrop.Text = ""
detailBackdrop.ZIndex = 35
detailBackdrop.Visible = false
detailBackdrop.Parent = gui

local detail = Instance.new("Frame")
detail.Name = "HeroDetail"
detail.AnchorPoint = Vector2.new(0.5, 0.5)
detail.Position = UDim2.fromScale(0.5, 0.5)
detail.Size = UDim2.new(0, 460, 0, 260)
detail.BackgroundColor3 = Color3.fromRGB(16, 19, 28)
detail.BorderSizePixel = 0
detail.ZIndex = 36
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
detailPortraitHolder.ZIndex = 36
detailPortraitHolder.Parent = detail

local detailHolderCorner = Instance.new("UICorner")
detailHolderCorner.CornerRadius = UDim.new(0, 10)
detailHolderCorner.Parent = detailPortraitHolder

local detailPortraitImage = Instance.new("ImageLabel")
detailPortraitImage.Name = "Portrait"
detailPortraitImage.Size = UDim2.new(1, -12, 1, -12)
detailPortraitImage.Position = UDim2.new(0, 6, 0, 6)
detailPortraitImage.ScaleType = Enum.ScaleType.Fit
detailPortraitImage.ResampleMode = Enum.ResamplerMode.Pixelated
detailPortraitImage.ZIndex = 37
detailPortraitImage.Parent = detailPortraitHolder

local detailName = Instance.new("TextLabel")
detailName.Size = UDim2.new(1, -190, 0, 34)
detailName.Position = UDim2.new(0, 176, 0, 14)
detailName.BackgroundTransparency = 1
detailName.TextColor3 = Color3.new(1, 1, 1)
detailName.TextXAlignment = Enum.TextXAlignment.Left
detailName.TextScaled = true
detailName.Font = Enum.Font.GothamBlack
detailName.ZIndex = 36
detailName.Parent = detail

local detailStats = Instance.new("TextLabel")
detailStats.Size = UDim2.new(1, -190, 0, 22)
detailStats.Position = UDim2.new(0, 176, 0, 50)
detailStats.BackgroundTransparency = 1
detailStats.TextColor3 = Color3.fromRGB(215, 225, 240)
detailStats.TextXAlignment = Enum.TextXAlignment.Left
detailStats.TextScaled = true
detailStats.Font = Enum.Font.GothamBold
detailStats.ZIndex = 36
detailStats.Parent = detail

-- Linha extra que a tela de seleção não tinha: lá o herói ainda não tinha
-- entrado em campo, aqui ele pode estar buffado, envenenado, congelado ou
-- abatido — informação que só existe DEPOIS que a partida começa.
local detailStatus = Instance.new("TextLabel")
detailStatus.Size = UDim2.new(1, -190, 0, 18)
detailStatus.Position = UDim2.new(0, 176, 0, 74)
detailStatus.BackgroundTransparency = 1
detailStatus.TextColor3 = Color3.fromRGB(150, 210, 255)
detailStatus.TextXAlignment = Enum.TextXAlignment.Left
detailStatus.TextSize = 14
detailStatus.Font = Enum.Font.GothamBold
detailStatus.Text = ""
detailStatus.ZIndex = 36
detailStatus.Parent = detail

local detailAbilities = Instance.new("TextLabel")
detailAbilities.Size = UDim2.new(1, -196, 1, -122)
detailAbilities.Position = UDim2.new(0, 176, 0, 96)
detailAbilities.BackgroundTransparency = 1
detailAbilities.TextColor3 = Color3.fromRGB(185, 215, 255)
detailAbilities.TextXAlignment = Enum.TextXAlignment.Left
detailAbilities.TextYAlignment = Enum.TextYAlignment.Top
detailAbilities.TextWrapped = true
detailAbilities.TextSize = 14
detailAbilities.Font = Enum.Font.Gotham
detailAbilities.ZIndex = 36
detailAbilities.Parent = detail

local detailCloseButton = Instance.new("TextButton")
detailCloseButton.Size = UDim2.new(0, 28, 0, 28)
detailCloseButton.Position = UDim2.new(1, -36, 0, 8)
detailCloseButton.BackgroundColor3 = Color3.fromRGB(48, 54, 70)
detailCloseButton.Text = ""
detailCloseButton.BorderSizePixel = 0
detailCloseButton.ZIndex = 37
detailCloseButton.Parent = detail

-- X desenhado com duas barras cruzadas, mesmo motivo do resto do jogo: nem
-- toda fonte do Roblox tem o glifo "✕" e ele sai como quadradinho.
for _, angle in ipairs({ 45, -45 }) do
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.5)
	bar.Size = UDim2.new(0, 14, 0, 2)
	bar.BackgroundColor3 = Color3.fromRGB(235, 240, 250)
	bar.BorderSizePixel = 0
	bar.Rotation = angle
	bar.ZIndex = 38
	bar.Parent = detailCloseButton
end

local detailCloseCorner = Instance.new("UICorner")
detailCloseCorner.CornerRadius = UDim.new(0, 6)
detailCloseCorner.Parent = detailCloseButton

local function hideDetail()
	detail.Visible = false
	detailBackdrop.Visible = false
end

detailCloseButton.MouseButton1Click:Connect(hideDetail)
detailBackdrop.MouseButton1Click:Connect(hideDetail)

showHeroDetail = function(hero)
	local data = HeroData.GetById(hero.dataId)
	if not data then return end

	local alive = hero.isAlive
	local spriteId = spriteOf(data)
	if spriteId then
		detailPortraitImage.Image = spriteId
		detailPortraitImage.ImageRectSize = HeroData.GetFrameSize(data)
		detailPortraitImage.ImageRectOffset = HeroData.GetFrameOffset(data)
		detailPortraitImage.BackgroundTransparency = 1
	else
		detailPortraitImage.Image = ""
		detailPortraitImage.BackgroundTransparency = 0
		detailPortraitImage.BackgroundColor3 = data.color
	end
	detailPortraitImage.ImageColor3 = alive and Color3.new(1, 1, 1) or DEAD_TINT
	detailPortraitImage.ImageTransparency = alive and 0 or 0.15

	detailName.Text = hero.name or data.name
	detailStats.Text = ("%d ATK   •   %d/%d HP   •   %s")
		:format(hero.attack, math.max(hero.currentHp, 0), hero.maxHp, hero.ability or "sem passiva")

	local statusBits = {}
	if not alive then table.insert(statusBits, "Abatido") end
	if hero.attack > (hero.baseAttack or hero.attack) then table.insert(statusBits, "ATK buffado") end
	if hero.frozen then table.insert(statusBits, "Congelado") end
	if (hero.poisonTurns or 0) > 0 then
		table.insert(statusBits, ("Envenenado (%d)"):format(hero.poisonTurns))
	end
	detailStatus.Text = table.concat(statusBits, "   •   ")

	local lines = {}
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

	detail.Visible = true
	detailBackdrop.Visible = true
end

-- ===== MODAL DE ESCOLHA DA CASA DE PROMOÇÃO =====
-- Sem botão de fechar e sem clique-fora: "entrou na casa, tem que escolher" é
-- regra, não sugestão — o servidor já recusa qualquer outra ação enquanto isto
-- está pendente (ver match.pendingPromotion em AuthorizeAction/EndTurn), então
-- deixar fechar sem escolher só confundiria o jogador sobre o que aconteceu.
local promotionBackdrop = Instance.new("TextButton")
promotionBackdrop.Name = "PromotionBackdrop"
promotionBackdrop.Size = UDim2.fromScale(1, 1)
promotionBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
promotionBackdrop.BackgroundTransparency = 0.5
promotionBackdrop.AutoButtonColor = false
promotionBackdrop.Text = ""
promotionBackdrop.ZIndex = 45
promotionBackdrop.Visible = false
promotionBackdrop.Parent = gui

local promotionPanel = Instance.new("Frame")
promotionPanel.Name = "PromotionChoice"
promotionPanel.AnchorPoint = Vector2.new(0.5, 0.5)
promotionPanel.Position = UDim2.fromScale(0.5, 0.5)
promotionPanel.Size = UDim2.new(0, 460, 0, 200)
promotionPanel.BackgroundColor3 = Color3.fromRGB(16, 19, 28)
promotionPanel.BorderSizePixel = 0
promotionPanel.ZIndex = 46
promotionPanel.Visible = false
promotionPanel.Parent = gui

local promotionCorner = Instance.new("UICorner")
promotionCorner.CornerRadius = UDim.new(0, 14)
promotionCorner.Parent = promotionPanel

local promotionStroke = Instance.new("UIStroke")
promotionStroke.Color = Color3.fromRGB(255, 205, 90)
promotionStroke.Thickness = 2
promotionStroke.Parent = promotionPanel

local promotionTitle = Instance.new("TextLabel")
promotionTitle.Size = UDim2.new(1, -32, 0, 30)
promotionTitle.Position = UDim2.new(0, 16, 0, 14)
promotionTitle.BackgroundTransparency = 1
promotionTitle.Text = "Casa de Promoção"
promotionTitle.TextColor3 = Color3.fromRGB(255, 214, 120)
promotionTitle.TextXAlignment = Enum.TextXAlignment.Left
promotionTitle.TextScaled = true
promotionTitle.Font = Enum.Font.GothamBlack
promotionTitle.ZIndex = 46
promotionTitle.Parent = promotionPanel

local promotionSubtitle = Instance.new("TextLabel")
promotionSubtitle.Size = UDim2.new(1, -32, 0, 20)
promotionSubtitle.Position = UDim2.new(0, 16, 0, 46)
promotionSubtitle.BackgroundTransparency = 1
promotionSubtitle.Text = "Escolha quem volta pra ajudar:"
promotionSubtitle.TextColor3 = Color3.fromRGB(200, 212, 232)
promotionSubtitle.TextXAlignment = Enum.TextXAlignment.Left
promotionSubtitle.TextSize = 15
promotionSubtitle.Font = Enum.Font.GothamBold
promotionSubtitle.ZIndex = 46
promotionSubtitle.Parent = promotionPanel

local promotionList = Instance.new("Frame")
promotionList.Name = "List"
promotionList.Position = UDim2.new(0, 16, 0, 72)
promotionList.Size = UDim2.new(1, -32, 0, 112)
promotionList.BackgroundTransparency = 1
promotionList.ZIndex = 46
promotionList.Parent = promotionPanel

local promotionListLayout = Instance.new("UIListLayout")
promotionListLayout.FillDirection = Enum.FillDirection.Horizontal
promotionListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
promotionListLayout.Padding = UDim.new(0, 10)
promotionListLayout.SortOrder = Enum.SortOrder.LayoutOrder
promotionListLayout.Parent = promotionList

local PROMO_CARD_SIZE = 100

-- `slot` é uma tabela (não só a Frame) porque o clique precisa ler o uid ATUAL
-- do card, não o de quando ele foi criado: os cards são reaproveitados entre
-- atualizações (a lista de opções pode encolher se uma lápide for destruída no
-- meio da escolha), então o handler fecha sobre `slot` e lê `slot.uid` na hora
-- do clique — nunca um uid capturado de saída.
local function buildPromotionCard()
	local slot = {}

	local card = Instance.new("TextButton")
	card.Name = "Card"
	card.Size = UDim2.new(0, PROMO_CARD_SIZE, 0, PROMO_CARD_SIZE)
	card.BackgroundColor3 = Color3.fromRGB(26, 31, 44)
	card.AutoButtonColor = false
	card.Text = ""
	card.BorderSizePixel = 0
	card.ZIndex = 47
	card.Parent = promotionList

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 10)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Name = "Edge"
	cardStroke.Color = Color3.fromRGB(90, 130, 200)
	cardStroke.Thickness = 1.4
	cardStroke.Parent = card

	local portrait = Instance.new("ImageLabel")
	portrait.Size = UDim2.new(1, -12, 1, -34)
	portrait.Position = UDim2.new(0, 6, 0, 6)
	portrait.BackgroundTransparency = 1
	portrait.ScaleType = Enum.ScaleType.Fit
	portrait.ResampleMode = Enum.ResamplerMode.Pixelated
	portrait.ZIndex = 48
	portrait.Parent = card

	local nameLabel = Instance.new("TextLabel")
	nameLabel.AnchorPoint = Vector2.new(0, 1)
	nameLabel.Position = UDim2.new(0, 4, 1, -4)
	nameLabel.Size = UDim2.new(1, -8, 0, 18)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.ZIndex = 48
	nameLabel.Parent = card

	card.MouseButton1Click:Connect(function()
		if slot.uid then
			GameAction:FireServer("resurrect", slot.uid)
		end
	end)

	slot.card = card
	slot.portrait = portrait
	slot.name = nameLabel
	return slot
end

-- Reaproveitados entre atualizações — igual às linhas da coluna de heróis,
-- criar/destruir Frame a cada snapshot seria trabalho pra nada quando a lista
-- de opções normalmente não muda de um snapshot pro outro.
local promotionCards = {}

local function renderPromotionChoice(state)
	local pending = state.pendingPromotion
	local options = pending and pending.options

	if not options or #options == 0 then
		promotionBackdrop.Visible = false
		promotionPanel.Visible = false
		return
	end

	promotionBackdrop.Visible = true
	promotionPanel.Visible = true

	for index, uid in ipairs(options) do
		local slot = promotionCards[index]
		if not slot then
			slot = buildPromotionCard()
			promotionCards[index] = slot
		end

		slot.card.LayoutOrder = index
		slot.card.Visible = true
		slot.uid = uid

		local hero = heroByUid(uid)
		local data = hero and HeroData.GetById(hero.dataId)
		if data then
			local spriteId = spriteOf(data)
			if spriteId then
				slot.portrait.Image = spriteId
				slot.portrait.ImageRectSize = HeroData.GetFrameSize(data)
				slot.portrait.ImageRectOffset = HeroData.GetFrameOffset(data)
				slot.portrait.BackgroundTransparency = 1
			else
				slot.portrait.Image = ""
				slot.portrait.BackgroundTransparency = 0
				slot.portrait.BackgroundColor3 = data.color
			end
			slot.name.Text = hero.name or data.name
		else
			-- Opcao que o cliente nao consegue resolver (uid fora de state.heroes).
			-- Esconder e mais honesto que deixar um cartao em branco e clicavel: o
			-- clique iria pro servidor com um uid que ele tambem recusaria, e o
			-- jogador ficaria sem saber por que "nao acontece nada".
			slot.uid = nil
			slot.card.Visible = false
		end
	end

	-- sobrou card de uma escolha anterior com mais opções: esconde em vez de
	-- destruir, pro próximo pending com mais gente reaproveitar de novo
	for index = #options + 1, #promotionCards do
		promotionCards[index].card.Visible = false
	end
end

local function hidePromotionChoice()
	promotionBackdrop.Visible = false
	promotionPanel.Visible = false
end

-- ===== CASAS DE PROMOÇÃO (pintura do tabuleiro) =====
-- Inativa/Usada são cores fixas, aplicadas direto no BaseColor da casa — é o
-- MESMO attribute que clearHighlights() lê pra restaurar depois de um hover,
-- então a casa de promoção nunca "esquece" o próprio estado quando o jogador
-- passa o mouse por cima mirando outra coisa. Liberada pulsa entre dois tons
-- de dourado via TweenService (Reverses + RepeatCount -1 fazem o loop sozinhos,
-- sem precisar de RenderStepped nem polling).
--
-- LIMITAÇÃO CONHECIDA: se a casa liberada também estiver destacada como alvo
-- de movimento/ataque do herói selecionado (teria que estar bem perto dela), o
-- pulso e o destaque brigam pela cor por cima um do outro por uns instantes —
-- cosmético, não afeta a jogada. Não vale a complexidade de pausar/retomar a
-- tween só por isso.
-- Chaveado pelo hexId, mas guardando TAMBEM a peca que a tween esta animando.
-- Cada partida gera um tabuleiro novo, com pecas novas de mesmo nome: sem
-- comparar a peca, a guarda "ja existe tween pra C0" daria positivo pra uma
-- tween que anima um bloco ja destruido, e a casa da partida nova nunca seria
-- pintada.
local promotionGlowTweens = {}

local function renderPromotionSquares(state)
	local board = state and state.boardFolder
	if not board then return end

	for _, square in ipairs(state.promotionSquares or {}) do
		local tile = board:FindFirstChild(square.hex)
		if tile and tile:IsA("BasePart") then
			local atual = promotionGlowTweens[square.hex]
			if atual and atual.tile ~= tile then
				atual.tween:Cancel()
				promotionGlowTweens[square.hex] = nil
				atual = nil
			end

			if square.state == "active" then
				if not atual then
					tile:SetAttribute("BaseColor", PROMOTION_ACTIVE_COLOR_LOW)
					-- A cor tem que ir pra LOW ANTES da tween nascer: uma tween
					-- oscila entre o valor que a peça tinha no momento em que
					-- foi criada e o alvo. Sem esta linha ela partia do escuro
					-- da casa trancada e o "brilho" virava um pisca-pisca de
					-- preto a dourado (medido em jogo: 0,15 -> 1,00).
					tile.Color = PROMOTION_ACTIVE_COLOR_LOW
					local tween = TweenService:Create(tile,
						TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
						{ Color = PROMOTION_ACTIVE_COLOR_HIGH })
					tween:Play()
					promotionGlowTweens[square.hex] = { tween = tween, tile = tile }
				end
			else
				if atual then
					atual.tween:Cancel()
					promotionGlowTweens[square.hex] = nil
				end

				local color = (square.state == "used") and fallbackColor(tile) or PROMOTION_INACTIVE_COLOR
				tile:SetAttribute("BaseColor", color)
				tile.Color = color
			end
		end
	end
end

-- O servidor transmite o estado várias vezes por ação (mover manda dois, atacar
-- manda mais um, o fim de partida outro). Sem esta guarda, cada transmissão
-- reescrevia as seis fichas e criava seis tweens que animavam de um valor pro
-- MESMO valor — dezenas de tweens por turno do bot, todos para nada.
-- Só o que o CARD desenha entra aqui. Veneno e gelo não entram mais: eles são
-- desenhados no crachá do tabuleiro, e o modal lê `row.hero`, que é atualizado
-- antes desta guarda — ou seja, continua sempre fresco sem forçar re-render.
local function rowSignature(hero)
	if not hero then return "vazio" end
	return ("%d|%d|%d|%s|%s"):format(hero.dataId, hero.currentHp, hero.attack,
		tostring(hero.isAlive), tostring(hero.sideIndex))
end

local function renderRow(row, hero)
	-- Sempre atualizado, mesmo quando a assinatura não muda: é o que o clique
	-- no card lê pra abrir o modal, e precisa ser a referência mais recente.
	row.hero = hero

	local signature = rowSignature(hero)
	if row.signature == signature then return end
	row.signature = signature

	if not hero then
		row.card.Visible = false
		return
	end

	local data = HeroData.GetById(hero.dataId)
	local accent = hero.sideIndex == 2 and SIDE_TWO_COLOR or SIDE_ONE_COLOR
	local alive = hero.isAlive

	row.card.Visible = true

	local spriteId = spriteOf(data)
	if spriteId then
		row.portrait.Image = spriteId
		row.portrait.ImageRectSize = HeroData.GetFrameSize(data)
		row.portrait.ImageRectOffset = HeroData.GetFrameOffset(data)
		row.portrait.BackgroundTransparency = 1
	else
		-- sem folha de sprite, a cor do herói faz as vezes do retrato
		row.portrait.Image = ""
		row.portrait.BackgroundTransparency = 0
		row.portrait.BackgroundColor3 = alive and (data and data.color or accent) or DEAD_TINT
	end

	-- Morto: retrato apagado e riscado. O Roblox não tem controle de saturação
	-- por elemento de GUI, então "sem cor" aqui é o ImageColor3 puxado pro
	-- cinza-chumbo — some com o vermelho/verde do sprite e some com o destaque.
	row.heroName.Text = hero.name
	row.heroName.TextColor3 = alive
		and Color3.fromRGB(232, 238, 250) or Color3.fromRGB(132, 136, 146)

	row.portrait.ImageColor3 = alive and Color3.new(1, 1, 1) or DEAD_TINT
	row.portrait.ImageTransparency = alive and 0 or 0.15
	row.card.BackgroundColor3 = alive and Color3.fromRGB(24, 27, 37) or DEAD_CARD
	row.stroke.Color = alive and accent or Color3.fromRGB(58, 60, 68)
	row.stroke.Transparency = alive and 0.15 or 0.5

	for _, dash in ipairs(row.cross) do
		dash.Visible = not alive
	end

	row.hpTrack.Visible = alive
	row.hpLabel.Visible = alive
	row.atkLabel.Visible = alive

	if alive then
		local ratio = hero.maxHp > 0 and math.clamp(hero.currentHp / hero.maxHp, 0, 1) or 0
		row.hpLabel.Text = tostring(math.max(hero.currentHp, 0))
		row.hpFill.BackgroundColor3 = ratio > 0.5 and Color3.fromRGB(80, 200, 110)
			or (ratio > 0.25 and Color3.fromRGB(220, 180, 70) or Color3.fromRGB(220, 80, 80))
		TweenService:Create(row.hpFill, TweenInfo.new(0.22), {
			Size = UDim2.fromScale(ratio, 1),
		}):Play()

		row.atkLabel.Text = tostring(hero.attack)
	end
end

local function renderTeams(state)
	local mine, theirs = {}, {}
	for _, hero in ipairs(state.heroes or {}) do
		table.insert(hero.isMine and mine or theirs, hero)
	end

	myTeam.nameLabel.Text = player.DisplayName
	theirTeam.nameLabel.Text = state.opponentName or "Adversário"

	for index, row in ipairs(myTeam.rows) do
		renderRow(row, mine[index])
	end
	for index, row in ipairs(theirTeam.rows) do
		renderRow(row, theirs[index])
	end

	myTeam.frame.Visible = true
	theirTeam.frame.Visible = true
end

local function hideTeams()
	myTeam.frame.Visible = false
	theirTeam.frame.Visible = false
	hideDetail()

	-- Zera as assinaturas: na revanche os heróis voltam com a vida cheia, e uma
	-- assinatura sobrevivente da partida anterior faria a ficha ser pulada e
	-- ficar mostrando o estado do jogo antigo.
	for _, team in ipairs({ myTeam, theirTeam }) do
		for _, row in ipairs(team.rows) do
			row.signature = nil
			row.hero = nil
		end
	end
	counterShown = nil
end

-- ===== DESTAQUE DE FINALIZAÇÃO =====
-- Faixa diagonal com o retrato ampliado de quem abateu. Só dispara em abate por
-- herói: o servidor não manda destaque pra morte por veneno ou Morte Súbita,
-- que não têm autor.
--
-- Vale pros DOIS lados, e é por isso que a faixa muda de cor: um abate seu entra
-- azul e comemorativo, um abate do adversário entra vermelho. Mostrar só as suas
-- vitórias esconderia justamente o golpe que você precisa entender.
local FINISHER_HOLD = 0.85
local FINISHER_IN = 0.26
local FINISHER_OUT = 0.3
local FINISHER_TILT = -6

local finisherLayer = Instance.new("Frame")
finisherLayer.Name = "Finisher"
finisherLayer.Size = UDim2.fromScale(1, 1)
finisherLayer.BackgroundTransparency = 1
finisherLayer.ClipsDescendants = true
finisherLayer.Visible = false
finisherLayer.ZIndex = 30
finisherLayer.Parent = gui

local finisherBand = Instance.new("Frame")
finisherBand.Name = "Band"
finisherBand.AnchorPoint = Vector2.new(0.5, 0.5)
finisherBand.Size = UDim2.new(1.6, 0, 0, 150)
finisherBand.Rotation = FINISHER_TILT
finisherBand.BorderSizePixel = 0
finisherBand.ZIndex = 30
finisherBand.Parent = finisherLayer

-- some nas duas pontas pra faixa não virar um retângulo colado na tela
local bandGradient = Instance.new("UIGradient")
bandGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.18, 0.1),
	NumberSequenceKeypoint.new(0.82, 0.1),
	NumberSequenceKeypoint.new(1, 1),
})
bandGradient.Parent = finisherBand

-- riscos finos acompanhando a inclinação, pra faixa ter movimento
local finisherStreaks = {}
for index, spec in ipairs({ { -34, 5, 0.45 }, { 30, 3, 0.6 }, { 52, 2, 0.75 } }) do
	local streak = Instance.new("Frame")
	streak.Name = "Streak" .. index
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.Position = UDim2.new(0.5, 0, 0.5, spec[1])
	streak.Size = UDim2.new(1, 0, 0, spec[2])
	streak.BorderSizePixel = 0
	streak.BackgroundTransparency = spec[3]
	streak.ZIndex = 31
	streak.Parent = finisherBand
	finisherStreaks[index] = streak
end

-- Retrato fora da faixa (e não dentro): a faixa corta o que passa dela, e a
-- graça é justamente o boneco estourar pra fora em cima e embaixo.
local finisherPortrait = Instance.new("ImageLabel")
finisherPortrait.Name = "Portrait"
finisherPortrait.AnchorPoint = Vector2.new(0.5, 0.5)
finisherPortrait.Size = UDim2.new(0, 230, 0, 290)
finisherPortrait.BackgroundTransparency = 1
finisherPortrait.ScaleType = Enum.ScaleType.Fit
finisherPortrait.ResampleMode = Enum.ResamplerMode.Pixelated
finisherPortrait.Rotation = FINISHER_TILT
finisherPortrait.ZIndex = 33
finisherPortrait.Parent = finisherLayer

local finisherCaption = Instance.new("TextLabel")
finisherCaption.Name = "Caption"
finisherCaption.AnchorPoint = Vector2.new(0, 0.5)
finisherCaption.Size = UDim2.new(0, 420, 0, 46)
finisherCaption.BackgroundTransparency = 1
finisherCaption.TextColor3 = Color3.new(1, 1, 1)
finisherCaption.TextStrokeColor3 = Color3.fromRGB(10, 6, 8)
finisherCaption.TextStrokeTransparency = 0.2
finisherCaption.TextXAlignment = Enum.TextXAlignment.Left
finisherCaption.TextScaled = true
finisherCaption.Font = Enum.Font.GothamBlack
finisherCaption.Rotation = FINISHER_TILT
finisherCaption.ZIndex = 34
finisherCaption.Parent = finisherLayer

local finisherToken = 0

local function playFinisher(info)
	local data = HeroData.GetById(info.dataId)
	local spriteId = spriteOf(data)
	if not spriteId then return end

	finisherToken += 1
	local token = finisherToken

	local accent = info.sideIndex == 2 and SIDE_TWO_COLOR or SIDE_ONE_COLOR
	local deep = info.sideIndex == 2
		and Color3.fromRGB(52, 10, 12) or Color3.fromRGB(12, 26, 58)

	finisherBand.BackgroundColor3 = deep
	bandGradient.Color = ColorSequence.new(deep, accent)
	for _, streak in ipairs(finisherStreaks) do
		streak.BackgroundColor3 = accent
	end

	finisherPortrait.Image = spriteId
	finisherPortrait.ImageRectSize = HeroData.GetFrameSize(data)
	finisherPortrait.ImageRectOffset = HeroData.GetFrameOffset(data)
	finisherPortrait.ImageTransparency = 0

	finisherCaption.Text = ("%s FINALIZOU %s"):format(
		info.name:upper(), (info.victim or "?"):upper())
	finisherCaption.TextTransparency = 0
	finisherCaption.TextStrokeTransparency = 0.2

	-- entram da esquerda; o retrato chega um pouco depois da faixa, e essa
	-- defasagem é o que dá sensação de profundidade em vez de bloco só
	finisherBand.Position = UDim2.new(-0.9, 0, 0.42, 0)
	finisherPortrait.Position = UDim2.new(-0.4, 0, 0.42, 0)
	finisherCaption.Position = UDim2.new(-0.4, 0, 0.42, 0)
	finisherLayer.Visible = true

	local enter = TweenInfo.new(FINISHER_IN, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(finisherBand, enter, { Position = UDim2.new(0.5, 0, 0.42, 0) }):Play()
	TweenService:Create(finisherPortrait,
		TweenInfo.new(FINISHER_IN, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0.05),
		{ Position = UDim2.new(0.26, 0, 0.42, 0) }):Play()
	TweenService:Create(finisherCaption,
		TweenInfo.new(FINISHER_IN, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 0.09),
		{ Position = UDim2.new(0.42, 0, 0.42, 0) }):Play()

	task.delay(FINISHER_IN + FINISHER_HOLD, function()
		if finisherToken ~= token then return end

		local leave = TweenInfo.new(FINISHER_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(finisherBand, leave, {
			Position = UDim2.new(1.7, 0, 0.42, 0), BackgroundTransparency = 1,
		}):Play()
		TweenService:Create(finisherPortrait, leave, {
			Position = UDim2.new(1.5, 0, 0.42, 0), ImageTransparency = 1,
		}):Play()
		TweenService:Create(finisherCaption, leave, {
			Position = UDim2.new(1.6, 0, 0.42, 0), TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()

		task.delay(FINISHER_OUT, function()
			if finisherToken ~= token then return end
			finisherLayer.Visible = false
			finisherBand.BackgroundTransparency = 0
		end)
	end)
end

-- ===== "SUA VEZ" / "ESPERE SUA VEZ" (flash centralizado na tela) =====
local MY_TURN_COLOR = Color3.fromRGB(255, 235, 150)
local WAIT_TURN_COLOR = Color3.fromRGB(255, 150, 150)

local turnFlashLabel = Instance.new("TextLabel")
turnFlashLabel.AnchorPoint = Vector2.new(0.5, 0.5)
turnFlashLabel.Size = UDim2.new(0, 400, 0, 70)
turnFlashLabel.Position = UDim2.new(0.5, 0, 0.4, 0)
turnFlashLabel.BackgroundTransparency = 1
turnFlashLabel.TextColor3 = MY_TURN_COLOR
turnFlashLabel.TextStrokeTransparency = 1
turnFlashLabel.TextScaled = true
turnFlashLabel.Font = Enum.Font.GothamBlack
turnFlashLabel.Text = "Sua vez!"
turnFlashLabel.TextTransparency = 1
turnFlashLabel.Parent = gui

-- O token evita que o fade-out de um flash antigo apague o que acabou de
-- aparecer: quem chegou por último é o único que tem direito de sumir.
local flashToken = 0

local function flashTurnBanner(text, color)
	flashToken += 1
	local token = flashToken

	turnFlashLabel.Text = text
	turnFlashLabel.TextColor3 = color
	turnFlashLabel.TextTransparency = 1
	turnFlashLabel.TextStrokeTransparency = 1
	TweenService:Create(turnFlashLabel, TweenInfo.new(0.2), {
		TextTransparency = 0, TextStrokeTransparency = 0.3,
	}):Play()

	task.delay(1.1, function()
		if flashToken ~= token then return end
		TweenService:Create(turnFlashLabel, TweenInfo.new(0.4), {
			TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()
	end)
end

-- Clique recusado por não ser seu turno. Quem chama isto já filtrou os cliques
-- que caíram no tabuleiro (casa, herói ou barril), então aqui não há risco de
-- apitar por clique no vazio.
local function warnNotYourTurn()
	flashTurnBanner("Espere sua vez", WAIT_TURN_COLOR)
	PlayUiSound("ActionBlocked")
end

local messageLabel = Instance.new("TextLabel")
messageLabel.Size = UDim2.new(0, 460, 0, 30)
messageLabel.Position = UDim2.new(0.5, -230, 0, 58)
messageLabel.BackgroundTransparency = 1
messageLabel.TextColor3 = Color3.fromRGB(255, 225, 130)
messageLabel.TextStrokeTransparency = 0.35
messageLabel.TextScaled = true
messageLabel.Font = Enum.Font.GothamBold
messageLabel.Text = ""
messageLabel.TextTransparency = 1
messageLabel.Parent = gui

-- ===== BOTÃO DE PASSAR TURNO (hexágono com check) =====
local endTurnButton = Instance.new("ImageButton")
endTurnButton.Size = UDim2.new(0, 74, 0, 74)
endTurnButton.Position = UDim2.new(1, -100, 1, -100)
endTurnButton.BackgroundTransparency = 1
endTurnButton.Image = "rbxassetid://87779944037512"
endTurnButton.ImageColor3 = Color3.fromRGB(60, 90, 150)
endTurnButton.Parent = gui

local endTurnCheck = Instance.new("TextLabel")
endTurnCheck.Size = UDim2.fromScale(1, 1)
endTurnCheck.BackgroundTransparency = 1
endTurnCheck.Text = "✓"
endTurnCheck.TextColor3 = Color3.new(1, 1, 1)
endTurnCheck.TextStrokeTransparency = 0.5
endTurnCheck.TextScaled = true
endTurnCheck.Font = Enum.Font.GothamBlack
endTurnCheck.Parent = endTurnButton

endTurnButton.MouseButton1Click:Connect(function()
	if not state or state.phase ~= "battle" then return end
	if not state.isMyTurn then
		warnNotYourTurn()
		return
	end
	GameAction:FireServer("endTurn")
end)

-- ===== DESISTIR (canto inferior esquerdo) =====
-- Mora no canto mais morto da tela e é pequeno de propósito: desistir entrega a
-- partida, então um toque acidental aqui custa o jogo inteiro. Pelo mesmo
-- motivo ele não age direto — abre uma confirmação.
local surrenderButton = Instance.new("TextButton")
surrenderButton.Name = "Surrender"
surrenderButton.AnchorPoint = Vector2.new(0, 1)
surrenderButton.Position = UDim2.new(0, 12, 1, -12)
surrenderButton.Size = UDim2.new(0, 42, 0, 42)
surrenderButton.BackgroundColor3 = Color3.fromRGB(26, 23, 30)
surrenderButton.BackgroundTransparency = 0.25
surrenderButton.Text = ""
surrenderButton.BorderSizePixel = 0
surrenderButton.AutoButtonColor = true
surrenderButton.Visible = false
surrenderButton.Parent = gui

local surrenderCorner = Instance.new("UICorner")
surrenderCorner.CornerRadius = UDim.new(0, 8)
surrenderCorner.Parent = surrenderButton

local surrenderStroke = Instance.new("UIStroke")
surrenderStroke.Color = Color3.fromRGB(150, 90, 90)
surrenderStroke.Thickness = 1.2
surrenderStroke.Transparency = 0.35
surrenderStroke.Parent = surrenderButton

local flagSlot = Instance.new("Frame")
flagSlot.Name = "FlagSlot"
flagSlot.AnchorPoint = Vector2.new(0.5, 0.5)
flagSlot.Position = UDim2.fromScale(0.5, 0.5)
flagSlot.Size = UDim2.new(0, 21, 0, 21) -- 7x7 em células de 3px, sem sobra
flagSlot.BackgroundTransparency = 1
flagSlot.Parent = surrenderButton

PixelIcons.Build("flag", flagSlot, Color3.fromRGB(222, 226, 238), 2)

-- ===== CONFIRMAÇÃO DE DESISTÊNCIA =====
local confirmLayer = Instance.new("Frame")
confirmLayer.Name = "SurrenderConfirm"
confirmLayer.Size = UDim2.fromScale(1, 1)
confirmLayer.BackgroundTransparency = 1
confirmLayer.Visible = false
confirmLayer.ZIndex = 45
confirmLayer.Parent = gui

local confirmBackdrop = Instance.new("TextButton")
confirmBackdrop.Size = UDim2.fromScale(1, 1)
confirmBackdrop.BackgroundColor3 = Color3.fromRGB(6, 7, 11)
confirmBackdrop.BackgroundTransparency = 0.45
confirmBackdrop.BorderSizePixel = 0
confirmBackdrop.Text = ""
confirmBackdrop.AutoButtonColor = false
confirmBackdrop.ZIndex = 45
confirmBackdrop.Parent = confirmLayer

local confirmPanel = Instance.new("Frame")
confirmPanel.AnchorPoint = Vector2.new(0.5, 0.5)
confirmPanel.Position = UDim2.fromScale(0.5, 0.5)
confirmPanel.Size = UDim2.new(0, 320, 0, 164)
confirmPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
confirmPanel.BorderSizePixel = 0
confirmPanel.ZIndex = 46
confirmPanel.Parent = confirmLayer

local confirmCorner = Instance.new("UICorner")
confirmCorner.CornerRadius = UDim.new(0, 12)
confirmCorner.Parent = confirmPanel

local confirmStroke = Instance.new("UIStroke")
confirmStroke.Color = Color3.fromRGB(190, 90, 90)
confirmStroke.Thickness = 2
confirmStroke.Transparency = 0.25
confirmStroke.Parent = confirmPanel

local confirmTitle = Instance.new("TextLabel")
confirmTitle.Size = UDim2.new(1, -24, 0, 30)
confirmTitle.Position = UDim2.new(0, 12, 0, 14)
confirmTitle.BackgroundTransparency = 1
confirmTitle.Text = "Desistir da partida?"
confirmTitle.TextColor3 = Color3.new(1, 1, 1)
confirmTitle.TextScaled = true
confirmTitle.Font = Enum.Font.GothamBlack
confirmTitle.ZIndex = 46
confirmTitle.Parent = confirmPanel

local confirmText = Instance.new("TextLabel")
confirmText.Size = UDim2.new(1, -28, 0, 40)
confirmText.Position = UDim2.new(0, 14, 0, 48)
confirmText.BackgroundTransparency = 1
confirmText.Text = ""
confirmText.TextColor3 = Color3.fromRGB(200, 208, 224)
confirmText.TextWrapped = true
confirmText.TextSize = 14
confirmText.Font = Enum.Font.Gotham
confirmText.ZIndex = 46
confirmText.Parent = confirmPanel

local function confirmButton(name, text, color, alignRight)
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(alignRight and 1 or 0, 1)
	button.Position = UDim2.new(alignRight and 1 or 0, alignRight and -16 or 16, 1, -16)
	button.Size = UDim2.new(0.5, -24, 0, 42)
	button.BackgroundColor3 = color
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Text = text
	button.TextSize = 17
	button.Font = Enum.Font.GothamBold
	button.BorderSizePixel = 0
	button.ZIndex = 47
	button.Parent = confirmPanel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	return button
end

local keepPlayingButton = confirmButton("KeepPlaying", "Continuar", Color3.fromRGB(60, 70, 90), false)
local giveUpButton = confirmButton("GiveUp", "Desistir", Color3.fromRGB(170, 60, 60), true)

local function closeConfirm()
	confirmLayer.Visible = false
end

confirmBackdrop.MouseButton1Click:Connect(closeConfirm)
keepPlayingButton.MouseButton1Click:Connect(closeConfirm)

surrenderButton.MouseButton1Click:Connect(function()
	if not state or state.phase ~= "battle" then return end

	-- O texto muda com o modo porque a consequência muda: contra o bot ninguém
	-- recebe nada (o AwardAbandon ignora lado sem jogador), em PvP o adversário
	-- leva a vitória. Prometer punição que não existe faz o jogador desconfiar
	-- do aviso da próxima vez.
	confirmText.Text = state.vsBot
		and "A partida acaba na hora e você volta pro lobby. Nenhum XP é pago."
		or "Seu adversário leva a vitória e o XP dela. Você não ganha nada."

	confirmLayer.Visible = true
end)

giveUpButton.MouseButton1Click:Connect(function()
	closeConfirm()
	GameAction:FireServer("leaveMatch")
end)

-- O painel de detalhe do herói selecionado (nome, ATK/HP, lista de habilidades)
-- foi REMOVIDO daqui. Ele ocupava 210x96 no canto inferior esquerdo, em cima do
-- tabuleiro, pra repetir o que o jogador já enxerga: o crachá de ataque e vida
-- fica embaixo do próprio boneco, a vida também está na coluna de retratos, e as
-- habilidades ele leu no draft. Quem quiser rever a ficha completa tem o menu do
-- lobby. As colunas das laterais continuam sendo a leitura rápida da partida.

-- ===== PAINEL DE FIM DE PARTIDA =====
local resultPanel = Instance.new("Frame")
resultPanel.Size = UDim2.new(0, 320, 0, 220)
resultPanel.Position = UDim2.new(0.5, -160, 0.5, -110)
resultPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
resultPanel.BackgroundTransparency = 0.1
resultPanel.BorderSizePixel = 0
resultPanel.Visible = false
resultPanel.Parent = gui

local resultCorner = Instance.new("UICorner")
resultCorner.CornerRadius = UDim.new(0, 12)
resultCorner.Parent = resultPanel

local resultLabel = Instance.new("TextLabel")
resultLabel.Size = UDim2.new(1, -20, 0, 60)
resultLabel.Position = UDim2.new(0, 10, 0, 16)
resultLabel.BackgroundTransparency = 1
resultLabel.TextScaled = true
resultLabel.Font = Enum.Font.GothamBold
resultLabel.Parent = resultPanel

local replayButton = Instance.new("TextButton")
replayButton.Size = UDim2.new(1, -60, 0, 46)
replayButton.Position = UDim2.new(0, 30, 1, -122)
replayButton.BackgroundColor3 = Color3.fromRGB(70, 150, 90)
replayButton.TextColor3 = Color3.new(1, 1, 1)
replayButton.Font = Enum.Font.GothamBold
replayButton.TextSize = 20
replayButton.Text = "Jogar novamente"
replayButton.BorderSizePixel = 0
replayButton.Parent = resultPanel

local replayCorner = Instance.new("UICorner")
replayCorner.CornerRadius = UDim.new(0, 8)
replayCorner.Parent = replayButton

local lobbyButton = Instance.new("TextButton")
lobbyButton.Size = UDim2.new(1, -60, 0, 46)
lobbyButton.Position = UDim2.new(0, 30, 1, -66)
lobbyButton.BackgroundColor3 = Color3.fromRGB(60, 70, 90)
lobbyButton.TextColor3 = Color3.new(1, 1, 1)
lobbyButton.Font = Enum.Font.GothamBold
lobbyButton.TextSize = 20
lobbyButton.Text = "Voltar pro lobby"
lobbyButton.BorderSizePixel = 0
lobbyButton.Parent = resultPanel

local lobbyCorner = Instance.new("UICorner")
lobbyCorner.CornerRadius = UDim.new(0, 8)
lobbyCorner.Parent = lobbyButton

replayButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("replay")
end)

lobbyButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("leaveMatch")
end)

-- Implementacao do heroByUid declarado la em cima. Em Lua uma funcao so enxerga
-- os locais declarados ANTES dela, e este e usado tanto pela linha de mira
-- quanto pelo modal da Casa de Promocao, que vem antes daqui.
function heroByUid(uid)
	if not state then return nil end
	for _, hero in ipairs(state.heroes) do
		if hero.uid == uid then return hero end
	end
	return nil
end

-- ===== SETA DE MIRA =====
-- Seta pontilhada que sai do herói selecionado e termina na casa sob o cursor.
-- Serve pra responder "esse boneco vai parar ONDE?" antes do clique — de cima e
-- com o tabuleiro em perspectiva, contar casas no olho erra fácil.
--
-- É tudo local: as peças nascem no cliente e não replicam, então cada jogador
-- vê só a própria mira. Um adversário enxergando pra onde você está apontando
-- entregaria a jogada antes dela acontecer.
local AIM_LIFT = 2.4 -- altura acima do tabuleiro
local AIM_DASH_LENGTH = 1.5
local AIM_DASH_GAP = 1.2
local AIM_DASH_THICKNESS = 0.5
-- Folgas curtas de propósito: entre duas casas vizinhas o centro fica a ~10,4
-- studs, e um par de folgas maior comia o traço inteiro justamente no caso mais
-- comum — mover uma casa.
local AIM_START_PAD = 2.4 -- não cola no herói
local AIM_END_PAD = 3.4 -- onde os traços param pra não invadir a ponta
local AIM_MAX_DASHES = 48
local AIM_FLOW_SPEED = 2.4 -- studs por segundo que os traços "andam" pro alvo
local AIM_NEUTRAL_COLOR = Color3.fromRGB(150, 165, 190)
-- Vermelho mais aceso que o ATTACK_COLOR das casas: a linha é fina e fica sobre
-- um tabuleiro claro, então precisa de mais brilho que uma casa inteira pintada.
local AIM_ATTACK_COLOR = Color3.fromRGB(255, 62, 52)

-- ===== CURVATURA =====
-- O traçado é uma Bézier quadrática (origem, um ponto de controle, alvo) em vez
-- de uma reta. Não é a reta "dobrada" na hora de desenhar: a curva é amostrada
-- e os traços caminham SOBRE ela, cada um girado na tangente do próprio ponto.
--
-- O ponto de controle sai do meio do caminho deslocado pra UM lado fixo em
-- relação à direção do golpe (a perpendicular no plano do tabuleiro). Fixo, e
-- não escolhido por caso, é o que faz esquerda, direita, cima, baixo e as
-- diagonais curvarem todas do mesmo jeito, sem a curva "virar" quando o cursor
-- cruza um eixo.
--
-- Numa Bézier quadrática a curva passa na METADE do deslocamento do controle,
-- então os números aqui rendem metade disso em desvio real — daí parecerem
-- generosos pra uma curva que é discreta na tela.
local AIM_CURVE_SAMPLES = 24 -- segmentos da amostragem; 24 já fica liso nesta escala
local AIM_CURVE_RATIO = 0.34 -- quanto da distância vira desvio lateral
local AIM_CURVE_MAX = 13 -- teto pro tiro longo não virar um arco exagerado
local AIM_CURVE_RISE = 2.6 -- levanta o meio do arco: a linha solta do tabuleiro
local AIM_TAIL_FADE = 0.4 -- quanto o começo do traçado escurece (0 = sem gradiente)

-- Ponta da seta: duas farpas abertas a partir do bico. Não é um bico fechado
-- porque a câmera olha o tabuleiro de cima e enviesada — um triângulo cheio
-- vira um borrão nessa perspectiva, enquanto duas barras continuam lendo como
-- "aponta pra cá" de qualquer ângulo.
local ARROW_HEAD_LENGTH = 3.6
local ARROW_HEAD_THICKNESS = 0.6 -- acompanha a espessura do traço, senão a ponta some perto dele
local ARROW_HEAD_SPREAD = 38 -- graus de abertura de cada farpa

local aimFolder = Instance.new("Folder")
aimFolder.Name = "AimLine"
aimFolder.Parent = Workspace

local function newAimPart(name)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Parent = aimFolder
	return part
end

local aimDashes = {}
for index = 1, AIM_MAX_DASHES do
	aimDashes[index] = newAimPart("Dash" .. index)
end

local aimBarbs = {
	newAimPart("ArrowBarbLeft"),
	newAimPart("ArrowBarbRight"),
}

local function hideAim()
	for _, dash in ipairs(aimDashes) do
		dash.Transparency = 1
	end
	for _, barb in ipairs(aimBarbs) do
		barb.Transparency = 1
	end
end

hideAim()

-- A posição vem da PEÇA do tabuleiro, não do HexGrid: o offset do módulo é
-- definido pelo CameraController num script separado, e depender dessa ordem de
-- carregamento daria uma linha apontando pro lugar errado nos primeiros quadros.
local function tilePosition(hexId)
	local board = state and state.boardFolder
	local tile = board and hexId and board:FindFirstChild(hexId)
	if not tile then return nil end
	if tile:IsA("BasePart") then return tile.Position end
	if tile:IsA("Model") then return tile:GetPivot().Position end
	return nil
end

-- Amostragem da curva. As duas tabelas são criadas UMA vez e reescritas a cada
-- quadro: isto roda em RenderStepped, e alocar duas tabelas por quadro só pra
-- jogar fora é lixo garantido pro coletor no meio da jogada.
local AIM_POINT_COUNT = AIM_CURVE_SAMPLES + 1
local curvePoints = table.create(AIM_POINT_COUNT)
local curveDistances = table.create(AIM_POINT_COUNT)

-- Onde fica o "cotovelo" da curva. Meio do caminho, empurrado pra perpendicular
-- (mesmo lado sempre) e levantado um pouco.
local function aimControlPoint(origin, target)
	local middle = origin:Lerp(target, 0.5)

	-- só o plano do tabuleiro decide o lado: se o desnível entrasse na conta, um
	-- alvo mais alto ou mais baixo inclinaria a curva sem motivo
	local delta = target - origin
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude
	if distance < 0.01 then return middle end

	local direction = flat.Unit
	local side = Vector3.new(-direction.Z, 0, direction.X)
	local bend = math.min(distance * AIM_CURVE_RATIO, AIM_CURVE_MAX)

	return middle + side * bend + Vector3.new(0, AIM_CURVE_RISE, 0)
end

-- Preenche curvePoints/curveDistances e devolve o comprimento do traçado.
-- O comprimento é somado segmento a segmento (não é a distância em linha reta)
-- porque é ele que os traços usam pra caminhar em passo constante — medir pela
-- reta faria o espaçamento encolher conforme a curva abre.
local function sampleAimCurve(origin, control, target)
	curvePoints[1] = origin
	curveDistances[1] = 0

	local previous = origin
	local total = 0

	for index = 1, AIM_CURVE_SAMPLES do
		local t = index / AIM_CURVE_SAMPLES
		local u = 1 - t
		local point = origin * (u * u) + control * (2 * u * t) + target * (t * t)

		total += (point - previous).Magnitude
		curvePoints[index + 1] = point
		curveDistances[index + 1] = total
		previous = point
	end

	return total
end

-- Ponto e tangente a `distance` studs do começo do traçado.
--
-- `searchFrom` é o segmento onde a busca começa: os traços são colocados em
-- ordem crescente de distância, então o cursor só anda pra frente e a varredura
-- inteira custa uma passada pela curva, não uma busca por traço.
local function aimCurveAt(distance, searchFrom)
	local index = math.max(searchFrom, 1)
	while index < AIM_CURVE_SAMPLES and curveDistances[index + 1] < distance do
		index += 1
	end

	local a, b = curvePoints[index], curvePoints[index + 1]
	local segmentStart = curveDistances[index]
	local segmentLength = curveDistances[index + 1] - segmentStart
	local alpha = segmentLength > 0 and (distance - segmentStart) / segmentLength or 0

	local direction = b - a
	direction = direction.Magnitude > 1e-4 and direction.Unit or Vector3.new(0, 0, 1)

	return a:Lerp(b, math.clamp(alpha, 0, 1)), direction, index
end

local function drawAim(fromPosition, toPosition, color)
	local lift = Vector3.new(0, AIM_LIFT, 0)
	local origin = fromPosition + lift
	local target = toPosition + lift

	if (target - origin).Magnitude < 0.1 then
		hideAim()
		return
	end

	local length = sampleAimCurve(origin, aimControlPoint(origin, target), target)
	local step = AIM_DASH_LENGTH + AIM_DASH_GAP

	-- o resto móvel faz os traços marcharem em direção ao alvo
	local travelled = AIM_START_PAD + (os.clock() * AIM_FLOW_SPEED) % step
	local limit = length - AIM_END_PAD
	local used = 0
	local cursor = 1

	while travelled < limit and used < AIM_MAX_DASHES do
		used += 1

		local position, direction
		position, direction, cursor = aimCurveAt(travelled, cursor)

		-- o traço engrossa e acende conforme se aproxima do alvo: dá o sentido
		-- da trajetória mesmo num quadro parado, sem depender da animação
		local progress = travelled / length

		local dash = aimDashes[used]
		local thickness = AIM_DASH_THICKNESS * (0.82 + 0.36 * progress)
		dash.Size = Vector3.new(thickness, thickness, AIM_DASH_LENGTH)
		dash.CFrame = CFrame.new(position, position + direction)
		dash.Color = color:Lerp(Color3.new(0, 0, 0), (1 - progress) * AIM_TAIL_FADE)
		dash.Transparency = 0.15
		travelled += step
	end

	for index = used + 1, AIM_MAX_DASHES do
		aimDashes[index].Transparency = 1
	end

	-- Bico no centro da casa mirada; as farpas abrem pra trás a partir dele.
	-- A direção é a tangente do FIM da curva, não a reta origem->alvo: com o
	-- traçado chegando de lado, uma ponta alinhada à reta apontaria pra fora do
	-- próprio rastro que ela termina.
	local tip = curvePoints[AIM_POINT_COUNT] - curvePoints[AIM_POINT_COUNT - 1]
	tip = tip.Magnitude > 1e-4 and tip.Unit or Vector3.new(0, 0, 1)

	local base = CFrame.new(target, target + tip)
	for index, barb in ipairs(aimBarbs) do
		local sign = (index == 1) and 1 or -1
		barb.Size = Vector3.new(ARROW_HEAD_THICKNESS, ARROW_HEAD_THICKNESS, ARROW_HEAD_LENGTH)
		barb.CFrame = base
			* CFrame.Angles(0, math.rad(sign * (180 - ARROW_HEAD_SPREAD)), 0)
			* CFrame.new(0, 0, -ARROW_HEAD_LENGTH / 2)
		barb.Color = color
		barb.Transparency = 0.1
	end
end

-- Qual casa está sob o cursor. Passar o mouse em cima de um HERÓI conta como
-- apontar pra casa dele, senão a linha piscava toda vez que o cursor cruzasse
-- um boneco no caminho até o alvo.
local function hoveredHexId()
	local target = mouse.Target
	if not target then return nil end

	local hexId = target:GetAttribute("HexId")
	if hexId then return hexId end

	local heroUid = target:GetAttribute("HeroUid")
	local hero = heroUid and state and heroByUid(heroUid)
	if hero then return hero.position end

	-- o barril também conta como "estou apontando pra casa dele"
	local barrelUid = target:GetAttribute("BarrelUid")
	if barrelUid and state then
		for _, barrel in ipairs(state.barrels or {}) do
			if barrel.uid == barrelUid then return barrel.position end
		end
	end
	return nil
end

local function updateAim()
	if not (state and state.phase == "battle" and state.isMyTurn and selectedUid) then
		hideAim()
		return
	end

	local hero = heroByUid(selectedUid)
	if not (hero and hero.isAlive) then
		hideAim()
		return
	end

	-- A seta nasce junto com as casas destacadas, não junto com a seleção. Um
	-- herói que já moveu e já atacou continua selecionável (o painel de detalhe
	-- vive disso), mas não tem pra onde ir — apontar uma seta ali prometeria uma
	-- jogada que o clique ia recusar.
	if next(moveTargets) == nil and next(attackTargets) == nil then
		hideAim()
		return
	end

	local hexId = hoveredHexId()
	if not hexId or hexId == hero.position then
		hideAim()
		return
	end

	local fromPosition = tilePosition(hero.position)
	local toPosition = tilePosition(hexId)
	if not (fromPosition and toPosition) then
		hideAim()
		return
	end

	-- a cor já diz o que vai acontecer no clique, sem precisar ler a casa.
	-- Mirar ataque usa um vermelho próprio, mais aceso que o das casas: a linha
	-- é fina e passa por cima do tabuleiro claro, onde o tom das casas apaga.
	local color = AIM_NEUTRAL_COLOR
	if attackTargets[hexId] then
		color = AIM_ATTACK_COLOR
	elseif moveTargets[hexId] then
		color = MOVE_COLOR
	end

	drawAim(fromPosition, toPosition, color)
end

-- RenderStepped, e não Heartbeat: a linha acompanha o cursor, então precisa ser
-- redesenhada no mesmo quadro em que a câmera e o mouse já se moveram — em
-- Heartbeat ela ficaria um quadro atrás e daria a impressão de arrastar.
RunService.RenderStepped:Connect(updateAim)

-- ===== DESTAQUES =====
local function clearHighlights()
	for part in pairs(savedColors) do
		if part.Parent then
			part.Color = part:GetAttribute("BaseColor") or fallbackColor(part)
		end
	end
	savedColors, moveTargets, attackTargets = {}, {}, {}
end

-- O tabuleiro vem no snapshot: com várias partidas rodando, procurar "Board"
-- pelo nome no Workspace acharia a arena de outra dupla.
local function paint(hexId, color)
	local board = state and state.boardFolder
	local tile = board and board:FindFirstChild(hexId)
	if tile and tile:IsA("BasePart") then
		if savedColors[tile] == nil then savedColors[tile] = true end
		tile.Color = color
	end
end

local function selectHero(uid)
	clearHighlights()

	local hero = heroByUid(uid)
	if not hero or not hero.isMine or not hero.isAlive then
		selectedUid = nil
		return
	end

	-- mesma corrida da zona de largada: nos primeiros frames o Board pode
	-- ainda não ter sido replicado e o paint falharia calado
	if not (state.boardFolder and state.boardFolder.Parent) then
		task.delay(0.15, function()
			if selectedUid == uid then selectHero(uid) end
		end)
	end

	selectedUid = uid

	local blocked, enemyAt, graveAt = {}, {}, {}
	for _, other in ipairs(state.heroes) do
		if other.isAlive then
			blocked[other.position] = true
			if not other.isMine then
				enemyAt[other.position] = other.uid
			end
		elseif not other.graveDestroyed then
			-- Lápide de pé bloqueia passagem como sempre bloqueou. Uma vez
			-- destruída ela some do tabuleiro (o servidor libera o hex em
			-- AttackGrave), e aqui é onde o cliente para de fingir que ainda
			-- tem alguma coisa lá.
			blocked[other.position] = true
			if not other.isMine then
				graveAt[other.position] = other.uid
			end
		end
	end

	-- Barril entra nas duas listas: bloqueia passagem como qualquer coisa em pé
	-- na casa, e é alvo de ataque como um inimigo. Quem decide o que acontece no
	-- clique é o servidor — aqui ele só precisa ser clicável e não prometer
	-- passagem por cima.
	local barrelAt = {}
	for _, barrel in ipairs(state.barrels or {}) do
		blocked[barrel.position] = true
		barrelAt[barrel.position] = barrel.uid
	end

	-- Casa de promoção trancada se comporta como parede — mesma regra do
	-- servidor (ver PromotionLocked no MatchManager). Sem isto o cliente
	-- pintaria a casa como destino válido e o clique seria recusado do outro
	-- lado, que é a pior combinação: promete a jogada e não entrega.
	for _, square in ipairs(state.promotionSquares or {}) do
		if square.state == "inactive" then
			blocked[square.hex] = true
		end
	end

	local isFree = function(hexId) return not blocked[hexId] end

	-- o moveRange já vem descontado do congelamento pelo servidor
	if not hero.hasMoved and not hero.hasAttacked then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.moveRange, isFree)) do
			if isFree(hexId) then
				moveTargets[hexId] = true
				paint(hexId, MOVE_COLOR)
			end
		end
	end

	if not hero.hasAttacked then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.attackRange, isFree)) do
			if enemyAt[hexId] then
				attackTargets[hexId] = enemyAt[hexId]
				moveTargets[hexId] = nil
				paint(hexId, ATTACK_COLOR)
			elseif barrelAt[hexId] then
				-- âmbar em vez do vermelho de inimigo: bater no barril é uma
				-- jogada diferente de bater em gente, e a cor avisa isso antes
				-- do clique
				attackTargets[hexId] = barrelAt[hexId]
				moveTargets[hexId] = nil
				paint(hexId, BARREL_COLOR)
			elseif graveAt[hexId] then
				attackTargets[hexId] = graveAt[hexId]
				moveTargets[hexId] = nil
				paint(hexId, GRAVE_ATTACK_COLOR)
			end
		end
	end
end

-- ===== CLIQUES =====
mouse.Button1Down:Connect(function()
	if not state or state.phase ~= "battle" then return end

	local target = mouse.Target
	if not target then return end

	local heroUid = target:GetAttribute("HeroUid")
	local hexId = target:GetAttribute("HexId")
	local barrelUid = target:GetAttribute("BarrelUid")

	-- fora do turno o clique não faz nada, mas ficar em silêncio parecia bug:
	-- avisa sempre que a tentativa foi no tabuleiro (casa, herói ou barril)
	if not state.isMyTurn then
		if heroUid or hexId or barrelUid then
			warnNotYourTurn()
		end
		return
	end

	-- clique no próprio barril: mesma jogada de clicar na casa dele
	if barrelUid and selectedUid then
		for _, barrel in ipairs(state.barrels or {}) do
			if barrel.uid == barrelUid and attackTargets[barrel.position] then
				GameAction:FireServer("attack", selectedUid, barrelUid)
				return
			end
		end
		return
	end

	if heroUid then
		local hero = heroByUid(heroUid)
		if hero and hero.isMine then
			local newUid = heroUid == selectedUid and "" or heroUid
			if newUid ~= "" then PlayUiSound("HeroSelectBattle") end
			selectHero(newUid)
		elseif selectedUid and hero and attackTargets[hero.position] then
			GameAction:FireServer("attack", selectedUid, hero.uid)
		end
		return
	end

	if hexId and selectedUid then
		if attackTargets[hexId] then
			GameAction:FireServer("attack", selectedUid, attackTargets[hexId])
		elseif moveTargets[hexId] then
			GameAction:FireServer("move", selectedUid, hexId)
		end
	end
end)

-- ===== FILA DE MENSAGENS (uma de cada vez, tipo tooltip) =====
local messageQueue = {}
local messageBusy = false

local function pumpMessages()
	if messageBusy then return end

	local text = table.remove(messageQueue, 1)
	if not text then return end

	messageBusy = true
	messageLabel.Text = text
	messageLabel.TextTransparency = 1
	TweenService:Create(messageLabel, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()

	task.delay(2.0, function()
		TweenService:Create(messageLabel, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		task.wait(0.35)
		messageBusy = false
		pumpMessages()
	end)
end

local function queueMessage(text)
	if not text or text == "" then return end
	table.insert(messageQueue, text)
	pumpMessages()
end

-- ===== CRONÔMETRO LOCAL =====
RunService.Heartbeat:Connect(function(dt)
	if secondsLeft then
		secondsLeft = math.max(0, secondsLeft - dt)
		timerLabel.Visible = secondsLeft <= 10
		if secondsLeft <= 10 then
			timerLabel.Text = ("%d"):format(math.ceil(secondsLeft))
		end
	end
end)

-- ===== ESTADO =====
MatchUpdate.OnClientEvent:Connect(function(newState)
	state = newState

	if state.message then
		queueMessage(state.message)
	end

	-- antes de decidir a fase: o golpe que encerra a partida também merece o
	-- destaque, e ele chega no mesmo snapshot que marca "finished"
	if state.finisher then
		playFinisher(state.finisher)
	end

	-- ANTES do desvio por fase: as casas de promoção são pintadas em TODAS as
	-- fases, inclusive no posicionamento. Elas fazem parte do tabuleiro desde o
	-- começo da partida, e ver as duas apagadas enquanto se escolhe onde largar
	-- os heróis é justamente o que ensina que elas existem e que ainda não
	-- valem. Só mexe em cor de casa, então não depende da GUI de batalha.
	renderPromotionSquares(state)

	if state.phase == "finished" then
		gui.Enabled = true
		turnPanel.Visible = false
		timerLabel.Visible = false
		counterBadge.Visible = false
		endTurnButton.Visible = false
		-- acabou: não há mais o que desistir, e o painel de resultado já oferece
		-- "voltar pro lobby"
		surrenderButton.Visible = false
		closeConfirm()
		resultPanel.Visible = true
		secondsLeft = nil
		wasMyTurn = false

		-- as colunas continuam: no fim da partida elas viram o placar do que
		-- sobrou de cada lado, e o painel de resultado fica no meio, sem tapar
		renderTeams(state)

		-- o servidor já manda o resultado do ponto de vista de quem recebe
		if state.winner == "draw" then
			resultLabel.Text = "Empate"
			resultLabel.TextColor3 = Color3.fromRGB(215, 215, 225)
		else
			resultLabel.Text = state.winner == "win" and "Vitória!" or "Derrota"
			resultLabel.TextColor3 = state.winner == "win"
				and Color3.fromRGB(130, 230, 150) or Color3.fromRGB(230, 120, 120)
		end

		-- o servidor manda o estado final uma vez, mas guardamos mesmo assim
		-- pra revanche não empilhar dois toques
		if not resultPlayed then
			resultPlayed = true
			PlayUiSound(state.winner == "win" and "Victory" or "Defeat")
		end

		hidePromotionChoice()
		clearHighlights()
		selectedUid = nil
		return
	end

	if state.phase ~= "battle" then
		gui.Enabled = false
		counterBadge.Visible = false
		surrenderButton.Visible = false
		closeConfirm()
		hideTeams()
		hidePromotionChoice()
		clearHighlights()
		selectedUid = nil
		return
	end

	gui.Enabled = true
	turnPanel.Visible = true
	resultPanel.Visible = false

	-- Disponível o turno inteiro, inclusive na vez do adversário: quem quer sair
	-- não deveria ter que esperar a própria vez pra conseguir.
	surrenderButton.Visible = true

	counterBadge.Visible = true
	renderCounterBadge(state.counterAttackUsed)
	renderTeams(state)
	-- renderPromotionSquares roda lá em cima, antes do desvio por fase
	renderPromotionChoice(state)
	resultPlayed = false
	endTurnButton.Visible = true
	endTurnButton.Active = state.isMyTurn
	endTurnButton.ImageColor3 = state.isMyTurn
		and Color3.fromRGB(60, 90, 150) or Color3.fromRGB(65, 65, 72)
	endTurnCheck.TextTransparency = state.isMyTurn and 0 or 0.5

	turnLabel.Text = ("Turno %d%s"):format(
		state.turnNumber,
		state.suddenDeath and "  ☠" or ""
	)
	turnLabel.TextColor3 = state.suddenDeath
		and Color3.fromRGB(255, 140, 140) or Color3.new(1, 1, 1)

	-- Só na VIRADA (false -> true), não a cada snapshot: o servidor transmite
	-- várias vezes por ação, e sem essa guarda o som repetiria no meio do turno.
	-- O aviso sonoro importa porque o turno do adversário pode demorar e o
	-- jogador desvia o olhar da tela — o banner sozinho passa despercebido.
	if state.isMyTurn and not wasMyTurn then
		flashTurnBanner("Sua vez!", MY_TURN_COLOR)
		-- Sem Sound chamado "TurnStart" em ReplicatedStorage.Sounds, o
		-- PlayUiSound sai calado — o banner continua funcionando sozinho.
		PlayUiSound("TurnStart")
	elseif wasMyTurn and not state.isMyTurn then
		-- Virada pro outro lado: o turno ACABOU. Sem banner de propósito — a
		-- tela já mostra o turno do adversário começando, e um segundo aviso
		-- escrito no meio disso vira poluição. O som sozinho fecha o ciclo.
		PlayUiSound("TurnEnd")
	end
	wasMyTurn = state.isMyTurn

	secondsLeft = state.turnSecondsLeft
	if not secondsLeft then timerLabel.Visible = false end

	local previous = selectedUid
	clearHighlights()
	selectedUid = nil

	-- a seleção sobrevive à atualização do estado: sem isto, cada snapshot
	-- (e são vários por ação) apagaria as casas destacadas no meio da jogada
	if state.isMyTurn and previous then
		local hero = heroByUid(previous)
		if hero and hero.isAlive then
			selectHero(previous)
		end
	end
end)
