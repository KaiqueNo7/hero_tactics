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
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local MOVE_COLOR = Color3.fromRGB(110, 220, 130)
local ATTACK_COLOR = Color3.fromRGB(230, 90, 90)

-- cor base caso o attribute BaseColor não exista (defensivo)
local COLOR_A = Color3.fromRGB(120, 170, 220)
local COLOR_B = Color3.fromRGB(90, 130, 180)

local function fallbackColor(tile)
	local col = string.byte(tile.Name, 1) - string.byte("A", 1)
	return (col % 2 == 0) and COLOR_A or COLOR_B
end

local state = nil
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
local CARD_SIZE = 48
local CARD_GAP = 5
local COLUMN_HEADER = 18
-- Começa abaixo do selo de contra-ataque e termina acima do painel de detalhe
-- (que fica a 112px do rodapé), pra caber até em celular deitado.
local COLUMN_TOP = 78

local SIDE_ONE_COLOR = Color3.fromRGB(70, 150, 255)
local SIDE_TWO_COLOR = Color3.fromRGB(230, 70, 70)

-- Cinza claro, e não chumbo: ImageColor3 MULTIPLICA o sprite, então um tom
-- escuro demais apagava o retrato inteiro e não dava mais pra saber QUEM tinha
-- morrido — que é justamente a informação que a coluna existe pra dar.
local DEAD_TINT = Color3.fromRGB(138, 141, 150)
local DEAD_CARD = Color3.fromRGB(18, 19, 23)

local function buildPortrait(parent)
	local image = Instance.new("ImageLabel")
	image.Name = "Portrait"
	image.Size = UDim2.new(1, -6, 1, -6)
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

		local hpLabel = Instance.new("TextLabel")
		hpLabel.Name = "Hp"
		hpLabel.AnchorPoint = Vector2.new(1, 1)
		hpLabel.Position = UDim2.new(1, -3, 1, -5)
		hpLabel.Size = UDim2.new(0, 24, 0, 13)
		hpLabel.BackgroundTransparency = 1
		hpLabel.TextColor3 = Color3.new(1, 1, 1)
		hpLabel.TextStrokeTransparency = 0.2
		hpLabel.TextXAlignment = Enum.TextXAlignment.Right
		hpLabel.TextSize = 12
		hpLabel.Font = Enum.Font.GothamBlack
		hpLabel.ZIndex = 5
		hpLabel.Parent = card

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
			hpTrack = hpTrack,
			hpFill = hpFill,
			hpLabel = hpLabel,
			cross = cross,
		}
	end

	return { frame = column, nameLabel = nameLabel, rows = rows }
end

local myTeam = buildTeamColumn(true)
local theirTeam = buildTeamColumn(false)

local SPRITE_SHEET_ID = HeroData.GetSpriteId()

-- O servidor transmite o estado várias vezes por ação (mover manda dois, atacar
-- manda mais um, o fim de partida outro). Sem esta guarda, cada transmissão
-- reescrevia as seis fichas e criava seis tweens que animavam de um valor pro
-- MESMO valor — dezenas de tweens por turno do bot, todos para nada.
local function rowSignature(hero)
	if not hero then return "vazio" end
	return ("%d|%d|%s|%s"):format(hero.dataId, hero.currentHp,
		tostring(hero.isAlive), tostring(hero.sideIndex))
end

local function renderRow(row, hero)
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

	if SPRITE_SHEET_ID and data then
		row.portrait.Image = SPRITE_SHEET_ID
		row.portrait.ImageRectSize = HeroData.GetFrameSize()
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

	if alive then
		local ratio = hero.maxHp > 0 and math.clamp(hero.currentHp / hero.maxHp, 0, 1) or 0
		row.hpLabel.Text = tostring(math.max(hero.currentHp, 0))
		row.hpFill.BackgroundColor3 = ratio > 0.5 and Color3.fromRGB(80, 200, 110)
			or (ratio > 0.25 and Color3.fromRGB(220, 180, 70) or Color3.fromRGB(220, 80, 80))
		TweenService:Create(row.hpFill, TweenInfo.new(0.22), {
			Size = UDim2.fromScale(ratio, 1),
		}):Play()
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

	-- Zera as assinaturas: na revanche os heróis voltam com a vida cheia, e uma
	-- assinatura sobrevivente da partida anterior faria a ficha ser pulada e
	-- ficar mostrando o estado do jogo antigo.
	for _, team in ipairs({ myTeam, theirTeam }) do
		for _, row in ipairs(team.rows) do
			row.signature = nil
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
	if not (SPRITE_SHEET_ID and data) then return end

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

	finisherPortrait.Image = SPRITE_SHEET_ID
	finisherPortrait.ImageRectSize = HeroData.GetFrameSize()
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

