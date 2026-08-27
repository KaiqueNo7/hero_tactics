--[[
	LobbyClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Cobre a transição entre lobby e arena: fila do PvP e tela de carregamento.
	O overlay some sozinho quando o primeiro estado de partida chega, então
	ninguém fica olhando tabuleiro meio montado.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local LobbyStatus = ReplicatedStorage.Remotes:WaitForChild("LobbyStatus")
local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")
local ProfileUpdate = ReplicatedStorage.Remotes:WaitForChild("ProfileUpdate")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Trava o jogo em paisagem, sem depender do jeito que o celular estava segurado
-- nem do bloqueio de rotação do sistema. LandscapeSensor deixa girar entre as
-- duas paisagens, mas nunca cai em retrato — o tabuleiro é largo demais pra
-- caber em pé.
--
-- Quem garante a abertura já deitada é StarterGui.ScreenOrientation (definido no
-- default.project.json), que vale desde o primeiro frame; aqui é só o reforço
-- em runtime, porque este script só roda depois do carregamento.
playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor

local FADE_TIME = 0.25
local TOAST_TIME = 2.5

local visible = false
local currentState = "idle"
local toastToken = 0

-- ===== UI =====
local gui = Instance.new("ScreenGui")
gui.Name = "LobbyGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50 -- por cima da GUI de partida
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromRGB(10, 11, 16)
backdrop.BackgroundTransparency = 1
backdrop.BorderSizePixel = 0
backdrop.Parent = gui

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.new(0, 460, 0, 190)
panel.BackgroundTransparency = 1
panel.Parent = backdrop

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 46)
title.BackgroundTransparency = 1
title.Text = "TÁTICAS DE HERÓI"
title.TextColor3 = Color3.fromRGB(255, 226, 150)
title.TextStrokeTransparency = 0.6
title.TextTransparency = 1
title.TextScaled = true
title.Font = Enum.Font.GothamBlack
title.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, 0, 0, 34)
status.Position = UDim2.new(0, 0, 0, 64)
status.BackgroundTransparency = 1
status.Text = ""
status.TextColor3 = Color3.fromRGB(226, 234, 248)
status.TextTransparency = 1
status.TextScaled = true
status.Font = Enum.Font.GothamBold
status.Parent = panel

-- barra de progresso indeterminada: um traço deslizando de um lado ao outro
local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.new(0.5, 0, 0, 112)
track.Size = UDim2.new(0, 300, 0, 5)
track.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
track.BackgroundTransparency = 1
track.BorderSizePixel = 0
track.ClipsDescendants = true
track.Parent = panel

local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track

local bar = Instance.new("Frame")
bar.Size = UDim2.new(0.32, 0, 1, 0)
bar.BackgroundColor3 = Color3.fromRGB(120, 180, 255)
bar.BackgroundTransparency = 1
bar.BorderSizePixel = 0
bar.Parent = track

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = bar

local cancelButton = Instance.new("TextButton")
cancelButton.AnchorPoint = Vector2.new(0.5, 0)
cancelButton.Position = UDim2.new(0.5, 0, 0, 138)
cancelButton.Size = UDim2.new(0, 168, 0, 40)
cancelButton.BackgroundColor3 = Color3.fromRGB(58, 64, 84)
cancelButton.BackgroundTransparency = 1
cancelButton.Text = "Sair da fila"
cancelButton.TextColor3 = Color3.new(1, 1, 1)
cancelButton.TextTransparency = 1
cancelButton.TextSize = 17
cancelButton.Font = Enum.Font.GothamBold
cancelButton.BorderSizePixel = 0
cancelButton.Visible = false
cancelButton.Parent = panel

local cancelCorner = Instance.new("UICorner")
cancelCorner.CornerRadius = UDim.new(0, 8)
cancelCorner.Parent = cancelButton

cancelButton.MouseButton1Click:Connect(function()
	GameAction:FireServer("cancelQueue")
end)

