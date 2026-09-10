local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HeroData = require(ReplicatedStorage.Modules.HeroData)

local Objectives = {}

local DONE, FAILED, PENDING = "done", "failed", "pending"

Objectives.DONE = DONE
Objectives.FAILED = FAILED
Objectives.PENDING = PENDING

local function HeroOf(run, check)
	if check.side == "enemy" then
		return run.enemyByData[check.hero] or run.playerByData[check.hero]
	end
	return run.playerByData[check.hero] or run.enemyByData[check.hero]
end

local function TurnNumber(match)
	return match.turn and match.turn.number or 0
end

local function TallyOf(hero, key)
	return (hero.stats and hero.stats.special and hero.stats.special[key]) or 0
end

local CHECKS = {}

CHECKS.defeatAll = function(match, run)
	for _, hero in pairs(match.heroes) do
		if hero.isAlive and not hero.summoner and hero.ownerId == run.enemyId then
			return PENDING
		end
	end
	return DONE
end

CHECKS.defeatHero = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end
	return hero.isAlive and PENDING or DONE
end

CHECKS.heroDown = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end
	return hero.isAlive and PENDING or DONE
end

CHECKS.reachHex = function(_, run, check)
	local hero = HeroOf(run, check)
	if not (hero and hero.isAlive) then return PENDING end
	return hero.position == check.hex and DONE or PENDING
end

CHECKS.surviveTurns = function(match, _, check)
	return TurnNumber(match) >= check.turns and DONE or PENDING
end

CHECKS.withinTurns = function(match, _, check)
	return TurnNumber(match) <= check.turns and DONE or FAILED
end

CHECKS.hpFull = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end
	return hero.currentHp >= hero.maxHp and DONE or PENDING
end

CHECKS.hpAtLeast = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end
	return hero.currentHp >= check.hp and DONE or PENDING
end

CHECKS.noDamageTaken = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end

	local before = (run.baseline[hero.uid] or {}).taken or 0
	return hero.stats.taken > before and FAILED or DONE
end

CHECKS.tallyAtLeast = function(_, run, check)
	local hero = HeroOf(run, check)
	if not hero then return PENDING end

	local before = (run.baseline[hero.uid] or {})[check.key] or 0
	return (TallyOf(hero, check.key) - before) >= (check.count or 1) and DONE or PENDING
end

-- ===== HERÓIS DE PÉ =====
-- Conta a COMPOSIÇÃO do jogador, não peças no tabuleiro: invocado é ferramenta
-- de outro herói, não uma vida a mais. Caveira do Morn e mini-golem ficam de
-- fora pelo `summoner`.
--
-- O GOLEM SÓ MORRE NO ÚLTIMO PEDAÇO. Ele estilhaça, o corpo grande fica com
-- `isAlive = false` e o túmulo dele fica PENDENTE enquanto sobrar pedaço de pé
-- (ver DeferGrave/ResolvePendingGraves no MatchManager). Enquanto pende, ele não
-- foi enterrado, e contar como baixa aqui puniria um jogador cujo Golem ainda
-- está inteiro em campo, só que repartido.
CHECKS.heroesAlive = function(match, run, check)
	local alive = 0
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == run.playerId and not hero.summoner
			and (hero.isAlive or hero.gravePending) then
			alive += 1
		end
	end
	return alive >= (check.count or 1) and DONE or FAILED
end

-- PISOU, USOU. Vale para qualquer caminho que gaste a Casa de Promoção, e é de
-- propósito que a Luz que Volta do Morn (que ressuscita sozinha quando um aliado
-- chega na casa) conte igual: quem decide é o passo, não a escolha do túmulo.
-- Por isso a leitura é o `promotionUsed` do lado, que é ligado nos dois caminhos,
-- e não uma marca nova só do caminho manual.
CHECKS.noPromotion = function(match, run)
	for _, side in ipairs(match.sides) do
		if side.id == run.playerId then
			return side.promotionUsed and FAILED or DONE
		end
	end
	return DONE
end

-- Junta condições sem inventar linguagem de expressão: FAILED de qualquer uma
-- derruba tudo, PENDING de qualquer uma segura, e só passa quando todas fecham.
-- É o que deixa "vencer antes do turno 10 COM o time inteiro E sem promoção" ser
-- uma estrela só em vez de três.
CHECKS.allOf = function(match, run, check)
	local result = DONE
	for _, inner in ipairs(check.checks or {}) do
		local state = Objectives.Eval(match, run, inner)
		if state == FAILED then return FAILED end
		if state == PENDING then result = PENDING end
	end
	return result
end

function Objectives.Kinds()
	return CHECKS
end

function Objectives.Has(kind)
	return CHECKS[kind] ~= nil
end

function Objectives.Eval(match, run, check)
	local fn = check and CHECKS[check.kind]
	if not fn then return PENDING end

	local ok, result = pcall(fn, match, run, check)
	if not ok then
		warn(("Objectives: %s falhou: %s"):format(tostring(check.kind), tostring(result)))
		return PENDING
	end
	return result
end

function Objectives.TrackedKeys(spec)
	local keys = { taken = true }
	local function scan(check)
		if type(check) ~= "table" then return end

		if check.kind == "tallyAtLeast" and check.key then
			keys[check.key] = true
		end

		-- desce no allOf: sem isto, um tallyAtLeast dentro de um grupo ficaria
		-- sem linha de base e passaria a contar a partida inteira do herói
		for _, inner in ipairs(check.checks or {}) do scan(inner) end
	end

	scan(spec.win)
	scan(spec.lose)
	for _, star in ipairs(spec.stars or {}) do scan(star.check) end
	return keys
end

local DESCRIPTIONS = {
	defeatAll = function() return "Derrote todos os inimigos" end,
	defeatHero = function(check)
		local data = HeroData.GetById(check.hero)
		return ("Derrote %s"):format(data and data.name or "o alvo")
	end,
	reachHex = function(check) return ("Chegue na casa %s"):format(check.hex) end,
	surviveTurns = function(check) return ("Sobreviva %d turnos"):format(check.turns) end,
	withinTurns = function(check) return ("Vença em até %d turnos"):format(check.turns) end,
	heroesAlive = function(check)
		return ("Termine com %d herói(s) de pé"):format(check.count or 1)
	end,
	noPromotion = function() return "Sem usar a Casa de Promoção" end,
}

function Objectives.Describe(check)
	local fn = check and DESCRIPTIONS[check.kind]
	return fn and fn(check) or "Cumpra o objetivo"
end

return Objectives
