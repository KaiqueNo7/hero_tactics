--[[
	GameStartTrigger.server.lua
	Script — ServerScriptService

	Porta de entrada do lobby: dois pads (bot e PvP) e a fila de espera do PvP.

	Várias partidas rodam ao mesmo tempo, cada uma na sua arena. O pad só recusa
	quando (a) as arenas acabaram — MAX_SIMULTANEOUS_MATCHES — ou (b) o jogador
	já está numa partida.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

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

-- O cenário da arena é persistente: só constrói se ainda não existir no place.
-- As arenas dos slots seguintes são clonadas sob demanda, na primeira partida
-- que precisar delas.
BoardSpawner.EnsureArena(1)

-- ===================== RAIO DE SPAWN =====================
-- Os 19 SpawnLocations do lobby chegam a ~30 studs do centro e o pad de PvP
-- está a ~33 — dava pra renascer praticamente em cima do pad e entrar na fila
-- sem querer. Desliga os pontos mais afastados; os de dentro do raio bastam.
local function TrimSpawnRadius()
	local lobby = Workspace:FindFirstChild("Folder")
	lobby = lobby and lobby:FindFirstChild("Lobby")
	local spawns = lobby and lobby:FindFirstChild("Spawns")
	if not spawns then return end

	local parts = {}
	local sum = Vector3.new()

	for _, child in ipairs(spawns:GetChildren()) do
		if child:IsA("SpawnLocation") then
			table.insert(parts, child)
			sum += child.Position
		end
	end

	if #parts == 0 then return end

	local center = sum / #parts
	local kept = 0

	for _, spawn in ipairs(parts) do
		local flat = Vector3.new(spawn.Position.X - center.X, 0, spawn.Position.Z - center.Z)
		local inside = flat.Magnitude <= GameConfig.LOBBY_SPAWN_RADIUS
		spawn.Enabled = inside
		if inside then kept += 1 end
	end

	-- se o raio for apertado demais, mantém o mais próximo do centro ligado
	if kept == 0 then
		local closest, bestDistance = parts[1], math.huge
		for _, spawn in ipairs(parts) do
			local distance = (spawn.Position - center).Magnitude
			if distance < bestDistance then
				closest, bestDistance = spawn, distance
			end
		end
		closest.Enabled = true
		kept = 1
	end

	print(("GameStartTrigger: %d de %d spawns ativos (raio %d)."):format(kept, #parts, GameConfig.LOBBY_SPAWN_RADIUS))
end

TrimSpawnRadius()

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
-- O MatchManager é quem escolhe a arena livre, monta o tabuleiro e avisa os
-- clientes: daqui em diante o pad só decide QUEM joga com QUEM.
local function CanStart(player)
	if MatchManager.IsInMatch(player) then
		SendStatus(player, "busy", "Você já está numa partida")
		return false
	end

	if not MatchManager.HasFreeSlot() then
		SendStatus(player, "busy", "Todas as arenas estão ocupadas — tente em instantes")
		return false
	end

	return true
end

local function OnBotPadTouched(player)
	if not CanStart(player) then return end

	LeaveQueue(player, false)
	SendStatus(player, "loading", "Preparando a arena...")

	-- corrida: entre o CanStart e aqui, outra pessoa pode ter pego a última arena
	if not MatchManager.StartMatch(player, nil) then
		SendStatus(player, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
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

	if not MatchManager.StartMatch(playerOne, playerTwo) then
		-- sem arena livre: devolve os dois pra fila em vez de perder o par
		SendStatus(playerOne, "busy", "Todas as arenas estão ocupadas — tente em instantes")
		SendStatus(playerTwo, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
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
