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
	recusa quando (a) as arenas acabaram — MAX_LIVE_MATCHES — ou (b) o
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
local LobbyZones = require(ReplicatedStorage.Modules.LobbyZones)
local Tutorial = require(ReplicatedStorage.Modules.Tutorial)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local LobbyZoneBuilder = require(ServerScriptService.Modules.LobbyZoneBuilder)
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)
local MatchManager = require(ServerScriptService.Modules.MatchManager)
local RewardQueueService = require(ServerScriptService.Modules.RewardQueueService)
local TutorialService = require(ServerScriptService.Modules.TutorialService)

local PlaceHero = ReplicatedStorage.Remotes.PlaceHero
local GameAction = ReplicatedStorage.Remotes.GameAction
local LobbyStatus = ReplicatedStorage.Remotes.LobbyStatus

local TOUCH_DEBOUNCE = 1.5
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

DecoratePad(botPad, Color3.fromRGB(60, 170, 130), "TREINO CONTRA O BOT", "campanha: menu CAMPANHA")
DecoratePad(pvpPad, Color3.fromRGB(200, 70, 70), "JOGAR CONTRA JOGADOR", "pise para entrar na fila")

local FIGHT_PAD_SIZE = Vector3.new(10, 1, 11)

local function InLobbyCircle(position)
	local center, half = LobbyZones.LOBBY_CENTER, LobbyZones.LOBBY_HALF
	return math.abs(position.X - center.X) <= half.X
		and math.abs(position.Z - center.Y) <= half.Y
end