local function warnNotYourTurn()
	flashTurnBanner("Espere sua vez", WAIT_TURN_COLOR)
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

-- ===== PAINEL DE DETALHE DO HERÓI SELECIONADO =====
local detailPanel = Instance.new("Frame")
detailPanel.Size = UDim2.new(0, 210, 0, 96)
detailPanel.Position = UDim2.new(0, 16, 1, -112)
detailPanel.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
detailPanel.BackgroundTransparency = 0.15
detailPanel.BorderSizePixel = 0
detailPanel.Visible = false
detailPanel.Parent = gui

local detailCorner = Instance.new("UICorner")
detailCorner.CornerRadius = UDim.new(0, 8)
detailCorner.Parent = detailPanel

local detailName = Instance.new("TextLabel")
detailName.Size = UDim2.new(1, -16, 0, 24)
detailName.Position = UDim2.new(0, 8, 0, 6)
detailName.BackgroundTransparency = 1
detailName.TextColor3 = Color3.new(1, 1, 1)
detailName.TextXAlignment = Enum.TextXAlignment.Left
detailName.TextScaled = true
detailName.Font = Enum.Font.GothamBold
detailName.Parent = detailPanel

local detailStats = Instance.new("TextLabel")
detailStats.Size = UDim2.new(1, -16, 0, 20)
detailStats.Position = UDim2.new(0, 8, 0, 32)
detailStats.BackgroundTransparency = 1
detailStats.TextColor3 = Color3.fromRGB(210, 220, 235)
detailStats.TextXAlignment = Enum.TextXAlignment.Left
detailStats.TextScaled = true
detailStats.Font = Enum.Font.Gotham
detailStats.Parent = detailPanel

local detailSkills = Instance.new("TextLabel")
detailSkills.Size = UDim2.new(1, -16, 0, 34)
detailSkills.Position = UDim2.new(0, 8, 0, 54)
detailSkills.BackgroundTransparency = 1
detailSkills.TextColor3 = Color3.fromRGB(180, 215, 255)
detailSkills.TextXAlignment = Enum.TextXAlignment.Left
detailSkills.TextYAlignment = Enum.TextYAlignment.Top
detailSkills.TextWrapped = true
detailSkills.TextSize = 13
detailSkills.Font = Enum.Font.Gotham
detailSkills.Parent = detailPanel

local function showDetail(hero)
	if not hero then
		detailPanel.Visible = false
		return
	end

	local data = HeroData.GetById(hero.dataId)
	detailPanel.Visible = true
	detailName.Text = hero.name
	detailStats.Text = ("%d ATK   %d/%d HP   %s"):format(
		hero.attack, math.max(hero.currentHp, 0), hero.maxHp, hero.ability or "-")

	local names = {}
	for _, key in ipairs(data and data.abilities or {}) do
		local info = HeroData.SKILL_INFO[key]
		table.insert(names, info and info.name or key)
	end
	detailSkills.Text = table.concat(names, " • ")
end

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

-- Definido aqui em cima porque a linha de mira também precisa dele, e em Lua
-- uma função só enxerga os locais declarados ANTES dela.
local function heroByUid(uid)
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
local AIM_DASH_THICKNESS = 0.34
-- Folgas curtas de propósito: entre duas casas vizinhas o centro fica a ~10,4
-- studs, e um par de folgas maior comia o traço inteiro justamente no caso mais
-- comum — mover uma casa.
local AIM_START_PAD = 2.4 -- não cola no herói
local AIM_END_PAD = 3.4 -- onde os traços param pra não invadir a ponta
local AIM_MAX_DASHES = 48
local AIM_FLOW_SPEED = 2.4 -- studs por segundo que os traços "andam" pro alvo
local AIM_NEUTRAL_COLOR = Color3.fromRGB(150, 165, 190)