-- ===== CONFIRMAÇÃO DE CONFRONTO =====
-- Pisar no quadrado da campanha NÃO entra na partida: o servidor manda a
-- pergunta e espera. Só o "Sim" volta como pedido de entrada — e lá o servidor
-- confere a escada de novo antes de montar a arena.
--
-- Mora aqui, e não no LobbyMenu, porque é o mesmo painel que já cobre fila e
-- carregamento: a pergunta herda o fade, o fundo escurecido e o sumiço
-- automático quando a partida começa, sem UI nova nenhuma.
local pendingFight = nil

local function buildChoiceButton(text, offsetX, color)
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, offsetX, 0, 138)
	button.Size = UDim2.new(0, 128, 0, 40)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = 1
	button.Text = text
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextTransparency = 1
	button.TextSize = 17
	button.Font = Enum.Font.GothamBold
	button.BorderSizePixel = 0
	button.Visible = false
	button.Parent = panel

	local choiceCorner = Instance.new("UICorner")
	choiceCorner.CornerRadius = UDim.new(0, 8)
	choiceCorner.Parent = button

	return button
end

local yesButton = buildChoiceButton("Sim", -68, Color3.fromRGB(56, 128, 88))
local noButton = buildChoiceButton("Não", 68, Color3.fromRGB(70, 74, 92))

-- ===== CRACHÁ DE NÍVEL (canto superior direito do lobby) =====
-- ScreenGui própria, e não dentro da LobbyGui: aquela vive apagada e só acende
-- na fila/carregamento, enquanto o crachá tem que ficar visível o lobby inteiro.
-- IgnoreGuiInset fica falso de propósito, pra ele descer abaixo da barra do
-- Roblox em vez de brigar por espaço com ela.
local profileGui = Instance.new("ScreenGui")
profileGui.Name = "ProfileGui"
profileGui.ResetOnSpawn = false
profileGui.DisplayOrder = 20
profileGui.Parent = playerGui

local levelBadge = Instance.new("Frame")
levelBadge.Name = "LevelBadge"
levelBadge.AnchorPoint = Vector2.new(1, 0)
levelBadge.Position = UDim2.new(1, -12, 0, 8)
-- 150 e não 136: com o número do nível e o "40/150" do XP na mesma linha, os
-- dois se encostavam e viravam um bloco de texto só
levelBadge.Size = UDim2.new(0, 150, 0, 46)
levelBadge.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
levelBadge.BackgroundTransparency = 0.2
levelBadge.BorderSizePixel = 0
levelBadge.Parent = profileGui

local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(0, 8)
badgeCorner.Parent = levelBadge

-- Nível e XP dividem a linha de cima do crachá, com um vão de 10px entre eles.
-- Antes o nível ocupava 55% da largura e o XP começava exatamente nos 55%: sem
-- vão nenhum, "Nível 2" e "40/150" se encostavam. E como os dois usam
-- TextScaled, o nível esticava até o limite da caixa — o teto de fonte abaixo é
-- o que impede que ele volte a engolir o espaço quando o número tiver 2 dígitos.
local levelLabel = Instance.new("TextLabel")
levelLabel.Size = UDim2.new(0, 78, 0, 20)
levelLabel.Position = UDim2.new(0, 10, 0, 5)
levelLabel.BackgroundTransparency = 1
levelLabel.Text = "Nível 1"
levelLabel.TextColor3 = Color3.fromRGB(255, 226, 150)
levelLabel.TextXAlignment = Enum.TextXAlignment.Left
levelLabel.TextScaled = true
levelLabel.Font = Enum.Font.GothamBlack
levelLabel.Parent = levelBadge

local levelSizeLimit = Instance.new("UITextSizeConstraint")
levelSizeLimit.MaxTextSize = 16
levelSizeLimit.Parent = levelLabel

local xpLabel = Instance.new("TextLabel")
xpLabel.AnchorPoint = Vector2.new(1, 0)
xpLabel.Size = UDim2.new(0, 52, 0, 14)
xpLabel.Position = UDim2.new(1, -10, 0, 8)
xpLabel.BackgroundTransparency = 1
xpLabel.Text = ""
xpLabel.TextColor3 = Color3.fromRGB(190, 200, 220)
xpLabel.TextXAlignment = Enum.TextXAlignment.Right
xpLabel.TextScaled = true
xpLabel.Font = Enum.Font.GothamBold
xpLabel.Parent = levelBadge

