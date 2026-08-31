local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local Arenas = require(ReplicatedStorage.Modules.Arenas)
local Skills = require(ServerScriptService.Modules.Skills)

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

local function FakeApi()
	local log = { damage = {}, heals = {}, flames = {}, status = {}, summons = {}, board = {} }
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
		RemoveStatusEffect = function(hero, effectType)
			for index = #hero.statusEffects, 1, -1 do
				local effect = hero.statusEffects[index]
				if effect.type == effectType then
					table.remove(hero.statusEffects, index)
					if effect.attackBonus then hero.attack -= effect.attackBonus end
				end
			end
		end,
		ApplyStatusEffect = function(hero, effect)
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


do
	local ahead = lineB and lineC and HexGrid.GetLineBeyond(lineB, lineC, 1)
	local lineD = ahead and ahead[1]
	local behindTarget = lineD and HexGrid.GetLineBeyond(lineC, lineD, 1)
	local behindShooter = lineA and lineB and HexGrid.GetLineBeyond(lineB, lineA, 1)

	if lineD then
		local lateral
		for _, neighbor in ipairs(HexGrid.GetNeighbors(lineB)) do
			local span = HexGrid.Distance(lineA, neighbor.id) + HexGrid.Distance(neighbor.id, lineD)
			if span > HexGrid.Distance(lineA, lineD) then
				lateral = neighbor.id
				break
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
			check("Taunt atras do atirador nao bloqueia",
				MatchQuery.TauntBlocks(board, shooter, victim) == nil, behindShooter[1])
		end

		if lateral then
			put(wall, lateral)
			check("Taunt fora do corredor nao bloqueia",
				MatchQuery.TauntBlocks(board, shooter, victim) == nil, lateral)
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
				if occupant and occupant ~= origin and not visited[neighbor.id] then
					visited[neighbor.id] = true
					table.insert(queue, neighbor.id)
					if occupant.isAlive and occupant.ownerId ~= origin.ownerId then
						table.insert(hit, occupant)
					end
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
				if occupant and occupant ~= origin and not visited[neighbor.id] then
					visited[neighbor.id] = true
					table.insert(queue, neighbor.id)
					if occupant.isAlive and occupant.ownerId ~= origin.ownerId then
						table.insert(hit, occupant)
					end
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

if #failures == 0 then
	print(("CoreChecks: %d verificacoes, tudo certo."):format(passed))
else
	warn(("CoreChecks: %d falha(s) em %d verificacoes:"):format(#failures, passed + #failures))
	for _, message in ipairs(failures) do
		warn("   - " .. message)
	end
end
