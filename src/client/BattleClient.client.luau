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
local COLOR_A = GameConfig.HEX_COLOR_A
local COLOR_B = GameConfig.HEX_COLOR_B

-- ===== CASAS DE PROMOÇÃO (cores por estado) =====
-- Inativa: escura, quase apagada — ainda não é nada. Liberada: dourado quente,
-- o mesmo tom da moldura dos crachás (BADGE_GOLD no HeroView), com um pulso
-- entre os dois tons pra "quase brilhando". Usada: volta pro checkerboard
-- comum da própria coluna — ela cumpriu o papel e se mistura de novo ao
-- tabuleiro normal, sem chamar mais atenção.
--
-- Os três tons desceram junto com a luz da taverna. O inativo era azul-chumbo,
-- a única cor FRIA num tabuleiro de pedra quente — lia como casa quebrada, não
-- como casa apagada; agora é a própria pedra escurecida. E o dourado alto batia
-- 255 no vermelho: com a lareira e as janelas acesas em cima dele, a casa
-- passava do Threshold do Bloom e virava um borrão branco a cada pulso, bem no
-- momento em que ela mais precisa ser lida.
--
-- A DO ADVERSÁRIO É OUTRA COR, e não a mesma dourada. As duas casas ficam nas
-- pontas opostas da coluna C: a SUA é a distante (6 casas da largada), a dele é
-- a que encosta na sua linha de largada (1 passo). Pintadas iguais, o caminho
-- óbvio era pisar na de um passo — a do inimigo —, o servidor recusava em
-- silêncio e a mecânica inteira parecia quebrada. Verde-pedra frio, estático,
-- sem pulso: continua legível como casa especial, sem convidar ninguém a ir lá.
local PROMOTION_INACTIVE_COLOR = Color3.fromRGB(52, 44, 38)
local PROMOTION_ACTIVE_COLOR_LOW = Color3.fromRGB(120, 92, 34)
local PROMOTION_ACTIVE_COLOR_HIGH = Color3.fromRGB(196, 158, 78)
local PROMOTION_ENEMY_COLOR = Color3.fromRGB(48, 62, 70)

local function fallbackColor(tile)
	local col = string.byte(tile.Name, 1) - string.byte("A", 1)
	return (col % 2 == 0) and COLOR_A or COLOR_B
end

local state = nil

-- Declarado AQUI, e nao junto da implementacao la embaixo, porque o destaque
-- azul da Casa de Promocao (renderPromotionResurrect) precisa dele umas 600
-- linhas antes. Com `local function` no ponto da implementacao o nome virava
-- global nil aqui em cima. Forward declaration resolve sem ter que mover
-- funcao nenhuma de lugar.
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
	sound.Volume = template.Volume * GameConfig.MASTER_VOLUME
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- ===== UI =====
local gui = Instance.new("ScreenGui")
gui.Name = "BattleGui"
gui.DisplayOrder = 5
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

-- Sub-linha dos pedaços do Golem dentro do card do corpo. 11px de altura é o que
-- deixa as duas caberem na barriga do card (y 16..38) sem encostar no retrato
-- nem na faixa do nome; 9pt é o menor tamanho em que dois dígitos ainda se leem.
local SUB_LINE_H = 11
local SUB_TEXT_SIZE = 9

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

local STATUS_BADGES = {
	{ key = "frozen", glyph = "❄", color = Color3.fromRGB(150, 225, 255) },
	{ key = "poison", glyph = "☠", color = Color3.fromRGB(150, 245, 110) },
	{ key = "shock", glyph = "⚡", color = Color3.fromRGB(255, 226, 90) },
}

local function statusOf(hero)
	return {
		frozen = hero.frozen == true,
		poison = (hero.poisonTurns or 0) > 0,
		shock = hero.paralyzed == true or (hero.charge or 0) > 0,
	}
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

		-- ===== SUB-LINHAS DOS PEDAÇOS (Golem estilhaçado) =====
		-- O Golem morre e vira dois mini-golens. Eles são heróis de verdade no
		-- servidor, e antes tomavam uma vaga da coluna cada um — num time de três,
		-- os três registros do Golem enchiam a coluna e os outros dois heróis
		-- sumiam da tela. Aqui os dois pedaços dividem o card do CORPO.
		--
		-- Cabem na barriga do card: o retrato acaba em y=39 e a faixa do nome
		-- começa em y=38, então as duas linhas ocupam y 16..38 sem empurrar nada.
		-- Enquanto o Golem está vivo não existe pedaço nenhum, então não há
		-- disputa de espaço — elas ficam invisíveis a partida inteira pra todo
		-- herói que não seja um Golem partido.
		local subs = {}
		for subIndex = 1, 2 do
			local line = Instance.new("Frame")
			line.Name = "Piece" .. subIndex
			line.Position = UDim2.new(0, 0, 0, 16 + (subIndex - 1) * (SUB_LINE_H + 1))
			line.Size = UDim2.new(1, 0, 0, SUB_LINE_H)
			line.BackgroundColor3 = Color3.fromRGB(10, 11, 16)
			line.BackgroundTransparency = 0.35
			line.BorderSizePixel = 0
			line.ZIndex = 4
			line.Visible = false
			line.Parent = card

			-- barra de vida do pedaço: é o próprio fundo da linha preenchido por
			-- escala, sem instância de trilho separada
			local fill = Instance.new("Frame")
			fill.Name = "Fill"
			fill.Size = UDim2.fromScale(1, 1)
			fill.BackgroundColor3 = Color3.fromRGB(80, 200, 110)
			fill.BackgroundTransparency = 0.55
			fill.BorderSizePixel = 0
			fill.ZIndex = 4
			fill.Parent = line

			-- mesma convenção do card grande: ATK à esquerda em azul, vida à
			-- direita em branco, só reduzida
			local atk = Instance.new("TextLabel")
			atk.Name = "Atk"
			atk.Position = UDim2.new(0, 3, 0, 0)
			atk.Size = UDim2.new(0, 18, 1, 0)
			atk.BackgroundTransparency = 1
			atk.TextXAlignment = Enum.TextXAlignment.Left
			atk.TextColor3 = ATK_TEXT_COLOR
			atk.TextSize = SUB_TEXT_SIZE
			atk.Font = Enum.Font.GothamBlack
			atk.ZIndex = 5
			atk.Parent = line

			local hp = Instance.new("TextLabel")
			hp.Name = "Hp"
			hp.AnchorPoint = Vector2.new(1, 0)
			hp.Position = UDim2.new(1, -3, 0, 0)
			hp.Size = UDim2.new(0, 22, 1, 0)
			hp.BackgroundTransparency = 1
			hp.TextXAlignment = Enum.TextXAlignment.Right
			hp.TextColor3 = Color3.new(1, 1, 1)
			hp.TextSize = SUB_TEXT_SIZE
			hp.Font = Enum.Font.GothamBlack
			hp.ZIndex = 5
			hp.Parent = line

			subs[subIndex] = { line = line, fill = fill, atk = atk, hp = hp }
		end

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
			if not hero then return end

			-- Card do Golem partido: abrir a ficha do CORPO mostraria "Abatido" e
			-- a vida zerada, contradizendo as sub-linhas logo acima. Quem está em
			-- jogo é o pedaço, então é a ficha dele que abre.
			for _, piece in ipairs(hero.summons or {}) do
				if piece.isAlive and piece.sameBody then
					hero = piece
					break
				end
			end

			if showHeroDetail then showHeroDetail(hero) end
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

		local statusStrip = Instance.new("Frame")
		statusStrip.Name = "StatusStrip"
		statusStrip.AnchorPoint = Vector2.new(1, 0)
		statusStrip.Position = UDim2.new(1, -3, 0, 17)
		statusStrip.Size = UDim2.new(0, 44, 0, 12)
		statusStrip.BackgroundTransparency = 1
		statusStrip.ZIndex = 7
		statusStrip.Parent = card

		local statusLayout = Instance.new("UIListLayout")
		statusLayout.FillDirection = Enum.FillDirection.Horizontal
		statusLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
		statusLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		statusLayout.SortOrder = Enum.SortOrder.LayoutOrder
		statusLayout.Padding = UDim.new(0, 2)
		statusLayout.Parent = statusStrip

		local statusBadges = {}
		for order, spec in ipairs(STATUS_BADGES) do
			local badge = Instance.new("TextLabel")
			badge.Name = spec.key
			badge.LayoutOrder = order
			badge.Size = UDim2.new(0, 13, 0, 12)
			badge.BackgroundTransparency = 0.25
			badge.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
			badge.TextColor3 = spec.color
			badge.Font = Enum.Font.GothamBold
			badge.TextSize = 9
			badge.Text = spec.glyph
			badge.ZIndex = 8
			badge.Visible = false
			badge.Parent = statusStrip

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 3)
			corner.Parent = badge

			statusBadges[spec.key] = badge
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
			subs = subs,
			statusBadges = statusBadges,
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
detailAbilities.Font = GameConfig.UI_FONT_BODY
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
	if hero.hidden then table.insert(statusBits, "Na sombra") end
	if hero.attack > (hero.baseAttack or hero.attack) then table.insert(statusBits, "ATK buffado") end
	if hero.shielded then table.insert(statusBits, "Escudo (bloqueia o próximo golpe)") end
	if hero.frozen then table.insert(statusBits, "Congelado") end
	-- Agility: o golpe saiu e o passo continua de pé. Sem isto o jogador via as
	-- casas azuis reaparecerem depois do ataque e achava que era bug.
	if hero.hasAttacked and not hero.hasMoved then
		table.insert(statusBits, "Movimento pós-ataque disponível")
	end
	if (hero.poisonTurns or 0) > 0 then
		table.insert(statusBits, ("Envenenado (%d)"):format(hero.poisonTurns))
	end
	detailStatus.Text = table.concat(statusBits, "   •   ")

	local lines = {}
	if data.ability and HeroData.ABILITY_INFO[data.ability] then
		table.insert(lines, ("•  %s — %s"):format(data.ability, HeroData.GetAbilityDescription(data)))
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

