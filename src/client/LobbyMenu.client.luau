--[[
	LobbyMenu.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Os painéis do lobby: mural de regras, campanha e elenco.

	A CAMPANHA é a progressão inteira do jogo: um quadrado por confronto contra
	bot, e vencer entrega o herói daquele quadrado. Ela é GUI e não pad físico
	porque o estado (aberto/trancado/concluído) é POR JOGADOR — uma Part no
	cenário tem uma cor só, igual pra todo mundo que passa por ela.

	Tudo aqui é GUI de tela, e não placa física no cenário, por um motivo prático:
	texto de regra é longo e precisa rolar. Numa SurfaceGui o jogador teria que
	andar até a placa, achar o ângulo e ainda assim ler letra miúda de longe —
	enquanto isso o pad de PvP está logo ali esperando um esbarrão.

	As duas ScreenGui existem porque uma coisa é barra de status e outra é modal:
	  menuGui  — botões e saldo, colados nos cantos, RESPEITANDO o inset da barra
	             do Roblox pra não brigar por espaço com ela (mesma escolha do
	             crachá de nível no LobbyClient)
	  modalGui — os painéis, que cobrem a tela inteira e ignoram o inset

	Só aparece no lobby: durante draft e batalha o MatchUpdate apaga os dois.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Campaign = require(ReplicatedStorage.Modules.Campaign)
local Orientation = require(ReplicatedStorage.Modules.Orientation)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroChallenges = require(ReplicatedStorage.Modules.HeroChallenges)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local Monetization = require(ReplicatedStorage.Modules.Monetization)
local Progression = require(ReplicatedStorage.Modules.Progression)
local RewardFx = require(ReplicatedStorage.Modules.RewardFx)
local SafeArea = require(ReplicatedStorage.Modules.SafeArea)

local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local WalletUpdate = ReplicatedStorage.Remotes:WaitForChild("WalletUpdate")
local RosterUpdate = ReplicatedStorage.Remotes:WaitForChild("RosterUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local PANEL_BG = Color3.fromRGB(16, 19, 28)
local CARD_BG = Color3.fromRGB(26, 31, 44)
local GOLD = Color3.fromRGB(255, 214, 120)
local TEXT_MAIN = Color3.fromRGB(228, 236, 250)
local TEXT_SOFT = Color3.fromRGB(168, 178, 198)
local ACCENT = Color3.fromRGB(90, 130, 200)

-- ===================== HELPERS DE ESTILO =====================
local function corner(parent, radius)
	local instance = Instance.new("UICorner")
	instance.CornerRadius = UDim.new(0, radius or 8)
	instance.Parent = parent
	return instance
end

local function stroke(parent, color, thickness, transparency)
	local instance = Instance.new("UIStroke")
	instance.Color = color
	instance.Thickness = thickness or 1
	instance.Transparency = transparency or 0
	instance.Parent = parent
	return instance
end

local function padding(parent, amount)
	local instance = Instance.new("UIPadding")
	instance.PaddingTop = UDim.new(0, amount)
	instance.PaddingBottom = UDim.new(0, amount)
	instance.PaddingLeft = UDim.new(0, amount)
	instance.PaddingRight = UDim.new(0, amount)
	instance.Parent = parent
	return instance
end

-- Texto que cresce sozinho pra caber: as regras têm parágrafos de tamanhos bem
-- diferentes e fixar altura na mão só rendia texto cortado.
local function paragraph(parent, text, color, size, order)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or TEXT_SOFT
	label.TextSize = size or 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Font = Enum.Font.Gotham
	label.FontFace.Weight = Enum.FontWeight.Medium
	label.LayoutOrder = order or 0
	label.Parent = parent
	return label
end

local function heading(parent, text, order)
	local label = paragraph(parent, text, GOLD, 16, order)
	label.Font = Enum.Font.GothamBold
	return label
end

-- X de duas barras cruzadas: o glifo "✕" não existe nas fontes do Roblox e sai
-- como quadradinho (mesma solução já usada no draft).
local function buildCloseButton(parent)
	local button = Instance.new("TextButton")
	button.Name = "Close"
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, 0, 0, 0)
	button.Size = UDim2.new(0, 30, 0, 30)
	button.BackgroundColor3 = Color3.fromRGB(48, 54, 70)
	button.Text = ""
	button.BorderSizePixel = 0
	button.ZIndex = 6
	button.Parent = parent
	corner(button, 6)

	for _, angle in ipairs({ 45, -45 }) do
		local dash = Instance.new("Frame")
		dash.AnchorPoint = Vector2.new(0.5, 0.5)
		dash.Position = UDim2.fromScale(0.5, 0.5)
		dash.Size = UDim2.new(0, 15, 0, 2)
		dash.BackgroundColor3 = Color3.fromRGB(235, 240, 250)
		dash.BorderSizePixel = 0
		dash.Rotation = angle
		dash.ZIndex = 7
		dash.Parent = button
	end

	return button
end

local function buildHeroImage(parent, data)
	local image = Instance.new("ImageLabel")
	image.Name = "Portrait"
	image.BackgroundTransparency = 1
	image.ScaleType = Enum.ScaleType.Fit
	image.ResampleMode = Enum.ResamplerMode.Pixelated

	-- a folha vem do próprio herói: os criados depois moram em asset separado
	local spriteId = HeroData.GetSpriteId(data)

	if spriteId then
		image.Image = spriteId
		image.ImageRectSize = HeroData.GetFrameSize(data)
		image.ImageRectOffset = HeroData.GetFrameOffset(data)
	else
		image.BackgroundTransparency = 0
		image.BackgroundColor3 = data.color
	end

	image.Parent = parent
	return image
end

-- ===================== GUIs =====================
local menuGui = Instance.new("ScreenGui")
menuGui.Name = "LobbyMenuGui"
menuGui.ResetOnSpawn = false
-- ABAIXO do modal (60). Modal é modal: nada da interface do lobby passa na
-- frente dele. A troca de painel, que era o motivo de eu ter posto a barra por
-- cima antes, virou uma fileira de abas DENTRO do modal — resolve a navegação
-- sem quebrar a hierarquia visual.
menuGui.DisplayOrder = 25
menuGui.Parent = playerGui

local modalGui = Instance.new("ScreenGui")
modalGui.Name = "LobbyModalGui"
modalGui.ResetOnSpawn = false
modalGui.IgnoreGuiInset = true
modalGui.DisplayOrder = 60 -- por cima do overlay de fila do LobbyClient (50)
modalGui.Enabled = false
modalGui.Parent = playerGui

-- ===================== SALDO DE MOEDAS =====================
-- Fica logo abaixo do crachá de nível (LobbyClient), na mesma coluna.
local coinBadge = Instance.new("Frame")
coinBadge.Name = "CoinBadge"
coinBadge.AnchorPoint = Vector2.new(1, 0)
coinBadge.Position = UDim2.new(1, -12, 0, 58)
-- mesma largura do crachá de nível (LobbyClient): os dois ficam um debaixo do
-- outro na mesma coluna, e larguras diferentes deixavam a pilha torta
coinBadge.Size = UDim2.new(0, 150, 0, 28)
coinBadge.BackgroundColor3 = PANEL_BG
coinBadge.BackgroundTransparency = 0.2
coinBadge.BorderSizePixel = 0
coinBadge.Parent = menuGui
corner(coinBadge, 8)

local coinDot = Instance.new("Frame")
coinDot.AnchorPoint = Vector2.new(0, 0.5)
coinDot.Position = UDim2.new(0, 10, 0.5, 0)
coinDot.Size = UDim2.new(0, 13, 0, 13)
coinDot.BackgroundColor3 = GOLD
coinDot.BorderSizePixel = 0
coinDot.Parent = coinBadge
corner(coinDot, 20)

-- A bolinha dourada sozinha não dizia o que era aquele número. O rótulo ao lado
-- dela resolve sem depender de o jogador adivinhar pelo desenho.
local coinName = Instance.new("TextLabel")
coinName.Name = "CoinName"
coinName.AnchorPoint = Vector2.new(0, 0.5)
coinName.Position = UDim2.new(0, 29, 0.5, 0)
coinName.Size = UDim2.new(0, 46, 0, 12)
coinName.BackgroundTransparency = 1
coinName.Text = "COINS"
coinName.TextColor3 = TEXT_SOFT
coinName.TextXAlignment = Enum.TextXAlignment.Left
coinName.TextScaled = true
coinName.Font = Enum.Font.GothamBold
coinName.Parent = coinBadge

local coinNameLimit = Instance.new("UITextSizeConstraint")
coinNameLimit.MaxTextSize = 11
coinNameLimit.Parent = coinName

local coinLabel = Instance.new("TextLabel")
coinLabel.AnchorPoint = Vector2.new(1, 0.5)
coinLabel.Position = UDim2.new(1, -10, 0.5, 0)
coinLabel.Size = UDim2.new(1, -90, 0, 16)
coinLabel.BackgroundTransparency = 1
coinLabel.Text = "0"
coinLabel.TextColor3 = GOLD
coinLabel.TextXAlignment = Enum.TextXAlignment.Right
coinLabel.TextScaled = true
coinLabel.Font = Enum.Font.GothamBlack
coinLabel.Parent = coinBadge

local coinValueLimit = Instance.new("UITextSizeConstraint")
coinValueLimit.MaxTextSize = 15
coinValueLimit.Parent = coinLabel

RewardFx.BindCoins(coinBadge, coinDot, function(value)
	coinLabel.Text = Monetization.FormatCoins(value)
end)

local myCoins = 0

-- Elenco comprado e a vitrine que o desenha. Declarados AQUI, antes da carteira,
-- porque tanto o saldo quanto a lista de heróis mandam redesenhar as linhas — e
-- as duas coisas podem chegar do servidor antes do menu ser montado. Declarado
-- depois, `refreshAllHeroRows` viraria uma global nil dentro do renderWallet.
--
-- `heroRefreshers` é [dataId] = função que redesenha aquela linha. O buildStore
-- zera o registro a cada abertura: a vitrine é remontada, e os refreshers velhos
-- apontariam pra Frames já destruídas.
local myHeroes = {} -- [dataId] = true, só os COMPRADOS
local heroRefreshers = {}

local myChallenges = {} -- ["dataId"] = { stars = {...}, turns = {...} }
local myFightStars = {} -- ["dataId"] = estrelas do confronto de campanha
local challengeHeroId = nil

local function refreshAllHeroRows()
	for _, refresh in pairs(heroRefreshers) do
		refresh()
	end
end

local function renderWallet(payload)
	myCoins = payload.coins or 0

	-- o preço não muda, mas o "Faltam X" e a cor do botão dependem do saldo
	refreshAllHeroRows()

	RewardFx.SetCoins(myCoins)
end

WalletUpdate.OnClientEvent:Connect(renderWallet)

-- ===================== ELENCO =====================
-- O servidor manda a lista de ids conquistados; o catálogo (que o cliente já
-- tem) diz quem é inicial. A soma dos dois é o conjunto que o Campaign lê pra
-- dizer o estado de cada quadrado — a MESMA conta que o servidor faz com o
-- GetPlayableIds antes de aceitar a entrada no confronto.
local function ownsHero(data)
	return HeroData.IsStarter(data) or myHeroes[data.id] == true
end

local function ownedSet()
	local set = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if ownsHero(data) then set[data.id] = true end
	end
	return set
end

-- ===================== QUADRADOS NO CENÁRIO =====================
-- Os pads de confronto existem pra todo mundo (o servidor cria e marca com a
-- tag), mas o ESTADO é de cada um. Pintar aqui, no cliente, é o que deixa o
-- mesmo pad estar verde pra quem já pode entrar e cinza com cadeado pra quem
-- ainda não — mexer em cor/transparência no cliente não volta pro servidor nem
-- vaza pro outro jogador (mesma ideia do vulto do Nash).
local PAD_COLOR = {
	open = Color3.fromRGB(60, 170, 130),
	done = Color3.fromRGB(64, 72, 92),
	locked = Color3.fromRGB(92, 94, 104),
}

-- Cadeado desenhado com duas Frames (corpo + arco), pelo mesmo motivo do X do
-- botão de fechar: o glifo 🔒 não existe nas fontes do Roblox e sai quadradinho.
-- Medidas em ESCALA, não em pixel. O retrato do pad é dimensionado no servidor
-- (GameStartTrigger.FIGHT_PORTRAIT_SCALE) e o cadeado mora dentro do MESMO
-- billboard: em pixel fixo ele parava de caber assim que o retrato encolhia —
-- 34px de cadeado num billboard de 66px de largura é metade da moldura. Assim
-- ele acompanha qualquer escala futura sozinho.
local function buildPadLock(parent)
	local holder = Instance.new("Frame")
	holder.Name = "Lock"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.38, 0) -- meio do retrato, acima do nome
	holder.Size = UDim2.new(0.42, 0, 0.42, 0)
	holder.SizeConstraint = Enum.SizeConstraint.RelativeXX -- quadrado, não achatado
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = parent

	local shackle = Instance.new("Frame")
	shackle.Name = "Shackle"
	shackle.AnchorPoint = Vector2.new(0.5, 0)
	shackle.Position = UDim2.new(0.5, 0, 0, 0)
	shackle.Size = UDim2.new(0.6, 0, 0.55, 0)
	shackle.BackgroundTransparency = 1
	shackle.Parent = holder
	corner(shackle, 10)
	stroke(shackle, Color3.fromRGB(226, 232, 245), 3, 0)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.AnchorPoint = Vector2.new(0.5, 1)
	body.Position = UDim2.new(0.5, 0, 1, 0)
	body.Size = UDim2.new(1, 0, 0.65, 0)
	body.BackgroundColor3 = Color3.fromRGB(226, 232, 245)
	body.BorderSizePixel = 0
	body.Parent = holder
	corner(body, 6)

	return holder
end

local function paintFightPad(pad, owned)
	local fight = Campaign.GetFight(pad:GetAttribute("FightHero"))
	if not fight then return end

	local state = Campaign.StateOf(owned, fight)
	pad.Color = PAD_COLOR[state]

	local label = pad:FindFirstChild("FightLabel")
	if not label then return end

	local portrait = label:FindFirstChild("Portrait")
	local nameLabel = label:FindFirstChild("HeroName")
	local lock = label:FindFirstChild("Lock") or buildPadLock(label)

	if portrait then
		-- trancado vira silhueta; concluído fica desbotado, mas reconhecível
		portrait.ImageColor3 = state == "locked" and Color3.fromRGB(46, 50, 62)
			or (state == "done" and Color3.fromRGB(170, 178, 195) or Color3.new(1, 1, 1))
	end

	if nameLabel then
		-- sem glifo de "check" nem cadeado em texto: as fontes do Roblox não têm
		-- esses símbolos e eles saem como quadradinho. Quem conta o estado é a
		-- cor do nome, a cor do pad e o cadeado desenhado ali em cima.
		nameLabel.TextColor3 = state == "open" and Color3.new(1, 1, 1)
			or (state == "done" and Color3.fromRGB(150, 200, 175) or Color3.fromRGB(150, 156, 172))
	end

	lock.Visible = state == "locked"
end

local function paintAllFightPads()
	local owned = ownedSet()
	for _, pad in ipairs(CollectionService:GetTagged(Campaign.PAD_TAG)) do
		paintFightPad(pad, owned)
	end
end

-- Pad que chega depois (streaming, ou o servidor criando na entrada) nasce
-- pintado: sem isto o jogador que anda até lá encontra a cor de fábrica.
CollectionService:GetInstanceAddedSignal(Campaign.PAD_TAG):Connect(function(pad)
	paintFightPad(pad, ownedSet())
end)

-- Preenchido lá embaixo (o painel aberto se redesenha quando chega elenco
-- novo). Declarado aqui porque o RosterUpdate pode chegar antes do menu montar.
local rebuildBody

RosterUpdate.OnClientEvent:Connect(function(payload)
	local set = {}
	for _, dataId in ipairs(payload.owned or {}) do
		set[dataId] = true
	end
	myHeroes = set
	refreshAllHeroRows()
	paintAllFightPads()

	-- herói novo muda o estado dos quadrados (o grupo seguinte pode ter aberto)
	-- e a lista de heróis: redesenha o painel que estiver na tela
	if rebuildBody then rebuildBody() end
end)

paintAllFightPads()

-- ===================== MODAL =====================
local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(6, 7, 11)
backdrop.BackgroundTransparency = 0.35
backdrop.BorderSizePixel = 0
backdrop.Text = ""
backdrop.AutoButtonColor = false
backdrop.Parent = modalGui

-- ÁREA ÚTIL DO MODAL
-- O fundo escurecido cobre a tela inteira (é isso que faz o modal ser modal),
-- mas o PAINEL não pode subir até o topo: lá moram o menu, o chat e o microfone
-- do Roblox. No celular, onde essa faixa é proporcionalmente mais alta, a borda
-- de cima do painel e a fileira de abas caíam bem embaixo dos botões deles — e o
-- toque ia pro Roblox em vez de trocar de aba. O painel é centralizado DENTRO
-- desta área, não da tela.
local modalArea = Instance.new("Frame")
modalArea.Name = "SafeArea"
modalArea.BackgroundTransparency = 1
modalArea.Parent = modalGui

local function layoutModalArea()
	local top = SafeArea.Top()
	modalArea.Position = UDim2.new(0, 0, 0, top)
	modalArea.Size = UDim2.new(1, 0, 1, -(top + SafeArea.MARGIN))
end

layoutModalArea()
SafeArea.OnChange(layoutModalArea)

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
-- em escala pra caber tanto em celular deitado quanto em monitor; a restrição
-- abaixo impede que vire um painel gigante numa tela grande
panel.Size = UDim2.new(0.88, 0, 0.86, 0)
panel.BackgroundColor3 = PANEL_BG
panel.BorderSizePixel = 0
panel.Parent = modalArea
corner(panel, 14)
stroke(panel, ACCENT, 2, 0.2)

local panelSize = Instance.new("UISizeConstraint")
panelSize.MaxSize = Vector2.new(640, 400)
panelSize.MinSize = Vector2.new(280, 200)
panelSize.Parent = panel

local panelPadding = padding(panel, 14)

local panelTitle = Instance.new("TextLabel")
panelTitle.Size = UDim2.new(1, -40, 0, 28)
panelTitle.BackgroundTransparency = 1
panelTitle.Text = ""
panelTitle.TextColor3 = GOLD
panelTitle.TextXAlignment = Enum.TextXAlignment.Left
panelTitle.TextScaled = true
panelTitle.Font = Enum.Font.GothamBlack
panelTitle.FontFace.Weight = Enum.FontWeight.Bold
panelTitle.Parent = panel

-- ===== ABAS DENTRO DO MODAL =====
-- A barra do lobby fica ABAIXO do modal (é o certo: modal é modal). Só que o
-- fundo escurecido cobre a tela inteira, então com a barra embaixo dela um
-- toque em "HERÓIS" com as regras abertas ia parar no fundo e só fechava o
-- painel. A troca de painel mudou de lugar: agora mora aqui dentro, onde
-- nenhum fundo passa na frente.
-- ===== A FILEIRA DE ABAS =====
-- Deitada no Landscape e EM PÉ no Portrait. Duas razões, e as duas aparecem na
-- tela estreita: três botões de 96px lado a lado não cabem, e a fileira encostava
-- no nível e nas moedas, que são ancorados no canto de cima da TELA e passam por
-- cima do painel.
--
-- Descer a fileira resolve a batida sem mexer nos crachás: eles ficam onde estão,
-- e quem sai da frente é o menu. O `TAB_CLEARANCE` é a altura que os dois crachás
-- ocupam a partir do topo (o de moedas começa em 58 e tem 28), com folga.
local TAB_HEIGHT = 26
local TAB_GAP = 6
local TAB_WIDTH = 96
local TAB_TOP = 36
local TAB_CLEARANCE = 62
local TAB_COUNT = 3

local tabTop = TAB_TOP
local BODY_TOP = TAB_TOP + TAB_HEIGHT + TAB_GAP

local openModal -- definido mais abaixo; as abas precisam dele aqui

local tabRow = Instance.new("Frame")
tabRow.Name = "Tabs"
tabRow.Position = UDim2.new(0, 0, 0, 36)
tabRow.Size = UDim2.new(1, 0, 0, TAB_HEIGHT)
tabRow.BackgroundTransparency = 1
tabRow.Parent = panel

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabRow

local tabs = {}

local function buildTab(text, key, order, accent)
	local button = Instance.new("TextButton")
	button.Name = key
	button.Size = UDim2.new(0, 96, 1, 0)
	button.BackgroundColor3 = CARD_BG
	button.Text = text
	button.TextColor3 = TEXT_SOFT
	button.TextSize = 13
	button.Font = Enum.Font.GothamBold
	button.BorderSizePixel = 0
	button.LayoutOrder = order
	button.Parent = tabRow
	corner(button, 6)

	local edge = stroke(button, accent or ACCENT, 1, 0.6)
	tabs[key] = { button = button, edge = edge, accent = accent or ACCENT }

	button.MouseButton1Click:Connect(function()
		openModal(key)
	end)
end

local function refreshTabs(activeKey)
	for key, tab in pairs(tabs) do
		local active = key == activeKey
		tab.button.BackgroundColor3 = active and Color3.fromHex("#2450ef") or CARD_BG
	end
end

buildTab("REGRAS", "rules", 1)
buildTab("CAMPANHA", "campaign", 2)
buildTab("HERÓIS", "store", 3)

local body = Instance.new("ScrollingFrame")
body.Name = "Body"
body.Position = UDim2.new(0, 0, 0, BODY_TOP)
body.Size = UDim2.new(1, 0, 1, -BODY_TOP)

-- Chamado na entrada e a cada rotação. Reposiciona o que já existe em vez de
-- montar uma segunda barra: os botões são os mesmos, muda direção, largura e
-- onde a fileira começa.
local function layoutTabs(orientation)
	local vertical = orientation == Orientation.PORTRAIT

	tabLayout.FillDirection = vertical
		and Enum.FillDirection.Vertical
		or Enum.FillDirection.Horizontal

	tabTop = vertical and (TAB_TOP + TAB_CLEARANCE) or TAB_TOP
	BODY_TOP = tabTop + TAB_HEIGHT + TAB_GAP

	if vertical then
		-- Empilhados, cada um ocupa a largura toda do painel e a fileira cresce
		-- pra baixo. O corpo desce junto pra não ficar por baixo dos botões.
		local altura = TAB_COUNT * TAB_HEIGHT + (TAB_COUNT - 1) * TAB_GAP
		tabRow.Size = UDim2.new(1, 0, 0, altura)
		BODY_TOP = tabTop + altura + TAB_GAP
	else
		tabRow.Size = UDim2.new(1, 0, 0, TAB_HEIGHT)
	end

	tabRow.Position = UDim2.new(0, 0, 0, tabTop)

	for _, tab in pairs(tabs) do
		tab.button.Size = vertical
			and UDim2.new(1, 0, 0, TAB_HEIGHT)
			or UDim2.new(0, TAB_WIDTH, 1, 0)
	end

	body.Position = UDim2.new(0, 0, 0, BODY_TOP)
	body.Size = UDim2.new(1, 0, 1, -BODY_TOP)
end

body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollBarThickness = 5
body.ScrollBarImageColor3 = ACCENT
body.Parent = panel

layoutTabs(Orientation.Current())
Orientation.OnChange(layoutTabs)

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.Padding = UDim.new(0, 10)
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body

local bodyPadding = Instance.new("UIPadding")
bodyPadding.PaddingRight = UDim.new(0, 10)
bodyPadding.PaddingLeft = UDim.new(0, 5)
bodyPadding.PaddingBottom = UDim.new(0, 6)
bodyPadding.PaddingTop = UDim.new(0, 10)
bodyPadding.Parent = body

local closeButton = buildCloseButton(panel)

local currentPanel = nil

local function closeModal()
	if not currentPanel then return end
	currentPanel = nil
	modalGui.Enabled = false
end

closeButton.MouseButton1Click:Connect(closeModal)

-- ===================== DESBLOQUEIO DE HERÓI (REVEAL) =====================
-- A comemoração NUNCA sai do RosterUpdate, que chega em plena partida: quem
-- guarda o que ainda não foi mostrado é o RewardQueueService, no servidor. O
-- cliente pede a fila ao chegar no lobby e desenrola um card de herói por vez;
-- quando não sobra herói, o XP e as moedas voam pros crachás (RewardFx) em vez
-- de virar mais um painel. É o que faz a comemoração sobreviver a uma sequência
-- de campanha inteira — e a fechar o jogo.
local UNLOCK_GREEN = Color3.fromRGB(90, 235, 150)

local inLobbyNow = true
local pendingUnlockIds = {}
local pendingXp, pendingCoins = 0, 0
local pendingXpTotal, pendingCoinsTotal = 0, 0
local showNextReward

local function hasPendingReward()
	return #pendingUnlockIds > 0 or pendingXp > 0 or pendingCoins > 0
end

local rewardGui = Instance.new("ScreenGui")
rewardGui.Name = "HeroRewardGui"
rewardGui.ResetOnSpawn = false
rewardGui.IgnoreGuiInset = true
rewardGui.DisplayOrder = 70 -- acima do modal de abas (60): a comemoração vence qualquer painel aberto
rewardGui.Enabled = false
rewardGui.Parent = playerGui

local rewardBackdrop = Instance.new("TextButton")
rewardBackdrop.Name = "Backdrop"
rewardBackdrop.Size = UDim2.fromScale(1, 1)
rewardBackdrop.BackgroundColor3 = Color3.fromRGB(4, 6, 8)
rewardBackdrop.BackgroundTransparency = 0.25
rewardBackdrop.BorderSizePixel = 0
rewardBackdrop.Text = ""
rewardBackdrop.AutoButtonColor = false
rewardBackdrop.Parent = rewardGui

local rewardPanel = Instance.new("Frame")
rewardPanel.Name = "Panel"
rewardPanel.AnchorPoint = Vector2.new(0.5, 0.5)
rewardPanel.Position = UDim2.fromScale(0.5, 0.5)
rewardPanel.Size = UDim2.new(0.7, 0, 0.6, 0)
rewardPanel.BackgroundColor3 = PANEL_BG
rewardPanel.BorderSizePixel = 0
rewardPanel.Parent = rewardGui
corner(rewardPanel, 16)

local rewardPanelSize = Instance.new("UISizeConstraint")
rewardPanelSize.MaxSize = Vector2.new(320, 380)
rewardPanelSize.MinSize = Vector2.new(220, 280)
rewardPanelSize.Parent = rewardPanel

local rewardStroke = stroke(rewardPanel, UNLOCK_GREEN, 3, 0)

local rewardPortraitHolder = Instance.new("Frame")
rewardPortraitHolder.Name = "PortraitHolder"
rewardPortraitHolder.AnchorPoint = Vector2.new(0.5, 0)
rewardPortraitHolder.Position = UDim2.new(0.5, 0, 0, 24)
rewardPortraitHolder.Size = UDim2.new(0, 160, 0, 160)
rewardPortraitHolder.BackgroundTransparency = 1
rewardPortraitHolder.ZIndex = 2
rewardPortraitHolder.Parent = rewardPanel

local rewardTitle = Instance.new("TextLabel")
rewardTitle.Name = "Title"
rewardTitle.AnchorPoint = Vector2.new(0.5, 0)
rewardTitle.Position = UDim2.new(0.5, 0, 0, 196)
rewardTitle.Size = UDim2.new(1, -20, 0, 26)
rewardTitle.BackgroundTransparency = 1
rewardTitle.Text = "HERÓI DESBLOQUEADO!"
rewardTitle.TextColor3 = UNLOCK_GREEN
rewardTitle.TextStrokeColor3 = UNLOCK_GREEN
rewardTitle.TextStrokeTransparency = 0.5
rewardTitle.TextScaled = true
rewardTitle.Font = Enum.Font.GothamBlack
rewardTitle.ZIndex = 2
rewardTitle.Parent = rewardPanel

local rewardTitleLimit = Instance.new("UITextSizeConstraint")
rewardTitleLimit.MaxTextSize = 20
rewardTitleLimit.Parent = rewardTitle

local rewardName = Instance.new("TextLabel")
rewardName.Name = "HeroName"
rewardName.AnchorPoint = Vector2.new(0.5, 0)
rewardName.Position = UDim2.new(0.5, 0, 0, 228)
rewardName.Size = UDim2.new(1, -20, 0, 30)
rewardName.BackgroundTransparency = 1
rewardName.Text = ""
rewardName.TextColor3 = TEXT_MAIN
rewardName.TextScaled = true
rewardName.Font = Enum.Font.GothamBold
rewardName.ZIndex = 2
rewardName.Parent = rewardPanel

local rewardNameLimit = Instance.new("UITextSizeConstraint")
rewardNameLimit.MaxTextSize = 24
rewardNameLimit.Parent = rewardName

local rewardButton = Instance.new("TextButton")
rewardButton.Name = "Continue"
rewardButton.AnchorPoint = Vector2.new(0.5, 1)
rewardButton.Position = UDim2.new(0.5, 0, 1, -18)
rewardButton.Size = UDim2.new(0.7, 0, 0, 36)
rewardButton.BackgroundColor3 = UNLOCK_GREEN
rewardButton.Text = "CONTINUAR"
rewardButton.TextColor3 = Color3.fromRGB(10, 20, 14)
rewardButton.Font = Enum.Font.GothamBlack
rewardButton.TextScaled = true
rewardButton.BorderSizePixel = 0
rewardButton.ZIndex = 2
rewardButton.Parent = rewardPanel
corner(rewardButton, 8)

local rewardButtonLimit = Instance.new("UITextSizeConstraint")
rewardButtonLimit.MaxTextSize = 16
rewardButtonLimit.Parent = rewardButton

-- a borda pulsa: a espessura efetiva sai da transparência, oscilando sem fim
local rewardStrokeTween = TweenService:Create(rewardStroke,
	TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Transparency = 0.6 })