-- Ponta da seta: duas farpas abertas a partir do bico. Não é um bico fechado
-- porque a câmera olha o tabuleiro de cima e enviesada — um triângulo cheio
-- vira um borrão nessa perspectiva, enquanto duas barras continuam lendo como
-- "aponta pra cá" de qualquer ângulo.
local ARROW_HEAD_LENGTH = 3.6
local ARROW_HEAD_THICKNESS = 0.44
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

local function drawAim(fromPosition, toPosition, color)
	local lift = Vector3.new(0, AIM_LIFT, 0)
	local origin = fromPosition + lift
	local target = toPosition + lift

	local delta = target - origin
	local distance = delta.Magnitude
	if distance < 0.1 then
		hideAim()
		return
	end

	local direction = delta.Unit
	local step = AIM_DASH_LENGTH + AIM_DASH_GAP

	-- o resto móvel faz os traços marcharem em direção ao alvo
	local travelled = AIM_START_PAD + (os.clock() * AIM_FLOW_SPEED) % step
	local limit = distance - AIM_END_PAD
	local used = 0

	while travelled < limit and used < AIM_MAX_DASHES do
		used += 1
		local position = origin + direction * travelled
		local dash = aimDashes[used]
		dash.Size = Vector3.new(AIM_DASH_THICKNESS, AIM_DASH_THICKNESS, AIM_DASH_LENGTH)
		dash.CFrame = CFrame.new(position, position + direction)
		dash.Color = color
		dash.Transparency = 0.15
		travelled += step
	end

	for index = used + 1, AIM_MAX_DASHES do
		aimDashes[index].Transparency = 1
	end

	-- Bico no centro da casa mirada; as farpas abrem pra trás a partir dele.
	-- `base` olha na direção do traçado, então o -Z local dela É a direção da
	-- seta — girar em Y por 180° ∓ abertura devolve exatamente as duas farpas.
	local base = CFrame.new(target, target + direction)
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
	return hero and hero.position or nil
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

	-- a cor já diz o que vai acontecer no clique, sem precisar ler a casa
	local color = AIM_NEUTRAL_COLOR
	if attackTargets[hexId] then
		color = ATTACK_COLOR
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
		showDetail(nil)
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

	local blocked, enemyAt = {}, {}
	for _, other in ipairs(state.heroes) do
		blocked[other.position] = true
		if other.isAlive and not other.isMine then
			enemyAt[other.position] = other.uid
		end
	end

	local isFree = function(hexId) return not blocked[hexId] end

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
			end
		end
	end

	showDetail(hero)
end

-- ===== CLIQUES =====
mouse.Button1Down:Connect(function()
	if not state or state.phase ~= "battle" then return end

	local target = mouse.Target
	if not target then return end

	local heroUid = target:GetAttribute("HeroUid")
	local hexId = target:GetAttribute("HexId")

	-- fora do turno o clique não faz nada, mas ficar em silêncio parecia bug:
	-- avisa sempre que a tentativa foi no tabuleiro (casa ou herói)
	if not state.isMyTurn then
		if heroUid or hexId then
			warnNotYourTurn()
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

	if state.phase == "finished" then
		gui.Enabled = true
		turnPanel.Visible = false
		timerLabel.Visible = false
		counterBadge.Visible = false
		endTurnButton.Visible = false
		detailPanel.Visible = false
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

		clearHighlights()
		selectedUid = nil
		return
	end

	if state.phase ~= "battle" then
		gui.Enabled = false
		counterBadge.Visible = false
		hideTeams()
		clearHighlights()
		selectedUid = nil
		showDetail(nil)
		return
	end

	gui.Enabled = true
	turnPanel.Visible = true
	resultPanel.Visible = false

	counterBadge.Visible = true
	renderCounterBadge(state.counterAttackUsed)
	renderTeams(state)
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

	if state.isMyTurn and not wasMyTurn then
		flashTurnBanner("Sua vez!", MY_TURN_COLOR)
	end
	wasMyTurn = state.isMyTurn

	secondsLeft = state.turnSecondsLeft
	if not secondsLeft then timerLabel.Visible = false end

	local previous = selectedUid
	clearHighlights()
	selectedUid = nil

	if state.isMyTurn and previous then
		local hero = heroByUid(previous)
		if hero and hero.isAlive then
			selectHero(previous)
		end
	else
		showDetail(nil)
	end
end)