-- ===== TÚMULO CLICÁVEL DA CASA DE PROMOÇÃO (sem modal) =====
-- Chegar na casa de promoção não abre mais um card de escolha: as lápides que
-- podem voltar ficam AZUIS no próprio tabuleiro (mesmo `paint()` que pinta
-- destino de movimento/ataque), e o jogador clica ali — o ressuscitado nasce
-- exatamente naquela casa, não perto da casa de promoção (ver
-- PerformResurrection). O bloqueio de qualquer outra ação enquanto isto está
-- pendente continua sendo o servidor (match.pendingPromotion em
-- AuthorizeAction/EndTurn) — aqui só decide COMO o jogador aponta a escolha.
-- Pisca entre dois tons de azul — mesma técnica da casa de promoção ativa
-- (renderPromotionSquares): TweenInfo com Reverses + RepeatCount -1 faz o loop
-- sozinho, sem RenderStepped nem polling.
local PROMOTION_RESURRECT_COLOR_LOW = Color3.fromRGB(40, 70, 130)
local PROMOTION_RESURRECT_COLOR_HIGH = Color3.fromRGB(120, 190, 255)

-- Bookkeeping PRÓPRIO, separado de savedColors/clearHighlights: aquele é
-- limpo toda vez que o jogador seleciona/desseleciona um herói, e o túmulo
-- azul precisa sobreviver a isso — ele reflete o estado do SERVIDOR
-- (pendingPromotion), não a seleção local.
local promotionHighlighted = {} -- [tile Part] = tween
local promotionOptionUids = {} -- [uid] = true, lido pelo clique

local function clearPromotionHighlights()
	for tile, tween in pairs(promotionHighlighted) do
		tween:Cancel()
		if tile.Parent then
			tile.Color = tile:GetAttribute("BaseColor") or fallbackColor(tile)
		end
	end
	promotionHighlighted = {}
	promotionOptionUids = {}
end

-- ===== "SELECIONE O HERÓI PARA REVIVER" =====
-- Texto persistente, não a fila de mensagens transientes (messageLabel) — este
-- fica na tela o tempo INTEIRO em que a escolha está pendente, não alguns
-- segundos e some.
local promotionPrompt = Instance.new("TextLabel")
promotionPrompt.Name = "PromotionPrompt"
promotionPrompt.AnchorPoint = Vector2.new(0.5, 0)
promotionPrompt.Position = UDim2.new(0.5, 0, 0, 58)
promotionPrompt.Size = UDim2.new(0, 460, 0, 30)
promotionPrompt.BackgroundTransparency = 1
promotionPrompt.Text = "Selecione o herói para reviver"
promotionPrompt.TextColor3 = Color3.fromRGB(140, 195, 255)
promotionPrompt.TextStrokeTransparency = 0.35
promotionPrompt.TextScaled = true
promotionPrompt.Font = Enum.Font.GothamBold
promotionPrompt.Visible = false
promotionPrompt.ZIndex = 40
promotionPrompt.Parent = gui

