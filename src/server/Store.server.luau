--[[
	Store.server.lua
	Script — ServerScriptService

	Liga a carteira de moedas. O CoinService registra sozinho os eventos de
	entrada/saída de jogador ao ser exigido — mas ninguém mais o
	exige (o MatchManager só conhece XP), então alguém precisa acordá-lo no boot.
	É só isso que este script faz.
]]

local ServerScriptService = game:GetService("ServerScriptService")

require(ServerScriptService.Modules.CoinService)