local function closeReward()
	rewardStrokeTween:Cancel()
	rewardGui.Enabled = false

	-- outro herói já pode ter chegado enquanto este estava na tela (revanche
	-- rápida, ou dois confrontos terminando perto um do outro), e depois dos
	-- heróis ainda vem o resumo de XP e moedas
	if hasPendingReward() then
		task.defer(showNextReward)
	end
end

local function openRewardPanel()
	rewardGui.Enabled = true
	rewardPanel.Size = UDim2.new(0.5, 0, 0.4, 0)
	TweenService:Create(rewardPanel, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.new(0.7, 0, 0.6, 0),
	}):Play()

	rewardStrokeTween:Play()
end

-- Fecha a sequência: com os cards de herói fora do caminho, o que sobrou de XP e
-- moedas desde a última visita ao lobby vai direto pros crachás. O total vem do
-- servidor; o ponto de partida é ele menos o ganho, então a contagem termina
-- exatamente no valor gravado.
local function flushProgress()
	local xp, coins = pendingXp, pendingCoins
	pendingXp, pendingCoins = 0, 0

	if xp > 0 then RewardFx.QueueXp(pendingXpTotal - xp, pendingXpTotal) end
	if coins > 0 then RewardFx.QueueCoins(pendingCoinsTotal - coins, pendingCoinsTotal) end