local function renderPromotionResurrect(state)
	clearPromotionHighlights()

	local pending = state and state.pendingPromotion
	local options = pending and pending.options
	local board = state and state.boardFolder

	promotionPrompt.Visible = options ~= nil and #options > 0

	if not options or #options == 0 or not board then return end

	for _, uid in ipairs(options) do
		promotionOptionUids[uid] = true

		local hero = heroByUid(uid)
		local tile = hero and board:FindFirstChild(hero.position)
		if tile and tile:IsA("BasePart") then
			-- SEM tocar no attribute BaseColor: essa é a cor ORIGINAL do
			-- xadrez do tabuleiro (gravada uma vez pelo BoardSpawner), e
			-- clearPromotionHighlights depende dela pra restaurar certo
			-- quando a escolha se resolve. Só o .Color visível pulsa.
			tile.Color = PROMOTION_RESURRECT_COLOR_LOW
			local tween = TweenService:Create(tile,
				TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Color = PROMOTION_RESURRECT_COLOR_HIGH })
			tween:Play()
			promotionHighlighted[tile] = tween
		end
	end
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

			if square.state == "active" and square.mine then
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

				local color
				if square.state == "used" then
					color = fallbackColor(tile)
				elseif square.state == "active" then
					color = PROMOTION_ENEMY_COLOR
				else
					color = PROMOTION_INACTIVE_COLOR
				end

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
	local status = statusOf(hero)
	local signature = ("%d|%d|%d|%s|%s|%s|%s|%s|%s"):format(hero.dataId, hero.currentHp, hero.attack,
		tostring(hero.isAlive), tostring(hero.sideIndex), tostring(hero.hidden),
		tostring(status.frozen), tostring(status.poison), tostring(status.shock))

	-- OS PEDAÇOS ENTRAM NA ASSINATURA. O card do Golem partido é desenhado com
	-- dados que NÃO estão no herói pai — o corpo já morreu e não muda mais nunca.
	-- Sem isto a assinatura ficaria constante, o `return` lá embaixo cortaria o
	-- redesenho e as sub-linhas congelariam no primeiro valor: os pedaços
	-- apanhariam na tela do jogador sem a vida se mexer.
	for _, piece in ipairs(hero.summons or {}) do
		signature ..= ("/%d|%d|%d|%s"):format(piece.dataId, piece.currentHp,
			piece.attack, tostring(piece.isAlive))
	end

	return signature
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
		for _, badge in pairs(row.statusBadges) do badge.Visible = false end
		return
	end

	local data = HeroData.GetById(hero.dataId)
	local accent = hero.sideIndex == 2 and SIDE_TWO_COLOR or SIDE_ONE_COLOR

	-- ===== O GOLEM PARTIDO =====
	-- O corpo morreu, mas os pedaços dele estão em jogo. `broken` é o terceiro
	-- estado do card, entre vivo e morto: o retrato apaga (o corpo se foi mesmo),
	-- mas a cruz NÃO aparece — nesta coluna cruz significa "eliminado", e o time
	-- ainda tem essa peça lutando. Quem conta a história são as sub-linhas.
	--
	-- Só pedaço VIVO entra: quando o último cai, `pieces` fica vazia, `broken`
	-- volta a ser falso e o card cai no caminho de morto de sempre — que é
	-- exatamente quando a lápide do corpo sobe no servidor.
	local pieces = {}
	for _, piece in ipairs(hero.summons or {}) do
		if piece.isAlive and piece.sameBody then table.insert(pieces, piece) end
	end

	local alive = hero.isAlive
	local broken = (not alive) and #pieces > 0

	local status = statusOf(hero)
	for key, badge in pairs(row.statusBadges) do
		badge.Visible = alive and status[key] == true
	end

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
	-- partido conta como "em jogo" pro fundo e pra moldura: o card precisa se ler
	-- como uma peça ativa do time, não como uma baixa
	row.card.BackgroundColor3 = (alive or broken) and Color3.fromRGB(24, 27, 37) or DEAD_CARD
	row.stroke.Color = (alive or broken) and accent or Color3.fromRGB(58, 60, 68)
	row.stroke.Transparency = (alive or broken) and 0.15 or 0.5

	for _, dash in ipairs(row.cross) do
		dash.Visible = not alive and not broken
	end

	-- Os números do topo são do CORPO. Com ele partido quem fala são as
	-- sub-linhas, e mostrar "0" de vida do Golem ao lado de dois pedaços de pé
	-- seria a informação errada em cima da certa.
	row.hpTrack.Visible = alive
	row.hpLabel.Visible = alive
	row.atkLabel.Visible = alive

	for subIndex, sub in ipairs(row.subs) do
		local piece = pieces[subIndex]
		sub.line.Visible = piece ~= nil

		if piece then
			local ratio = piece.maxHp > 0 and math.clamp(piece.currentHp / piece.maxHp, 0, 1) or 0
			sub.fill.Size = UDim2.fromScale(ratio, 1)
			-- mesmos limiares de cor do card grande, pra vida baixa gritar igual
			sub.fill.BackgroundColor3 = ratio > 0.5 and Color3.fromRGB(80, 200, 110)
				or (ratio > 0.25 and Color3.fromRGB(220, 180, 70) or Color3.fromRGB(220, 80, 80))
			sub.atk.Text = tostring(piece.attack)
			sub.hp.Text = tostring(math.max(piece.currentHp, 0))
		end
	end

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

	if hero.hidden then
		row.portrait.ImageTransparency = 0.55
		row.stroke.Color = Color3.fromRGB(90, 94, 120)
		row.stroke.Transparency = 0.35
		row.heroName.TextColor3 = Color3.fromRGB(150, 156, 180)
	end
end

-- Pendura cada invocação no herói que a gerou e devolve só os "pais", que são as
-- peças que o jogador escolheu no draft. É o que garante que o time continue
-- ocupando HEROES_PER_PLAYER vagas na coluna, mesmo com o Golem virando três
-- registros ao estilhaçar.
--
-- Pai ausente da lista devolve o filho como card próprio, de propósito: um card
-- a mais é um problema menor do que um herói vivo invisível na tela.
--
-- ZERA `summons` NA ENTRADA, e isso não é zelo à toa. No fim da partida a mesma
-- tabela `state` é agrupada duas vezes (a coluna e o painel de resultado); sem
-- limpar, a segunda passada empilharia os pedaços de novo e o painel somaria o
-- dano deles em dobro.
local function groupHeroes(list)
	local byUid = {}
	for _, hero in ipairs(list) do
		hero.summons = nil
		byUid[hero.uid] = hero
	end

	local parents = {}
	for _, hero in ipairs(list) do
		local parent = hero.summonOf and byUid[hero.summonOf]
		if parent then
			parent.summons = parent.summons or {}
			table.insert(parent.summons, hero)
		else
			table.insert(parents, hero)
		end
	end
	return parents
end

local function renderTeams(state)
	local mine, theirs = {}, {}
	for _, hero in ipairs(state.heroes or {}) do
		table.insert(hero.isMine and mine or theirs, hero)
	end

	mine, theirs = groupHeroes(mine), groupHeroes(theirs)

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

-- AÇÃO BARRADA SE EXPLICA EM CIMA DO HERÓI, não num banner no topo da tela: o
-- jogador está olhando pro tabuleiro, e o aviso longe do lugar em que a coisa
-- aconteceu obriga a procurar quem barrou. Taunt e paralisia saem pelo balão
-- amarelo do HeroView (ver TEXT_STYLES.taunt) e por isso não têm linha aqui.
--
-- Os que sobraram são os que NÃO têm um herói pra apontar, ou que o destaque do
-- cliente já deveria ter impedido — quando um deles aparece, é sinal de que a
-- pintura das casas e a regra do servidor discordaram.
local REJECTION_TEXT = {
	NOT_YOUR_TURN = "Não é o turno deste herói.",
	MOVE_OUT_OF_RANGE = "Casa fora do alcance",
	ATTACK_OUT_OF_RANGE = "Inimigo fora do alcance",
	OCCUPIED = "Esta casa está ocupada.",
	INVALID_TARGET = "Alvo inválido.",
	INVALID_MOVE = "Movimento inválido.",
}

local feedback = { gap = 0.9, lastText = nil, lastAt = 0 }

function feedback.refuse(text)
	local now = os.clock()
	if text == feedback.lastText and now - feedback.lastAt < feedback.gap then return end
	feedback.lastText, feedback.lastAt = text, now

	flashTurnBanner(text, WAIT_TURN_COLOR)
	PlayUiSound("ActionBlocked")
end

function feedback.outOfReach(hexId)
	local selected = heroByUid(selectedUid)
	if not (selected and hexId) then return end

	local occupant = nil
	for _, other in ipairs(state.heroes) do
		if other.position == hexId and (other.isAlive or not other.graveDestroyed) then
			occupant = other
			break
		end
	end

	if occupant then
		if occupant.isMine or not occupant.isAlive then return end
		if selected.hasAttacked then return end
		feedback.refuse(REJECTION_TEXT.ATTACK_OUT_OF_RANGE)
		return
	end

	for _, barrel in ipairs(state.barrels or {}) do
		if barrel.position == hexId then return end
	end

	if selected.hasMoved then return end
	feedback.refuse(REJECTION_TEXT.MOVE_OUT_OF_RANGE)
