local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local Arenas = require(ReplicatedStorage.Modules.Arenas)
local Skills = require(ServerScriptService.Modules.Skills)
local BotBrain = require(ServerScriptService.Modules.BotBrain)

local KOR_ID = 10

local passed, failures = 0, {}

local function check(name, ok, detail)
	if ok then
		passed += 1
	else
		table.insert(failures, detail and (name .. " :: " .. tostring(detail)) or name)
	end
end

local function idOf(hex)
	return type(hex) == "table" and hex.id or hex
end

if #HexGrid.GetAllHexes() == 0 then
	HexGrid.Generate()
end

local hexes = HexGrid.GetAllHexes()

local function FindStraightLine()
	for _, hex in ipairs(hexes) do
		local a = idOf(hex)
		for _, neighbor in ipairs(HexGrid.GetNeighbors(a)) do
			local b = idOf(neighbor)
			local beyond = HexGrid.GetLineBeyond(a, b, 1)
			if beyond and beyond[1] then
				return a, b, beyond[1]
			end
		end
	end
	return nil, nil, nil
end

local lineA, lineB, lineC = FindStraightLine()

local nextUid = 0

local function FakeHero(dataId, ownerId, position)
	local data = HeroData.GetById(dataId)
	nextUid += 1
	return {
		uid = "h" .. nextUid,
		dataId = dataId,
		name = data.name,
		ownerId = ownerId,
		position = position,
		attack = data.attack,
		baseAttack = data.attack,
		maxHp = data.hp,
		currentHp = data.hp,
		isAlive = true,
		ability = data.ability,
		abilities = data.abilities,
		statusEffects = {},
		moveRange = HeroData.GetMoveRange(data),
		attackRange = HeroData.GetAttackRange(data),
		stats = { dealt = 0, taken = 0, healed = 0, kills = 0 },
	}
end

local function FakeMatch(heroes)
	local match = { heroes = {}, occupied = {}, flames = {}, turn = { number = 99 } }
	for _, hero in ipairs(heroes) do
		match.heroes[hero.uid] = hero
		match.occupied[hero.position] = hero
	end
	return match
end

local missingApi = {}

local function FakeApi()
	local log = { damage = {}, heals = {}, flames = {}, status = {}, summons = {}, board = {}, missing = {} }
	local api = {
		ApplyDamage = function(hero, amount, attacker)
			table.insert(log.damage, { hero = hero, amount = amount, attacker = attacker })
			hero.currentHp -= amount
			if hero.currentHp <= 0 then hero.isAlive = false end
		end,
		Heal = function(hero, amount)
			table.insert(log.heals, { hero = hero, amount = amount })
		end,
		IncreaseAttack = function(hero, amount) hero.attack += amount end,
		Effect = function() end,
		PlaySkillSound = function() end,
		FlashAttackRange = function() end,
		IceStorm = function() end,
		FireCircle = function() end,
		PoisonBomb = function() end,
		GetLineBeyond = HexGrid.GetLineBeyond,
		Distance = HexGrid.Distance,
		GetHeroAt = function() return nil end,
		GetEnemiesInRange = function() return {} end,
		GetAlliesInRange = function() return {} end,
		IsFree = function() return true end,
		ForceMove = function() return true end,
		CountAllies = function() return 0, 0 end,
		CountDeaths = function() return 0 end,
		LightFlame = function(hexId) table.insert(log.flames, hexId) end,
		FindStatusEffect = MatchQuery.FindStatusEffect,
		ResolveTogether = function(fn) return fn() end,
		RemoveStatusEffect = function(hero, effectType)
			for index = #hero.statusEffects, 1, -1 do
				local effect = hero.statusEffects[index]
				if effect.type == effectType then
					table.remove(hero.statusEffects, index)
					if effect.attackBonus then hero.attack -= effect.attackBonus end
				end
			end
		end,
		-- SUBSTITUI o efeito do mesmo tipo, como o de verdade (ver
		-- MatchManager.ApplyStatusEffect). Enquanto so empilhava, a fake dizia
		-- que renovar um efeito criava um segundo — e a renovacao acumulativa do
		-- Sangue Fervendo, que passa a MESMA tabela de volta, ficava impossivel
		-- de testar aqui.
		ApplyStatusEffect = function(hero, effect)
			for index = #hero.statusEffects, 1, -1 do
				if hero.statusEffects[index].type == effect.type then
					table.remove(hero.statusEffects, index)
				end
			end
			table.insert(hero.statusEffects, effect)
			table.insert(log.status, effect)
		end,
		IsMyTurn = function() return true end,
		GetAllyByData = function(_, dataId) return log.board[dataId] end,
		Summon = function(origin, dataId)
			local minion = FakeHero(dataId, origin.ownerId, origin.position)
			log.board[dataId] = minion
			table.insert(log.summons, minion)
			return minion
		end,
	}
	-- QUALQUER funcao da API real que nao tenha dublê aqui vira um no-op em vez
	-- de estourar "attempt to call a nil value" no meio de um Play. O nome fica
	-- gravado em log.missing, e a checagem no fim do arquivo denuncia a lista —
	-- assim o harness acompanha a API sozinho e a falha vira aviso, nao crash.
	setmetatable(api, {
		__index = function(_, key)
			return function()
				log.missing[key] = (log.missing[key] or 0) + 1
				missingApi[key] = true
			end
		end,
	})

	return api, log
end

