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

-- ===== RECOMPENSA POR PARTIDA =====
-- A vitória paga pela margem: quanto mais herói sobrou vivo, mais XP. A derrota
-- paga um consolo fixo pra quem perdeu ainda sentir que avançou.
-- A tabela é indexada por sobreviventes e cobre de 1 até HEROES_PER_PLAYER.
Progression.WIN_XP_BY_SURVIVORS = {
	[1] = 30,
	[2] = 40,
	[3] = 60,
}

Progression.LOSS_XP = 20
Progression.DRAW_XP = 20 -- empate é os dois lados zerados: paga igual à derrota

-- Vitória contra o bot paga fixo, independente da margem: o bot é treino, não
-- fonte de XP. (Derrota continua pagando LOSS_XP em qualquer modo.)
Progression.BOT_WIN_XP = 10

-- ===== CURVA DE NÍVEL =====
-- Cada nível pede um pouco mais que o anterior: nível 2 com 100 de XP, nível 3
-- com +150, nível 4 com +200... Assim as primeiras partidas sobem rápido e o
-- ritmo desacelera sozinho, sem precisar de tabela escrita à mão.
Progression.BASE_XP = 100 -- XP pra sair do nível 1
Progression.XP_STEP = 50 -- quanto cada nível seguinte cobra a mais
Progression.MAX_LEVEL = 100

-- XP necessário pra sair deste nível e ir pro seguinte
function Progression.XpToAdvance(level)
	level = math.max(1, math.floor(tonumber(level) or 1))
	return Progression.BASE_XP + (level - 1) * Progression.XP_STEP
end

-- Traduz o XP acumulado da vida inteira em { level, xpIntoLevel, xpForNext }.
-- xpForNext = 0 significa nível máximo (a barra fica cheia).
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

-- result: "win" | "loss" | "draw". survivors só importa na vitória.
-- vsBot marca partida contra o bot.
function Progression.MatchReward(result, survivors, vsBot)
	if result == "win" then
		if vsBot then return Progression.BOT_WIN_XP end

		local alive = math.clamp(
			math.floor(tonumber(survivors) or 1),
			1,
			GameConfig.HEROES_PER_PLAYER
		)
		-- se HEROES_PER_PLAYER crescer sem a tabela acompanhar, paga o mínimo em
		-- vez de dar nil e derrubar o fim de partida
		return Progression.WIN_XP_BY_SURVIVORS[alive] or Progression.LOSS_XP
	elseif result == "draw" then
		return Progression.DRAW_XP
	end

	return Progression.LOSS_XP
end

return Progression