end

GameAction.OnClientEvent:Connect(function(action, payload)
	if action ~= "reject" then return end

	local text = REJECTION_TEXT[payload]
	if not text then return end

	feedback.refuse(text)
end)

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
confirmText.Font = GameConfig.UI_FONT_BODY
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
	if not state or (state.phase ~= "battle" and state.phase ~= "placement") then return end

	local placing = state.phase == "placement"
	confirmTitle.Text = placing and "Abandonar a partida?" or "Desistir da partida?"
	giveUpButton.Text = placing and "Abandonar" or "Desistir"

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
-- Deixou de ser só "Vitória/Derrota + dois botões". Agora é a prestação de
-- contas da partida: os heróis QUE VOCÊ levou, um card cada, com o que fizeram.
--
-- CADA JOGADOR VÊ O PRÓPRIO TIME. Os números vêm do `summary` do snapshot, que
-- o servidor já calcula por espectador (ver MatchManager.Snapshot) — o cliente
-- não escolhe de quem é o destaque, só desenha o que chegou pra ele.
--
-- Painel maior (520x412) e centralizado. As colunas laterais continuam visíveis
-- por trás dele: elas mostram QUEM sobrou dos dois lados, ele mostra o que cada
-- um dos seus fez pra chegar lá.
local RESULT_CARD_W = 148
local RESULT_CARD_H = 176
local RESULT_CARD_GAP = 10
local RESULT_PAGE_TOP = 76
local RESULT_ROW_TOP = 98

local resultPanel = Instance.new("Frame")
resultPanel.Size = UDim2.new(0, 520, 0, 412)
resultPanel.AnchorPoint = Vector2.new(0.5, 0.5)
resultPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
resultPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
resultPanel.BackgroundTransparency = 0.06
resultPanel.BorderSizePixel = 0
resultPanel.Visible = false
resultPanel.Parent = gui

local resultCorner = Instance.new("UICorner")
resultCorner.CornerRadius = UDim.new(0, 14)
resultCorner.Parent = resultPanel

local resultLabel = Instance.new("TextLabel")
resultLabel.Size = UDim2.new(1, -20, 0, 46)
resultLabel.Position = UDim2.new(0, 10, 0, 12)
resultLabel.BackgroundTransparency = 1
resultLabel.TextScaled = true
resultLabel.Font = Enum.Font.GothamBold
resultLabel.Parent = resultPanel

-- Linha de contexto embaixo do título: quantos turnos e o maior golpe da
-- partida. É o "resumo em uma frase" antes dos cards detalharem por herói.
local resultSubtitle = Instance.new("TextLabel")
resultSubtitle.Size = UDim2.new(1, -20, 0, 16)
resultSubtitle.Position = UDim2.new(0, 10, 0, 58)
resultSubtitle.BackgroundTransparency = 1
resultSubtitle.TextColor3 = Color3.fromRGB(150, 160, 182)
resultSubtitle.TextSize = 13
resultSubtitle.Font = GameConfig.UI_FONT_BODY
resultSubtitle.Text = ""
resultSubtitle.Parent = resultPanel

-- Onde os cards dos heróis entram. Centralizado por UIListLayout horizontal, pra
-- 3 heróis ou 4 (o Golem estilhaçado vira dois) caberem sem recalcular posição.
local resultTeam = Instance.new("Frame")
resultTeam.Name = "TeamRow"
resultTeam.Position = UDim2.new(0, 0, 0, RESULT_ROW_TOP)
resultTeam.Size = UDim2.new(1, 0, 0, RESULT_CARD_H)
resultTeam.BackgroundTransparency = 1
resultTeam.Parent = resultPanel

local resultTeamLayout = Instance.new("UIListLayout")
resultTeamLayout.FillDirection = Enum.FillDirection.Horizontal
resultTeamLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
resultTeamLayout.VerticalAlignment = Enum.VerticalAlignment.Center
resultTeamLayout.Padding = UDim.new(0, RESULT_CARD_GAP)
resultTeamLayout.SortOrder = Enum.SortOrder.LayoutOrder
resultTeamLayout.Parent = resultTeam

local resultPage = "mine"
local renderResultTeam

local function buildPagerArrow(text, alignRight)
	local arrow = Instance.new("TextButton")
	arrow.Name = "Pager" .. text
	arrow.AnchorPoint = Vector2.new(alignRight and 1 or 0, 0.5)
	arrow.Position = UDim2.new(alignRight and 1 or 0, alignRight and -14 or 14,
		0, RESULT_ROW_TOP + RESULT_CARD_H / 2)
	arrow.Size = UDim2.fromOffset(30, 30)
	arrow.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
	arrow.BorderSizePixel = 0
	arrow.Text = text
	arrow.TextColor3 = Color3.fromRGB(225, 232, 245)
	arrow.TextSize = 20
	arrow.Font = Enum.Font.GothamBold
	arrow.Parent = resultPanel

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = arrow

	return arrow
end

local resultPageLabel = Instance.new("TextLabel")
resultPageLabel.Name = "PageLabel"
resultPageLabel.AnchorPoint = Vector2.new(0.5, 0)
resultPageLabel.Position = UDim2.new(0.5, 0, 0, RESULT_PAGE_TOP)
resultPageLabel.Size = UDim2.new(0, 220, 0, 18)
resultPageLabel.BackgroundTransparency = 1
resultPageLabel.TextColor3 = Color3.fromRGB(170, 180, 200)
resultPageLabel.TextSize = 13
resultPageLabel.Font = Enum.Font.GothamBold
resultPageLabel.Parent = resultPanel

local resultPrev = buildPagerArrow("‹", false)
local resultNext = buildPagerArrow("›", true)

local function flipResultPage()
	resultPage = (resultPage == "mine") and "theirs" or "mine"
	if state then renderResultTeam(state) end
end

resultPrev.MouseButton1Click:Connect(flipResultPage)
resultNext.MouseButton1Click:Connect(flipResultPage)

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

-- O botão de cima muda de papel conforme a partida. Contra bot ele é decisão de
-- um só; no PvP ele vira um convite que o adversário precisa aceitar, e some se
-- ele já voltou pro lobby.
local replayAction = "replay"
local renderReplayButton

function renderReplayButton(state)
	local rematch = state.rematch

	if not rematch then
		replayAction = "replay"
		replayButton.Visible = true
		replayButton.AutoButtonColor = true
		replayButton.BackgroundColor3 = Color3.fromRGB(70, 150, 90)

		if state.campaign and state.winner == "win" then
			replayButton.Text = "Próximo herói"
		elseif state.campaign then
			replayButton.Text = "Tentar de novo"
		else
			replayButton.Text = "Jogar novamente"
		end
		return
	end

	if not rematch.open then
		replayAction = "queue"
		replayButton.Visible = true
		replayButton.AutoButtonColor = true
		replayButton.BackgroundColor3 = Color3.fromRGB(70, 110, 170)
		replayButton.Text = "Voltar para a fila"
		return
	end

	replayAction = "replay"
	replayButton.Visible = true

	if rematch.mine then
		replayButton.AutoButtonColor = false
		replayButton.BackgroundColor3 = Color3.fromRGB(70, 80, 96)
		replayButton.Text = "Aguardando o oponente..."
	elseif rematch.theirs then
		replayButton.AutoButtonColor = true
		replayButton.BackgroundColor3 = Color3.fromRGB(210, 160, 60)
		replayButton.Text = "Aceitar revanche"
	else
		replayButton.AutoButtonColor = true
		replayButton.BackgroundColor3 = Color3.fromRGB(70, 150, 90)
		replayButton.Text = "Pedir revanche"
	end
