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
levelBadge.Size = UDim2.new(0, 136, 0, 46)
levelBadge.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
levelBadge.BackgroundTransparency = 0.2
levelBadge.BorderSizePixel = 0
levelBadge.Parent = profileGui

local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(0, 8)
badgeCorner.Parent = levelBadge

local levelLabel = Instance.new("TextLabel")
levelLabel.Size = UDim2.new(0.55, 0, 0, 22)
levelLabel.Position = UDim2.new(0, 10, 0, 4)
levelLabel.BackgroundTransparency = 1
levelLabel.Text = "Nível 1"
levelLabel.TextColor3 = Color3.fromRGB(255, 226, 150)
levelLabel.TextXAlignment = Enum.TextXAlignment.Left
levelLabel.TextScaled = true
levelLabel.Font = Enum.Font.GothamBlack
levelLabel.Parent = levelBadge

local xpLabel = Instance.new("TextLabel")
xpLabel.Size = UDim2.new(0.45, -10, 0, 16)
xpLabel.Position = UDim2.new(0.55, 0, 0, 8)
xpLabel.BackgroundTransparency = 1
xpLabel.Text = ""
xpLabel.TextColor3 = Color3.fromRGB(190, 200, 220)
xpLabel.TextXAlignment = Enum.TextXAlignment.Right
xpLabel.TextScaled = true
xpLabel.Font = Enum.Font.GothamBold
xpLabel.Parent = levelBadge

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

	if cancelButton.Visible then
		TweenService:Create(cancelButton, info, {
			BackgroundTransparency = textTransparency,
			TextTransparency = textTransparency,
		}):Play()
	end

	if not targetVisible then
		task.delay(FADE_TIME, function()
			if not visible then gui.Enabled = false end
		end)
	end
end

local function show(state, text, showCancel, showBar)
	currentState = state
	status.Text = text or ""
	cancelButton.Visible = showCancel or false
	track.Visible = showBar ~= false

	if showCancel then
		cancelButton.BackgroundTransparency = 0
		cancelButton.TextTransparency = 0
	end

	fade(true)
end

-- ===== ESTADO =====
LobbyStatus.OnClientEvent:Connect(function(payload)
	local state = payload and payload.state or "idle"

	if state == "idle" then
		currentState = "idle"
		fade(false)

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
