--[[
	HeroUnlockService.lua
	ModuleScript — ServerScriptService/Modules/HeroUnlockService

	Quais heróis cada jogador possui, e a vitória que adiciona um à lista.

	Duas gerações ficaram pelo caminho: o elenco já foi liberado por NÍVEL e
	depois por COMPRA com moedas. Agora é conquista — cada herói sai de derrotar
	o bot correspondente (ReplicatedStorage.Modules.Campaign). O `starter` do
	catálogo marca os três que já vêm no primeiro login.

	O QUE MORA ONDE
	A regra (quem é inicial, qual confronto paga qual herói) fica em
	ReplicatedStorage.Modules — cliente e servidor leem a mesma coisa. A POSSE
	mora aqui e só aqui, e é ela a FONTE ÚNICA da progressão inteira: bot
	derrotado, grupo liberado e PvP liberado são todos DERIVADOS desta lista
	(ver Campaign). Não existe segunda lista de bots vencidos pra gravar e
	discordar desta. O cliente nunca informa posse; ele só recebe.

	Mesma dependência de DataStore do ProgressionService e do CoinService: exige
	"Enable Studio Access to API Services" (Game Settings > Security) pra
	persistir dentro do Studio. Sem isso os pcall do SafeStore falham com warn e
	o desbloqueio vale só pra sessão.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local DevAccess = require(ServerScriptService.Modules.DevAccess)
local SafeStore = require(ServerScriptService.Modules.SafeStore)
local RewardQueueService = require(ServerScriptService.Modules.RewardQueueService)

local HERO_STORE_NAME = "HeroTactics_Heroes_v1"
local heroStore = DataStoreService:GetDataStore(HERO_STORE_NAME)

local remotes = ReplicatedStorage:WaitForChild("Remotes")

local function EnsureRemote(className, name)
	local existing = remotes:FindFirstChild(name)
	if existing then return existing end

	local created = Instance.new(className)
	created.Name = name
	created.Parent = remotes
	return created
end

local rosterUpdate = EnsureRemote("RemoteEvent", "RosterUpdate")

local HeroUnlockService = {}

local owned = {}

local function WonSet(userId)
	return owned[userId] or {}
end

function HeroUnlockService.GetPlayableIds(player)
	local userId = player and player.UserId or nil
	local fullCatalog = DevAccess.HasFullCatalog(player)
	local won = userId and WonSet(userId) or {}

	local set = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if fullCatalog or HeroData.IsStarter(data) or won[data.id] then
			set[data.id] = true
		end
	end
	return set
end

function HeroUnlockService.OwnsHero(player, dataId)
	return HeroUnlockService.GetPlayableIds(player)[dataId] == true
end

local function Push(player, unlocked)
	if not player or not player.Parent then return end

	local ids = {}
	for dataId in pairs(HeroUnlockService.GetPlayableIds(player)) do
		table.insert(ids, dataId)
	end
	table.sort(ids)

	rosterUpdate:FireClient(player, { owned = ids, unlocked = unlocked })
end

local function Load(player)
	local ok, value = SafeStore.Get(heroStore, tostring(player.UserId),
		("leitura de heróis de %s"):format(player.Name))
	if not ok then value = nil end

	if not player.Parent then return end

	local set = {}
	if type(value) == "table" then
		for _, dataId in ipairs(value) do
			local id = tonumber(dataId)
			if id then set[id] = true end
		end
	end

	owned[player.UserId] = set
	Push(player)
end

function HeroUnlockService.Unlock(player, dataId)
	if not player then return false, "sem jogador" end

	dataId = tonumber(dataId)
	if not dataId then return false, "id inválido" end

	local data = HeroData.GetById(dataId)
	if not data then return false, "herói inexistente" end
	if HeroData.IsStarter(data) then return false, "herói é inicial" end

	local userId = player.UserId
	if WonSet(userId)[dataId] then return false, "já possui" end

	local set = owned[userId] or {}
	set[dataId] = true

	local ids = {}
	for id in pairs(set) do table.insert(ids, id) end
	table.sort(ids)

	local hadBefore = owned[userId]
	owned[userId] = set

	local stored = SafeStore.Update(heroStore, tostring(userId), function()
		return ids
	end, ("gravação de heróis de %s"):format(player.Name))

	if not stored then
		set[dataId] = nil
		owned[userId] = hadBefore
		warn(("HeroUnlockService: %s venceu %s e o desbloqueio não gravou.")
			:format(player.Name, data.name))
		return false, "falha ao gravar"
	end
	RewardQueueService.Push(userId, { hero = dataId })
	Push(player, dataId)

	print(("HeroUnlockService: %s desbloqueou %s."):format(player.Name, data.name))
	return true, nil
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(Load, player)
end)

Players.PlayerRemoving:Connect(function(player)
	owned[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return HeroUnlockService