end

replayButton.MouseButton1Click:Connect(function()
	if replayAction == "queue" then
		GameAction:FireServer("leaveMatch")
		GameAction:FireServer("queue")
		return
	end

	GameAction:FireServer("replay")
end)

lobbyButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("leaveMatch")
end)

-- ===== CARDS DO FIM DE PARTIDA =====
-- Uma faixa colorida no topo do card marca o papel daquele herói na partida.
-- Um selo só por herói, na ordem abaixo: o destaque vence o escudo quando o
-- mesmo herói fez as duas coisas, porque "quem mais bateu" é a leitura que o
-- jogador procura primeiro.
local RESULT_BADGES = {
	{ key = "mvp",       text = "DESTAQUE",   color = Color3.fromRGB(240, 196, 84) },
	{ key = "protector", text = "ESCUDO",     color = Color3.fromRGB(110, 180, 240) },
}

-- Rótulo à esquerda, número à direita. Duas TextLabels e não uma string
-- formatada com espaços: alinhado por espaço, o número dança de card pra card
-- (a fonte não é monoespaçada) e some da borda quando o card encolhe — e ele
-- encolhe, porque o Golem estilhaçado enfia dois cards a mais na fileira.
local function buildResultStat(parent, order, label, value, color)
	local y = 112 + order * 15

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(0.62, -8, 0, 15)
	name.Position = UDim2.new(0, 8, 0, y)
	name.BackgroundTransparency = 1
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = color
	name.TextSize = 11
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Font = GameConfig.UI_FONT_BODY
	name.Text = label
	name.Parent = parent

	local number = Instance.new("TextLabel")
	number.Size = UDim2.new(0.38, -8, 0, 15)
	number.Position = UDim2.new(0.62, 0, 0, y)
	number.BackgroundTransparency = 1
	number.TextXAlignment = Enum.TextXAlignment.Right
	number.TextColor3 = color
	number.TextSize = 12
	number.Font = Enum.Font.GothamBold
	number.Text = tostring(value)
	number.Parent = parent
end

-- Soma o que os pedaços fizeram no número do corpo. O Golem estilhaçado agora
-- ocupa UM card, então o dano que os mini-golens causaram sairia da tela junto
-- com os cards deles — e o jogador leria "o Golem não fez nada" sobre uma peça
-- que lutou a partida inteira em dois corpos.
--
-- Copia antes de somar: `state` é o mesmo snapshot que a coluna lateral desenha,
-- e escrever nele contaminaria o outro render.
local function mergedStats(hero)
	local total = table.clone(hero.stats or {})
	for _, piece in ipairs(hero.summons or {}) do
		local s = piece.stats
		if s then
			total.dealt = (total.dealt or 0) + (s.dealt or 0)
			total.taken = (total.taken or 0) + (s.taken or 0)
			total.healed = (total.healed or 0) + (s.healed or 0)
			total.kills = (total.kills or 0) + (s.kills or 0)
		end
	end
	return total
end

local function buildResultCard(hero, badgeKey, order)
	local data = HeroData.GetById(hero.dataId)
	local stats = mergedStats(hero)

	-- Um pedaço de pé conta como sobrevivente do card: quem terminou a partida
	-- com meio Golem em campo não perdeu a peça.
	local standing = hero.isAlive
	for _, piece in ipairs(hero.summons or {}) do
		if piece.isAlive and piece.sameBody then standing = true break end
	end

	local card = Instance.new("Frame")
	card.Name = hero.uid
	card.Size = UDim2.new(0, RESULT_CARD_W, 0, RESULT_CARD_H)
	card.BackgroundColor3 = standing and Color3.fromRGB(26, 30, 42) or DEAD_CARD
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = resultTeam

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card

	local badge = nil
	for _, entry in ipairs(RESULT_BADGES) do
		if entry.key == badgeKey then badge = entry break end
	end

	local stroke = Instance.new("UIStroke")
	stroke.Color = badge and badge.color or Color3.fromRGB(52, 58, 74)
	stroke.Thickness = badge and 2 or 1
	stroke.Parent = card

	-- Faixa do selo. Ocupa espaço fixo mesmo sem selo (fica transparente), pra
	-- os quatro cards alinharem os retratos na mesma altura.
	local ribbon = Instance.new("TextLabel")
	ribbon.Size = UDim2.new(1, 0, 0, 18)
	ribbon.BackgroundColor3 = badge and badge.color or Color3.new(0, 0, 0)
	ribbon.BackgroundTransparency = badge and 0.12 or 1
	ribbon.BorderSizePixel = 0
	ribbon.Text = badge and badge.text or ""
	ribbon.TextColor3 = Color3.fromRGB(22, 22, 28)
	ribbon.TextSize = 10
	ribbon.Font = Enum.Font.GothamBlack
	ribbon.Parent = card

	local ribbonCorner = Instance.new("UICorner")
	ribbonCorner.CornerRadius = UDim.new(0, 10)
	ribbonCorner.Parent = ribbon

	local portrait = Instance.new("ImageLabel")
	portrait.Size = UDim2.new(0, 62, 0, 62)
	portrait.Position = UDim2.new(0.5, -31, 0, 22)
	portrait.BackgroundTransparency = 1
	portrait.ScaleType = Enum.ScaleType.Fit
	portrait.ResampleMode = Enum.ResamplerMode.Pixelated
	portrait.Parent = card

	local spriteId = spriteOf(data)
	if spriteId and data then
		portrait.Image = spriteId
		portrait.ImageRectSize = HeroData.GetFrameSize(data)
		portrait.ImageRectOffset = HeroData.GetFrameOffset(data)
		-- morto fica dessaturado, mas reconhecível: mesma regra da coluna lateral
		portrait.ImageColor3 = standing and Color3.new(1, 1, 1) or DEAD_TINT
	elseif data then
		portrait.BackgroundTransparency = 0
		portrait.BackgroundColor3 = data.color
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Position = UDim2.new(0, 4, 0, 86)
	nameLabel.Size = UDim2.new(1, -8, 0, 16)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = hero.name or (data and data.name) or "?"
	nameLabel.TextColor3 = standing and Color3.fromRGB(232, 238, 250) or DEAD_TINT
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.Parent = card

	-- Três estados, não dois: o Golem que acabou a partida em pedaços não
	-- "sobreviveu" nem "caiu" — dizer qualquer um dos dois seria mentira.
	local pecasVivas = 0
	for _, piece in ipairs(hero.summons or {}) do
		if piece.isAlive and piece.sameBody then pecasVivas += 1 end
	end

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Position = UDim2.new(0, 4, 0, 100)
	statusLabel.Size = UDim2.new(1, -8, 0, 12)
	statusLabel.BackgroundTransparency = 1
	if hero.isAlive then
		statusLabel.Text = ""
	elseif pecasVivas > 0 then
		statusLabel.Text = ("em pedaços · %d de pé"):format(pecasVivas)
	else
		statusLabel.Text = "caiu em combate"
	end
	statusLabel.TextColor3 = standing
		and Color3.fromRGB(130, 200, 150) or Color3.fromRGB(198, 116, 116)
	statusLabel.TextSize = 10
	statusLabel.Font = GameConfig.UI_FONT_BODY
	statusLabel.Parent = card

	buildResultStat(card, 0, "Dano causado", stats.dealt or 0, Color3.fromRGB(255, 186, 120))
	buildResultStat(card, 1, "Dano recebido", stats.taken or 0, Color3.fromRGB(150, 190, 245))

	local order = 2
	if (stats.kills or 0) > 0 then
		buildResultStat(card, order, "Abates", stats.kills, Color3.fromRGB(238, 170, 160))
		order += 1
	end
	if (stats.healed or 0) > 0 then
		buildResultStat(card, order, "Cura", stats.healed, Color3.fromRGB(150, 225, 175))
	end
