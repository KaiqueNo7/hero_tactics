--[[
	LobbyMenu.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Os três painéis do lobby: mural de regras, vitrine de heróis e apoio.

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

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local Monetization = require(ReplicatedStorage.Modules.Monetization)
local Progression = require(ReplicatedStorage.Modules.Progression)

local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local WalletUpdate = ReplicatedStorage.Remotes:WaitForChild("WalletUpdate")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SPRITE_SHEET_ID = HeroData.GetSpriteId()

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

	if SPRITE_SHEET_ID then
		image.Image = SPRITE_SHEET_ID
		image.ImageRectSize = HeroData.GetFrameSize()
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
coinBadge.Size = UDim2.new(0, 136, 0, 28)
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

local coinLabel = Instance.new("TextLabel")
coinLabel.AnchorPoint = Vector2.new(1, 0.5)
coinLabel.Position = UDim2.new(1, -10, 0.5, 0)
coinLabel.Size = UDim2.new(1, -32, 0, 16)
coinLabel.BackgroundTransparency = 1
coinLabel.Text = "0"
coinLabel.TextColor3 = GOLD
coinLabel.TextXAlignment = Enum.TextXAlignment.Right
coinLabel.TextScaled = true
coinLabel.Font = Enum.Font.GothamBlack
coinLabel.Parent = coinBadge

local coinGain = Instance.new("TextLabel")
coinGain.AnchorPoint = Vector2.new(1, 0)
coinGain.Position = UDim2.new(1, -12, 0, 88)
coinGain.Size = UDim2.new(0, 136, 0, 20)
coinGain.BackgroundTransparency = 1
coinGain.Text = ""
coinGain.TextColor3 = GOLD
coinGain.TextStrokeTransparency = 1
coinGain.TextTransparency = 1
coinGain.TextXAlignment = Enum.TextXAlignment.Right
coinGain.TextScaled = true
coinGain.Font = Enum.Font.GothamBlack
coinGain.Parent = menuGui

local myCoins = 0
local coinGainToken = 0

-- A linha "Seu saldo" do painel de apoio. Ela é construída junto com o painel,
-- e a compra acontece justamente com o painel ABERTO — sem esta referência o
-- saldo de lá continuava marcando o valor de antes da compra.
local tipBalanceLabel = nil

local function balanceText()
	return ("Seu saldo: %s %s")
		:format(Monetization.FormatCoins(myCoins), Monetization.COIN_NAME:lower())
end

local function renderWallet(payload)
	myCoins = payload.coins or 0
	coinLabel.Text = Monetization.FormatCoins(myCoins)

	if tipBalanceLabel and tipBalanceLabel.Parent then
		tipBalanceLabel.Text = balanceText()
	end

	local gained = payload.gained
	if not gained or gained <= 0 then return end

	coinGainToken += 1
	local token = coinGainToken

	coinGain.Text = ("+%s"):format(Monetization.FormatCoins(gained))
	coinGain.TextTransparency = 1
	TweenService:Create(coinGain, TweenInfo.new(0.2), {
		TextTransparency = 0, TextStrokeTransparency = 0.4,
	}):Play()

	task.delay(2.4, function()
		if coinGainToken ~= token then return end
		TweenService:Create(coinGain, TweenInfo.new(0.5), {
			TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()
	end)
end

WalletUpdate.OnClientEvent:Connect(renderWallet)

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

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
-- em escala pra caber tanto em celular deitado quanto em monitor; a restrição
-- abaixo impede que vire um painel gigante numa tela grande
panel.Size = UDim2.new(0.88, 0, 0.86, 0)
panel.BackgroundColor3 = PANEL_BG
panel.BorderSizePixel = 0
panel.Parent = modalGui
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
panelTitle.Parent = panel

-- ===== ABAS DENTRO DO MODAL =====
-- A barra do lobby fica ABAIXO do modal (é o certo: modal é modal). Só que o
-- fundo escurecido cobre a tela inteira, então com a barra embaixo dela um
-- toque em "HERÓIS" com as regras abertas ia parar no fundo e só fechava o
-- painel. A troca de painel mudou de lugar: agora mora aqui dentro, onde
-- nenhum fundo passa na frente.
local TAB_HEIGHT = 26
local BODY_TOP = 36 + TAB_HEIGHT + 6

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
		tab.button.BackgroundColor3 = active and Color3.fromRGB(42, 48, 66) or CARD_BG
		tab.button.TextColor3 = active and tab.accent or TEXT_SOFT
		tab.edge.Transparency = active and 0 or 0.6
	end
end

buildTab("REGRAS", "rules", 1)
buildTab("HERÓIS", "store", 2)
buildTab("APOIAR", "tips", 3, GOLD)

local body = Instance.new("ScrollingFrame")
body.Name = "Body"
body.Position = UDim2.new(0, 0, 0, BODY_TOP)
body.Size = UDim2.new(1, 0, 1, -BODY_TOP)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollBarThickness = 5
body.ScrollBarImageColor3 = ACCENT
body.Parent = panel

local bodyLayout = Instance.new("UIListLayout")
bodyLayout.Padding = UDim.new(0, 10)
bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
bodyLayout.Parent = body

local bodyPadding = Instance.new("UIPadding")
bodyPadding.PaddingRight = UDim.new(0, 10)
bodyPadding.PaddingBottom = UDim.new(0, 6)
bodyPadding.Parent = body

local closeButton = buildCloseButton(panel)

local currentPanel = nil

local function closeModal()
	if not currentPanel then return end
	currentPanel = nil
	modalGui.Enabled = false
end

closeButton.MouseButton1Click:Connect(closeModal)
backdrop.MouseButton1Click:Connect(closeModal)

local function clearBody()
	tipBalanceLabel = nil
	for _, child in ipairs(body:GetChildren()) do
		if not child:IsA("UILayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	body.CanvasPosition = Vector2.new()
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

-- ===================== CONTEÚDO: VITRINE DE HERÓIS =====================
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

	paragraph(text, ("%d ATK   •   %d HP   •   %s")
		:format(data.attack, data.hp, data.ability or "sem passiva"),
		Color3.fromRGB(200, 212, 232), 13, 2).Font = Enum.Font.GothamBold

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
	paragraph(text, table.concat(lines, "\n"), Color3.fromRGB(178, 208, 250), 13, 3)
end

local function buildStore()
	paragraph(body, ("Os %d heróis abaixo já estão liberados para todo mundo, de graça. " ..
		"Cada partida usa %d deles — e o adversário escolhe do mesmo catálogo, então " ..
		"quem escolhe primeiro decide o que sobra.")
		:format(#HeroData.CATALOG, GameConfig.HEROES_PER_PLAYER), TEXT_SOFT, 14, 0)

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

-- ===================== CONTEÚDO: APOIO =====================
local function buildTipButton(tip, order)
	local configured = Monetization.IsConfigured(tip)

	local card = Instance.new("TextButton")
	card.Name = tip.key
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = configured and CARD_BG or Color3.fromRGB(30, 30, 34)
	card.BorderSizePixel = 0
	card.Text = ""
	card.AutoButtonColor = configured
	card.LayoutOrder = order
	card.Parent = body
	corner(card, 10)
	padding(card, 10)
	stroke(card, configured and ACCENT or Color3.fromRGB(70, 70, 76), 1, 0.4)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = card

	local titleLine = paragraph(card, tip.title, configured and TEXT_MAIN or Color3.fromRGB(150, 150, 158), 16, 1)
	titleLine.Font = Enum.Font.GothamBlack

	local reward = ("%s moedas   •   R$ %d"):format(Monetization.FormatCoins(tip.coins), tip.robux)
	if tip.bonus then
		reward = reward .. ("   •   %s"):format(tip.bonus)
	end
	paragraph(card, reward, configured and GOLD or Color3.fromRGB(130, 126, 110), 14, 2).Font = Enum.Font.GothamBold

	paragraph(card, tip.blurb, TEXT_SOFT, 13, 3)

	if not configured then
		-- Sem id de produto o PromptProductPurchase erra e o jogador leva um
		-- diálogo de falha sem entender — por isso o botão nasce desabilitado.
		--
		-- O QUE O JOGADOR LÊ é só "Em breve". A pendência é do desenvolvedor, e
		-- despejar "falta cadastrar o id do Developer Product em
		-- ReplicatedStorage.Modules.Monetization" na tela de quem está jogando
		-- não conserta nada: expõe caminho interno do projeto e passa a
		-- impressão de jogo quebrado. O recado técnico vai pro console.
		paragraph(card, "Em breve.", Color3.fromRGB(150, 156, 170), 12, 4)
		warn(("LobbyMenu: apoio '%s' sem Developer Product cadastrado — " ..
			"preencha productId em ReplicatedStorage.Modules.Monetization."):format(tip.key))
		return
	end

	card.MouseButton1Click:Connect(function()
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(player, tip.productId)
		end)
		if not ok then
			warn("LobbyMenu: não deu pra abrir a compra: " .. tostring(err))
		end
	end)
end

local function buildTips()
	local intro = paragraph(body, Monetization.THANK_YOU, TEXT_MAIN, 14, 0)
	intro.Font = Enum.Font.GothamBold

	local balance = Instance.new("Frame")
	balance.Size = UDim2.new(1, 0, 0, 34)
	balance.BackgroundColor3 = Color3.fromRGB(30, 26, 18)
	balance.BorderSizePixel = 0
	balance.LayoutOrder = 1
	balance.Parent = body
	corner(balance, 8)

	local balanceLabel = Instance.new("TextLabel")
	balanceLabel.Size = UDim2.new(1, -20, 1, 0)
	balanceLabel.Position = UDim2.new(0, 10, 0, 0)
	balanceLabel.BackgroundTransparency = 1
	balanceLabel.Text = balanceText()
	balanceLabel.TextColor3 = GOLD
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Left
	balanceLabel.TextSize = 15
	balanceLabel.Font = Enum.Font.GothamBlack
	balanceLabel.Parent = balance
	tipBalanceLabel = balanceLabel

	for index, tip in ipairs(Monetization.TIPS) do
		buildTipButton(tip, index + 1)
	end

	local notice = Instance.new("Frame")
	notice.Size = UDim2.new(1, 0, 0, 0)
	notice.AutomaticSize = Enum.AutomaticSize.Y
	notice.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
	notice.BorderSizePixel = 0
	notice.LayoutOrder = #Monetization.TIPS + 2
	notice.Parent = body
	corner(notice, 10)
	padding(notice, 10)

	local noticeLayout = Instance.new("UIListLayout")
	noticeLayout.Padding = UDim.new(0, 4)
	noticeLayout.SortOrder = Enum.SortOrder.LayoutOrder
	noticeLayout.Parent = notice

	heading(notice, "Para que servem as moedas", 1)
	paragraph(notice, Monetization.FUTURE_CONTENT_NOTICE, TEXT_SOFT, 13, 2)
end

-- ===================== ABERTURA =====================
local PANELS = {
	rules = { title = "MURAL DE REGRAS", build = buildRules },
	store = { title = "HERÓIS", build = buildStore },
	tips = { title = "SEJA UM APOIADOR", build = buildTips },
}

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
buttonBar.Size = UDim2.new(0, 300, 0, 34)
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
buildMenuButton("HERÓIS", "store", 2)
buildMenuButton("APOIAR", "tips", 3, GOLD)

-- ===================== VISIBILIDADE =====================
-- Mesma regra do crachá de nível: fora do lobby isso tudo sai da frente.
MatchUpdate.OnClientEvent:Connect(function(state)
	local inLobby = state.phase == "lobby"
	menuGui.Enabled = inLobby
	if not inLobby then
		closeModal()
	end
end)
