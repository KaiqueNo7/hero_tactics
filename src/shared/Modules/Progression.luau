--[[
	Progression.lua
	ModuleScript — ReplicatedStorage/Modules/Progression

	Curva de XP e nível — as duas contas do progresso num lugar só: quanto cada
	resultado de partida paga e em que nível um total de XP cai.

	Fica em ReplicatedStorage porque é regra de jogo, não detalhe de servidor: o
	servidor guarda apenas o XP acumulado e manda o nível já calculado pro
	cliente, mas a UI pode ler a curva daqui pra explicar quanto falta pro
	próximo nível sem duplicar a fórmula.
]]

local GameConfig = require(script.Parent.GameConfig)

local Progression = {}

Progression.WIN_XP_BY_SURVIVORS = {
	[1] = 30,
	[2] = 40,
	[3] = 60,
}

Progression.LOSS_XP = 20
Progression.DRAW_XP = 20
Progression.BOT_WIN_XP = 10
Progression.BASE_XP = 100
Progression.XP_STEP = 50
Progression.MAX_LEVEL = 100
Progression.WIN_COINS = 50
Progression.LEVEL_UP_COINS = 500

function Progression.MatchCoins(result)
	return result == "win" and Progression.WIN_COINS or 0
end

function Progression.XpToAdvance(level)
	level = math.max(1, math.floor(tonumber(level) or 1))
	return Progression.BASE_XP + (level - 1) * Progression.XP_STEP
end

function Progression.FromTotalXp(totalXp)
	totalXp = math.max(0, math.floor(tonumber(totalXp) or 0))

	local level = 1
	local remaining = totalXp
	local needed = Progression.XpToAdvance(level)

	while level < Progression.MAX_LEVEL and remaining >= needed do
		remaining -= needed
		level += 1
		needed = Progression.XpToAdvance(level)
	end

	if level >= Progression.MAX_LEVEL then
		return { level = Progression.MAX_LEVEL, xpIntoLevel = 0, xpForNext = 0, totalXp = totalXp }
	end

	return { level = level, xpIntoLevel = remaining, xpForNext = needed, totalXp = totalXp }
end

function Progression.MatchReward(result, survivors, vsBot)
	if result == "win" then
		if vsBot then return Progression.BOT_WIN_XP end

		local alive = math.clamp(
			math.floor(tonumber(survivors) or 1),
			1,
			GameConfig.HEROES_PER_PLAYER
		)

		return Progression.WIN_XP_BY_SURVIVORS[alive] or Progression.LOSS_XP
	elseif result == "draw" then
		return Progression.DRAW_XP
	end

	return Progression.LOSS_XP
end

return Progression