end

-- Redesenha a fileira inteira. Os cards são descartáveis: a partida acabou, não
-- há atualização incremental pra otimizar, e recriar é o que garante que uma
-- revanche não herde os números da anterior.
function renderResultTeam(state)
	for _, child in ipairs(resultTeam:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	local showingMine = resultPage == "mine"
	local summary = showingMine and (state.summary or {}) or {}

	local mine = {}
	for _, hero in ipairs(state.heroes) do
		if hero.isMine == showingMine then table.insert(mine, hero) end
	end

	resultPageLabel.Text = showingMine and "SEU TIME" or "ADVERSÁRIO"

	-- Mesmo agrupamento da coluna lateral: os pedaços do Golem entram no card do
	-- corpo em vez de virarem cards próprios. A ordem já vem pronta do servidor
	-- (Snapshot ordena por lado e id), então não se reordena aqui — reordenar por
	-- uid era o bug que embaralhava a fileira em relação à coluna.
	mine = groupHeroes(mine)

	-- O painel acompanha a fileira. Com o agrupamento são sempre
	-- HEROES_PER_PLAYER cards, mas a conta fica: um herói invocado cujo pai não
	-- esteja na lista ainda pode virar card solto (ver groupHeroes).
	local count = math.max(#mine, 1)
	local width = 24 + count * RESULT_CARD_W + (count - 1) * RESULT_CARD_GAP
	resultPanel.Size = UDim2.new(0, math.clamp(width, 460, 840), 0, 412)

	-- O selo é por uid, e um PEDAÇO pode ter sido o destaque da partida. Sem
	-- olhar os filhos, o card do Golem ficaria sem faixa nenhuma enquanto o
	-- resumo do topo anuncia um maior golpe que ninguém na tela reivindica.
	local function wearsBadge(hero, uid)
		if not uid then return false end
		if hero.uid == uid then return true end
		for _, piece in ipairs(hero.summons or {}) do
			if piece.uid == uid then return true end
		end
		return false
	end

	for index, hero in ipairs(mine) do
		local badgeKey = nil
		if wearsBadge(hero, summary.mvpUid) then badgeKey = "mvp"
		elseif wearsBadge(hero, summary.protectorUid) then badgeKey = "protector" end

		buildResultCard(hero, badgeKey, index)
	end

	resultSubtitle.Text = summary.turns and ("%d turnos"):format(summary.turns) or ""
end

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
-- Vermelho mais saturado que o ATTACK_COLOR das casas: a linha é fina e fica
-- sobre um tabuleiro claro, então precisa destacar mais que uma casa inteira
-- pintada. Agora que a seta é fosca (ver newAimPart) ela é sombreada pela arena,
-- então é AQUI que se compensa se ela ficar apagada demais numa arena escura —
-- subindo a cor, não devolvendo o Neon.
local AIM_ATTACK_COLOR = Color3.fromRGB(255, 62, 52)

-- ===== CURVATURA =====
-- O traçado é uma Bézier quadrática (origem, um ponto de controle, alvo) em vez
-- de uma reta. Não é a reta "dobrada" na hora de desenhar: a curva é amostrada
-- e os traços caminham SOBRE ela, cada um girado na tangente do próprio ponto.
--
-- O ponto de controle sai do meio do caminho levantado NA VERTICAL. Vertical e
-- não lateral: é o que faz o traçado ler como projétil lançado (sobe, desce e
-- cai no alvo) em vez de uma linha que desvia pro lado. Como a direção é sempre
-- pra cima, esquerda, direita, longe e perto arqueiam todas igual — não existe
-- o problema antigo da curva "virar de lado" quando o cursor cruzava um eixo.
-- O desvio é VERTICAL, não lateral: o traçado sobe no meio do caminho e desce
-- no alvo, como a trajetória de um projétil lançado. O desvio lateral que
-- existia aqui antes empurrava a linha pro lado no plano do tabuleiro — dava
-- movimento ao traço, mas lia como "corda torta", não como tiro.
--
-- Numa Bézier quadrática a curva passa na METADE do deslocamento do controle,
-- então o controle sobe o DOBRO da altura desejada no ápice (ver
-- aimControlPoint) e estes números são a altura de verdade, não a do controle.
local AIM_CURVE_SAMPLES = 24 -- segmentos da amostragem; 24 já fica liso nesta escala
local AIM_ARC_RATIO = 0.18 -- quanto da distância vira altura no ápice
local AIM_ARC_MAX = 6 -- teto: acima disso o tiro longo some do enquadramento
-- Piso pra jogada de UMA casa (~10 studs) ainda ler como arco em vez de risco
-- reto — sem ele, mover pra casa vizinha desenhava uma linha praticamente plana.
local AIM_ARC_MIN = 1.2
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
	-- FOSCA, sem brilho próprio. Era Neon, que ignora a iluminação e sai sempre
	-- na cor cheia — a seta acendia por cima do tabuleiro como se fosse fonte de
	-- luz. SmoothPlastic com reflexo zero é a superfície mais chapada que uma
	-- Part tem: ela passa a ser sombreada pela arena como o resto do cenário.
	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = 0
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

-- Onde fica o "cotovelo" da curva: no meio do caminho, direto pra cima. É isso
-- que faz o traçado virar um arco de projétil em vez de desviar pro lado.
local function aimControlPoint(origin, target)
	local middle = origin:Lerp(target, 0.5)

	-- a altura sai da distância NO PLANO do tabuleiro: um alvo mais alto ou mais
	-- baixo não deve engordar nem achatar o arco, só inclinar as duas pontas
	local delta = target - origin
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude
	if distance < 0.01 then return middle end

	local apex = math.clamp(distance * AIM_ARC_RATIO, AIM_ARC_MIN, AIM_ARC_MAX)

	-- DOBRO do ápice: a Bézier quadrática só chega na metade do deslocamento do
	-- controle, então subir `apex` aqui daria metade da altura pedida.
	return middle + Vector3.new(0, apex * 2, 0)
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
-- Declarado aqui, e não junto do renderShieldChoice lá embaixo, porque o
-- clearHighlights logo abaixo já precisa dele: em Lua uma função só enxerga
-- local declarado ANTES dela, e mais tarde viraria uma global silenciosa.
local shieldOptionUids = {} -- [uid] = true, lido pelo clique

local function clearHighlights()
	for part in pairs(savedColors) do
		if part.Parent then
			part.Color = part:GetAttribute("BaseColor") or fallbackColor(part)
		end
	end
	savedColors, moveTargets, attackTargets = {}, {}, {}

	-- A casa azul da Égide é pintada pelo mesmo `paint`, então ela já saiu no
	-- laço acima junto com passo e ataque — aqui só cai a lista de quem o clique
	-- aceita. Quem reacende é o fim do selectHero.
	shieldOptionUids = {}
end

-- O tabuleiro vem no snapshot: com várias partidas rodando, procurar "Board"
-- pelo nome no Workspace acharia a arena de outra dupla.
--
-- MISTURA, NÃO SUBSTITUI. Antes o destaque trocava a cor da casa por completo
-- (verde puro sobre a pedra), e o tabuleiro virava um tapete de adesivos: berrava
-- mais que os próprios heróis e apagava o xadrez que separa uma casa da vizinha.
-- Interpolando a partir da cor de base, o destaque vira um TINGIMENTO — a pedra
-- continua aparecendo por baixo, as casas claras e escuras seguem distinguíveis,
-- e a leitura de "onde eu posso ir" não se perde.
--
-- Vale pros quatro destaques de uma vez (passo, ataque, barril, lápide), porque
-- todos passam por aqui. HIGHLIGHT_STRENGTH é o único botão: 0 não pinta nada,
-- 1 volta ao comportamento antigo.
local HIGHLIGHT_STRENGTH = 0.55

local function paint(hexId, color)
	local board = state and state.boardFolder
	local tile = board and board:FindFirstChild(hexId)
	if tile and tile:IsA("BasePart") then
		if savedColors[tile] == nil then savedColors[tile] = true end
		-- Lê a base do ATRIBUTO, nunca da cor atual: a casa pode já estar pintada
		-- por outro destaque nesta mesma passada, e partir dela empilharia tinta
		-- em cima de tinta até saturar.
		local base = tile:GetAttribute("BaseColor") or fallbackColor(tile)
		tile.Color = base:Lerp(color, HIGHLIGHT_STRENGTH)
	end
end

-- ===== ESCOLHA DO ESCUDO DA KIRA =====
-- A CASA do aliado, pelo mesmo `paint` do passo e do ataque. É a linguagem que o
-- jogador já lê no tabuleiro — casa tingida = ação possível ali —, e sai de
-- graça no clearHighlights junto com as outras, sem bookkeeping próprio.
--
-- Não briga por cor com passo nem ataque: a casa de um aliado está OCUPADA,
-- então nunca é destino de movimento (o isFree recusa) nem alvo de ataque (é do
-- mesmo time). As três listas são disjuntas por construção.
--
-- Sem texto na tela: o azul já diz o que precisa ser dito, e um aviso fixo no
-- topo competia com o banner de turno e com a fila de mensagens.
local SHIELD_CHOICE_COLOR = Color3.fromRGB(70, 150, 235)

-- `selectedUid` é quem está selecionado AGORA. A oferta só acende quando a
-- própria Kira está na mão do jogador: ela deixou de ser um modo à parte que
-- nasce no início do turno e virou mais uma coisa que a seleção dela revela,
-- junto das casas de passo e dos inimigos no alcance.
local function renderShieldChoice(state, selectedUid)
	shieldOptionUids = {}

	local pending = state and state.pendingShield
	if not pending or pending.sourceUid ~= selectedUid then return end

	for _, uid in ipairs(pending.options or {}) do
		local hero = heroByUid(uid)
		if hero and hero.isAlive then
			shieldOptionUids[uid] = true
			paint(hero.position, SHIELD_CHOICE_COLOR)
		end
	end
end

local function selectHero(uid)
	clearHighlights()

	-- Escolha de reviver pendente: o servidor já recusa mover/atacar com
	-- qualquer herói enquanto isto está aberto (AuthorizeAction), mas sem o
	-- backdrop de tela cheia que o modal antigo tinha, nada mais impedia o
	-- clique de selecionar um herói vivo e pintar um destaque de
	-- movimento/ataque que o servidor ia rejeitar em silêncio. A única jogada
	-- válida agora é clicar no túmulo azul.
	if state and state.pendingPromotion and #state.pendingPromotion.options > 0 then
		selectedUid = nil
		return
	end

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

			-- Shadow invisível: BLOQUEIA a casa, mas não vira alvo. As duas
			-- coisas juntas são a furtividade — pintar a casa de vermelho como
			-- "ataque possível" entregaria de graça exatamente o que o servidor
			-- se deu ao trabalho de não contar (ver o desvio no Snapshot).
			--
			-- Ele fica de fora do enemyAt, então nenhum destaque nasce ali e o
			-- clique não tem uid pra mandar: o jogador vê uma casa que não dá
			-- pra usar, sem saber por quê.
			if not other.isMine and not other.hidden then
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
	if not hero.hasMoved then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, hero.moveRange, isFree)) do
			if isFree(hexId) then
				moveTargets[hexId] = true
				paint(hexId, MOVE_COLOR)
			end
		end
	end

	if not hero.hasAttacked then
		-- O destaque mostra o ALCANCE, não a permissão. Todo inimigo dentro do
		-- alcance fica clicável, inclusive o que o Taunt vai barrar — quem
		-- explica a recusa é o balão amarelo em cima do provocador, no clique.
		--
		-- O cliente já filtrou Taunt aqui, e o resultado era pior: o corpo a
		-- corpo simplesmente não via alvo nenhum (some sem dizer por quê) e o
		-- Ranged via, porque a regra do CORREDOR — tiro que atravessa a casa do
		-- provocador — nunca foi modelada aqui. Duas leituras diferentes da mesma
		-- regra, e a mais silenciosa era a que mais confundia.
		--
		-- Ensinar > prevenir: descobrir que o Taunt puxa o foco clicando nele uma
		-- vez é mais barato que ficar olhando pra um inimigo ao lado que
		-- inexplicavelmente não acende. O clique recusado não custa nada — o
		-- servidor sai antes do MarkAttacked, então o golpe do turno continua na
		-- mão do jogador.
		local attackReach = HexGrid.ComputeReach(hero.position, hero.attackRange, isFree)

		for hexId in pairs(attackReach) do
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

	-- A Égide entra AQUI, no mesmo lugar que as casas de passo e os inimigos no
	-- alcance: selecionar a Kira revela as três coisas de uma vez. Não é modo
	-- separado nem botão de habilidade — é mais uma opção da seleção dela, e
	-- some junto com o resto quando ela é desselecionada (ver clearHighlights).
	renderShieldChoice(state, uid)
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

	-- Casa azul da Casa de Promoção: o clique revive direto, sem passar pela
	-- seleção normal de herói. Vale na lápide E em qualquer ponto do hexágono
	-- dela — a pedra é só o desenho, a casa inteira é a área clicável.
	-- Checado ANTES do resto porque uma lápide também bate `heroUid and
	-- hero.isMine` lá embaixo, e a casa cairia no movimento do herói selecionado.
	local resurrectUid = nil
	if heroUid and promotionOptionUids[heroUid] then
		resurrectUid = heroUid
	elseif hexId then
		for uid in pairs(promotionOptionUids) do
			local option = heroByUid(uid)
			if option and option.position == hexId then
				resurrectUid = uid
				break
			end
		end
	end

	if resurrectUid then
		GameAction:FireServer("resurrect", resurrectUid)
		return
	end

	-- Casa azul da Égide: clicar no aliado destacado dá o escudo a ele. Também
	-- vem ANTES da seleção normal, e pelo motivo oposto ao da promoção — aqui o
	-- alvo é um herói MEU e vivo, que é exatamente o que a seleção comum captura;
	-- sem este desvio, clicar no elegível só o selecionaria.
	--
	-- O destaque some na hora, sem esperar o snapshot: o servidor já vai fechar a
	-- oferta, e deixar o azul aceso até a resposta chegar convidava a um segundo
	-- clique que não faria nada.
	local shieldUid = nil
	if heroUid and shieldOptionUids[heroUid] then
		shieldUid = heroUid
	elseif hexId then
		for uid in pairs(shieldOptionUids) do
			local option = heroByUid(uid)
			if option and option.position == hexId then
				shieldUid = uid
				break
			end
		end
	end

	if shieldUid then
		-- some na hora, sem esperar o snapshot: o servidor já vai fechar a oferta,
		-- e deixar o azul aceso até a resposta chegar convidava a um segundo
		-- clique que não faria nada
		clearHighlights()
		GameAction:FireServer("shield", shieldUid)
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
		elseif selectedUid and hero then
			feedback.outOfReach(hexId or hero.position)
		end
		return
	end

	if hexId and selectedUid then
		if attackTargets[hexId] then
			GameAction:FireServer("attack", selectedUid, attackTargets[hexId])
		elseif moveTargets[hexId] then
			GameAction:FireServer("move", selectedUid, hexId)
		else
			feedback.outOfReach(hexId)
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

