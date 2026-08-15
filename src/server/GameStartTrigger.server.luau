--[[
	GameStartTrigger.server.lua
	Script — ServerScriptService

	Porta de entrada do lobby: dois pads (bot e PvP) e a fila de espera do PvP.
	Uma partida por servidor — enquanto uma estiver rodando, os pads recusam
	novos jogadores em vez de atropelar o tabuleiro.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local BoardReady = ReplicatedStorage.Remotes.BoardReady
local PlaceHero = ReplicatedStorage.Remotes.PlaceHero
local GameAction = ReplicatedStorage.Remotes.GameAction
local LobbyStatus = ReplicatedStorage.Remotes.LobbyStatus

local TOUCH_DEBOUNCE = 1.5

local botPad = Workspace:WaitForChild("StartBotMatch")
local pvpPad = Workspace:WaitForChild("StartPvpMatch")

local queue = {}
local lastTouch = {}

-- ===================== PADS =====================
-- Os pads vieram do build à mão soltos e tortos; deixa em pé, ancorado e
-- com placa legível pra virar um botão de verdade.
local function DecoratePad(pad, color, title, subtitle)
	pad.Anchored = true
	pad.CanCollide = true
	pad.Material = Enum.Material.SmoothPlastic
	pad.Color = color
	pad.CFrame = CFrame.new(pad.Position)

	if pad:FindFirstChild("PadLabel") then return end

	local glow = Instance.new("PointLight")
	glow.Name = "PadGlow"
	glow.Color = color
	glow.Brightness = 1.6
	glow.Range = 18
	glow.Parent = pad

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PadLabel"
	billboard.Size = UDim2.new(0, 220, 0, 70)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.Parent = pad

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, 0, 0.58, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.TextStrokeTransparency = 0.3
	titleLabel.TextScaled = true
	titleLabel.Font = Enum.Font.GothamBlack
	titleLabel.Parent = billboard

	local subtitleLabel = Instance.new("TextLabel")
	subtitleLabel.Name = "Subtitle"
	subtitleLabel.Size = UDim2.new(1, 0, 0.42, 0)
	subtitleLabel.Position = UDim2.new(0, 0, 0.58, 0)
	subtitleLabel.BackgroundTransparency = 1
	subtitleLabel.Text = subtitle
	subtitleLabel.TextColor3 = Color3.fromRGB(220, 230, 245)
	subtitleLabel.TextStrokeTransparency = 0.5
	subtitleLabel.TextScaled = true
	subtitleLabel.Font = Enum.Font.GothamBold
	subtitleLabel.Parent = billboard
end

DecoratePad(botPad, Color3.fromRGB(60, 170, 130), "JOGAR CONTRA O BOT", "pise para começar")
DecoratePad(pvpPad, Color3.fromRGB(200, 70, 70), "JOGAR CONTRA JOGADOR", "pise para entrar na fila")

local function SetPvpSubtitle(text)
	local label = pvpPad:FindFirstChild("PadLabel")
	local subtitle = label and label:FindFirstChild("Subtitle")
	if subtitle then subtitle.Text = text end
end

-- ===================== FILA =====================
local function SendStatus(player, state, text)
	LobbyStatus:FireClient(player, { state = state, text = text })
end

local function RefreshQueue()
	SetPvpSubtitle(#queue > 0
		and ("na fila: %d/2"):format(#queue)
		or "pise para entrar na fila")

	for _, player in ipairs(queue) do
		SendStatus(player, "queued", ("Procurando oponente...  %d/2"):format(#queue))
	end
end

local function LeaveQueue(player, notify)
	local index = table.find(queue, player)
	if not index then return end

	table.remove(queue, index)
	if notify then SendStatus(player, "idle") end
	RefreshQueue()
end

-- ===================== PARTIDA =====================
local function BeginMatch(playerOne, playerTwo)
	BoardSpawner.SpawnBoard(playerTwo == nil)

	local hexSize, offset = HexGrid.GetHexSize(), HexGrid.GetBoardOffset()
	BoardReady:FireClient(playerOne, hexSize, offset, 1)
	if playerTwo then
		BoardReady:FireClient(playerTwo, hexSize, offset, 2)
	end

	MatchManager.StartMatch(playerOne, playerTwo)
end

local function CanStart(player)
	if MatchManager.IsActive() then
		SendStatus(player, "busy", "Já existe uma partida em andamento neste servidor")
		return false
	end
	return true
end

local function OnBotPadTouched(player)
	if not CanStart(player) then return end

	LeaveQueue(player, false)
	SendStatus(player, "loading", "Preparando a arena...")
	BeginMatch(player, nil)
end

local function OnPvpPadTouched(player)
	if table.find(queue, player) then return end
	if not CanStart(player) then return end

	table.insert(queue, player)
	RefreshQueue()

	if #queue < 2 then return end

	local playerOne = table.remove(queue, 1)
	local playerTwo = table.remove(queue, 1)
	RefreshQueue()

	SendStatus(playerOne, "loading", "Oponente encontrado! Preparando a arena...")
	SendStatus(playerTwo, "loading", "Oponente encontrado! Preparando a arena...")

	BeginMatch(playerOne, playerTwo)
end

-- ===================== ENTRADA =====================
local function ConnectPad(pad, handler)
	pad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player then return end

		local now = os.clock()
		if lastTouch[player] and now - lastTouch[player] < TOUCH_DEBOUNCE then return end
		lastTouch[player] = now

		handler(player)
	end)
end

ConnectPad(botPad, OnBotPadTouched)
ConnectPad(pvpPad, OnPvpPadTouched)

PlaceHero.OnServerEvent:Connect(function(player, dataId, hexId)
	MatchManager.PlaceHero(player, dataId, hexId)
end)

GameAction.OnServerEvent:Connect(function(player, action, arg1, arg2)
	if action == "move" then
		MatchManager.MoveHero(player, arg1, arg2)
	elseif action == "attack" then
		MatchManager.AttackHero(player, arg1, arg2)
	elseif action == "endTurn" then
		MatchManager.EndTurn(player)
	elseif action == "replay" then
		MatchManager.Replay(player)
	elseif action == "leaveMatch" then
		MatchManager.LeaveMatch(player)
	elseif action == "cancelQueue" then
		LeaveQueue(player, true)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastTouch[player] = nil
	LeaveQueue(player, false)
	MatchManager.HandlePlayerLeft(player)
end)