end

function showNextReward()
	local dataId = table.remove(pendingUnlockIds, 1)

	if not dataId then
		flushProgress()
		return
	end

	local data = HeroData.GetById(dataId)
	if not data then return end

	for _, child in ipairs(rewardPortraitHolder:GetChildren()) do
		child:Destroy()
	end
	local portrait = buildHeroImage(rewardPortraitHolder, data)
	portrait.Size = UDim2.fromScale(1, 1)
	portrait.ZIndex = 3

	rewardPortraitHolder.Visible = true

	rewardTitle.Position = UDim2.new(0.5, 0, 0, 196)
	rewardTitle.TextStrokeTransparency = 0.5
	rewardTitle.Font = Enum.Font.GothamBlack
	rewardTitle.Text = "HERÓI DESBLOQUEADO!"

	rewardName.Position = UDim2.new(0.5, 0, 0, 228)
	rewardName.Size = UDim2.new(1, -20, 0, 30)
	rewardName.Font = Enum.Font.GothamBold
	rewardName.TextColor3 = TEXT_MAIN
	rewardName.Text = data.name

	openRewardPanel()
end

rewardButton.MouseButton1Click:Connect(closeReward)
rewardBackdrop.MouseButton1Click:Connect(closeReward)

local function clearBody()
	for _, child in ipairs(body:GetChildren()) do
		if not child:IsA("UILayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	body.CanvasPosition = Vector2.new()
end

local function keepScroll(build)
	local position = body.CanvasPosition
	clearBody()
	build()
	task.defer(function()
		if body.Parent then body.CanvasPosition = position end
	end)
end

-- ===================== CONTEÚDO: REGRAS =====================
-- Os números saem do GameConfig e do Progression de propósito: se algum dia o
-- alcance do Sprint ou o XP de vitória mudar, o mural muda junto em vez de
-- virar documentação mentirosa.
local function buildRules()
	local order = 0
	local function next()
		order += 1
		return order
	end

	heading(body, "Objetivo", next())
	paragraph(body, ("Elimine os %d heróis do adversário. Se os dois times caírem no mesmo lance, é empate.")
		:format(GameConfig.HEROES_PER_PLAYER), TEXT_SOFT, 14, next())

	heading(body, "Escolha dos heróis", next())
	paragraph(body, ("Vocês escolhem alternando, um herói por vez, até %d cada. O catálogo é " ..
		"compartilhado: o herói que o adversário levar some da sua lista também. Arraste a " ..
		"carta até uma casa verde da sua fileira para posicionar.")
		:format(GameConfig.HEROES_PER_PLAYER), TEXT_SOFT, 14, next())

	heading(body, "O turno", next())
	paragraph(body, ("Cada herói pode mover uma vez E atacar uma vez por turno, nessa ordem. " ..
		"Quem já atacou não anda mais naquele turno. Você tem %d segundos por turno — " ..
		"se o tempo acabar, a vez passa sozinha.")
		:format(GameConfig.TURN_TIME_LIMIT), TEXT_SOFT, 14, next())

	heading(body, "Movimento por casas", next())
	paragraph(body, ("%d casas por turno; heróis com Sprint andam %d. O caminho precisa estar " ..
		"livre — heróis bloqueiam a passagem, e os túmulos também: a casa de quem morreu " ..
		"continua ocupada até o fim da partida.")
		:format(GameConfig.BASE_MOVE_RANGE, GameConfig.SPRINT_MOVE_RANGE), TEXT_SOFT, 14, next())

	heading(body, "Ataque corpo a corpo", next())
	paragraph(body, ("Alcance %d: só dá para bater em quem está numa casa vizinha.")
		:format(GameConfig.BASE_ATTACK_RANGE), TEXT_SOFT, 14, next())

	heading(body, "Ataque à distância (Ranged)", next())
	paragraph(body, ("Alcance %d. Mas o caminho até o alvo também precisa estar livre: um herói " ..
		"parado na casa do meio bloqueia o tiro. A vantagem é ficar exatamente a %d casas — " ..
		"de lá o Ranged bate sem levar contra-ataque de quem só alcança %d.")
		:format(GameConfig.RANGED_ATTACK_RANGE, GameConfig.RANGED_ATTACK_RANGE,
			GameConfig.BASE_ATTACK_RANGE), TEXT_SOFT, 14, next())

	heading(body, "Taunt", next())
	paragraph(body, "Enquanto um inimigo com Taunt estiver numa casa vizinha ao seu herói, ele é " ..
		"o único alvo que esse herói consegue atacar.", TEXT_SOFT, 14, next())

	heading(body, "Contra-ataque — e o limite dele", next())
	paragraph(body, "Quando seu herói é atacado e sobrevive, ele revida sozinho, desde que o " ..
		"atacante esteja dentro do alcance dele.\n\n" ..
		"O limite: é UM contra-ataque por turno, no turno inteiro, contando os dois lados. " ..
		"Depois que ele acontece, ninguém mais revida até a vez virar — por isso o segundo " ..
		"ataque do turno é sempre o mais barato. O selo no canto superior direito da tela " ..
		"mostra se o contra-ataque do turno ainda está de pé.",
		TEXT_SOFT, 14, next())

	heading(body, "Morte Súbita", next())
	paragraph(body, ("No turno %d aparece o aviso. A partir do turno %d, TODOS os heróis do " ..
		"tabuleiro perdem %d de vida no início de cada turno — partida arrastada não " ..
		"existe aqui.")
		:format(GameConfig.SUDDEN_DEATH_WARNING_TURN, GameConfig.SUDDEN_DEATH_START_TURN,
			GameConfig.SUDDEN_DEATH_DAMAGE), TEXT_SOFT, 14, next())

	heading(body, "Recompensas", next())
	paragraph(body, ("Vitória em PvP paga de %d a %d de XP, conforme quantos heróis seus " ..
		"sobreviveram. Derrota e empate pagam %d. Contra o bot a vitória paga %d — ele é " ..
		"treino, não fazenda de XP.")
		:format(Progression.WIN_XP_BY_SURVIVORS[1], Progression.WIN_XP_BY_SURVIVORS[3],
			Progression.LOSS_XP, Progression.BOT_WIN_XP), TEXT_SOFT, 14, next())
end

-- ===================== CONTEÚDO: CAMPANHA =====================
-- Um quadrado por confronto, na ordem da escada. O estado sai do Campaign, que
-- é a mesma função que o servidor chama pra aceitar ou recusar a entrada — a
-- cor aqui nunca promete o que o servidor vai negar.
local FIGHT_STYLE = {
	open   = { edge = Color3.fromRGB(90, 200, 140), tag = "DISPONÍVEL",  tagColor = Color3.fromRGB(150, 240, 180) },
	done   = { edge = Color3.fromRGB(120, 130, 155), tag = "CONCLUÍDO",  tagColor = Color3.fromRGB(180, 190, 210) },
	locked = { edge = Color3.fromRGB(70, 74, 90),    tag = "BLOQUEADO",  tagColor = Color3.fromRGB(150, 156, 172) },
}

local function teamNames(fight)
	local names = {}
	for _, dataId in ipairs(fight.team) do
		table.insert(names, HeroData.GetById(dataId).name)
	end
	return table.concat(names, ", ")
end

-- A pilha do quadrado, medida a partir da área ÚTIL (célula menos o padding de
-- 8 de cada lado): retrato até 74, nome até 96, etiqueta até 109, time até 137.
-- A faixa de estrelas começa em 140 e ocupa 18, então a célula precisa de 158 de
-- área útil — e é daí que sai o 174 do CellSize.
local FIGHT_STARS_TOP = 140
local FIGHT_CARD_H = FIGHT_STARS_TOP + 18 + 16

local function buildFightSquare(grid, fight, state, order)
	local style = FIGHT_STYLE[state]
	local data = HeroData.GetById(fight.hero)

	local card = Instance.new("TextButton")
	card.Name = data.name
	card.BackgroundColor3 = state == "locked" and Color3.fromRGB(20, 22, 30) or CARD_BG
	card.Text = ""
	card.AutoButtonColor = state ~= "locked"
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = grid
	corner(card, 10)
	padding(card, 8)
	stroke(card, style.edge, state == "open" and 2 or 1, state == "open" and 0 or 0.5)

	local portraitHolder = Instance.new("Frame")
	portraitHolder.Size = UDim2.new(1, 0, 0, 74)
	portraitHolder.BackgroundColor3 = Color3.fromRGB(18, 21, 30)
	portraitHolder.BorderSizePixel = 0
	portraitHolder.Parent = card
	corner(portraitHolder, 8)

	local portrait = buildHeroImage(portraitHolder, data)
	portrait.Size = UDim2.new(1, -8, 1, -8)
	portrait.Position = UDim2.new(0, 4, 0, 4)
	-- trancado fica em silhueta: dá pra ver que existe alguém ali, não quem é
	portrait.ImageColor3 = state == "locked" and Color3.fromRGB(40, 44, 58) or Color3.new(1, 1, 1)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Position = UDim2.new(0, 0, 0, 78)
	nameLabel.Size = UDim2.new(1, 0, 0, 18)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = data.name
	nameLabel.TextColor3 = state == "locked" and TEXT_SOFT or TEXT_MAIN
	nameLabel.TextSize = 15
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Parent = card

	local tag = Instance.new("TextLabel")
	tag.Position = UDim2.new(0, 0, 0, 96)
	tag.Size = UDim2.new(1, 0, 0, 13)
	tag.BackgroundTransparency = 1
	tag.Text = style.tag
	tag.TextColor3 = style.tagColor
	tag.TextSize = 10
	tag.Font = Enum.Font.GothamBold
	tag.Parent = card

	local teamLabel = Instance.new("TextLabel")
	teamLabel.Position = UDim2.new(0, 0, 0, 111)
	teamLabel.Size = UDim2.new(1, 0, 0, 26)
	teamLabel.BackgroundTransparency = 1
	teamLabel.Text = state == "locked" and "?" or teamNames(fight)
	teamLabel.TextColor3 = Color3.fromRGB(160, 172, 196)
	teamLabel.TextSize = 11
	teamLabel.TextWrapped = true
	teamLabel.Font = Enum.Font.Gotham
	teamLabel.Parent = card

	if state == "locked" then return end

	-- A NOTA DO CONFRONTO, e não a dos desafios: acesa até a estrela conquistada,
	-- apagada no que falta.
	--
	-- FAIXA PRÓPRIA NO RODAPÉ, em offset absoluto e não ancorada embaixo. Ancorar
	-- em `1, -20` colocava a linha em cima do nome do time, que termina em 137 na
	-- área útil de 142 — as estrelas ficavam sobrepostas e espremidas contra a
	-- borda. A célula cresceu o bastante pra caber a faixa inteira (ver
	-- gridLayout.CellSize), e este número é onde ela começa.
	--
	-- RichText porque a linha tem DUAS cores: conquistada em dourado, faltando em
	-- cinza. Uma cor só pintava a estrela vazia de dourado também, e aí ★★☆ lia
	-- como três. O espaço entre os glifos é o respiro que o TextLabel não dá.
	local fightStars = myFightStars[tostring(fight.hero)] or 0
	local marks = {}
	for index = 1, Campaign.MAX_STARS do
		local lit = index <= fightStars
		table.insert(marks, ('<font color="#%s">%s</font>')
			:format(lit and "FFCE68" or "3E4354", lit and "★" or "☆"))
	end

	local scoreLabel = Instance.new("TextLabel")
	scoreLabel.Name = "FightStarScore"
	scoreLabel.Position = UDim2.new(0, 0, 0, FIGHT_STARS_TOP)
	scoreLabel.Size = UDim2.new(1, 0, 0, 18)
	scoreLabel.BackgroundTransparency = 1
	scoreLabel.RichText = true
	scoreLabel.Text = table.concat(marks, " ")
	scoreLabel.TextColor3 = GOLD
	scoreLabel.TextSize = 15
	scoreLabel.Font = Enum.Font.GothamBold
	scoreLabel.Parent = card

	local stars = (myChallenges[tostring(fight.hero)] or {}).stars or {}
	local hasChallenges = state == "done" and HeroChallenges.CountFor(fight.hero) > 0

	if hasChallenges then
		local total = HeroChallenges.TotalStars(stars, fight.hero)
		local maximum = HeroChallenges.MaxStarsFor(fight.hero)

		tag.Text = ("★ %d/%d"):format(total, maximum)
		tag.TextColor3 = total == maximum and GOLD or Color3.fromRGB(210, 200, 170)
		tag.TextSize = 12
		teamLabel.Text = "Toque para ver os desafios"
		teamLabel.TextColor3 = Color3.fromRGB(150, 200, 240)
	end

	card.MouseButton1Click:Connect(function()
		if hasChallenges then
			challengeHeroId = fight.hero
			rebuildBody(true)
			return
		end

		-- O cliente só diz QUAL confronto. Quem confere a escada e monta o time
		-- do bot é o servidor (GameStartTrigger/Campaign).
		GameAction:FireServer("fight", fight.hero)
		closeModal()
	end)
end

local CHALLENGE_STATE_COLOR = {
	open   = Color3.fromRGB(150, 240, 180),
	done   = GOLD,
	locked = Color3.fromRGB(120, 126, 142),
}

local function starLine(earned)
	return string.rep("★", earned)
		.. string.rep("☆", HeroChallenges.STARS_PER_CHALLENGE - earned)
end

local function buildChallengeRow(parent, heroId, index, spec, state, stars, order)
	local row = Instance.new("Frame")
	row.Name = spec.id
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundColor3 = Color3.fromRGB(20, 23, 32)
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = parent
	corner(row, 8)
	padding(row, 10)

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = row

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 20)
	header.BackgroundTransparency = 1
	header.LayoutOrder = 0
	header.Parent = row

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -90, 1, 0)
	title.BackgroundTransparency = 1
	title.Text = ("%d. %s"):format(index, state == "locked" and "???" or spec.name)
	title.TextColor3 = CHALLENGE_STATE_COLOR[state]
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.Parent = header

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.new(0, 86, 1, 0)
	badge.Position = UDim2.new(1, -86, 0, 0)
	badge.BackgroundTransparency = 1
	badge.Text = state == "locked" and "BLOQUEADO" or starLine(stars)
	badge.TextColor3 = state == "locked" and TEXT_SOFT or GOLD
	badge.TextSize = state == "locked" and 10 or 15
	badge.TextXAlignment = Enum.TextXAlignment.Right
	badge.Font = Enum.Font.GothamBold
	badge.Parent = header

	if state == "locked" then
		paragraph(row, "Conclua o desafio anterior para liberar.", TEXT_SOFT, 12, 1)
		return
	end

	paragraph(row, spec.concept, Color3.fromRGB(200, 210, 230), 12, 1)
	paragraph(row, spec.how, TEXT_SOFT, 12, 2)

	for starIndex, star in ipairs(spec.stars) do
		paragraph(row, ("★  %s"):format(star.text),
			stars > starIndex and GOLD or TEXT_SOFT, 11, 2 + starIndex)
	end

	local gap = Instance.new("Frame")
	gap.Size = UDim2.new(1, 0, 0, 12)
	gap.BackgroundTransparency = 1
	gap.LayoutOrder = 19
	gap.Parent = row

	local start = Instance.new("TextButton")
	start.Size = UDim2.new(0, 130, 0, 32)
	start.BackgroundColor3 = Color3.fromRGB(60, 150, 100)
	start.Text = stars > 0 and "JOGAR DE NOVO" or "INICIAR"
	start.TextColor3 = Color3.new(1, 1, 1)
	start.TextSize = 13
	start.Font = Enum.Font.GothamBold
	start.BorderSizePixel = 0
	start.LayoutOrder = 20
	start.Parent = row
	corner(start, 6)

	start.MouseButton1Click:Connect(function()
		GameAction:FireServer("challenge", "start", heroId, index)
		closeModal()
	end)