do
	local label = Instance.new("TextLabel")
	label.Name = "ReconnectWait"
	label.Size = UDim2.new(0, 520, 0, 34)
	label.Position = UDim2.new(0.5, -260, 0, 96)
	label.BackgroundColor3 = Color3.fromRGB(28, 24, 34)
	label.BackgroundTransparency = 0.25
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(255, 205, 120)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.Visible = false
	label.Parent = gui

	feedback.waitLabel = label
	feedback.waitSeconds = nil
	feedback.waitMine = false
end

function feedback.paintWait()
	if not feedback.waitSeconds then
		feedback.waitLabel.Visible = false
		return
	end

	feedback.waitLabel.Visible = true
	feedback.waitLabel.Text = (feedback.waitMine and "Reconectando... (%ds)"
		or "Adversário desconectado. Aguardando reconexão... (%ds)")
		:format(math.max(0, math.ceil(feedback.waitSeconds)))
end

function feedback.renderWait(snapshot)
	local waiting = snapshot and snapshot.reconnect
	feedback.waitSeconds = waiting and waiting.secondsLeft or nil
	feedback.waitMine = waiting ~= nil and waiting.mine == true
	feedback.paintWait()
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

	if feedback.waitSeconds then
		feedback.waitSeconds = math.max(0, feedback.waitSeconds - dt)
		feedback.paintWait()
	end