local xpSizeLimit = Instance.new("UITextSizeConstraint")
xpSizeLimit.MaxTextSize = 12
xpSizeLimit.Parent = xpLabel

local xpTrack = Instance.new("Frame")
xpTrack.Size = UDim2.new(1, -20, 0, 6)
xpTrack.Position = UDim2.new(0, 10, 1, -13)
xpTrack.BackgroundColor3 = Color3.fromRGB(38, 44, 60)
xpTrack.BorderSizePixel = 0
xpTrack.ClipsDescendants = true
xpTrack.Parent = levelBadge

local xpTrackCorner = Instance.new("UICorner")
xpTrackCorner.CornerRadius = UDim.new(1, 0)
xpTrackCorner.Parent = xpTrack

local xpFill = Instance.new("Frame")
xpFill.Size = UDim2.new(0, 0, 1, 0)
xpFill.BackgroundColor3 = Color3.fromRGB(120, 180, 255)
xpFill.BorderSizePixel = 0
xpFill.Parent = xpTrack

local xpFillCorner = Instance.new("UICorner")
xpFillCorner.CornerRadius = UDim.new(1, 0)
xpFillCorner.Parent = xpFill

-- "+60 XP" ao LADO do crachá quando a partida termina. Ficava logo abaixo, mas
-- ali agora mora o saldo de moedas (LobbyMenu) — e um flash por cima do saldo
-- fazia parecer que o XP tinha virado moeda.
local gainLabel = Instance.new("TextLabel")
gainLabel.AnchorPoint = Vector2.new(1, 0)
gainLabel.Position = UDim2.new(1, -156, 0, 14)
gainLabel.Size = UDim2.new(0, 136, 0, 22)
gainLabel.BackgroundTransparency = 1
gainLabel.Text = ""
gainLabel.TextColor3 = Color3.fromRGB(150, 240, 170)
gainLabel.TextStrokeTransparency = 1
gainLabel.TextXAlignment = Enum.TextXAlignment.Right
gainLabel.TextScaled = true
gainLabel.Font = Enum.Font.GothamBlack
gainLabel.TextTransparency = 1
gainLabel.Parent = profileGui

local gainToken = 0