end

function buildChallengePage(heroId)
	local data = HeroData.GetById(heroId)
	local stars = (myChallenges[tostring(heroId)] or {}).stars or {}
	local total = HeroChallenges.TotalStars(stars, heroId)
	local maximum = HeroChallenges.MaxStarsFor(heroId)

	local back = Instance.new("TextButton")
	back.Size = UDim2.new(0, 130, 0, 28)
	back.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
	back.Text = "VOLTAR"
	back.TextColor3 = TEXT_MAIN
	back.TextSize = 12
	back.Font = Enum.Font.GothamBold
	back.BorderSizePixel = 0
	back.LayoutOrder = 0
	back.Parent = body
	corner(back, 6)

	back.MouseButton1Click:Connect(function()
		challengeHeroId = nil
		rebuildBody(true)
	end)

	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 62)
	head.BackgroundColor3 = CARD_BG
	head.BorderSizePixel = 0
	head.LayoutOrder = 1
	head.Parent = body
	corner(head, 10)
	padding(head, 10)
	stroke(head, total == maximum and GOLD or ACCENT, 1, 0.5)

	local portrait = buildHeroImage(head, data)
	portrait.Size = UDim2.new(0, 36, 0, 42)
	portrait.Position = UDim2.new(0, 0, 0, 0)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -150, 0, 22)
	name.Position = UDim2.new(0, 46, 0, 0)
	name.BackgroundTransparency = 1
	name.Text = data.name:upper()
	name.TextColor3 = TEXT_MAIN
	name.TextSize = 17
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Font = Enum.Font.GothamBlack
	name.Parent = head

	local sub = Instance.new("TextLabel")
	sub.Size = UDim2.new(1, -150, 0, 16)
	sub.Position = UDim2.new(0, 46, 0, 24)
	sub.BackgroundTransparency = 1
	sub.Text = total == maximum
		and ("HERÓI DOMINADO  ·  %d de %d estrelas"):format(total, maximum)
		or ("%d de %d estrelas"):format(total, maximum)
	sub.TextColor3 = total == maximum and GOLD or TEXT_SOFT
	sub.TextSize = 12
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Font = Enum.Font.GothamBold
	sub.Parent = head

	local rematch = Instance.new("TextButton")
	rematch.AnchorPoint = Vector2.new(1, 0.5)
	rematch.Position = UDim2.new(1, 0, 0.5, 0)
	rematch.Size = UDim2.new(0, 96, 0, 28)
	rematch.BackgroundColor3 = Color3.fromRGB(48, 56, 74)
	rematch.Text = "REVANCHE"
	rematch.TextColor3 = TEXT_SOFT
	rematch.TextSize = 11
	rematch.Font = Enum.Font.GothamBold
	rematch.BorderSizePixel = 0
	rematch.Parent = head
	corner(rematch, 6)

	rematch.MouseButton1Click:Connect(function()
		GameAction:FireServer("fight", heroId)
		closeModal()
	end)

	for index, spec in ipairs(HeroChallenges.ListFor(heroId)) do
		buildChallengeRow(body, heroId, index, spec,
			HeroChallenges.StateOf(stars, true, index), stars[index] or 0, 1 + index)
	end
