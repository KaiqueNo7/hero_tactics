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

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Trava o jogo em paisagem já na abertura, sem depender do jeito que o celular
-- estava segurado. LandscapeSensor deixa girar entre as duas paisagens, mas
-- nunca cai em retrato — o tabuleiro é largo demais pra caber em pé.
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
