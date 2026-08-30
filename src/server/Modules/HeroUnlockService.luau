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

-- Mesmo padrão do ProfileUpdate e do WalletUpdate: criados aqui se faltarem, pra
-- quem clonar o repo não precisar montar os remotes na mão dentro do place.
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

-- [userId] = { [dataId] = true } — só os CONQUISTADOS. Os `starter` não entram
-- aqui: eles saem do catálogo, e gravar o óbvio só faria a chave crescer à toa.
local owned = {}

-- ===================== LEITURA =====================
local function WonSet(userId)
	return owned[userId] or {}
end

-- O que o jogador pode levar pra partida: os iniciais + os conquistados. É
-- também o conjunto que o Campaign lê pra dizer o que está aberto, o que está
-- concluído e se o PvP já abriu. `player` (e não userId) porque o DevAccess
-- decide pela pessoa, não pelo número.
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


-- ===================== ESTADO PRO CLIENTE =====================
-- Manda a lista de ids conquistados. O lobby junta isso com o catálogo (que ele
-- já tem) e com o Campaign pra desenhar o elenco E os quadrados de confronto.
-- `unlocked` é o id recém-conquistado, pra UI poder comemorar; nil no estado
-- inicial.
-- Manda o conjunto EFETIVO (GetPlayableIds), e não só os conquistados: é o
-- mesmo que o servidor usa pra decidir se o confronto está trancado. Enquanto
-- eram listas diferentes, o testador/dono via cadeado na tela e entrava assim
-- mesmo — porque pro servidor o DevAccess já tinha liberado tudo, e o cliente
-- não sabia disso. Uma lista só, os dois lados enxergam a mesma coisa.
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

	-- saiu enquanto o GetAsync rodava: não deixa lixo no cache
	if not player.Parent then return end

	-- guardado como lista de ids (compacto e legível no painel do DataStore);
	-- em memória vira conjunto, que é como todo o resto do código pergunta
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

-- ===================== CONQUISTA =====================
-- Chamada pelo MatchManager quando o jogador vence um confronto da campanha.
-- Devolve (ok, motivo); o motivo é pro log do servidor.
--
-- IDEMPOTENTE de propósito: "já possui" sai como recusa silenciosa e sem erro.
-- É o que faz o estado "concluído" do quadrado valer — repetir um confronto já
-- vencido (revanche, ou o mesmo evento de fim de partida chegando duas vezes)
-- não regrava nada nem dispara comemoração de novo.
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

	local stored = SafeStore.Update(heroStore, tostring(userId), function()
		return ids
	end, ("gravação de heróis de %s"):format(player.Name))

	if not stored then
		-- Não gravou: o cache NÃO recebe o herói, pra sessão e disco não
		-- divergirem. O jogador vence de novo e conquista de novo — melhor do
		-- que ele achar que tem um herói que some no próximo login.
		warn(("HeroUnlockService: %s venceu %s e o desbloqueio não gravou.")
			:format(player.Name, data.name))
		return false, "falha ao gravar"
	end

	owned[userId] = set
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

-- o módulo pode ser exigido depois de alguém já ter entrado (Studio, hot reload)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return HeroUnlockService
