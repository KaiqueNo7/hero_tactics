--[[
	HeroStatsService.lua
	ModuleScript — ServerScriptService/Modules/HeroStatsService

	O histórico de cada HERÓI, somado entre todos os jogadores e todos os
	servidores. Existe pra uma coisa só: trocar "acho que o Bramm está fraco"
	por um número.

	NÃO É PROGRESSO DE JOGADOR. O ProgressionService guarda o XP de quem joga e o
	HeroUnlockService guarda o que cada um possui — os dois são por userId. Este
	é por dataId de herói e não pertence a ninguém: é telemetria de balanceamento.

	O QUE DÁ PRA RESPONDER COM ISTO
	  taxa de vitória do herói   = wins / matches
	  ele carrega ou acompanha?  = damageDealt / matches
	  ele segura a linha?        = damageTaken / matches
	  ele paga o suporte?        = healed / matches
	  ele sobrevive?             = survived / matches
	Sem `healed`, todo suporte pareceria inútil ao lado de um atacante — a Elaria
	converte turno em vida, não em dano, e a coluna de dano dela é justamente a
	que não conta a história.

	GRAVAÇÃO EM LOTE, e isso não é otimização prematura: é o que torna o recurso
	possível. O DataStore aceita poucas escritas por minuto POR CHAVE, e uma
	partida movimenta até seis heróis. Gravando na hora, duas partidas seguidas
	já estourariam o limite da chave de um herói popular e o dado sairia furado
	sem ninguém perceber. Aqui os números se acumulam em memória e descem de
	FLUSH_INTERVAL em FLUSH_INTERVAL, uma chave por herói.

	O merge é feito DENTRO do UpdateAsync, somando em cima do que estiver
	gravado — nunca "li, somei, escrevi". É o que mantém a conta certa com vários
	servidores gravando o mesmo herói ao mesmo tempo.

	Mesma dependência do resto: exige "Enable Studio Access to API Services" pra
	persistir dentro do Studio. Sem isso o SafeStore avisa e a telemetria da
	sessão se perde — nenhuma partida quebra por causa disso.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local HeroData = require(ReplicatedStorage.Modules.HeroData)
local SafeStore = require(ServerScriptService.Modules.SafeStore)

local STORE_NAME = "HeroTactics_HeroStats_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local FLUSH_INTERVAL = 90

local HeroStatsService = {}

local FIELDS = {
	"matches", "wins", "losses", "draws",
	"damageDealt", "damageTaken", "healed",
	"kills", "deaths", "survived",
	"pvpMatches", "pvpWins",
}

local pending = {} -- [dataId] = { campo = delta }
local dirty = false

local function BlankRow()
	local row = {}
	for _, field in ipairs(FIELDS) do row[field] = 0 end
	return row
end

function HeroStatsService.Add(dataId, delta)
	dataId = tonumber(dataId)
	if not dataId or type(delta) ~= "table" then return end

	local row = pending[dataId] or BlankRow()

	for _, field in ipairs(FIELDS) do
		local value = tonumber(delta[field])
		if value then row[field] += value end
	end

	pending[dataId] = row
	dirty = true
end

function HeroStatsService.AddMatch(entries)
	for dataId, delta in pairs(entries) do
		HeroStatsService.Add(dataId, delta)
	end
end

-- ===================== GRAVAÇÃO =====================
local function FlushHero(dataId, row)
	local ok = SafeStore.Update(store, "hero_" .. dataId, function(old)
		local merged = (type(old) == "table") and old or BlankRow()
		for _, field in ipairs(FIELDS) do
			merged[field] = (tonumber(merged[field]) or 0) + (row[field] or 0)
		end
		return merged
	end, ("gravação do histórico do herói %d"):format(dataId))

	return ok
end

function HeroStatsService.Flush()
	if not dirty then return 0 end

	local batch = pending
	pending = {}
	dirty = false

	local written = 0
	for dataId, row in pairs(batch) do
		if FlushHero(dataId, row) then
			written += 1
		else
			HeroStatsService.Add(dataId, row)
		end
	end

	return written
end

function HeroStatsService.GetAll()
	local result = {}

	for _, data in ipairs(HeroData.CATALOG) do
		local ok, value = SafeStore.Get(store, "hero_" .. data.id,
			("leitura do histórico do herói %d"):format(data.id))

		local row = (ok and type(value) == "table") and value or BlankRow()
		row.name = data.name

		local matches = math.max(tonumber(row.matches) or 0, 1)
		row.winRate = (tonumber(row.wins) or 0) / matches
		row.damagePerMatch = (tonumber(row.damageDealt) or 0) / matches
		row.tankedPerMatch = (tonumber(row.damageTaken) or 0) / matches
		row.healedPerMatch = (tonumber(row.healed) or 0) / matches
		row.survivalRate = (tonumber(row.survived) or 0) / matches
		row.pvpWinRate = (tonumber(row.pvpWins) or 0) / math.max(tonumber(row.pvpMatches) or 0, 1)

		result[data.id] = row
	end

	return result
end

function HeroStatsService.Report()
	local rows = {}
	for dataId, row in pairs(HeroStatsService.GetAll()) do
		table.insert(rows, { id = dataId, row = row })
	end
	table.sort(rows, function(a, b) return a.row.winRate > b.row.winRate end)

	local lines = { ("%-10s %7s %7s %6s %7s %8s %8s %8s %8s"):format(
		"HERÓI", "JOGOS", "VITÓR.", "PVP-J", "PVP-V.", "DANO/J", "TANK/J", "CURA/J", "SOBREV.") }

	for _, entry in ipairs(rows) do
		local row = entry.row
		table.insert(lines, ("%-10s %7d %6.1f%% %6d %6.1f%% %8.1f %8.1f %8.1f %7.1f%%"):format(
			row.name, row.matches or 0, row.winRate * 100,
			row.pvpMatches or 0, row.pvpWinRate * 100,
			row.damagePerMatch, row.tankedPerMatch, row.healedPerMatch,
			row.survivalRate * 100))
	end

	return table.concat(lines, "\n")
end

if RunService:IsRunning() then
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			HeroStatsService.Flush()
		end
	end)

	game:BindToClose(function()
		HeroStatsService.Flush()
	end)
end

return HeroStatsService