local function DefaultFightPadPosition(fight)
	if fight.island then
		return LobbyZoneBuilder.IslandTop(fight.island)
	end

	local zone = LobbyZones.ForGroup(fight.group)
	if not zone then return nil end

	local peers = {}
	for _, other in ipairs(Campaign.FIGHTS) do
		if other.group == fight.group and not other.island then
			table.insert(peers, other)
		end
	end

	local slots = LobbyZones.PadSlots(zone, #peers)
	local index = table.find(peers, fight) or 1
	return slots[index]
end

local FIGHT_PORTRAIT_SCALE = 0.55

local function BuildFightBillboard(pad, data)
	local scale = FIGHT_PORTRAIT_SCALE
	local portraitHeight = math.round(110 * scale)
	local nameHeight = math.round(24 * scale)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "FightLabel"
	billboard.Size = UDim2.new(0, math.round(120 * scale), 0, portraitHeight + nameHeight + 6)
	billboard.StudsOffset = Vector3.new(0, 3 + 4 * scale, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 90
	billboard.Enabled = true
	billboard.Parent = pad

	local portrait = Instance.new("ImageLabel")
	portrait.Name = "Portrait"
	portrait.Size = UDim2.new(1, 0, 0, portraitHeight)
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
	nameLabel.Position = UDim2.new(0, 0, 0, portraitHeight + 2)
	nameLabel.Size = UDim2.new(1, 0, 0, nameHeight)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = data.name:upper()
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Parent = billboard
end

local function EnsureFightPad(fight)
	local data = HeroData.GetById(fight.hero)
	if not data then return nil end

	local padName = "FightPad_" .. fight.hero
	local pad = Workspace:FindFirstChild(padName, true)
	local home = DefaultFightPadPosition(fight)

	if not home then
		if pad and InLobbyCircle(pad.Position) and not pad:GetAttribute("KeepPosition") then
			pad:Destroy()
			pad = nil
		end

		if not pad then
			warn(("GameStartTrigger: confronto de %s nao tem ilha (nem `island` no Campaign, "
				.. "nem zona do grupo %d no LobbyZones) — sem quadrado no lobby. "
				.. "O heroi continua acessivel pelo painel CAMPANHA."):format(data.name, fight.group))
			return nil
		end
	end

	if not pad then
		pad = Instance.new("Part")
		pad.Name = padName
		pad.Size = FIGHT_PAD_SIZE
		pad.Position = home
		pad.Parent = Workspace:FindFirstChild("Base") or Workspace

		pad:SetAttribute("TrailPending", true)
	end

	pad.Anchored = true
	pad.CanCollide = true
	pad.Material = Enum.Material.SmoothPlastic
	pad.Color = Color3.fromRGB(70, 90, 120)
	pad:SetAttribute("FightHero", fight.hero)

	local existingLabel = pad:FindFirstChild("FightLabel")
	if existingLabel then existingLabel:Destroy() end
	BuildFightBillboard(pad, data)

	CollectionService:AddTag(pad, Campaign.PAD_TAG)
	return pad
end

BoardSpawner.EnsureArena(1)
LobbyZoneBuilder.BuildTerrain()

local function TrimSpawnRadius()
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

	if not MatchManager.StartMatch(player, nil) then
		SendStatus(player, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
end

local function ResolveFight(player, heroId)
	local fight = Campaign.GetFight(tonumber(heroId))
	if not fight then return nil end

	if Campaign.StateOf(HeroUnlockService.GetPlayableIds(player), fight) == "locked" then
		SendStatus(player, "busy", "Vença os confrontos anteriores primeiro")
		return nil
	end

	return fight
end

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

	if not MatchManager.StartMatch(player, nil, nil, fight) then
		SendStatus(player, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
end

local function OnPvpPadTouched(player)
	if table.find(queue, player) then return end

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
		SendStatus(playerOne, "busy", "Todas as arenas estão ocupadas — tente em instantes")
		SendStatus(playerTwo, "busy", "Todas as arenas estão ocupadas — tente em instantes")
	end
end

local function ConnectPad(pad, handler)
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

for _, fight in ipairs(Campaign.FIGHTS) do
	ConnectPad(EnsureFightPad(fight), function(player)
		OnFightPadTouched(player, fight.hero)
	end)
end

LobbyZoneBuilder.PlacePads()

local ACTION_BUDGET = 12
local windowStart, actionCount = {}, {}

local function AllowAction(player)
	local now = os.clock()

	if not windowStart[player] or now - windowStart[player] >= 1 then
		windowStart[player] = now
		actionCount[player] = 0
	end

	actionCount[player] += 1
	return actionCount[player] <= ACTION_BUDGET
end

PlaceHero.OnServerEvent:Connect(function(player, dataId, hexId)
	if not AllowAction(player) then return end
	MatchManager.PlaceHero(player, dataId, hexId)
end)

GameAction.OnServerEvent:Connect(function(player, action, arg1, arg2)
	if not AllowAction(player) then return end

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
	elseif action == "shield" then
		MatchManager.GrantShield(player, arg1)
	elseif action == "leaveMatch" then
		MatchManager.LeaveMatch(player)
	elseif action == "matchLog" then
		GameAction:FireClient(player, "matchLog", MatchManager.GetLog(player))
	elseif action == "cancelQueue" then
		LeaveQueue(player, true)
	elseif action == "queue" then
		OnPvpPadTouched(player)
	elseif action == "claimRewards" then
		local pending = RewardQueueService.Take(player)
		if pending then
			GameAction:FireClient(player, "rewards", pending)
		end
	elseif action == "fight" then
		OnFightRequested(player, arg1)
	end
end)

ReplicatedStorage.Remotes[Tutorial.REMOTE_NAME].OnServerEvent:Connect(function(player, lessonId)
	if not AllowAction(player) then return end
	TutorialService.MarkSeen(player, lessonId)
end)

Players.PlayerAdded:Connect(function(player)
	if not player.Character then player.CharacterAdded:Wait() end
	task.wait(1)
	if player.Parent then MatchManager.HandlePlayerRejoined(player) end
end)

Players.PlayerRemoving:Connect(function(player)
	lastTouch[player] = nil

	windowStart[player] = nil
	actionCount[player] = nil
	LeaveQueue(player, false)
	MatchManager.HandlePlayerLeft(player)
end)
