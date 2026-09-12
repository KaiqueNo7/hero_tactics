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

local SafeStore = require(ServerScriptService.Modules.Data.SafeStore)

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
-- LER E LIMPAR NUMA OPERAÇÃO SÓ. Era Get e depois Set, e entre os dois havia uma
-- chamada de DataStore inteira cedendo: dois `claimRewards` na mesma janela liam
-- a fila antes de qualquer um esvaziar, e a comemoração saía duas vezes. Nada era
-- creditado duas vezes (moeda e XP entram na hora em que são ganhos, não aqui),
-- mas a festa repetida parece bug de economia — que é pior do que ser um.
--
-- O `transform` do UpdateAsync roda com a fila travada, então a captura aqui
-- dentro é o que garante que só UMA chamada leva o prêmio.
function RewardQueueService.Take(player)
	if not player then return nil end

	local taken = nil

	local ok = SafeStore.Update(store, tostring(player.UserId), function(old)
		-- zerado a cada passagem: o SafeStore repete o transform na retentativa,
		-- e o que vale é sempre a última leitura, não a da tentativa que falhou
		taken = nil
		if IsEmpty(old) then return nil end

		taken = {
			heroes = old.heroes or {},
			xp = old.xp or 0,
			coins = old.coins or 0,
		}
		return Empty()
	end, ("retirada da fila de recompensa de %s"):format(player.Name))

	-- A escrita falhou depois de o transform ter rodado: devolver o prêmio agora
	-- mostraria uma comemoração que continua na fila, e ela voltaria no próximo
	-- login. Melhor mostrar só quando a limpeza pegou.
	if not ok then return nil end

	return taken
end

return RewardQueueService