end

local function buildCampaign()
	if challengeHeroId then
		buildChallengePage(challengeHeroId)
		return
	end

	local owned = ownedSet()
	local total = Campaign.CountOwned(owned)

	local pvpLine = Campaign.PvpUnlocked(owned)
		and "O modo online já está liberado — o pad vermelho do lobby entra na fila."
		or ("Faltam %d heróis para liberar o modo online.")
			:format(Campaign.PVP_MIN_HEROES - total)

	paragraph(body, ("Cada quadrado é um confronto contra um time fixo. Vencer entrega o herói " ..
		"daquele quadrado, de uma vez por todas. Você tem %d de %d heróis. %s")
		:format(total, #HeroData.CATALOG, pvpLine), TEXT_SOFT, 14, 0)

	paragraph(body, "Herói já conquistado mostra as estrelas dos desafios dele no quadrado. " ..
		"Toque nesse quadrado para abrir os três desafios do personagem, puzzles preparados " ..
		"que ensinam a habilidade dele do básico ao domínio. A revanche contra o bot fica " ..
		"lá dentro.", Color3.fromRGB(150, 200, 240), 13, 1)

	local grid = Instance.new("Frame")
	grid.Name = "Fights"
	grid.Size = UDim2.new(1, 0, 0, 0)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	grid.BackgroundTransparency = 1
	grid.LayoutOrder = 2
	grid.Parent = body

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0, 118, 0, FIGHT_CARD_H)
	gridLayout.CellPadding = UDim2.new(0, 8, 0, 8)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	for index, fight in ipairs(Campaign.FIGHTS) do
		buildFightSquare(grid, fight, Campaign.StateOf(owned, fight), index)
	end
end

-- ===================== CONTEÚDO: ELENCO =====================
local function buildHeroRow(data, order)
	local row = Instance.new("Frame")
	row.Name = data.name
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundColor3 = CARD_BG
	row.BorderSizePixel = 0
	row.LayoutOrder = order
	row.Parent = body
	corner(row, 10)
	padding(row, 10)

	local portraitHolder = Instance.new("Frame")
	portraitHolder.Size = UDim2.new(0, 62, 0, 78)
	portraitHolder.BackgroundColor3 = Color3.fromRGB(18, 21, 30)
	portraitHolder.BorderSizePixel = 0
	portraitHolder.Parent = row
	corner(portraitHolder, 8)

	local portrait = buildHeroImage(portraitHolder, data)
	portrait.Size = UDim2.new(1, -8, 1, -8)
	portrait.Position = UDim2.new(0, 4, 0, 4)

	local text = Instance.new("Frame")
	text.Position = UDim2.new(0, 72, 0, 0)
	text.Size = UDim2.new(1, -72, 0, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.BackgroundTransparency = 1
	text.Parent = row

	local textLayout = Instance.new("UIListLayout")
	textLayout.Padding = UDim.new(0, 3)
	textLayout.SortOrder = Enum.SortOrder.LayoutOrder
	textLayout.Parent = text

	local nameLabel = paragraph(text, data.name, TEXT_MAIN, 17, 1)
	nameLabel.Font = Enum.Font.GothamBlack

	local statsLabel = paragraph(text, "", Color3.fromRGB(200, 212, 232), 13, 2)
	statsLabel.Font = Enum.Font.GothamBold

	-- Sem botão: herói não se compra mais. A linha de status diz de onde ele vem
	-- (inicial, seu, ou o confronto que ainda falta vencer) e o quadrado da
	-- campanha é quem leva o jogador até lá.
	local function refresh()
		local status
		if HeroData.IsStarter(data) then
			status = "   •   inicial"
		elseif ownsHero(data) then
			status = "   •   seu"
		else
			status = "   •   prêmio do confronto " .. data.name
		end

		statsLabel.Text = ("%d ATK   •   %d HP   •   %s%s")
			:format(data.attack, data.hp, data.ability or "sem passiva", status)
	end

	refresh()
	row:SetAttribute("HeroId", data.id)
	heroRefreshers[data.id] = refresh

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
	paragraph(text, table.concat(lines, "\n"), Color3.fromRGB(178, 208, 250), 13, 3)
end

local function buildStore()
	-- a lista é remontada a cada abertura: os refreshers antigos apontam pra
	-- Frames que já foram destruídas
	heroRefreshers = {}

	-- contado do catálogo em vez de escrito à mão: marcar um herói como `starter`
	-- não pode deixar este texto mentindo
	local starters = 0
	for _, data in ipairs(HeroData.CATALOG) do
		if HeroData.IsStarter(data) then starters += 1 end
	end

	paragraph(body, ("O catálogo tem %d heróis: você começa com %d e conquista os outros " ..
		"vencendo os confrontos da CAMPANHA — um herói por confronto, nenhum se compra. " ..
		"Cada partida usa %d heróis, e no online o adversário escolhe do mesmo catálogo, " ..
		"então quem escolhe primeiro decide o que sobra.")
		:format(#HeroData.CATALOG, starters, GameConfig.HEROES_PER_PLAYER), TEXT_SOFT, 14, 0)

	for index, data in ipairs(HeroData.CATALOG) do
		buildHeroRow(data, index)
	end

	local soon = Instance.new("Frame")
	soon.Size = UDim2.new(1, 0, 0, 0)
	soon.AutomaticSize = Enum.AutomaticSize.Y
	soon.BackgroundColor3 = Color3.fromRGB(30, 26, 18)
	soon.BorderSizePixel = 0
	soon.LayoutOrder = #HeroData.CATALOG + 1
	soon.Parent = body
	corner(soon, 10)
	padding(soon, 10)
	stroke(soon, GOLD, 1, 0.6)

	local soonLayout = Instance.new("UIListLayout")
	soonLayout.Padding = UDim.new(0, 4)
	soonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	soonLayout.Parent = soon

	heading(soon, "Em breve: novos heróis", 1)
	paragraph(soon, Monetization.FUTURE_CONTENT_NOTICE, TEXT_SOFT, 13, 2)
end

-- ===================== ABERTURA =====================
local PANELS = {
	rules = { title = "MURAL DE REGRAS", build = buildRules },
	campaign = { title = "CAMPANHA", build = buildCampaign },
	store = { title = "HERÓIS", build = buildStore },
}

-- Redesenha o painel ABERTO sem fechar nem reabrir o modal: é o que o
-- RosterUpdate chama quando um herói novo chega, pra o quadrado recém-vencido
-- virar "concluído" (e o grupo seguinte abrir) na mesma hora.
function rebuildBody(toTop)
	local entry = currentPanel and PANELS[currentPanel]
	if not entry then return end

	if toTop then
		clearBody()
		entry.build()
	else
		keepScroll(entry.build)
	end
end

-- atribui ao local declarado lá em cima (as abas do modal já apontam pra ele)
function openModal(key)
	local entry = PANELS[key]
	if not entry then return end

	-- Já está neste painel: não faz nada. (Antes isto fechava o modal, pra servir
	-- de liga-desliga na barra do lobby — mas a barra agora fica debaixo do
	-- fundo escurecido e não recebe clique com o modal aberto. Quem chega aqui
	-- repetido é a aba de dentro, e fechar o painel ao clicar na aba em que
	-- você já está seria só confuso.)
	if currentPanel == key then return end

	challengeHeroId = nil
	currentPanel = key
	panelTitle.Text = entry.title
	refreshTabs(key)
	clearBody()
	entry.build()

	modalGui.Enabled = true
	panel.Size = UDim2.new(0.84, 0, 0.82, 0)
	TweenService:Create(panel, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.new(0.88, 0, 0.86, 0),
	}):Play()
end

-- ===================== BOTÕES DO LOBBY =====================
local buttonBar = Instance.new("Frame")
buttonBar.Name = "MenuBar"
buttonBar.Position = UDim2.new(0, 12, 0, 8)
buttonBar.Size = UDim2.new(0, 400, 0, 34)
buttonBar.BackgroundTransparency = 1
buttonBar.Parent = menuGui

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.Padding = UDim.new(0, 6)
barLayout.SortOrder = Enum.SortOrder.LayoutOrder
barLayout.Parent = buttonBar

local function buildMenuButton(text, key, order, accent)
	local button = Instance.new("TextButton")
	button.Name = key
	button.Size = UDim2.new(0, 92, 1, 0)
	button.BackgroundColor3 = PANEL_BG
	button.BackgroundTransparency = 0.15
	button.Text = text
	button.TextColor3 = accent or TEXT_MAIN
	button.TextSize = 14
	button.Font = Enum.Font.GothamBold
	button.BorderSizePixel = 0
	button.LayoutOrder = order
	button.Parent = buttonBar
	corner(button, 8)
	stroke(button, accent or ACCENT, 1, 0.55)

	button.MouseButton1Click:Connect(function()
		openModal(key)
	end)
end

buildMenuButton("REGRAS", "rules", 1)
buildMenuButton("CAMPANHA", "campaign", 2, Color3.fromRGB(120, 220, 170))
buildMenuButton("HERÓIS", "store", 3)

-- ===== A BARRA EM PÉ NO PORTRAIT =====
-- Deitada, os três botões ocupam 292px e o crachá de nível está ancorado no
-- canto direito da TELA: numa tela de 375 eles se encontram, e "HERÓIS" some
-- por baixo do nível. Empilhados, a barra ocupa 92px de largura e passa longe.
--
-- São os MESMOS botões, só mudam direção e largura — a barra não é remontada.
local BAR_BUTTON_W = 92
local BAR_BUTTON_H = 34
local BAR_GAP = 6
local BAR_COUNT = 3

local function layoutMenuBar(orientation)
	local vertical = orientation == Orientation.PORTRAIT

	barLayout.FillDirection = vertical
		and Enum.FillDirection.Vertical
		or Enum.FillDirection.Horizontal

	buttonBar.Size = vertical
		and UDim2.new(0, BAR_BUTTON_W, 0, BAR_COUNT * BAR_BUTTON_H + (BAR_COUNT - 1) * BAR_GAP)
		or UDim2.new(0, BAR_COUNT * BAR_BUTTON_W + (BAR_COUNT - 1) * BAR_GAP, 0, BAR_BUTTON_H)

	for _, child in ipairs(buttonBar:GetChildren()) do
		if child:IsA("TextButton") then
			child.Size = vertical
				and UDim2.new(1, 0, 0, BAR_BUTTON_H)
				or UDim2.new(0, BAR_BUTTON_W, 1, 0)
		end
	end
end

layoutMenuBar(Orientation.Current())
Orientation.OnChange(layoutMenuBar)

-- ===================== VISIBILIDADE =====================
-- Mesma regra do crachá de nível: fora do lobby isso tudo sai da frente.
MatchUpdate.OnClientEvent:Connect(function(state)
	local inLobby = state.phase == "lobby"
	menuGui.Enabled = inLobby
	if not inLobby then
		closeModal()
	end

	local justArrived = inLobby and not inLobbyNow
	inLobbyNow = inLobby

	-- Chegou no lobby: pede o que ficou guardado desde a última vez que ele viu
	-- a comemoração. Cobre a sequência de campanha (várias partidas sem passar
	-- por aqui) e quem fechou o jogo e voltou depois.
	if justArrived then
		GameAction:FireServer("claimRewards")
	end

	if inLobby and not rewardGui.Enabled then
		showNextReward()
	end
end)

GameAction.OnClientEvent:Connect(function(action, payload)
	if action == "challenges" and type(payload) == "table" then
		myChallenges = payload.heroes or {}
		if currentPanel == "campaign" then rebuildBody() end
		return
	end

	if action == "fightStars" and type(payload) == "table" then
		myFightStars = payload
		if currentPanel == "campaign" then rebuildBody() end
		return
	end

	if action ~= "rewards" or type(payload) ~= "table" then return end

	for _, dataId in ipairs(payload.heroes or {}) do
		table.insert(pendingUnlockIds, dataId)
	end

	pendingXp += payload.xp or 0
	pendingCoins += payload.coins or 0
	pendingXpTotal = payload.xpTotal or pendingXpTotal
	pendingCoinsTotal = payload.coinsTotal or pendingCoinsTotal

	if inLobbyNow and not rewardGui.Enabled then
		showNextReward()
	end
end)

-- O jogador pode entrar direto no lobby (login, ou volta depois de fechar o
-- jogo) sem nenhum MatchUpdate de transição — aí o pedido acima nunca sairia.
task.defer(function()
	GameAction:FireServer("claimRewards")
	GameAction:FireServer("challenge", "sync")
	GameAction:FireServer("fightStars")
end)