check("tabuleiro gerado", #hexes > 0, #hexes)
check("linha reta encontrada no tabuleiro", lineA ~= nil)

for _, data in ipairs(HeroData.CATALOG) do
	local range = HeroData.GetAttackRange(data)
	local expected

	if data.attackRange then
		expected = data.attackRange
	elseif data.ability == GameConfig.ABILITIES.RANGED then
		expected = GameConfig.RANGED_ATTACK_RANGE
	else
		expected = GameConfig.BASE_ATTACK_RANGE
	end

	check("alcance de ataque: " .. data.name, range == expected, range)
	check("IsRangedAttack coerente: " .. data.name,
		GameConfig.IsRangedAttack(range) == (range > GameConfig.BASE_ATTACK_RANGE))

	if data.id ~= KOR_ID then
		check("so o Kor alcanca 3: " .. data.name, range < 3, range)
	end

	local move = HeroData.GetMoveRange(data)
	local expectedMove = data.ability == GameConfig.ABILITIES.SPRINT
		and GameConfig.SPRINT_MOVE_RANGE
		or GameConfig.BASE_MOVE_RANGE
	check("alcance de movimento: " .. data.name, move == expectedMove, move)
end

check("Kor alcanca 3", HeroData.GetAttackRange(HeroData.GetById(KOR_ID)) == 3)

local seenIds = {}
for _, data in ipairs(HeroData.CATALOG) do
	check("id unico: " .. data.name, seenIds[data.id] == nil, data.id)
	seenIds[data.id] = true

	for _, key in ipairs(data.abilities) do
		check("skill existe no modulo: " .. key, Skills[key] ~= nil)
		check("skill tem texto de UI: " .. key, HeroData.SKILL_INFO[key] ~= nil)
	end

	if data.ability then
		check("passiva conhecida: " .. data.name, HeroData.ABILITY_INFO[data.ability] ~= nil, data.ability)
	end
end

if lineA then
	check("distancia de si mesmo e zero", HexGrid.Distance(lineA, lineA) == 0)
	check("distancia e simetrica", HexGrid.Distance(lineA, lineC) == HexGrid.Distance(lineC, lineA))
	check("vizinho esta a uma casa", HexGrid.Distance(lineA, lineB) == 1)
	check("linha reta avanca duas casas", HexGrid.Distance(lineA, lineC) == 2)
	check("no maximo seis vizinhos", #HexGrid.GetNeighbors(lineA) <= 6)

	local alwaysFree = function() return true end
	local path = HexGrid.FindPath(lineA, lineC, 2, alwaysFree)
	check("acha caminho dentro do alcance", path ~= nil and #path == 2, path and #path)
	check("recusa caminho fora do alcance", HexGrid.FindPath(lineA, lineC, 1, alwaysFree) == nil)

	local blocked = function(hexId) return hexId ~= lineB end
	local detour = HexGrid.FindPath(lineA, lineC, 2, blocked)
	check("nao atravessa casa bloqueada", detour == nil or detour[1] ~= lineB)

	local mids = {}
	for _, neighbor in ipairs(HexGrid.GetNeighbors(lineA)) do
		if HexGrid.Distance(neighbor.id, lineC) == 1 then table.insert(mids, neighbor.id) end
	end
	check("existe mais de um caminho de mesmo tamanho", #mids >= 2, #mids)

	for index = 1, math.min(#mids, 2) do
		local want = mids[index]
		local biased = HexGrid.FindPath(lineA, lineC, 2, alwaysFree,
			function(hexId) return hexId == want and 1 or -1 end)
		check("caminho desempata pela casa preferida " .. index,
			biased ~= nil and biased[1] == want, biased and biased[1])
	end

	if #mids >= 2 then
		local burning = mids[1]
		local away = HexGrid.FindPath(lineA, lineC, 2, alwaysFree,
			function(hexId) return hexId == burning and -4 or 0 end)
		check("caminho foge da casa penalizada",
			away ~= nil and away[1] ~= burning, away and away[1])
	end

	local heroA = FakeHero(1, "A", lineA)
	local heroB = FakeHero(1, "B", lineB)
	local match = FakeMatch({ heroA, heroB })

	check("casa ocupada nao esta livre", MatchQuery.IsFree(match, lineA) == false)
	check("casa vazia esta livre", MatchQuery.IsFree(match, lineC) == true)
	check("inimigo colado e alvo", #MatchQuery.GetEnemiesInRange(match, heroA, 1) == 1)
	check("inimigo nao conta como aliado", #MatchQuery.GetAlliesInRange(match, heroA, 1) == 0)

	heroB.isAlive = false
	check("morto nao e alvo", #MatchQuery.GetEnemiesInRange(match, heroA, 1) == 0)

	local sprinter = FakeHero(3, "A", lineA)
	local sprintMatch = FakeMatch({ sprinter })
	check("Sprint anda mais", MatchQuery.MoveRangeOf(sprintMatch, sprinter) == GameConfig.SPRINT_MOVE_RANGE)

	local windAlly = FakeHero(18, "A", lineB)
	local windMatch = FakeMatch({ sprinter, windAlly })
	check("Vento a Favor soma na hora", MatchQuery.MoveRangeOf(windMatch, sprinter)
		== GameConfig.SPRINT_MOVE_RANGE + GameConfig.WIND_BOOST_MOVE_BONUS)
	windAlly.position = lineC
	windMatch.occupied[lineB] = nil
	windMatch.occupied[lineC] = windAlly
	check("Vento a Favor some ao afastar", MatchQuery.MoveRangeOf(windMatch, sprinter) == GameConfig.SPRINT_MOVE_RANGE)

	table.insert(sprinter.statusEffects, { type = "freeze", duration = 2 })
	check("gelo limita o Sprint", MatchQuery.MoveRangeOf(sprintMatch, sprinter) == GameConfig.FREEZE_MOVE_RANGE)

	local promoHex = next(MatchQuery.PROMOTION_HEXES)
	if promoHex then
		local empty = FakeMatch({})
		empty.turn = { number = 1 }
		check("casa de promocao fechada no inicio", MatchQuery.IsFree(empty, promoHex) == false)
		empty.turn = { number = GameConfig.PROMOTION_UNLOCK_TURN }
		check("casa de promocao abre no turno certo", MatchQuery.IsFree(empty, promoHex) == true)
	end

	local dante = FakeHero(5, "A", lineA)
	local tauntTarget = FakeHero(6, "B", lineB)
	local plainTarget = FakeHero(1, "B", lineB)

	local api, log = FakeApi()
	local ctx = { hero = dante, target = tauntTarget, api = api, damageApplied = false }
	Skills.brokenDefense.apply(ctx)
	check("brokenDefense soma dano contra Taunt",
		log.damage[1] ~= nil and log.damage[1].amount == dante.attack + 1,
		log.damage[1] and log.damage[1].amount)
	check("brokenDefense substitui o dano padrao", ctx.damageApplied == true)

	api, log = FakeApi()
	ctx = { hero = dante, target = plainTarget, api = api, damageApplied = false }
	Skills.brokenDefense.apply(ctx)
	check("brokenDefense normal fora do Taunt",
		log.damage[1] ~= nil and log.damage[1].amount == dante.attack)

	local kor = FakeHero(KOR_ID, "A", lineA)
	local victim = FakeHero(1, "B", lineB)

	api, log = FakeApi()
	ctx = { hero = kor, target = victim, api = api, damageApplied = false }
	Skills.iceEffect.apply(ctx)
	check("primeiro golpe do Kor nao dobra", #log.damage == 0)
	check("primeiro golpe do Kor congela", MatchQuery.FindStatusEffect(victim, "freeze") ~= nil)

	api, log = FakeApi()
	ctx = { hero = kor, target = victim, api = api, damageApplied = false }
	Skills.iceEffect.apply(ctx)
	check("golpe em alvo congelado dobra",
		log.damage[1] ~= nil
			and log.damage[1].amount == kor.attack * GameConfig.FREEZE_DAMAGE_MULTIPLIER,
		log.damage[1] and log.damage[1].amount)

	local karo = FakeHero(12, "A", lineA)
	api, log = FakeApi()
	ctx = {
		hero = karo,
		movedHero = karo,
		api = api,
		origin = lineA,
		path = { lineB, lineC },
		consumedOwnTiles = {},
	}
	Skills.flamePath.apply(ctx)
	check("fogo acende na casa de origem", table.find(log.flames, lineA) ~= nil)
	check("fogo acende na casa atravessada", table.find(log.flames, lineB) ~= nil)
	check("fogo nao acende na casa de destino", table.find(log.flames, lineC) == nil)

	local blade = FakeHero(4, "A", lineA)
	local front = FakeHero(1, "B", lineB)
	local behind = FakeHero(1, "B", lineC)

	api, log = FakeApi()
	local lineMatch = FakeMatch({ blade, front, behind })
	api.GetHeroAt = function(hexId) return MatchQuery.GetHeroAt(lineMatch, hexId) end
	ctx = { hero = blade, target = front, api = api, damageApplied = false }
	Skills.beyondFront.apply(ctx)
	check("corte atinge quem esta atras",
		log.damage[1] ~= nil and log.damage[1].hero == behind)
	check("corte nao substitui o dano do alvo", ctx.damageApplied == false)

	local ally = FakeHero(1, "A", lineC)
	api, log = FakeApi()
	local allyMatch = FakeMatch({ blade, front, ally })
	api.GetHeroAt = function(hexId) return MatchQuery.GetHeroAt(allyMatch, hexId) end
	ctx = { hero = blade, target = front, api = api, damageApplied = false }
	Skills.beyondFront.apply(ctx)
	check("corte para no aliado", #log.damage == 0)

	local doctor = FakeHero(20, "A", lineA)
	local tough = FakeHero(6, "B", lineB)
	local frail = FakeHero(1, "B", lineC)
	frail.currentHp = GameConfig.ESTOPIM_DAMAGE

	api, log = FakeApi()
	api.GetEnemiesInRange = function() return { tough, frail } end
	ctx = { hero = doctor, api = api, damageApplied = false }
	Skills.estopim.apply(ctx)
	check("estopim atinge todo vizinho", #log.damage == 2, #log.damage)
	check("estopim credita o dano a quem explodiu",
		log.damage[1].attacker == doctor and log.damage[2].attacker == doctor)
	check("estopim envenena quem sobrevive",
		MatchQuery.FindStatusEffect(tough, "poison") ~= nil)
	check("estopim nao envenena quem ja morreu",
		MatchQuery.FindStatusEffect(frail, "poison") == nil)

	local zeff = FakeHero(18, "A", lineA)
	api, log = FakeApi()
	api.IsFree = function() return false end
	ctx = { hero = zeff, target = plainTarget, api = api, damageApplied = false }
	Skills.gustPush.apply(ctx)
	check("empurrao bloqueado credita o Zeff",
		log.damage[1] ~= nil and log.damage[1].attacker == zeff
			and log.damage[1].amount == zeff.attack + GameConfig.ZEFF_PUSH_BLOCKED_BONUS,
		log.damage[1] and log.damage[1].amount)

	local wren = FakeHero(19, "A", lineA)
	local faraway = FakeHero(1, "B", lineC)
	api, log = FakeApi()
	ctx = { hero = wren, target = faraway, api = api, damageApplied = false }
	Skills.longShot.apply(ctx)
	check("tiro longo credita a Wren pela distancia",
		log.damage[1] ~= nil and log.damage[1].attacker == wren
			and log.damage[1].amount == HexGrid.Distance(lineA, lineC),
		log.damage[1] and log.damage[1].amount)

	local morn = FakeHero(20, "A", lineA)
	local skullCap = #GameConfig.MORN_SUMMON_IDS
	api, log = FakeApi()
	ctx = { hero = morn, api = api }

	Skills.raiseSkulls.apply(ctx)
	check("Morn ergue a leva inteira", #log.summons == skullCap, #log.summons)
	check("caveira nasce 1/1",
		log.summons[1] ~= nil and log.summons[1].attack == 1 and log.summons[1].maxHp == 1)
	check("caveira anda so uma casa",
		HeroData.GetMoveRange(HeroData.GetById(GameConfig.MORN_SUMMON_IDS[1])) == 1)

	Skills.raiseSkulls.apply(ctx)
	check("nao ergue de novo com a leva de pe", #log.summons == skullCap, #log.summons)

	log.board[GameConfig.MORN_SUMMON_IDS[1]].isAlive = false
	for _ = 1, GameConfig.MORN_SUMMON_COOLDOWN + 1 do
		Skills.raiseSkulls.apply(ctx)
	end
	check("repoe so a caveira que caiu", #log.summons == skullCap + 1, #log.summons)

	for _, minion in pairs(log.board) do minion.isAlive = true end
	ctx.trigger = "onDie"
	Skills.raiseSkulls.apply(ctx)

	local dePe = 0
	for _, minion in pairs(log.board) do
		if minion.isAlive then dePe += 1 end
	end
	check("caveira cai junto com o Morn", dePe == 0, dePe)
end

do
	local rows = {}
	for _, hex in ipairs(hexes) do
		local letter, row = hex.letter, hex.row
		rows[letter] = rows[letter] or { min = row, max = row }
		rows[letter].min = math.min(rows[letter].min, row)
		rows[letter].max = math.max(rows[letter].max, row)
	end

	local DEPLOY = {
		A6 = true, B7 = true, C6 = true, D7 = true, E6 = true,
		A1 = true, B1 = true, C1 = true, D1 = true, E1 = true,
	}

	local function mirrorOf(hexId)
		local letter, row = hexId:match("^(%a)(%d+)$")
		if not letter or not rows[letter] then return nil end
		return letter .. tostring(rows[letter].min + rows[letter].max - tonumber(row))
	end

	local groups = {}
	for _, fight in ipairs(Campaign.FIGHTS) do
		groups[fight.group] = true
	end

	for group in pairs(groups) do
		check("grupo " .. group .. " tem arena", Arenas.ForGroup(group) ~= nil)
	end

	for _, theme in ipairs(Arenas.THEMES) do
		local set = {}
		for _, hexId in ipairs(theme.objectHexes) do set[hexId] = true end

		check(theme.id .. ": paleta montada", type(Arenas.PaletteOf(theme.id)) == "table")
		check(theme.id .. ": tem objeto de board", theme.object ~= nil)

		for _, hexId in ipairs(theme.objectHexes) do
			check(theme.id .. ": casa existe", HexGrid.Exists(hexId), hexId)
			check(theme.id .. ": casa fora da largada", not DEPLOY[hexId], hexId)
			check(theme.id .. ": casa fora da promocao",
				GameConfig.PROMOTION_HEX_FOR_SLOT[1] ~= hexId and GameConfig.PROMOTION_HEX_FOR_SLOT[2] ~= hexId, hexId)
			check(theme.id .. ": disposicao simetrica", set[mirrorOf(hexId)] == true, hexId)
		end
	end
end

do
	local RUSH_ID = 24
	local rush = FakeHero(RUSH_ID, "A", lineA)
	local base = rush.attack

	local api = FakeApi()
	Skills.momentum.apply({ hero = rush, movedHero = rush, trigger = "onMove",
		path = { "B2", "B3", "B4" }, api = api })
	check("Embalo soma uma casa andada por ponto", rush.attack == base + 3, rush.attack)

	Skills.momentum.apply({ hero = rush, movedHero = rush, trigger = "onMove",
		path = { "B5" }, api = api })
	check("Embalo do passo novo substitui o anterior", rush.attack == base + 1, rush.attack)

	Skills.momentum.apply({ hero = rush, trigger = "onAttackResolved", api = api })
	check("Embalo e gasto no ataque", rush.attack == base, rush.attack)

	Skills.momentum.apply({ hero = rush, movedHero = rush, trigger = "onMove",
		path = { "B6", "B7" }, api = api })
	Skills.momentum.apply({ hero = rush, trigger = "onTurnEnd", api = api })
	check("Embalo nao passa do turno", rush.attack == base, rush.attack)

	local other = FakeHero(1, "A", lineB)
	Skills.momentum.apply({ hero = rush, movedHero = other, trigger = "onMove",
		path = { "C1", "C2" }, api = api })
	check("Embalo ignora o passo alheio", rush.attack == base, rush.attack)

	check("Rush anda 4 casas", HeroData.GetMoveRange(HeroData.GetById(RUSH_ID)) == 4)
	check("Reflexo Supersonico e passivo sem gatilho",
		Skills.dodge.passive == true and #Skills.dodge.triggers == 0)
end

-- ===== KIRA / ESCUDO =====
do
	local KIRA_ID = 27
	local kiraData = HeroData.GetById(KIRA_ID)

	check("Kira esta no catalogo", kiraData ~= nil)

	if kiraData then
		check("Kira tem a ficha combinada",
			kiraData.attack == 1 and kiraData.hp == 33
				and kiraData.ability == GameConfig.ABILITIES.TAUNT,
			("%d/%d/%s"):format(kiraData.attack, kiraData.hp, tostring(kiraData.ability)))

		-- Taunt de ficha e so isso: nenhuma regra de Taunt exclusiva dela
		check("Kira usa o Taunt comum, sem passiva propria",
			HeroData.ABILITY_INFO[kiraData.ability] ~= nil)
	end

	check("a Egide dispara no inicio do turno",
		Skills.aegis ~= nil and table.find(Skills.aegis.triggers, "onTurnStart") ~= nil)

	-- A skill so ABRE a oferta: nao aplica escudo, nao bloqueia dano, nao conhece
	-- a tabela de efeitos. Se um dia ela passar a fazer mais que isto, este check
	-- cai junto.
	local offered = nil
	local api = FakeApi()
	api.OfferShield = function(hero) offered = hero end
	local kira = FakeHero(KIRA_ID, "A", lineA)
	Skills.aegis.apply({ hero = kira, api = api, trigger = "onTurnStart" })
	check("a Egide so abre a oferta, quem aplica e o servidor", offered == kira)

	-- ===== QUEM PODE RECEBER =====
	-- Espelha o ShieldOptionsFor do MatchManager: aliado VIVO, A UMA CASA dela e
	-- ainda sem escudo. Os tres filtros moram no mesmo lugar — e é o mesmo que
	-- vira o destaque azul no cliente e a validação do servidor.
	--
	-- Uma segunda casa vizinha da Kira, pra testar aliado que se APROXIMA: lineB
	-- ja esta ocupado pelo Ralph.
	local outroVizinho
	for _, neighbor in ipairs(HexGrid.GetNeighbors(lineA)) do
		if neighbor.id ~= lineB then outroVizinho = neighbor.id break end
	end

	local ralph = FakeHero(1, "A", lineB)   -- colado na Kira
	local ceos = FakeHero(6, "A", lineC)    -- a duas casas
	local morto = FakeHero(4, "A", lineA)
	local inimigo = FakeHero(2, "B", lineB)
	morto.isAlive = false

	local roster = { ralph, ceos, morto, inimigo }

	local function Eligible()
		local options = {}
		for _, other in ipairs(roster) do
			if other ~= kira and other.isAlive and other.ownerId == kira.ownerId
				and HexGrid.Distance(kira.position, other.position) <= 1
				and not MatchQuery.FindStatusEffect(other, "shield") then
				table.insert(options, other)
			end
		end
		return options
	end

	local function GiveShield(hero)
		if MatchQuery.FindStatusEffect(hero, "shield") then return false end
		table.insert(hero.statusEffects, { type = "shield", permanent = true, duration = 0 })
		return true
	end

	local eligible = Eligible()
	check("so o aliado COLADO na Kira entra na lista",
		#eligible == 1 and eligible[1] == ralph, #eligible)
	check("aliado a duas casas fica de fora",
		HexGrid.Distance(kira.position, ceos.position) == 2)
	check("morto e inimigo ficam de fora", eligible[1] ~= morto and eligible[1] ~= inimigo)
	check("a propria Kira nao entra na lista", eligible[1] ~= kira)

	-- o aliado se aproxima: a lista tem que responder AO PASSO, e é por isso que
	-- ela é recalculada a cada leitura em vez de congelada no inicio do turno
	if outroVizinho then
		ceos.position = outroVizinho
		eligible = Eligible()
		check("aliado que chega perto passa a poder receber", #eligible == 2, #eligible)
		ceos.position = lineC
	end

	-- e a Kira andando ate ele tem o mesmo efeito
	kira.position = lineB
	eligible = Eligible()
	check("a Kira andando ate o aliado tambem habilita",
		#eligible == 1 and eligible[1] == ceos, #eligible)
	kira.position = lineA

	GiveShield(ralph)
	eligible = Eligible()
	check("quem ja tem escudo sai da lista", #eligible == 0, #eligible)

	check("nunca dois escudos no mesmo heroi", GiveShield(ralph) == false)

	-- varios aliados protegidos AO MESMO TEMPO e valido: o maximo e por heroi
	GiveShield(ceos)
	check("o teto e por heroi, nao por time",
		MatchQuery.FindStatusEffect(ralph, "shield") ~= nil
			and MatchQuery.FindStatusEffect(ceos, "shield") ~= nil)
	check("sem ninguem elegivel a oferta nem abre", #Eligible() == 0)

	-- ===== O BLOQUEIO =====
	-- Espelha o ConsumeShield do MatchManager: exige AUTOR (golpe, nao veneno),
	-- anula o dano inteiro seja ele qual for, e sai no primeiro que chegar.
	local function Hit(hero, amount, attacker)
		if attacker and MatchQuery.FindStatusEffect(hero, "shield") then
			for index = #hero.statusEffects, 1, -1 do
				if hero.statusEffects[index].type == "shield" then
					table.remove(hero.statusEffects, index)
				end
			end
			return 0
		end
		hero.currentHp -= amount
		return amount
	end

	local ralphHp = ralph.currentHp
	check("golpe de 8 num heroi com escudo causa 0", Hit(ralph, 8, kira) == 0)
	check("e a vida dele nao muda", ralph.currentHp == ralphHp, ralph.currentHp)
	check("o escudo foi consumido", MatchQuery.FindStatusEffect(ralph, "shield") == nil)
	check("o golpe seguinte passa normal", Hit(ralph, 8, kira) == 8)
	check("e agora a vida cai", ralph.currentHp == ralphHp - 8, ralph.currentHp)

	-- MULTI-HIT: um escudo nao segura a sequencia inteira
	GiveShield(ralph)
	check("multi-hit) hit 1 bloqueado", Hit(ralph, 3, kira) == 0)
	check("multi-hit) hit 2 normal", Hit(ralph, 3, kira) == 3)
	check("multi-hit) hit 3 normal", Hit(ralph, 3, kira) == 3)

	-- AREA: cada escudo por conta propria
	local aoeA, aoeB, aoeC = FakeHero(1, "A", lineA), FakeHero(6, "A", lineB), FakeHero(4, "A", lineC)
	GiveShield(aoeA)
	GiveShield(aoeB)
	check("area) protegido bloqueia", Hit(aoeA, 5, kira) == 0)
	check("area) o outro protegido tambem", Hit(aoeB, 5, kira) == 0)
	check("area) quem nao tinha escudo leva o golpe inteiro", Hit(aoeC, 5, kira) == 5)
	check("area) os dois escudos sairam",
		MatchQuery.FindStatusEffect(aoeA, "shield") == nil
			and MatchQuery.FindStatusEffect(aoeB, "shield") == nil)

	-- AMBIENTE nao gasta escudo: veneno e Morte Subita chegam sem autor
	GiveShield(aoeC)
	check("dano sem autor atravessa o escudo", Hit(aoeC, 1, nil) == 1)
	check("e o escudo continua de pe pro proximo golpe",
		MatchQuery.FindStatusEffect(aoeC, "shield") ~= nil)
end

-- ===== SPYKE / AGILITY =====
do
	local SPYKE_ID = 26
	local spykeData = HeroData.GetById(SPYKE_ID)

	check("Spyke esta no catalogo", spykeData ~= nil)

	if spykeData then
		check("Spyke tem a ficha combinada",
			spykeData.attack == 1 and spykeData.hp == 22
				and spykeData.ability == GameConfig.ABILITIES.AGILITY,
			("%d/%d/%s"):format(spykeData.attack, spykeData.hp, tostring(spykeData.ability)))

		-- Agility nao mexe em alcance: o que ele ganha e um SEGUNDO passo, nao
		-- um passo maior nem um alcance maior
		check("Agility nao altera alcance nem passo",
			HeroData.GetMoveRange(spykeData) == GameConfig.BASE_MOVE_RANGE
				and HeroData.GetAttackRange(spykeData) == GameConfig.BASE_ATTACK_RANGE)

		check("Agility e reconhecida pela ability, nao pelo nome",
			GameConfig.HasAgility({ ability = GameConfig.ABILITIES.AGILITY })
				and not GameConfig.HasAgility({ name = "Spyke", ability = nil }))
	end

	-- ===== AS TRES FASES DO TURNO =====
	-- MatchQuery.CanMove e a MESMA funcao que o MoveHero, o snapshot e o bot
	-- consultam. `bonusMove` e o passo avulso que o MarkAttacked acende pra quem
	-- tem Agility; aqui ele e ligado na mao pra testar a regra sem partida.
	local spyke = FakeHero(SPYKE_ID, "A", lineA)
	local ralph = FakeHero(1, "A", lineB)
	local board = { turn = { moved = {}, attacked = {}, bonusMove = {} } }

	check("A) comeco do turno: anda", MatchQuery.CanMove(board, spyke))

	board.turn.moved[spyke.uid] = true
	check("A) depois de andar: nao anda de novo sozinho", not MatchQuery.CanMove(board, spyke))

	board.turn.attacked[spyke.uid] = true
	board.turn.bonusMove[spyke.uid] = true
	check("A) Mover -> Atacar -> Mover: o golpe libera o segundo passo",
		MatchQuery.CanMove(board, spyke))

	board.turn.moved[spyke.uid] = true
	board.turn.bonusMove[spyke.uid] = nil
	check("A) o segundo passo acaba o turno dele", not MatchQuery.CanMove(board, spyke))
	check("C) o ataque continua sendo um so", board.turn.attacked[spyke.uid] == true)

	-- B) Atacar -> Mover, sem ter andado antes
	local fresh = { turn = { moved = {}, attacked = {}, bonusMove = {} } }
	fresh.turn.attacked[spyke.uid] = true
	fresh.turn.bonusMove[spyke.uid] = true
	check("B) Atacar -> Mover funciona sem o passo de ida",
		MatchQuery.CanMove(fresh, spyke))

	-- sem Agility, o golpe encerra o passo: e o contraste que prova que a regra
	-- veio da ability e nao de um "todo mundo anda depois de bater"
	local plain = { turn = { moved = {}, attacked = {}, bonusMove = {} } }
	plain.turn.attacked[ralph.uid] = true
	check("sem Agility o golpe encerra o movimento", not MatchQuery.CanMove(plain, ralph))

	-- ===== PASSIVA: PONTO DE APOIO =====
	local ceos = FakeHero(6, "A", lineC)
	local near = { [ralph.uid] = ralph }
	local api = FakeApi()
	local base1, base2 = ralph.attack, ceos.attack

	api.GetAlliesInRange = function() return { ralph, ceos } end
	api.Distance = function(_, position)
		return (position == ralph.position and near[ralph.uid]) and 1
			or (position == ceos.position and near[ceos.uid]) and 1
			or 3
	end

	local function Sync(trigger)
		Skills.rallyAura.apply({ hero = spyke, api = api, trigger = trigger or "onMove" })
	end

	Sync()
	check("passiva A) 1 aliado colado ganha +1", ralph.attack == base1 + 1, ralph.attack)
	check("passiva A) quem esta longe nao ganha nada", ceos.attack == base2, ceos.attack)

	Sync()
	Sync()
	check("passiva) recalcular nao empilha o bonus", ralph.attack == base1 + 1, ralph.attack)

	near[ceos.uid] = ceos
	Sync()
	check("passiva B) 2 aliados colados ganham +1 cada",
		ralph.attack == base1 + 1 and ceos.attack == base2 + 1)

	near[ralph.uid] = nil
	Sync()
	check("passiva C) sai da adjacencia e perde na hora", ralph.attack == base1, ralph.attack)
	check("passiva C) quem continuou colado mantem", ceos.attack == base2 + 1, ceos.attack)

	-- E) o segundo passo da Agility e so mais um onMove: troca de protegido
	near[ralph.uid] = ralph
	near[ceos.uid] = nil
	Sync()
	check("passiva E) reposicionar troca quem recebe a aura",
		ralph.attack == base1 + 1 and ceos.attack == base2)

	-- D) morte do Spyke devolve tudo, mesmo de quem ainda esta colado nele
	spyke.isAlive = false
	Sync("onDie")
	check("passiva D) Spyke morre e a aura inteira e devolvida",
		ralph.attack == base1 and ceos.attack == base2)
	check("passiva D) nao sobra marca de origem em ninguem",
		ralph.rallyAuraFrom == nil and ceos.rallyAuraFrom == nil)

	-- ===== SKILL: SANGUE FERVENDO =====
	local guard = FakeHero(SPYKE_ID, "A", lineA)
	local victim = FakeHero(1, "A", lineB)
	local guardHp = guard.currentHp
	local guardAtk = guard.attack

	-- Refaz o que o ApplyDamage faz por evento de dano: se o vizinho tem o
	-- efeito aberto, o bonus e somado DENTRO dele (`attackBonus`) e no ataque.
	-- Cada aliado atingido e uma passagem — e um golpe em area vira N passagens,
	-- que e exatamente como os +2/+3 nascem.
	-- Refaz o que o ApplyDamage faz por evento de dano: o cofre nasce sozinho no
	-- primeiro aliado ferido e o bonus mora DENTRO dele (`attackBonus`), nunca
	-- solto no ataque. Cada aliado atingido e uma passagem — e um golpe em area
	-- vira N passagens, que e exatamente como os +2/+3 nascem.
	local function AllyWasHit(spyke)
		local bonus = Skills.vengeance.attackFromNearbyHit({
			hero = victim, ally = spyke,
		}) or 0

		if bonus > 0 then
			local effect = MatchQuery.FindStatusEffect(spyke, "vengeance")
			if not effect then
				effect = { type = "vengeance", duration = math.huge, attackBonus = 0 }
				table.insert(spyke.statusEffects, effect)
			end
			effect.attackBonus += bonus
			spyke.attack += bonus
		end
	end

	AllyWasHit(guard)
	check("skill) 1 aliado atingido rende +1 ATK sem precisar ter atacado antes",
		guard.attack == guardAtk + GameConfig.SPYKE_VENGEANCE_ATTACK, guard.attack)
	check("skill) o Spyke nao perde vida nenhuma", guard.currentHp == guardHp, guard.currentHp)

	AllyWasHit(guard)
	check("skill) 2 aliados atingidos rendem +2 ATK",
		guard.attack == guardAtk + GameConfig.SPYKE_VENGEANCE_ATTACK * 2, guard.attack)

	AllyWasHit(guard)
	check("skill) 3 aliados numa area rendem +3 ATK",
		guard.attack == guardAtk + GameConfig.SPYKE_VENGEANCE_ATTACK * 3, guard.attack)
	check("skill) HP intacto depois dos tres", guard.currentHp == guardHp, guard.currentHp)

	-- o bonus acumulado mora NO EFEITO, que e o cofre que o onAttackResolved
	-- esvazia — sem residuo solto no ataque
	local effect = MatchQuery.FindStatusEffect(guard, "vengeance")
	check("skill) o bonus fica guardado no efeito, nao solto no ataque",
		effect ~= nil and effect.attackBonus == GameConfig.SPYKE_VENGEANCE_ATTACK * 3,
		effect and effect.attackBonus)

	check("skill) so um efeito aberto, por mais aliados que caiam",
		#guard.statusEffects == 1, #guard.statusEffects)

	-- ATACAR GASTA. O bonus acompanha o golpe inteiro e so e devolvido depois
	-- que ele resolve (onAttackResolved), nunca no onAttack — que roda ANTES do
	-- dano e deixaria o Spyke batendo com o ataque de ficha.
	local api = FakeApi()
	api.RemoveStatusEffect = function(hero, effectType)
		for index = #hero.statusEffects, 1, -1 do
			local open = hero.statusEffects[index]
			if open.type == effectType then
				table.remove(hero.statusEffects, index)
				if open.attackBonus then hero.attack -= open.attackBonus end
			end
		end
	end

	Skills.vengeance.apply({ hero = guard, api = api, trigger = "onAttackResolved" })
	check("skill) depois do golpe o ataque volta pra ficha",
		guard.attack == guardAtk, guard.attack)
	check("skill) sem residuo de efeito depois do estorno",
		#guard.statusEffects == 0, #guard.statusEffects)

	AllyWasHit(guard)
	check("skill) e volta a acumular do zero",
		guard.attack == guardAtk + GameConfig.SPYKE_VENGEANCE_ATTACK, guard.attack)

	guard.isAlive = false
	check("skill) Spyke morto nao acumula mais nada",
		Skills.vengeance.attackFromNearbyHit({ hero = victim, ally = guard }) == 0)
end

do
	check("Wren atira 4 casas", HeroData.GetAttackRange(HeroData.GetById(19)) == 4)

	local miner = FakeHero(3, "A", lineA)
	local base = miner.attack
	local api, log = FakeApi()
	for _ = 1, 60 do
		Skills.goodLuck.apply({ hero = miner, api = api, trigger = "onTurnEnd" })
	end
	check("Good Luck cura junto com o ataque que ganhou",
		#log.heals == miner.attack - base, ("%d curas / %d ataque"):format(#log.heals, miner.attack - base))
	check("Good Luck cura o proprio Mineiro pelo valor de config",
		log.heals[1] == nil or (log.heals[1].hero == miner
			and log.heals[1].amount == GameConfig.GOOD_LUCK_HEAL))

	local ralph = FakeHero(1, "A", lineA)
	local sack = FakeHero(6, "B", lineB)
	ralph.firstAttack = false
	ralph.firstPunchApplied = false
	api = FakeApi()
	local card = ralph.attack

	Skills.firstPunch.apply({ hero = ralph, target = nil, api = api })
	check("First Punch carrega +2 no comeco do turno", ralph.attack == card + 2, ralph.attack)
	Skills.firstPunch.apply({ hero = ralph, target = nil, api = api })
	check("First Punch nao carrega duas vezes", ralph.attack == card + 2, ralph.attack)

	Skills.firstPunch.apply({ hero = ralph, target = sack, api = api, damageApplied = false })
	check("First Punch devolve o que carregou", ralph.attack == card, ralph.attack)

	local revived = FakeHero(1, "A", lineA)
	revived.firstAttack = false
	revived.firstPunchApplied = false
	api = FakeApi()
	Skills.firstPunch.apply({ hero = revived, target = sack, api = api, damageApplied = false })
	check("First Punch nao desconta carga que nunca existiu",
		revived.attack == card, revived.attack)
end


do
	local ahead = lineB and lineC and HexGrid.GetLineBeyond(lineB, lineC, 1)
	local lineD = ahead and ahead[1]
	local behindTarget = lineD and HexGrid.GetLineBeyond(lineC, lineD, 1)
	local behindShooter = lineA and lineB and HexGrid.GetLineBeyond(lineB, lineA, 1)

	if lineD then
		local lateral, sideStep
		for _, neighbor in ipairs(HexGrid.GetNeighbors(lineB)) do
			local span = HexGrid.Distance(lineA, neighbor.id) + HexGrid.Distance(neighbor.id, lineD)
			if span > HexGrid.Distance(lineA, lineD) then
				if HexGrid.Distance(lineA, neighbor.id) == 1 then
					sideStep = sideStep or neighbor.id
				elseif not lateral then
					lateral = neighbor.id
				end
			end
		end

		local shooter = FakeHero(19, "A", lineA)
		local melee = FakeHero(1, "A", lineA)
		local victim = FakeHero(1, "B", lineD)
		local wall = FakeHero(6, "B", lineB)

		local board = { occupied = {}, heroes = {} }
		local function put(hero, hexId)
			if hero.position then board.occupied[hero.position] = nil end
			hero.position = hexId
			board.occupied[hexId] = hero
			board.heroes[hero.uid] = hero
		end

		put(shooter, lineA)
		put(victim, lineD)

		check("sem Taunt o tiro passa", MatchQuery.TauntBlocks(board, shooter, victim) == nil)

		put(wall, lineB)
		check("Taunt no corredor bloqueia mesmo longe do alvo",
			MatchQuery.TauntBlocks(board, shooter, victim) == wall, lineB)
		check("o bloqueador nao encosta no alvo", HexGrid.Distance(lineB, lineD) > 1)

		put(wall, lineC)
		check("Taunt no corredor colado no alvo bloqueia",
			MatchQuery.TauntBlocks(board, shooter, victim) == wall, lineC)

		if behindTarget and behindTarget[1] then
			put(wall, behindTarget[1])
			check("Taunt atras do alvo nao bloqueia",
				MatchQuery.TauntBlocks(board, shooter, victim) == nil, behindTarget[1])
		end

		if behindShooter and behindShooter[1] then
			put(wall, behindShooter[1])
			check("Taunt colado atras do atirador tambem prende",
				MatchQuery.TauntBlocks(board, shooter, victim) == wall, behindShooter[1])
		end

		if lateral then
			put(wall, lateral)
			check("Taunt fora do corredor nao bloqueia",
				MatchQuery.TauntBlocks(board, shooter, victim) == nil, lateral)
		end

		if sideStep then
			put(wall, sideStep)
			check("Taunt colado prende o Ranged fora do corredor",
				MatchQuery.TauntBlocks(board, shooter, victim) == wall, sideStep)
			check("o Taunt colado continua atacavel pelo Ranged",
				MatchQuery.TauntBlocks(board, shooter, wall) == nil, sideStep)

			-- Taunt LONGE tambem e alvo legitimo. O provocador colado barra o
			-- inimigo SEM Taunt, nao os outros provocadores: "nao passe por cima
			-- de mim" nao e "ataque exatamente a mim".
			local farTaunt = FakeHero(9, "B", lineD)
			put(victim, lineC)
			put(farTaunt, lineD)
			check("com um Taunt colado, outro Taunt longe continua atacavel",
				MatchQuery.TauntBlocks(board, shooter, farTaunt) == nil, sideStep)
			check("mas o inimigo sem Taunt continua barrado",
				MatchQuery.TauntBlocks(board, shooter, victim) == wall, sideStep)
			board.heroes[farTaunt.uid] = nil
			board.occupied[farTaunt.position] = nil
			put(victim, lineD)
		end

		put(wall, lineB)
		check("alvo com Taunt continua atacavel",
			MatchQuery.TauntBlocks(board, shooter, wall) == nil)

		put(melee, lineA)
		put(wall, lineC)
		check("melee nao trava com Taunt longe",
			MatchQuery.TauntBlocks(board, melee, victim) == nil)
		put(wall, lineB)
		check("melee trava com Taunt colado",
			MatchQuery.TauntBlocks(board, melee, victim) == wall)
	end
end

-- ===== MULTIPLOS TAUNTS NAO SE TRAVAM =====
-- Tabuleiro proprio: estes casos precisam de dois provocadores ao mesmo tempo, e
-- misturar com o tabuleiro do corredor acima so confundiria quem for ler.
if lineA and lineB and lineC then
	local board = { occupied = {}, heroes = {} }
	local function put(hero, hexId)
		if hero.position then board.occupied[hero.position] = nil end
		hero.position = hexId
		board.occupied[hexId] = hero
		board.heroes[hero.uid] = hero
	end

	-- Dois provocadores colados, um de cada lado. Era o caso que travava: a
	-- varredura de vizinhos devolvia um bloqueador ANTES de olhar se o proprio
	-- alvo era Taunt, e nenhum dos dois conseguia bater no outro.
	local tauntA = FakeHero(6, "A", lineA)
	local tauntB = FakeHero(9, "B", lineB)
	put(tauntA, lineA)
	put(tauntB, lineB)

	check("Taunt bate no Taunt inimigo colado",
		MatchQuery.TauntBlocks(board, tauntA, tauntB) == nil)
	check("e o de volta tambem",
		MatchQuery.TauntBlocks(board, tauntB, tauntA) == nil)

	-- Agora um atacante comum cercado por DOIS provocadores inimigos: os dois
	-- valem, e o terceiro inimigo nao.
	local hitter = FakeHero(1, "A", lineA)
	local guardOne = FakeHero(6, "B", lineB)
	local guardTwo = nil
	for _, neighbor in ipairs(HexGrid.GetNeighbors(lineA)) do
		if neighbor.id ~= lineB then
			guardTwo = FakeHero(9, "B", neighbor.id)
			break
		end
	end

	local outsider = FakeHero(2, "B", lineC)
	put(hitter, lineA)
	put(guardOne, lineB)
	put(outsider, lineC)

	check("1 Taunt valido: so ele pode ser atacado",
		MatchQuery.TauntBlocks(board, hitter, guardOne) == nil
			and MatchQuery.TauntBlocks(board, hitter, outsider) == guardOne)

	if guardTwo then
		put(guardTwo, guardTwo.position)

		check("2 Taunts validos: o primeiro e alvo",
			MatchQuery.TauntBlocks(board, hitter, guardOne) == nil, guardOne.position)
		check("2 Taunts validos: o segundo tambem e alvo",
			MatchQuery.TauntBlocks(board, hitter, guardTwo) == nil, guardTwo.position)
		check("2 Taunts validos: o inimigo sem Taunt segue barrado",
			MatchQuery.TauntBlocks(board, hitter, outsider) ~= nil)

		-- e um Ranged no mesmo aperto le a MESMA regra, sem excecao propria
		local sniper = FakeHero(19, "A", lineA)
		put(sniper, lineA)
		check("Ranged com 2 Taunts colados escolhe qualquer um dos dois",
			MatchQuery.TauntBlocks(board, sniper, guardOne) == nil
				and MatchQuery.TauntBlocks(board, sniper, guardTwo) == nil)
		check("Ranged com 2 Taunts colados nao alcanca o terceiro",
			MatchQuery.TauntBlocks(board, sniper, outsider) ~= nil)
	end
end

do
	local core
	for _, hex in ipairs(hexes) do
		local id = idOf(hex)
		if #HexGrid.GetNeighbors(id) == 6 then
			core = id
			break
		end
	end

	if core then
		local corner = HexGrid.GetNeighbors(core)[1].id
		local rush = FakeHero(24, "A", core)
		local bully = FakeHero(1, "B", corner)
		local board = { occupied = {}, heroes = {} }

		local function put(hero, hexId)
			hero.position = hexId
			board.occupied[hexId] = hero
			board.heroes[hero.uid] = hero
		end
		put(rush, core)
		put(bully, corner)

		local escape = MatchQuery.DodgeHexFor(board, rush, corner)
		check("Rush esquiva com espaco aberto", escape ~= nil)
		check("a esquiva termina longe do atacante",
			escape ~= nil and HexGrid.Distance(escape, corner) >= GameConfig.DODGE_MIN_DISTANCE,
			escape and HexGrid.Distance(escape, corner))

		local blocked = 0
		for _, neighbor in ipairs(HexGrid.GetNeighbors(core)) do
			if HexGrid.Distance(neighbor.id, corner) >= GameConfig.DODGE_MIN_DISTANCE then
				put(FakeHero(1, "B", neighbor.id), neighbor.id)
				blocked += 1
			end
		end
		check("o cerco tem casas pra fechar", blocked > 0, blocked)
		check("sem saida a 2 casas o Rush leva o golpe",
			MatchQuery.DodgeHexFor(board, rush, corner) == nil)

		check("vizinho colado no atacante nao serve de fuga",
			HexGrid.Distance(corner, core) < GameConfig.DODGE_MIN_DISTANCE)
	end
end


do
	local VOLT_ID = 25
	local chain = {}
	local occupied = {}

	local function Electrify(victim)
		local existing = MatchQuery.FindStatusEffect(victim, "charge")
		local stacks = (existing and existing.stacks or 0) + 1
		for i = #victim.statusEffects, 1, -1 do
			if victim.statusEffects[i].type == "charge" then table.remove(victim.statusEffects, i) end
		end
		if stacks >= GameConfig.VOLT_CHARGES_TO_PARALYZE then
			table.insert(victim.statusEffects, { type = "paralysis", duration = GameConfig.PARALYSIS_DURATION })
		else
			table.insert(victim.statusEffects, { type = "charge", duration = GameConfig.VOLT_CHARGE_DURATION, stacks = stacks })
		end
	end

	local function ChainFrom(origin, hexId)
		local visited = { [hexId] = true }
		local queue, hit = { hexId }, {}
		while #queue > 0 do
			local current = table.remove(queue, 1)
			for _, neighbor in ipairs(HexGrid.GetNeighbors(current)) do
				local occupant = occupied[neighbor.id]
				-- espelha o IsChainTarget do MatchManager: so inimigo VIVO com
				-- dono conduz, e o que conduz e o que apanha
				if not visited[neighbor.id] and occupant ~= nil
					and occupant ~= origin
					and occupant.isAlive == true
					and occupant.ownerId ~= nil
					and occupant.ownerId ~= origin.ownerId then
					visited[neighbor.id] = true
					table.insert(queue, neighbor.id)
					table.insert(hit, occupant)
				end
			end
		end
		for _, victim in ipairs(hit) do
			victim.currentHp -= GameConfig.VOLT_CHAIN_DAMAGE
			Electrify(victim)
			table.insert(chain, victim)
		end
		return #hit
	end

	local function api()
		local a = FakeApi()
		a.ChainFrom = ChainFrom
		a.Say = function() end
		a.Electrify = Electrify
		a.RemoveStatusEffect = function(hero, t)
			for i = #hero.statusEffects, 1, -1 do
				if hero.statusEffects[i].type == t then table.remove(hero.statusEffects, i) end
			end
		end
		return a
	end

	local volt = FakeHero(VOLT_ID, "A", lineA)
	local a1 = FakeHero(1, "B", lineB)
	occupied[lineB] = a1

	chain = {}
	Skills.voltChain.apply({ hero = volt, target = a1, api = api(), trigger = "onAttack" })
	check("caso 1: alvo sozinho nao propaga", #chain == 0, #chain)
	check("caso 1: alvo ganha carga",
		MatchQuery.FindStatusEffect(a1, "charge") ~= nil)

	local b1 = FakeHero(1, "B", lineC)
	occupied[lineC] = b1
	chain = {}
	Skills.voltChain.apply({ hero = volt, target = a1, api = api(), trigger = "onAttack" })
	check("caso 2: vizinho do alvo leva a corrente", #chain == 1, #chain)
	check("caso 2: alvo direto nao leva a corrente de novo",
		chain[1] ~= a1)
	check("caso 2: condutor nao ganha carga",
		MatchQuery.FindStatusEffect(b1, "charge") == nil)

	local gap = HexGrid.GetLineBeyond(lineB, lineC, 1)
	if gap and gap[1] then
		local beyond = HexGrid.GetLineBeyond(lineC, gap[1], 1)
		if beyond and beyond[1] then
			local far = FakeHero(1, "B", beyond[1])
			occupied[beyond[1]] = far
			chain = {}
			Skills.voltChain.apply({ hero = volt, target = a1, api = api(), trigger = "onAttack" })
			check("caso 4: casa vazia corta a corrente", #chain == 1, #chain)

			local barrel = { isBarrel = true, position = gap[1], ownerId = "N" }
			occupied[gap[1]] = barrel
			chain = {}
			Skills.voltChain.apply({ hero = volt, target = a1, api = api(), trigger = "onAttack" })
			check("caso 5: barril conduz a corrente", #chain == 2, #chain)
			occupied[gap[1]] = nil
			occupied[beyond[1]] = nil
		end
	end

	local ally = FakeHero(1, "A", lineA)
	occupied[lineA] = ally
	chain = {}
	Skills.voltChain.apply({ hero = volt, target = a1, api = api(), trigger = "onAttack" })
	check("aliado conduz mas nao leva dano", #chain == 1, #chain)
	occupied[lineA] = nil

	local seen = {}
	for _, victim in ipairs(chain) do
		check("caso 7: ninguem leva a corrente duas vezes", seen[victim] == nil)
		seen[victim] = true
	end

	local target = FakeHero(1, "B", lineB)
	occupied[lineB] = target
	local ctx = { hero = volt, target = target, api = api(), trigger = "onAttack" }
	Skills.voltChain.apply(ctx)
	Skills.voltChain.apply(ctx)
	check("caso 8: duas cargas ainda nao paralisam",
		MatchQuery.FindStatusEffect(target, "paralysis") == nil)
	Skills.voltChain.apply(ctx)
	check("caso 8: terceira carga paralisa",
		MatchQuery.FindStatusEffect(target, "paralysis") ~= nil)
	check("caso 8: a paralisia consome as cargas",
		MatchQuery.FindStatusEffect(target, "charge") == nil)

	check("carga dura 2 turnos", GameConfig.VOLT_CHARGE_DURATION == 2)

	local c1 = FakeHero(1, "B", lineB)
	local c2 = FakeHero(1, "B", lineC)
	occupied = { [lineB] = c1, [lineC] = c2 }
	chain = {}
	Skills.voltChain.apply({ hero = volt, target = c1, api = api(), trigger = "onAttack" })
	local charged = MatchQuery.FindStatusEffect(c2, "charge")
	check("descarga tambem aplica carga", charged ~= nil and charged.stacks == 1,
		charged and charged.stacks)
	local direct = MatchQuery.FindStatusEffect(c1, "charge")
	check("alvo direto nao recebe carga dupla", direct ~= nil and direct.stacks == 1,
		direct and direct.stacks)

	Skills.voltChain.apply({ hero = volt, target = c1, api = api(), trigger = "onAttack" })
	Skills.voltChain.apply({ hero = volt, target = c1, api = api(), trigger = "onAttack" })
	check("tres descargas paralisam o condutor",
		MatchQuery.FindStatusEffect(c2, "paralysis") ~= nil)
end

do
	local rush = FakeHero(24, "A", lineB)
	local bully = FakeHero(1, "B", lineA)
	local board = { occupied = { [lineB] = rush, [lineA] = bully }, heroes = {} }
	board.heroes[rush.uid] = rush
	board.heroes[bully.uid] = bully

	check("caso 1: Rush normal tem rota de fuga",
		MatchQuery.DodgeHexFor(board, rush, lineA) ~= nil)

	table.insert(rush.statusEffects, { type = "paralysis", duration = 1 })
	check("caso 2: paralisia nao remove a rota, quem barra e o PerformAttack",
		MatchQuery.DodgeHexFor(board, rush, lineA) ~= nil)
	check("caso 2: paralisado e reconhecido como incapacitado",
		MatchQuery.FindStatusEffect(rush, "paralysis") ~= nil)
end

do
	local function AllowsReaction(attacker)
		for _, key in ipairs(attacker.abilities) do
			local skill = Skills[key]
			if skill and skill.suppressesReaction and skill.suppressesReaction(attacker) then
				return false
			end
		end
		return true
	end

	local nash = FakeHero(13, "B", lineA)
	local plain = FakeHero(1, "B", lineA)

	nash.stealth = false
	check("caso A: Nash visivel permite reacao", AllowsReaction(nash) == true)

	nash.stealth = true
	check("caso B: ataque surpresa nao permite reacao", AllowsReaction(nash) == false)

	check("caso C: heroi comum nao suprime reacao", AllowsReaction(plain) == true)

	check("a regra vem da skill, nao do nome",
		Skills.ambush.suppressesReaction ~= nil and Skills.dodge.suppressesReaction == nil)
end

do
	local BLOCKERS = { "paralysis", "freeze" }

	local function AllowsReaction(attacker)
		for _, key in ipairs(attacker.abilities) do
			local skill = Skills[key]
			if skill and skill.suppressesReaction and skill.suppressesReaction(attacker) then
				return false
			end
		end
		return true
	end

	local function CanReact(hero, attacker)
		if not (hero and hero.isAlive) then return false end
		for _, effectType in ipairs(BLOCKERS) do
			if MatchQuery.FindStatusEffect(hero, effectType) then return false end
		end
		return AllowsReaction(attacker)
	end

	local rush = FakeHero(24, "A", lineB)
	local plain = FakeHero(1, "B", lineA)
	local nash = FakeHero(13, "B", lineA)

	check("Rush inteiro reage a golpe comum", CanReact(rush, plain) == true)

	table.insert(rush.statusEffects, { type = "freeze", duration = 1 })
	check("Rush congelado nao reage", CanReact(rush, plain) == false)
	rush.statusEffects = {}

	table.insert(rush.statusEffects, { type = "paralysis", duration = 1 })
	check("Rush paralisado nao reage", CanReact(rush, plain) == false)
	rush.statusEffects = {}

	nash.stealth = true
	check("Rush inteiro nao reage a ataque surpresa", CanReact(rush, nash) == false)

	table.insert(rush.statusEffects, { type = "freeze", duration = 1 })
	check("Rush congelado + surpresa nao reage", CanReact(rush, nash) == false)
	rush.statusEffects = {}

	rush.isAlive = false
	check("Rush morto nao reage", CanReact(rush, plain) == false)
	rush.isAlive = true

	nash.stealth = false
	check("Nash visivel devolve a reacao", CanReact(rush, nash) == true)
end
do
	local occupied = {}
	local function ChainFrom(origin, hexId)
		local visited = { [hexId] = true }
		local queue, hit = { hexId }, {}
		while #queue > 0 do
			local current = table.remove(queue, 1)
			for _, neighbor in ipairs(HexGrid.GetNeighbors(current)) do
				local occupant = occupied[neighbor.id]
				-- espelha o IsChainTarget do MatchManager: so inimigo VIVO com
				-- dono conduz, e o que conduz e o que apanha
				if not visited[neighbor.id] and occupant ~= nil
					and occupant ~= origin
					and occupant.isAlive == true
					and occupant.ownerId ~= nil
					and occupant.ownerId ~= origin.ownerId then
					visited[neighbor.id] = true
					table.insert(queue, neighbor.id)
					table.insert(hit, occupant)
				end
			end
		end
		return hit
	end

	local core
	for _, hex in ipairs(hexes) do
		if #HexGrid.GetNeighbors(idOf(hex)) == 6 then
			core = idOf(hex)
			break
		end
	end

	if core then
		local ring = HexGrid.GetNeighbors(core)
		local volt = FakeHero(25, "A", core)
		occupied[core] = volt

		local target, isolated
		for _, neighbor in ipairs(ring) do
			if not target then
				target = FakeHero(1, "B", neighbor.id)
				occupied[neighbor.id] = target
			elseif not isolated and HexGrid.Distance(neighbor.id, target.position) > 1 then
				isolated = FakeHero(1, "B", neighbor.id)
				occupied[neighbor.id] = isolated
			end
		end

		if target and isolated then
			local hit = ChainFrom(volt, target.position)
			local reached = false
			for _, victim in ipairs(hit) do
				if victim == isolated then reached = true end
			end
			check("Volt nao e ponte: vizinho isolado fica de fora", reached == false)
			check("o isolado encosta no Volt", HexGrid.Distance(isolated.position, core) == 1)
			check("o isolado nao encosta no alvo",
				HexGrid.Distance(isolated.position, target.position) > 1)
		end
	end
end

-- ===== A CORRENTE DO VOLT SO ANDA NA REDE INIMIGA =====
-- Linha reta A-B-C: o alvo em A, o meio em B, e um inimigo em C que SO se
-- alcanca passando por B. Trocando quem esta em B, cada caso responde uma
-- pergunta: aliado conduz? lapide conduz? barril conduz? inimigo conduz?
if lineA and lineB and lineC then
	local occupied = {}

	local function ChainFrom(origin, hexId)
		local visited = { [hexId] = true }
		local queue, hit = { hexId }, {}
		while #queue > 0 do
			local current = table.remove(queue, 1)
			for _, neighbor in ipairs(HexGrid.GetNeighbors(current)) do
				local occupant = occupied[neighbor.id]
				if not visited[neighbor.id] and occupant ~= nil
					and occupant ~= origin
					and occupant.isAlive == true
					and occupant.ownerId ~= nil
					and occupant.ownerId ~= origin.ownerId then
					visited[neighbor.id] = true
					table.insert(queue, neighbor.id)
					table.insert(hit, occupant)
				end
			end
		end
		return hit
	end

	local voltHex
	for _, n in ipairs(HexGrid.GetNeighbors(lineA)) do
		if n.id ~= lineB then voltHex = n.id break end
	end

	if voltHex then
		local volt = FakeHero(25, "A", voltHex)
		local alvo = FakeHero(1, "B", lineA)   -- o inimigo que o Volt atacou
		local atras = FakeHero(2, "B", lineC)  -- so alcancavel atraves de B
		occupied[voltHex] = volt
		occupied[lineA] = alvo
		occupied[lineC] = atras

		check("o inimigo de tras nao encosta no alvo",
			HexGrid.Distance(lineA, lineC) == 2)

		local function AtingidosComMeio(meio)
			occupied[lineB] = meio
			local pegou = {}
			for _, v in ipairs(ChainFrom(volt, alvo.position)) do pegou[v] = true end
			return pegou
		end

		-- ALIADO no meio
		local aliado = FakeHero(6, "A", lineB)
		local pegou = AtingidosComMeio(aliado)
		check("corrente) aliado nao recebe dano", pegou[aliado] ~= true)
		check("corrente) aliado nao e ponte", pegou[atras] ~= true)
		check("corrente) o proprio Volt nunca entra", pegou[volt] ~= true)

		-- LAPIDE no meio (inimigo morto: ocupa a casa, mas nao e combatente)
		local lapide = FakeHero(4, "B", lineB)
		lapide.isAlive = false
		pegou = AtingidosComMeio(lapide)
		check("corrente) lapide nao recebe nem conduz",
			pegou[lapide] ~= true and pegou[atras] ~= true)

		-- BARRIL no meio (neutro: sem dono)
		local barril = { position = lineB, isBarrel = true, hitsLeft = 3 }
		pegou = AtingidosComMeio(barril)
		check("corrente) barril neutro nao conduz", pegou[atras] ~= true)

		-- INIMIGO no meio: agora sim a corrente atravessa
		local vizinho = FakeHero(9, "B", lineB)
		pegou = AtingidosComMeio(vizinho)
		check("corrente) inimigo colado no alvo recebe", pegou[vizinho] == true)
		check("corrente) e a corrente segue pro inimigo seguinte", pegou[atras] == true)
	end
end

do
	local faltando = {}
	for key in pairs(missingApi) do table.insert(faltando, key) end
	table.sort(faltando)
	check("FakeApi cobre a API que as skills usam", #faltando == 0, table.concat(faltando, ", "))
end


do
	local core
	for _, hex in ipairs(hexes) do
		if #HexGrid.GetNeighbors(idOf(hex)) == 6 then
			core = idOf(hex)
			break
		end
	end

	if core then
		local hunter = FakeHero(1, "A", core)
		local mate = FakeHero(6, "A", HexGrid.GetNeighbors(core)[1].id)
		local board = {
			occupied = { [core] = hunter },
			heroes = {},
			turn = { moved = {}, attacked = {} },
		}
		board.occupied[mate.position] = mate
		board.heroes[hunter.uid] = hunter
		board.heroes[mate.uid] = mate

		local ctx = { allies = { hunter, mate }, enemies = {} }

		local goals = BotBrain.SearchGoals(board, ctx, core)
		check("busca) a ultima casa vista vira o primeiro objetivo",
			goals[1] == core, goals[1])
		check("busca) sempre sobra objetivo mesmo sem pista",
			#BotBrain.SearchGoals(board, ctx, nil) > 0)

		local longe = goals[#goals]
		local plan = BotBrain.SearchPlanFor(board, hunter, ctx, longe)
		check("busca) o bot sempre acha uma jogada", plan ~= nil)
		check("busca) e ela nao e ficar parado",
			plan ~= nil and plan.position ~= hunter.position, plan and plan.position)
		check("busca) o passo aproxima do objetivo",
			plan ~= nil and HexGrid.Distance(plan.position, longe)
				< HexGrid.Distance(core, longe))

		BotBrain.RememberSearchTile(hunter, core)
		check("busca) a casa recem-visitada fica na memoria",
			#hunter.searchMemory == 1 and hunter.searchMemory[1] == core)

		table.insert(hunter.statusEffects, { type = "paralysis", duration = 1 })
		check("busca) paralisado nao entra na caçada",
			BotBrain.SearchPlanFor(board, hunter, ctx, longe) == nil)
		hunter.statusEffects = {}

		board.turn.moved[hunter.uid] = true
		check("busca) quem ja andou no turno nao anda de novo",
			BotBrain.SearchPlanFor(board, hunter, ctx, longe) == nil)
	end
end

do
	local NEGATIVOS = { "poison", "freeze", "wound", "charge", "paralysis" }
	for _, tipo in ipairs(NEGATIVOS) do
		check("escudo cobre o efeito negativo: " .. tipo,
			GameConfig.IsNegativeEffect(tipo) == true)
	end
	check("escudo nao e tratado como negativo",
		GameConfig.IsNegativeEffect("shield") == false)

	-- espelha a guarda do ApplyStatusEffect
	local function aceita(hero, tipo)
		if hero.frenzyActive and GameConfig.IsNegativeEffect(tipo) then return false end
		if GameConfig.IsNegativeEffect(tipo)
			and (hero.shieldJustBroke or MatchQuery.FindStatusEffect(hero, "shield")) then
			return false
		end
		return true
	end

	local karo = FakeHero(12, "A", lineA)
	check("sem escudo, o gelo entra", aceita(karo, "freeze") == true)

	table.insert(karo.statusEffects, { type = "shield", duration = math.huge })
	check("com escudo, o gelo do Kor e recusado", aceita(karo, "freeze") == false)
	check("com escudo, o veneno e recusado", aceita(karo, "poison") == false)
	check("escudo nao barra efeito bom", aceita(karo, "vengeance") == true)

	-- estopim: o dano gasta o escudo ANTES do veneno sair
	karo.statusEffects = {}
	karo.shieldJustBroke = true
	check("escudo recem-estourado ainda barra o veneno do estopim",
		aceita(karo, "poison") == false)

	karo.shieldJustBroke = nil
	check("passada a acao, o veneno volta a entrar", aceita(karo, "poison") == true)
end
if #failures == 0 then
	print(("CoreChecks: %d verificacoes, tudo certo."):format(passed))
else
	warn(("CoreChecks: %d falha(s) em %d verificacoes:"):format(#failures, passed + #failures))
	for _, message in ipairs(failures) do
		warn("   - " .. message)
	end
end
