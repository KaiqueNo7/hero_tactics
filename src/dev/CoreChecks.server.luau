local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)
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
	local log = { damage = {}, heals = {}, flames = {}, status = {} }
	local api = {
		ApplyDamage = function(hero, amount)
			table.insert(log.damage, { hero = hero, amount = amount })
		end,
		Heal = function(hero, amount)
			table.insert(log.heals, { hero = hero, amount = amount })
		end,
		IncreaseAttack = function(hero, amount) hero.attack += amount end,
		Effect = function() end,
		PlaySkillSound = function() end,
		FlashAttackRange = function() end,
		IceStorm = function() end,
		GetLineBeyond = HexGrid.GetLineBeyond,
		GetHeroAt = function() return nil end,
		GetEnemiesInRange = function() return {} end,
		GetAlliesInRange = function() return {} end,
		IsFree = function() return true end,
		ForceMove = function() return true end,
		CountAllies = function() return 0, 0 end,
		CountDeaths = function() return 0 end,
		LightFlame = function(hexId) table.insert(log.flames, hexId) end,
		FindStatusEffect = MatchQuery.FindStatusEffect,
		ApplyStatusEffect = function(hero, effect)
			table.insert(hero.statusEffects, effect)
			table.insert(log.status, effect)
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
	check("Sprint anda mais", MatchQuery.MoveRangeOf(sprinter) == GameConfig.SPRINT_MOVE_RANGE)
	table.insert(sprinter.statusEffects, { type = "freeze", duration = 2 })
	check("gelo limita o Sprint", MatchQuery.MoveRangeOf(sprinter) == GameConfig.FREEZE_MOVE_RANGE)

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
end

if #failures == 0 then
	print(("CoreChecks: %d verificacoes, tudo certo."):format(passed))
else
	warn(("CoreChecks: %d falha(s) em %d verificacoes:"):format(#failures, passed + #failures))
	for _, message in ipairs(failures) do
		warn("   - " .. message)
	end
end
