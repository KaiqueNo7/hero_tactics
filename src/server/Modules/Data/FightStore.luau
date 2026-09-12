--[[
	FightStore.lua
	ModuleScript — ServerScriptService/Modules/FightStore

	Quantas estrelas o jogador já tirou em cada confronto da campanha.

	SÓ O MELHOR RESULTADO FICA. Repetir um confronto que já valeu três estrelas e
	sair com uma não apaga nada: o `max` no `Record` é o que garante isso, e é
	também o que faz a recompensa ser paga UMA vez por estrela. Quem repete a
	mesma batalha recebe zero, porque `gained` é a diferença pro melhor anterior,
	nunca o total.

	POR QUE NÃO MORA NO ChallengeStore. Os dois guardam estrelas, mas a chave é
	diferente: desafio de herói é (herói, índice) e confronto é só o herói do
	prêmio. Enfiar confronto num índice reservado do outro economizava um arquivo
	e cobrava o preço na primeira vez que alguém fosse ler a linha e não soubesse
	qual das duas coisas estava vendo.

	Mesma dependência dos outros serviços: sem "Enable Studio Access to API
	Services" os pcall falham com warn e as estrelas valem só pra sessão.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Campaign = require(ReplicatedStorage.Modules.Campaign)
local SafeStore = require(ServerScriptService.Modules.Data.SafeStore)

local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local STORE_NAME = "HeroTactics_FightStars_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local FightStore = {}

local records = {}

-- Peneira o que veio do disco: chave que não é confronto sai, e estrela fora da
-- faixa é grampeada. Save antigo, save corrompido e save de uma versão com outra
-- regra de estrelas entram todos por aqui sem derrubar o lobby.
local function Sanitize(raw)
	local clean = {}
	if type(raw) ~= "table" then return clean end

	for key, value in pairs(raw) do
		local heroId = tonumber(key)
		if heroId and Campaign.GetFight(heroId) then
			local stars = math.floor(tonumber(value) or 0)
			clean[tostring(heroId)] = math.clamp(stars, 0, Campaign.MAX_STARS)
		end
	end

	return clean
end

local function RecordOf(userId)
	return records[userId] or {}
end

function FightStore.Preload(player)
	if not player then return end

	local ok, raw = SafeStore.Get(store, tostring(player.UserId),
		("leitura das estrelas de %s"):format(player.Name))

	records[player.UserId] = ok and Sanitize(raw) or {}
	FightStore.Push(player)
end

function FightStore.StarsOf(player, heroId)
	if not player then return 0 end
	return RecordOf(player.UserId)[tostring(heroId)] or 0
end

-- O mapa inteiro pro cliente desenhar os quadrados da campanha de uma vez.
function FightStore.Payload(player)
	if not player then return {} end

	local out = {}
	for key, stars in pairs(RecordOf(player.UserId)) do
		out[key] = stars
	end
	return out
end

-- Mesmo canal e mesmo formato do ChallengeStore.Push: o lobby já escuta o
-- GameAction e redesenha a campanha quando chega um payload desses.
function FightStore.Push(player)
	if not (player and player.Parent) then return end
	GameAction:FireClient(player, "fightStars", FightStore.Payload(player))
end

function FightStore.TotalStars(player)
	local total = 0
	for _, stars in pairs(RecordOf(player and player.UserId)) do
		total += stars
	end
	return total
end

-- Devolve quantas estrelas são NOVAS. É esse número que a recompensa usa, e é o
-- que impede farm: a segunda vitória de três estrelas devolve zero.
function FightStore.Record(player, heroId, stars)
	if not player then return 0 end
	if not Campaign.GetFight(heroId) then return 0 end

	stars = math.clamp(math.floor(tonumber(stars) or 0), 0, Campaign.MAX_STARS)

	local userId = player.UserId
	local key = tostring(heroId)
	if stars <= (RecordOf(userId)[key] or 0) then return 0 end

	local gained = 0

	local ok, merged = SafeStore.Update(store, tostring(userId), function(old)
		local record = Sanitize(old)
		local previous = record[key] or 0

		gained = math.max(0, stars - previous)
		record[key] = math.max(previous, stars)
		return record
	end, ("gravação das estrelas de %s"):format(player.Name))

	-- O disco falhou, mas a partida aconteceu: vale na sessão pra que a tela de
	-- vitória não minta, e volta ao que estava no próximo login.
	if ok and type(merged) == "table" then
		records[userId] = Sanitize(merged)
	else
		local record = RecordOf(userId)
		record[key] = math.max(record[key] or 0, stars)
		records[userId] = record
	end

	FightStore.Push(player)
	return gained
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(FightStore.Preload, player)
end)

Players.PlayerRemoving:Connect(function(player)
	records[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(FightStore.Preload, player)
end

return FightStore
