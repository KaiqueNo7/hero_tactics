--[[
	GameStartTrigger.server.lua
	Script — ServerScriptService

	Porta de entrada do lobby: o pad de treino, o pad de PvP com a fila, e os onze
	quadrados da campanha — um por confronto, com o retrato do herói em cima.

	Os quadrados também respondem pelo painel CAMPANHA do menu (mesma ação
	"fight"), então o jogador entra pisando ou clicando. O ESTADO deles é por
	jogador, e uma Part tem uma cor só pra todo mundo: quem pinta cada cópia é o
	cliente (LobbyMenu), pela tag Campaign.PAD_TAG.

	Várias partidas rodam ao mesmo tempo, cada uma na sua arena. A entrada só
	recusa quando (a) as arenas acabaram — MAX_SIMULTANEOUS_MATCHES — ou (b) o
	jogador já está numa partida.
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Campaign = require(ReplicatedStorage.Modules.Campaign)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local PlaceHero = ReplicatedStorage.Remotes.PlaceHero
local GameAction = ReplicatedStorage.Remotes.GameAction
local LobbyStatus = ReplicatedStorage.Remotes.LobbyStatus

local TOUCH_DEBOUNCE = 1.5

-- Os pads são construídos à mão no place, e onde eles moram é decisão de quem
-- edita o cenário: agrupar o lobby inteiro numa pasta (Workspace.Base) tirava os
-- dois da raiz do Workspace, o WaitForChild direto ficava pendurado pra sempre e
-- ninguém conseguia entrar em partida nenhuma — sem erro na saída, só silêncio.
-- Agora procura em qualquer profundidade, e continua esperando o que ainda não
-- replicou.
local PAD_WAIT_TIMEOUT = 20

local function WaitForPad(name)
	local deadline = os.clock() + PAD_WAIT_TIMEOUT

	repeat
		local pad = Workspace:FindFirstChild(name, true)
		if pad and pad:IsA("BasePart") then return pad end
		task.wait(0.25)
	until os.clock() > deadline

	warn(("GameStartTrigger: pad '%s' não encontrado no Workspace em %ds. " ..
		"Ele precisa ser uma Part com esse nome exato, em qualquer lugar do cenário.")
		:format(name, PAD_WAIT_TIMEOUT))
	return nil
end

local botPad = WaitForPad("StartBotMatch")
local pvpPad = WaitForPad("StartPvpMatch")

local queue = {}
local lastTouch = {}

-- ===================== PADS =====================
-- Os pads vieram do build à mão soltos e tortos; deixa em pé, ancorado e
-- com placa legível pra virar um botão de verdade.
local function DecoratePad(pad, color, title, subtitle)
	if not pad then return end

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

-- O pad do bot continua sendo treino LIVRE (time sorteado, sem prêmio). Quem
-- desbloqueia herói é o painel CAMPANHA, no menu do lobby.
DecoratePad(botPad, Color3.fromRGB(60, 170, 130), "TREINO CONTRA O BOT", "campanha: menu CAMPANHA")
DecoratePad(pvpPad, Color3.fromRGB(200, 70, 70), "JOGAR CONTRA JOGADOR", "pise para entrar na fila")

-- ===================== QUADRADOS DA CAMPANHA =====================
-- Um pad por confronto, com o retrato do herói e o nome flutuando em cima.
--
-- ADOTA o que já existir: se houver uma Part chamada FightPad_<id> em qualquer
-- lugar do Workspace, ela é usada como está — posição, tamanho e material do
-- jeito que foram deixados no Studio. Só quando não existe é que uma é criada,
-- numa grade solta perto da neve. É o mesmo acordo dos pads de bot e PvP: o
-- cenário é de quem edita o place, o script só liga o comportamento.
--
-- A COR e o CADEADO não saem daqui: o estado (aberto/trancado/concluído) é POR
-- JOGADOR, e uma Part tem uma cor só pra todo mundo. Quem pinta é o cliente
-- (LobbyMenu), na cópia dele, pela tag CollectionService abaixo.

local FIGHT_PAD_SIZE = Vector3.new(10, 1, 11)
local FIGHT_PAD_Y = 712.9 -- mesmo chão dos outros pads do lobby

-- Grade padrão: 6 na fileira de trás, o resto na da frente, ao norte do lobby
-- (lado da neve). Só vale pra pads que ainda não existem no place.
local function DefaultFightPadPosition(index)
	local row = index <= 6 and 0 or 1
	local column = row == 0 and (index - 1) or (index - 7)
	local perRow = row == 0 and 6 or (#Campaign.FIGHTS - 6)
	local spread = 18

	local x = (column - (perRow - 1) / 2) * spread
	local z = -34 - row * 16
	return Vector3.new(x, FIGHT_PAD_Y, z)
end

local function BuildFightBillboard(pad, data)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "FightLabel"
	billboard.Size = UDim2.new(0, 120, 0, 150)
	billboard.StudsOffset = Vector3.new(0, 7, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 160
	billboard.Parent = pad

	local portrait = Instance.new("ImageLabel")
	portrait.Name = "Portrait"
	portrait.Size = UDim2.new(1, 0, 0, 110)
	portrait.BackgroundTransparency = 1
	portrait.ScaleType = Enum.ScaleType.Fit
	portrait.ResampleMode = Enum.ResamplerMode.Pixelated
	portrait.Parent = billboard

	local spriteId = HeroData.GetSpriteId(data)
	if spriteId then
		portrait.Image = spriteId
		portrait.ImageRectSize = HeroData.GetFrameSize(data)
		portrait.ImageRectOffset = HeroData.GetFrameOffset(data)
	else
		portrait.BackgroundTransparency = 0
		portrait.BackgroundColor3 = data.color
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "HeroName"
	nameLabel.Position = UDim2.new(0, 0, 0, 112)
	nameLabel.Size = UDim2.new(1, 0, 0, 24)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = data.name:upper()
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Parent = billboard
end

-- Monta a Part (ou adota a que já existe) e devolve ela pronta. Quem liga o
-- toque é o final do arquivo, junto dos outros pads — lá o OnFightRequested já
-- existe.
local function EnsureFightPad(fight, index)
	local data = HeroData.GetById(fight.hero)
	if not data then return nil end

	local padName = "FightPad_" .. fight.hero
	local pad = Workspace:FindFirstChild(padName, true)

	if not pad then
		pad = Instance.new("Part")
		pad.Name = padName
		pad.Size = FIGHT_PAD_SIZE
		pad.Position = DefaultFightPadPosition(index)
		pad.Parent = Workspace:FindFirstChild("Base") or Workspace
	end

	pad.Anchored = true
	pad.CanCollide = true
	pad.Material = Enum.Material.SmoothPlastic
	-- cor de partida; o cliente repinta conforme o estado DELE
	pad.Color = Color3.fromRGB(70, 90, 120)
	pad:SetAttribute("FightHero", fight.hero)

	if not pad:FindFirstChild("FightLabel") then
		BuildFightBillboard(pad, data)
	end

	CollectionService:AddTag(pad, Campaign.PAD_TAG)
	return pad
end

-- O cenário da arena é persistente: só constrói se ainda não existir no place.
-- As arenas dos slots seguintes são clonadas sob demanda, na primeira partida
-- que precisar delas.
BoardSpawner.EnsureArena(1)

-- ===================== RAIO DE SPAWN =====================
-- Os 19 SpawnLocations do lobby chegam a ~30 studs do centro e o pad de PvP
-- está a ~33 — dava pra renascer praticamente em cima do pad e entrar na fila
-- sem querer. Desliga os pontos mais afastados; os de dentro do raio bastam.
local function TrimSpawnRadius()
	-- Antes isso descia por um caminho fixo (Workspace.Folder.Lobby.Spawns) e
	-- quebrava calado assim que o lobby era reorganizado ou renomeado no Studio.
	-- Varrer o Workspace atrás de SpawnLocation dá no mesmo e não depende de
	-- onde as coisas estão guardadas.
	local parts = {}
	local sum = Vector3.new()

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("SpawnLocation") then
			table.insert(parts, descendant)
			sum += descendant.Position
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
	if not pvpPad then return end

	local label = pvpPad:FindFirstChild("PadLabel")
	local subtitle = label and label:FindFirstChild("Subtitle")
	if subtitle then subtitle.Text = text end
end

-- ===================== FILA =====================
-- `extra` leva campos soltos do estado (hoje só o confronto que o modal de
-- confirmação está perguntando).
local function SendStatus(player, state, text, extra)
	local payload = { state = state, text = text }
	if extra then
		for key, value in pairs(extra) do payload[key] = value end
	end
	LobbyStatus:FireClient(player, payload)
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

-- ===================== CAMPANHA =====================
-- Confronto liberado pra ESTE jogador, ou nil (já avisando o motivo). A conta é
-- a mesma que o lobby faz pra desenhar o quadrado — e agora sobre a MESMA lista
-- dos dois lados (ver HeroUnlockService.Push), senão a tela mostra cadeado e o
-- servidor deixa passar.
--
-- Roda nas DUAS pontas do fluxo, de propósito: quando o jogador pisa no
-- quadrado (pra decidir se pergunta) e de novo quando ele responde "Sim" (pra
-- valer de verdade). Confiar na primeira seria confiar no cliente — um
-- FireServer à mão pularia a escada inteira e pegaria o Golem no primeiro
-- minuto.
local function ResolveFight(player, heroId)
	local fight = Campaign.GetFight(tonumber(heroId))
	if not fight then return nil end

	if Campaign.StateOf(HeroUnlockService.GetPlayableIds(player), fight) == "locked" then
		SendStatus(player, "busy", "Vença os confrontos anteriores primeiro")
		return nil
	end

	return fight
end

-- Pisou no quadrado: PERGUNTA, não entra. Quem entra é o "Sim" do modal, que
-- volta pelo GameAction como um pedido normal.
local function OnFightPadTouched(player, heroId)
	local fight = ResolveFight(player, heroId)
	if not fight then return end
	if not CanStart(player) then return end

	SendStatus(player, "confirm",
		("Deseja enfrentar %s?"):format(HeroData.GetById(fight.hero).name),
		{ fight = fight.hero })
end

local function OnFightRequested(player, heroId)
	local fight = ResolveFight(player, heroId)
	if not fight then return end
	if not CanStart(player) then return end

	LeaveQueue(player, false)
	SendStatus(player, "loading", "Preparando a arena...")

	-- confronto CONCLUÍDO continua entrando: é revanche/treino contra o mesmo
	-- time, e o Unlock idempotente cuida de não premiar duas vezes
	if not MatchManager.StartMatch(player, nil, nil, fight) then
		SendStatus(player, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
end

local function OnPvpPadTouched(player)
	if table.find(queue, player) then return end

	-- O PvP abre com PVP_MIN_HEROES heróis na mão, quaisquer que sejam. Mesma
	-- regra que o lobby usa pra apagar o botão — aqui é onde ela vale.
	if not Campaign.PvpUnlocked(HeroUnlockService.GetPlayableIds(player)) then
		SendStatus(player, "busy", ("Desbloqueie %d heróis para jogar online")
			:format(Campaign.PVP_MIN_HEROES))
		return
	end

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
	-- pad faltando não pode derrubar o script: os RemoteEvents lá embaixo são o
	-- que faz uma partida em andamento continuar respondendo
	if not pad then return end

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

-- Os quadrados da campanha entram pelo MESMO caminho dos outros pads (debounce
-- de toque incluído) — só que pisar abre a pergunta em vez de começar a
-- partida. Quem recusa confronto trancado é o ResolveFight, nas duas pontas.
for index, fight in ipairs(Campaign.FIGHTS) do
	ConnectPad(EnsureFightPad(fight, index), function(player)
		OnFightPadTouched(player, fight.hero)
	end)
end

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
	elseif action == "resurrect" then
		MatchManager.Resurrect(player, arg1)
	elseif action == "leaveMatch" then
		MatchManager.LeaveMatch(player)
	elseif action == "cancelQueue" then
		LeaveQueue(player, true)
	elseif action == "fight" then
		OnFightRequested(player, arg1)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastTouch[player] = nil
	LeaveQueue(player, false)
	MatchManager.HandlePlayerLeft(player)
end)
