--[[
	RewardQueueService.lua
	ModuleScript — ServerScriptService/Modules/RewardQueueService

	O que o jogador conquistou e ainda NÃO viu comemorado.

	POR QUE ISSO EXISTE
	Herói novo, XP e moedas são creditados no meio da partida, quando o jogador
	está olhando o tabuleiro — e numa sequência de campanha ele encadeia várias
	partidas sem passar pelo lobby. Sem uma fila, a comemoração ou aparecia por
	cima da batalha ou simplesmente não aparecia. Pior: fechando o jogo, o
	progresso era creditado e nunca mostrado.

	Aqui a conquista fica GUARDADA até ser mostrada. Sobrevive a fechar o jogo,
	porque mora em DataStore como o resto do progresso — quem entra direto no
	lobby no dia seguinte vê o que ganhou ontem.

	Mesma dependência dos outros serviços: sem "Enable Studio Access to API
	Services" os pcall falham com warn e a fila vale só pra sessão.
]]

local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

local SafeStore = require(ServerScriptService.Modules.SafeStore)

local STORE_NAME = "HeroTactics_Rewards_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local RewardQueueService = {}

local function Empty()
	return { heroes = {}, xp = 0, coins = 0 }
end

local function IsEmpty(data)
	return data == nil
		or (#(data.heroes or {}) == 0 and (data.xp or 0) <= 0 and (data.coins or 0) <= 0)
end

-- `patch` = { hero = dataId } e/ou { xp = n } e/ou { coins = n }. Soma no que já
-- estava guardado; herói repetido não entra duas vezes (a revanche de um
-- confronto já vencido não paga o mesmo card de novo).
function RewardQueueService.Push(userId, patch)
	if not (userId and patch) then return end

	SafeStore.Update(store, tostring(userId), function(old)
		local heroes = (old and old.heroes) or {}

		if patch.hero and not table.find(heroes, patch.hero) then
			table.insert(heroes, patch.hero)
		end

		return {
			heroes = heroes,
			xp = ((old and old.xp) or 0) + (patch.xp or 0),
			coins = ((old and old.coins) or 0) + (patch.coins or 0),
		}
	end, ("fila de recompensa de %s"):format(tostring(userId)))
end

-- Lê e ESVAZIA. O cliente pede isto ao chegar no lobby; devolve nil quando não
-- tem nada guardado, e aí nenhuma tela sobe.
--
-- Esvaziar ANTES de devolver é de propósito: se o jogador cair entre a leitura e
-- a limpeza, o pior caso é ver a comemoração duas vezes — melhor que perder uma
-- conquista que ele nunca chegou a ver.
function RewardQueueService.Take(player)
	if not player then return nil end

	local key = tostring(player.UserId)
	local ok, data = SafeStore.Get(store, key, "leitura da fila de recompensa")
	if not ok or IsEmpty(data) then return nil end

	SafeStore.Set(store, key, Empty(), "limpeza da fila de recompensa")

	return {
		heroes = data.heroes or {},
		xp = data.xp or 0,
		coins = data.coins or 0,
	}
end

return RewardQueueService