end)

-- ===== FURTIVIDADE: O MESMO BONECO, DUAS APARÊNCIAS =====
-- Primeiro lugar do jogo em que um herói aparece diferente pra cada jogador. O
-- servidor cria UM modelo e o Roblox replica igual pros dois clientes; o que
-- torna isto possível é que transparência mexida NO CLIENTE não volta pro
-- servidor nem chega ao adversário. Cada um pinta a sua cópia.
--
-- Isto é só a APARÊNCIA. Quem garante a regra é o servidor, que nem conta ao
-- adversário que este herói existe (ver Snapshot) e recusa ataque contra
-- invisível (ver AttackHero). Se este arquivo inteiro fosse adulterado, o
-- máximo que se ganharia era ver um vulto que continua não sendo alvo.
--
-- `alpha`: 0 = sólido, 1 = sumido.
local function paintHero(anchor, alpha)
	local hidden = alpha >= 1

	for _, child in ipairs(anchor:GetChildren()) do
		if child:IsA("BasePart") then
			-- anéis de time, cilindro de placeholder — e VFX pendurado no herói,
			-- como a bolha do escudo da Kira.
			--
			-- `max`, e não atribuição direta: quem tem transparência PRÓPRIA
			-- (BaseTransparency, gravado por quem criou a peça) nunca fica mais
			-- opaco do que nasceu, mas continua sumindo junto com o dono quando a
			-- furtividade pede. Sem isto o laço forçava tudo pra `alpha` — e como
			-- ele roda a cada snapshot, a bolha aparecia certa por um instante e
			-- voltava a sólida sozinha, várias vezes por turno.
			child.Transparency = math.max(alpha, child:GetAttribute("BaseTransparency") or 0)
		elseif child:IsA("BillboardGui") then
			-- O crachá de ATK/HP some junto com o dono. O balão de texto também:
			-- número de dano flutuando sobre uma casa vazia é a denúncia mais
			-- óbvia possível de que tem alguém ali.
			if child.Name == "HeroInfo" or child.Name == "FloatingText" then
				child.Enabled = not hidden
			end

			local image = child:FindFirstChildWhichIsA("ImageLabel")
			if image then image.ImageTransparency = alpha end
		end
	end

	-- Some do mouse junto com o desenho: sem isto o adversário acharia o
	-- invisível varrendo o tabuleiro com o cursor e vendo o clique pegar em algo
	-- que não está na tela.
	anchor.CanQuery = not hidden
end

local function applyStealthVisuals(state)
	local folder = state and state.heroesFolder
	if not (folder and folder.Parent) then return end

	for _, hero in ipairs(state.heroes or {}) do
		local anchor = folder:FindFirstChild(hero.uid)
		if anchor and anchor:IsA("BasePart") then
			local alpha = 0
			if hero.hidden then
				alpha = 1
			elseif hero.stealth then
				-- o dono enxerga o próprio vulto, translúcido: precisa saber onde
				-- ele está pra planejar a emboscada
				alpha = GameConfig.STEALTH_OWNER_TRANSPARENCY
			end
			paintHero(anchor, alpha)
		end
	end
end

-- ===== ESTADO =====
MatchUpdate.OnClientEvent:Connect(function(newState)
	state = newState

	if state.message then
		queueMessage(state.message)
	end

	-- ANTES do desvio por fase: as casas de promoção são pintadas em TODAS as
	-- fases, inclusive no posicionamento. Elas fazem parte do tabuleiro desde o
	-- começo da partida, e ver as duas apagadas enquanto se escolhe onde largar
	-- os heróis é justamente o que ensina que elas existem e que ainda não
	-- valem. Só mexe em cor de casa, então não depende da GUI de batalha.
	renderPromotionSquares(state)

	feedback.renderWait(state)

	-- ANTES do desvio por fase, como as casas de promoção e pelo mesmo motivo:
	-- mexe só em objeto do Workspace, não depende da GUI de batalha, e um
	-- invisível que reaparecesse durante a tela de fim de jogo entregaria a
	-- posição dele numa revanche.
	applyStealthVisuals(state)

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
		if not resultPanel.Visible then resultPage = "mine" end
		resultPanel.Visible = true
		secondsLeft = nil
		wasMyTurn = false

		-- as colunas continuam: no fim da partida elas viram o placar do que
		-- sobrou de cada lado, e o painel de resultado fica no meio, sem tapar
		renderTeams(state)

		-- o time DELE, com o que cada herói fez. O servidor já mandou o resumo
		-- do ponto de vista deste espectador (ver Snapshot.summary).
		renderResultTeam(state)
		renderReplayButton(state)

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

		clearPromotionHighlights()
		clearHighlights()
		selectedUid = nil
		return
	end

	if state.phase ~= "battle" then
		local placing = state.phase == "placement"

		gui.Enabled = placing
		turnPanel.Visible = false
		timerLabel.Visible = false
		endTurnButton.Visible = false
		resultPanel.Visible = false
		counterBadge.Visible = false
		surrenderButton.Visible = placing
		if not placing then closeConfirm() end
		hideTeams()
		clearPromotionHighlights()
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
	renderPromotionResurrect(state)
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
