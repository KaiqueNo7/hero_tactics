--[[
	HeroUnlockService.lua
	ModuleScript — ServerScriptService/Modules/HeroUnlockService

	Quais heróis cada jogador possui, e a compra que adiciona um à lista.

	Antes o elenco era liberado por NÍVEL: o catálogo em HeroData carregava um
	`unlock` e o ProgressionService dizia o nível. Agora o nível não tranca mais
	ninguém — o catálogo inteiro está à venda desde a primeira partida, e o que
	separa é a carteira. Quem começa de graça está marcado com `starter` no
	catálogo; o resto custa Progression.HERO_COST.

	O QUE MORA ONDE
	A regra (quem é grátis, quanto custa) fica em ReplicatedStorage.Modules —
	cliente e servidor leem a mesma coisa. A POSSE mora aqui e só aqui: é o
	servidor que compra, grava e responde. O cliente manda "quero o herói 7" e
	recebe de volta a lista atualizada; ele nunca informa preço nem posse.

	Mesma dependência de DataStore do ProgressionService e do CoinService: exige
	"Enable Studio Access to API Services" (Game Settings > Security) pra
	persistir dentro do Studio. Sem isso os pcall do SafeStore falham com warn e
	a compra vale só pra sessão.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local Progression = require(ReplicatedStorage.Modules.Progression)
local CoinService = require(ServerScriptService.Modules.CoinService)
local DevAccess = require(ServerScriptService.Modules.DevAccess)
local SafeStore = require(ServerScriptService.Modules.SafeStore)

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
local buyHero = EnsureRemote("RemoteEvent", "BuyHero")

local HeroUnlockService = {}

-- [userId] = { [dataId] = true } — só os COMPRADOS. Os `starter` não entram
-- aqui: eles saem do catálogo, e gravar o óbvio só faria a chave crescer à toa.
local owned = {}

-- ===================== LEITURA =====================
local function BoughtSet(userId)
	return owned[userId] or {}
end

-- O que o jogador pode levar pra partida: os grátis + os comprados. `player`
-- (e não userId) porque o DevAccess decide pela pessoa, não pelo número.
function HeroUnlockService.GetPlayableIds(player)
	local userId = player and player.UserId or nil
	local fullCatalog = DevAccess.HasFullCatalog(player)
	local bought = userId and BoughtSet(userId) or {}

	local set = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if fullCatalog or HeroData.IsStarter(data) or bought[data.id] then
			set[data.id] = true
		end
	end
	return set
end

function HeroUnlockService.OwnsHero(player, dataId)
	return HeroUnlockService.GetPlayableIds(player)[dataId] == true
end

-- ===================== ESTADO PRO CLIENTE =====================
-- Manda a lista de ids comprados. A vitrine junta isso com o catálogo (que ela
-- já tem) pra saber o que desenhar como "seu" e o que desenhar com preço.
-- `bought` é o id recém-comprado, pra UI poder comemorar; nil no estado inicial.
local function Push(player, bought)
	if not player or not player.Parent then return end

	local ids = {}
	for dataId in pairs(BoughtSet(player.UserId)) do
		table.insert(ids, dataId)
	end
	table.sort(ids)

	rosterUpdate:FireClient(player, { owned = ids, bought = bought })
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

-- ===================== COMPRA =====================
-- Devolve (ok, motivo). O motivo é pro log do servidor; o cliente só vê a lista
-- nova (ou a ausência dela) e o saldo, que o CoinService empurra sozinho.
function HeroUnlockService.Buy(player, dataId)
	if not player then return false, "sem jogador" end

	dataId = tonumber(dataId)
	if not dataId then return false, "id inválido" end

	local data = HeroData.GetById(dataId)
	if not data then return false, "herói inexistente" end

	-- Grátis e já-comprado saem aqui: nos dois casos cobrar seria roubo, e o
	-- jogador não perde nada por um clique repetido numa carta que já é dele.
	if HeroData.IsStarter(data) then return false, "herói é inicial" end

	local userId = player.UserId
	if BoughtSet(userId)[dataId] then return false, "já possui" end

	local cost = HeroData.GetCost(data)
	if cost <= 0 then return false, "sem preço" end

	-- A ORDEM IMPORTA: debita primeiro, grava a posse depois. Se invertesse e a
	-- cobrança falhasse, o jogador ficaria com um herói de graça; assim, o pior
	-- caso é o inverso — e o inverso é tratado logo abaixo, devolvendo a moeda.
	local paid, saldo = CoinService.Spend(userId, cost)
	if not paid then return false, "saldo insuficiente" end

	local set = owned[userId] or {}
	set[dataId] = true

	local ids = {}
	for id in pairs(set) do table.insert(ids, id) end
	table.sort(ids)

	local stored = SafeStore.Update(heroStore, tostring(userId), function()
		return ids
	end, ("gravação de heróis de %s"):format(player.Name))

	if not stored then
		-- Pagou e não gravou. Devolver a moeda é a única saída honesta: sem isso
		-- o jogador perde 500 e não leva nada, e é o tipo de coisa que ele vai
		-- lembrar. A posse NÃO entra no cache, pra sessão e disco não divergirem.
		CoinService.Award(userId, cost)
		warn(("HeroUnlockService: compra de %s por %s não gravou — moedas devolvidas.")
			:format(data.name, player.Name))
		return false, "falha ao gravar"
	end

	owned[userId] = set
	Push(player, dataId)

	print(("HeroUnlockService: %s comprou %s por %d (saldo %s)."):format(
		player.Name, data.name, cost, tostring(saldo)))

	return true, nil
end

buyHero.OnServerEvent:Connect(function(player, dataId)
	HeroUnlockService.Buy(player, dataId)
end)

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
