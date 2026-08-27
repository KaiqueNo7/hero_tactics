--[[
	TutorialClient.client.lua
	LocalScript — StarterPlayer/StarterPlayerScripts

	Mostra o cartão da lição certa na hora certa. As lições e os gatilhos moram
	em ReplicatedStorage.Modules.Tutorial; o que já foi visto mora no servidor
	(ServerScriptService.Modules.TutorialService). Aqui é só a tela.

	SCRIPT SEPARADO, e não mais um pedaço do BattleClient. O MatchUpdate é um
	RemoteEvent: dois ouvintes escutam o mesmo snapshot sem um atrapalhar o
	outro. Então o tutorial inteiro entrou sem tocar uma linha das 2136 do
	BattleClient — e sai do jogo apagando um arquivo, se um dia não servir mais.

	ONDE O CARTÃO FICA. Rodapé central: é a faixa que sobra entre o botão de
	desistir (canto inferior esquerdo) e o de encerrar turno (canto inferior
	direito), longe da coluna de retratos (esquerda) e do painel de turno (topo).
	DisplayOrder 40 põe ele acima da partida (5) e abaixo do overlay do lobby
	(50), pra tela de carregamento continuar cobrindo tudo.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Tutorial = require(ReplicatedStorage.Modules.Tutorial)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local MatchUpdate = ReplicatedStorage.Remotes:WaitForChild("MatchUpdate")
local TutorialUpdate = ReplicatedStorage.Remotes:WaitForChild(Tutorial.REMOTE_NAME)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SHOW_DELAY = 1.2 -- respiro entre o tabuleiro aparecer e o cartão subir
local AUTO_DISMISS = 15 -- criança distraída não pode deixar o cartão preso na tela
local FADE = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ===== ESTADO =====
local seen = {}
-- Só mostra depois que o servidor disser o que já foi visto. Sem esta trava, o
-- primeiro MatchUpdate (que costuma chegar antes) reensinaria tudo do zero a
-- cada login — inclusive pra quem já joga há meses.
local seenReady = false
local showing = nil
local dismissToken = 0

-- ===== UI =====
local gui = Instance.new("ScreenGui")
gui.Name = "TutorialGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 40
gui.Enabled = false
gui.Parent = playerGui

local card = Instance.new("Frame")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 1)
card.Position = UDim2.new(0.5, 0, 1, 40) -- fora da tela; sobe ao aparecer
card.Size = UDim2.new(0, 470, 0, 128)
card.BackgroundColor3 = Color3.fromRGB(24, 27, 38)
card.BackgroundTransparency = 0.06
card.BorderSizePixel = 0
card.Parent = gui

local cardCorner = Instance.new("UICorner")
cardCorner.CornerRadius = UDim.new(0, 14)
cardCorner.Parent = card

local cardStroke = Instance.new("UIStroke")
cardStroke.Color = Color3.fromRGB(96, 176, 240)
cardStroke.Thickness = 2
cardStroke.Transparency = 0.15
cardStroke.Parent = card

-- Faixa de cor na lateral: dá identidade de "dica" sem precisar de ícone, e o
-- glifo de lâmpada não existe nas fontes do Roblox (sairia quadradinho, o mesmo
-- problema do cadeado e do check no LobbyMenu).
local accent = Instance.new("Frame")
accent.Size = UDim2.new(0, 5, 1, -24)
accent.Position = UDim2.new(0, 12, 0, 12)
accent.BackgroundColor3 = Color3.fromRGB(96, 176, 240)
accent.BorderSizePixel = 0
accent.Parent = card

local accentCorner = Instance.new("UICorner")
accentCorner.CornerRadius = UDim.new(1, 0)
accentCorner.Parent = accent

local titleLabel = Instance.new("TextLabel")
titleLabel.Position = UDim2.new(0, 30, 0, 14)
titleLabel.Size = UDim2.new(1, -120, 0, 22)
titleLabel.BackgroundTransparency = 1
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextColor3 = Color3.fromRGB(150, 205, 250)
titleLabel.TextSize = 17
titleLabel.Font = Enum.Font.GothamBlack
titleLabel.Text = ""
titleLabel.Parent = card

local textLabel = Instance.new("TextLabel")
textLabel.Position = UDim2.new(0, 30, 0, 40)
textLabel.Size = UDim2.new(1, -52, 0, 60)
textLabel.BackgroundTransparency = 1
textLabel.TextXAlignment = Enum.TextXAlignment.Left
textLabel.TextYAlignment = Enum.TextYAlignment.Top
textLabel.TextWrapped = true
textLabel.TextColor3 = Color3.fromRGB(214, 222, 238)
textLabel.TextSize = 14
textLabel.Font = GameConfig.UI_FONT_BODY
textLabel.Text = ""
textLabel.Parent = card

local okButton = Instance.new("TextButton")
okButton.AnchorPoint = Vector2.new(1, 1)
okButton.Position = UDim2.new(1, -14, 1, -12)
okButton.Size = UDim2.new(0, 96, 0, 30)
okButton.BackgroundColor3 = Color3.fromRGB(56, 128, 200)
okButton.BorderSizePixel = 0
okButton.Text = "Entendi"
okButton.TextColor3 = Color3.new(1, 1, 1)
okButton.TextSize = 14
okButton.Font = Enum.Font.GothamBold
okButton.Parent = card

local okCorner = Instance.new("UICorner")
okCorner.CornerRadius = UDim.new(0, 8)
okCorner.Parent = okButton

-- ===== APARECER / SUMIR =====
local function hide()
	if not showing then return end
	showing = nil
	dismissToken += 1

	TweenService:Create(card, FADE, { Position = UDim2.new(0.5, 0, 1, 40) }):Play()
	task.delay(FADE.Time, function()
		if not showing then gui.Enabled = false end
	end)
end

local function show(lesson)
	showing = lesson
	dismissToken += 1
	local token = dismissToken

	titleLabel.Text = lesson.title
	textLabel.Text = lesson.text

	gui.Enabled = true
	card.Position = UDim2.new(0.5, 0, 1, 40)
	TweenService:Create(card, FADE, { Position = UDim2.new(0.5, 0, 1, -18) }):Play()

	-- MARCA COMO VISTA AO APARECER, não ao fechar. Fechando, quem saísse da
	-- partida com o cartão aberto reencontraria a mesma lição no próximo login,
	-- pra sempre. Apareceu na tela, já ensinou o que tinha pra ensinar.
	seen[lesson.id] = true
	TutorialUpdate:FireServer(lesson.id)

	task.delay(AUTO_DISMISS, function()
		if dismissToken == token then hide() end
	end)
end

okButton.MouseButton1Click:Connect(hide)

-- ===== ENTRADA =====
TutorialUpdate.OnClientEvent:Connect(function(payload)
	for _, lessonId in ipairs(payload.seen or {}) do
		seen[lessonId] = true
	end
	seenReady = true
end)

MatchUpdate.OnClientEvent:Connect(function(state)
	-- Voltou pro lobby: recolhe o cartão. Sem isto ele ficaria pendurado por
	-- cima do menu depois da partida.
	if not state or state.phase == "lobby" or state.phase == "finished" or state.winner then
		hide()
		return
	end

	if showing or not seenReady then return end

	local lesson = Tutorial.NextLesson(state, seen)
	if not lesson then return end

	-- Segura o cartão por um instante: no primeiro snapshot da partida o
	-- tabuleiro ainda está montando, e a dica entrava junto com a animação de
	-- entrada — duas coisas se mexendo ao mesmo tempo, nenhuma delas lida.
	task.delay(SHOW_DELAY, function()
		-- Reconfere: o jogador pode ter voltado pro lobby nesse intervalo, e a
		-- lição pode ter sido mostrada por outro snapshot que chegou antes.
		if showing or seen[lesson.id] then return end
		show(lesson)
	end)
end)