local function flashGain(amount)
	if not amount or amount <= 0 then return end

	gainToken += 1
	local token = gainToken

	gainLabel.Text = ("+%d XP"):format(amount)
	gainLabel.TextTransparency = 1
	TweenService:Create(gainLabel, TweenInfo.new(0.2), {
		TextTransparency = 0, TextStrokeTransparency = 0.4,
	}):Play()

	task.delay(2.2, function()
		if gainToken ~= token then return end
		TweenService:Create(gainLabel, TweenInfo.new(0.5), {
			TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()
	end)
end

-- info vem pronto do servidor: { level, xpIntoLevel, xpForNext, totalXp, gained }
local function renderProfile(info)
	levelLabel.Text = ("Nível %d"):format(info.level or 1)

	local intoLevel = info.xpIntoLevel or 0
	local forNext = info.xpForNext or 0

	if forNext > 0 then
		xpLabel.Text = ("%d/%d"):format(intoLevel, forNext)
		TweenService:Create(xpFill, TweenInfo.new(0.35), {
			Size = UDim2.fromScale(math.clamp(intoLevel / forNext, 0, 1), 1),
		}):Play()
	else
		xpLabel.Text = "MAX"
		xpFill.Size = UDim2.fromScale(1, 1)
	end

	flashGain(info.gained)
end

ProfileUpdate.OnClientEvent:Connect(renderProfile)

-- ===== ANIMAÇÃO =====
RunService.RenderStepped:Connect(function()
	if not visible then return end
	-- vai e volta suave, sem depender de tween encadeado
	local t = (math.sin(os.clock() * 1.8) + 1) / 2
	bar.Position = UDim2.new(t * 0.68, 0, 0, 0)
end)

local function fade(targetVisible)
	if visible == targetVisible then return end
	visible = targetVisible

	if targetVisible then gui.Enabled = true end

	local info = TweenInfo.new(FADE_TIME)
	local textTransparency = targetVisible and 0 or 1

	TweenService:Create(backdrop, info, { BackgroundTransparency = targetVisible and 0.15 or 1 }):Play()
	TweenService:Create(title, info, { TextTransparency = textTransparency }):Play()
	TweenService:Create(status, info, { TextTransparency = textTransparency }):Play()
	TweenService:Create(track, info, { BackgroundTransparency = targetVisible and 0 or 1 }):Play()
	TweenService:Create(bar, info, { BackgroundTransparency = targetVisible and 0 or 1 }):Play()

	for _, button in ipairs({ cancelButton, yesButton, noButton }) do
		if button.Visible then
			TweenService:Create(button, info, {
				BackgroundTransparency = textTransparency,
				TextTransparency = textTransparency,
			}):Play()
		end
	end

	if not targetVisible then
		task.delay(FADE_TIME, function()
			if not visible then gui.Enabled = false end
		end)
	end
end

local function show(state, text, showCancel, showBar, showChoice)
	currentState = state
	status.Text = text or ""
	cancelButton.Visible = showCancel or false
	track.Visible = showBar ~= false
	yesButton.Visible = showChoice or false
	noButton.Visible = showChoice or false

	-- Opacidade na mão, e não por tween: o painel pode JÁ estar na tela (a
	-- pergunta virando "preparando a arena", por exemplo), e nesse caso o fade
	-- abaixo sai pela porta dos fundos sem tocar em nada.
	if showCancel then
		cancelButton.BackgroundTransparency = 0
		cancelButton.TextTransparency = 0
	end

	if showChoice then
		for _, button in ipairs({ yesButton, noButton }) do
			button.BackgroundTransparency = 0
			button.TextTransparency = 0
		end
	end

	fade(true)
end

yesButton.MouseButton1Click:Connect(function()
	if not pendingFight then return end

	local fight = pendingFight
	pendingFight = nil

	-- resposta imediata na tela; o servidor manda o "loading" dele logo em
	-- seguida (ou um aviso, se a arena tiver acabado nesse intervalo)
	show("loading", "Preparando a arena...", false, true, false)
	GameAction:FireServer("fight", fight)
end)

noButton.MouseButton1Click:Connect(function()
	pendingFight = nil
	currentState = "idle"
	fade(false)
end)

-- ===== ESTADO =====
LobbyStatus.OnClientEvent:Connect(function(payload)
	local state = payload and payload.state or "idle"

	if state == "idle" then
		currentState = "idle"
		pendingFight = nil
		fade(false)

	elseif state == "confirm" then
		-- pisou num quadrado da campanha: a partida só começa no "Sim"
		pendingFight = payload.fight
		show("confirm", payload.text or "Deseja enfrentar este time?", false, false, true)

	elseif state == "queued" then
		show("queued", payload.text or "Procurando oponente...", true, true)

	elseif state == "loading" then
		show("loading", payload.text or "Preparando a arena...", false, true)

	elseif state == "busy" then
		-- aviso passageiro: não trava o lobby
		toastToken += 1
		local token = toastToken
		show("busy", payload.text or "Servidor ocupado", false, false)

		task.delay(TOAST_TIME, function()
			if toastToken == token and currentState == "busy" then
				fade(false)
			end
		end)
	end
end)

-- Quando o primeiro estado da partida chega, a arena já está montada
MatchUpdate.OnClientEvent:Connect(function(state)
	-- o crachá é do lobby: durante draft/batalha ele sairia por cima do timer
	profileGui.Enabled = state.phase == "lobby"

	if state.phase == "lobby" then
		currentState = "idle"
		fade(false)
		return
	end

	if currentState == "loading" or currentState == "queued" then
		currentState = "idle"
		task.delay(0.35, function()
			if currentState == "idle" then fade(false) end
		end)
	end
end)

-- ===================== AMBIENTAÇÃO DA TRILHA =====================
-- Cada ilha da trilha (ReplicatedStorage.Modules.LobbyZones) tem o próprio ar:
-- a Clareira é clara e limpa, o Bosque Sombrio é roxo e denso, a Geleira é
-- branca e estourada, a Forja é laranja e fechada. Atravessar a ponte troca a
-- paleta, e é isso que faz cada trecho parecer um LUGAR e não mais um pedaço de
-- chão com árvore diferente.
--
-- POR QUE NO CLIENTE. Lighting é global e replicado: se o servidor trocasse a
-- paleta, o jogador parado no lobby veria o mundo escurecer porque OUTRA pessoa
-- entrou no Bosque. Mexer aqui só afeta a tela de quem atravessou — mesma ideia
-- do vulto do Nash e da cor dos quadrados por jogador.
--
-- Sair de todas as zonas devolve a paleta padrão chamando o MESMO LightingSetup
-- que o servidor aplicou na entrada. Sem uma cópia dos valores do lobby aqui:
-- eram duas listas pra discordar, e a segunda ficaria velha na primeira vez que
-- alguém calibrasse o sol.
local LobbyZones = require(ReplicatedStorage.Modules.LobbyZones)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

local ZONE_FADE = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local ZONE_POLL = 0.4 -- andar não é um evento; olhar 2x por segundo basta e não pesa

-- A paleta do lobby, lida UMA vez do que o servidor deixou pronto. Ler no
-- primeiro uso e não no topo do arquivo é de propósito: este script sobe antes
-- do Environment do servidor replicar, e a captura sairia com a Lighting de
-- fábrica do place.
local lobbyPalette = nil

local function capture()
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	return {
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Brightness = Lighting.Brightness,
		Atmosphere = atmosphere and {
			Density = atmosphere.Density,
			Haze = atmosphere.Haze,
			Color = atmosphere.Color,
			Decay = atmosphere.Decay,
		} or nil,
		Tint = Color3.new(1, 1, 1),
	}
end

-- Correção de cor própria da trilha. Nome explícito e reaproveitada: criar uma
-- por travessia deixava um rastro de efeitos mortos em Lighting.
local function zoneTint()
	local existing = Lighting:FindFirstChild("TrailTint")
	if existing then return existing end

	local tint = Instance.new("ColorCorrectionEffect")
	tint.Name = "TrailTint"
	tint.Parent = Lighting
	return tint
end

local function applyPalette(palette)
	TweenService:Create(Lighting, ZONE_FADE, {
		Ambient = palette.Ambient,
		OutdoorAmbient = palette.OutdoorAmbient,
		Brightness = palette.Brightness,
	}):Play()

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere and palette.Atmosphere then
		TweenService:Create(atmosphere, ZONE_FADE, palette.Atmosphere):Play()
	end

	TweenService:Create(zoneTint(), ZONE_FADE, { TintColor = palette.Tint }):Play()
end

local currentZoneId = nil

local function ShowPadLabels(zoneId)
	for _, pad in ipairs(CollectionService:GetTagged(Campaign.PAD_TAG)) do
		local label = pad:FindFirstChild("FightLabel")
		if label then
			local fight = Campaign.GetFight(pad:GetAttribute("FightHero"))
			local zone = fight and LobbyZones.ForGroup(fight.group)
			label.Enabled = zoneId ~= nil and zone ~= nil and zone.id == zoneId
		end
	end
end

task.spawn(function()
	while true do
		task.wait(ZONE_POLL)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")

		-- Durante a partida a câmera está na arena, longe de qualquer zona: sem
		-- esta guarda, entrar em batalha "saía" da trilha e reacendia o lobby no
		-- meio do tabuleiro.
		if root and currentState == "idle" then
			lobbyPalette = lobbyPalette or capture()

			local zone = LobbyZones.ZoneAt(root.Position)
			local id = zone and zone.id or nil

			if id ~= currentZoneId then
				currentZoneId = id
				applyPalette(zone and zone.ambience or lobbyPalette)
			end

			ShowPadLabels(id)
		end
	end
end)
