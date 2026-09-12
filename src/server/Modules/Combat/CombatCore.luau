local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local Skills = require(ServerScriptService.Modules.Combat.Skills)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local BoardVfx = require(ServerScriptService.Modules.View.BoardVfx)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)

local CombatCore = {}

local PROMOTION_HEXES = MatchQuery.PROMOTION_HEXES
local IsFree = MatchQuery.IsFree
local GetHeroAt = MatchQuery.GetHeroAt
local GetAlliesInRange = MatchQuery.GetAlliesInRange
local GetEnemiesInRange = MatchQuery.GetEnemiesInRange
local HasSkill = MatchQuery.HasSkill
local FindStatusEffect = MatchQuery.FindStatusEffect
local ActiveShieldOf = MatchQuery.ActiveShieldOf
local FindNearestFreeHex = MatchQuery.FindNearestFreeHex

local CreateHero

function CombatCore.Bind(deps)
	CreateHero = deps.CreateHero
end

-- ===================== SKILLS =====================
local function TriggerSkills(match, hero, triggerName, target, isCounterAttack, ctx)
	if not hero.isAlive and triggerName ~= "onDie" then return end

	for _, key in ipairs(hero.abilities) do
		local skill = Skills[key]
		if skill and skill.apply and table.find(skill.triggers, triggerName) then
			local scope = ctx or {}
			scope.hero = hero
			scope.target = target
			scope.isCounterAttack = isCounterAttack or false
			scope.trigger = triggerName
			scope.api = setmetatable({
				Effect = function(target, variant)
					HeroView.PlaySkillEffect(target, variant or key)
				end,

				ApplyStatusEffect = function(target, effect)
					effect.source = effect.source or hero
					match.skillApi.ApplyStatusEffect(target, effect)
				end,
			}, { __index = match.skillApi })

			local ok, err = pcall(skill.apply, scope)
			if not ok then
				warn(("Skill %s falhou em %s: %s"):format(key, hero.name, tostring(err)))
			end
			HeroView.UpdateStats(hero)
		end
	end
end

local function AnnounceArrival(match, arrival)
	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(match, other, "onMove", nil, false, { movedHero = arrival })
		end
	end
end

local ApplyDamage, KillHero, IncreaseAttack, RemoveStatusEffect

local function RaisePendingGrave(match, hero)
	local hexId = FindNearestFreeHex(match, hero.graveHex or hero.position, PROMOTION_HEXES)
	if not hexId then return end

	hero.gravePending = false
	hero.graveHitsLeft = GameConfig.GRAVE_HITS
	hero.graveDestroyed = false
	hero.position = hexId
	match.occupied[hexId] = hero

	HeroView.CreateGrave(hero)
end

local function ResolvePendingGraves(match)
	for _, hero in pairs(match.heroes) do
		if hero.gravePending then
			local sobrouPedaco = false
			for _, other in pairs(match.heroes) do
				if other.isAlive and other.graveOwner == hero then
					sobrouPedaco = true
					break
				end
			end

			if not sobrouPedaco then
				RaisePendingGrave(match, hero)
			end
		end
	end
end

local LogEvent = MatchLog.Event
local RootOf = MatchLog.RootOf
local Tally = MatchLog.Tally

local function CloseShield(match, effect, key)
	local source = effect and effect.source
	if not source then return end

	Tally(source, key)
	Tally(source, "shieldsEnded")
	Tally(source, "shieldLifetimeTurnSum",
		math.max(0, (match.turn and match.turn.number or 0) - (effect.grantedTurn or 0)))
end

function KillHero(match, hero, attacker, sourceKey)
	hero.isAlive = false

	CloseShield(match, FindStatusEffect(hero, "shield"), "shieldExpiredOrRemoved")

	LogEvent(match, "death", hero.sideIndex, attacker and attacker ~= hero
		and ("%s derrubou %s"):format(attacker.name, hero.name)
		or ("%s caiu"):format(hero.name))

	if attacker and attacker ~= hero and attacker.stats and not hero.summoner then
		attacker.stats.kills += 1
		if attacker.frenzyActive then Tally(attacker, "killsDuringFrenzy") end
		if attacker.summoner then Tally(attacker, "summonKills") end
	end

	if hero.summoner then
		Tally(hero, "summonDeaths")
	elseif MatchQuery.HasSkill(hero, "frenzy") then
		Tally(hero, hero.frenzyActive and "deathsAfterFrenzy" or "deathsBeforeFrenzy")
	end

	TriggerSkills(match, hero, "onDie")

	if attacker and attacker ~= hero then
		TriggerSkills(match, attacker, "onKill", hero)
	end

	if match.deferDeathTriggers then
		table.insert(match.pendingDeathTriggers, hero)
	else
		for _, other in pairs(match.heroes) do
			if other.isAlive then
				TriggerSkills(match, other, "onAnyDeath", nil, false, { deadHero = hero })
			end
		end
	end
	if hero.noGrave then
		hero.graveDestroyed = true
		hero.graveHitsLeft = 0

		if match.occupied[hero.position] == hero then
			match.occupied[hero.position] = nil
		end

		if not hero.gravePending then
			HeroView.PlayAnimation(hero, "die")
		end

		HeroView.Destroy(hero)
	else
		if hero.graveOwner then
			hero.graveDestroyed = true
			hero.graveHitsLeft = 0

			hero.graveOwner.graveHex = hero.position

			if match.occupied[hero.position] == hero then
				match.occupied[hero.position] = nil
			end
			HeroView.PlayAnimation(hero, "die")
			HeroView.Destroy(hero)
		else
			hero.graveHitsLeft = GameConfig.GRAVE_HITS
			hero.graveDestroyed = false

			if PROMOTION_HEXES[hero.position] then
				local destino = FindNearestFreeHex(match, hero.position)
				if destino then
					match.occupied[hero.position] = nil
					hero.position = destino
					match.occupied[destino] = hero
				end
			end

			HeroView.PlayAnimation(hero, "die")
			HeroView.Destroy(hero)
			HeroView.CreateGrave(hero)
		end
	end

	ResolvePendingGraves(match)

	local fallen = hero.graveOwner or hero
	if attacker and attacker ~= hero and not fallen.summoner and not fallen.gravePending then
		match.finisher = {
			dataId = attacker.dataId,
			name = attacker.name,
			ownerId = attacker.ownerId,
			sideIndex = attacker.sideIndex,
			victim = fallen.name,
			hex = attacker.position,
		}
	end

	match.lastDeath = {
		hex = hero.position,
		name = hero.name,
		dataId = hero.dataId,
		ownerId = hero.ownerId,
		sideIndex = hero.sideIndex,
		sourceKey = sourceKey,
		killer = attacker and attacker ~= hero and {
			dataId = attacker.dataId,
			name = attacker.name,
			ownerId = attacker.ownerId,
			sideIndex = attacker.sideIndex,
			hex = attacker.position,
		} or nil,
		at = os.clock(),
	}

	if hero.deathHold then
		local wasBusy = match.busy
		match.busy = true
		task.wait(hero.deathHold)
		match.busy = wasBusy
	end
end

local DAMAGE_SOURCES = {
	voltChain = "corrente elétrica",
	poison = "veneno",
	flame = "fogo",
	suddenDeath = "Morte Súbita",
	graveCurse = "maldição do túmulo",
	summonerFell = "perder quem a invocou",
}

local function ConsumeShield(match, hero, attacker, amount)
	if not attacker then return false end

	local effect = FindStatusEffect(hero, "shield")
	if not effect then return false end

	RemoveStatusEffect(match, hero, "shield")
	hero.shieldJustBroke = true
	HeroView.SetShieldAura(hero, false)
	HeroView.PlaySkillEffect(hero, "aegisBreak")
	HeroView.Say(hero, "BLOQUEADO", "absorb")

	CloseShield(match, effect, "shieldBlocks")
	Tally(effect.source, "damageBlockedByShield", amount or 0)

	LogEvent(match, "status", hero.sideIndex,
		("O escudo de %s bloqueou %d de dano de %s"):format(hero.name, amount or 0, attacker.name))
	return true
end

function ApplyDamage(match, hero, amount, attacker, isCounterAttack, credit, sourceKey)
	if not hero.isAlive then return end

	if ConsumeShield(match, hero, attacker, amount) then return end

	for _, key in ipairs(hero.abilities) do
		local skill = Skills[key]
		if skill and skill.modifyIncomingDamage then
			amount = skill.modifyIncomingDamage(amount, {
				hero = hero, attacker = attacker, isCounterAttack = isCounterAttack or false,
			})
		end
	end

	for _, ally in ipairs(GetAlliesInRange(match, hero, 1)) do
		for _, key in ipairs(ally.abilities) do
			local skill = Skills[key]
			if skill and skill.modifyIncomingDamageNearby then
				local before = amount
				amount = skill.modifyIncomingDamageNearby(amount, {
					hero = hero, ally = ally, attacker = attacker, isCounterAttack = isCounterAttack or false,
				})

				local absorbed = before - amount
				if absorbed > 0 then
					HeroView.Say(ally, "+" .. tostring(absorbed), "absorb")
				end
			end

			if skill and skill.attackFromNearbyHit then
				local bonus = skill.attackFromNearbyHit({
					hero = hero, ally = ally, attacker = attacker,
				}) or 0

				if bonus > 0 then
					local effect = FindStatusEffect(ally, key)
					if not effect then
						effect = { type = key, duration = math.huge, attackBonus = 0 }
						table.insert(ally.statusEffects, effect)
					end

					effect.attackBonus += bonus
					IncreaseAttack(match, ally, bonus)
				end
			end
		end
	end

	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == "wound" then amount += 1 end
	end

	local landed = math.min(amount, math.max(hero.currentHp, 0))
	local author = attacker or credit
	hero.stats.taken += landed
	if author and author.stats then
		author.stats.dealt += landed
		author.stats.biggestHit = math.max(author.stats.biggestHit, landed)
		if author.frenzyActive then Tally(author, "frenzyDamage", landed) end
		if author.summoner then Tally(author, "summonDamage", landed) end
	end

	hero.currentHp -= amount
	HeroView.UpdateStats(hero)

	HeroView.PlayAnimation(hero, "hit", attacker == nil)
	HeroView.Say(hero, "-" .. tostring(amount), "damage")

	local sourceName = sourceKey and DAMAGE_SOURCES[sourceKey]

	LogEvent(match, "damage", attacker and attacker.sideIndex or hero.sideIndex,
		attacker and ("%s causou %d de dano em %s"):format(attacker.name, amount, hero.name)
		or sourceName and ("%s sofreu %d de dano de %s"):format(hero.name, amount, sourceName)
		or ("%s sofreu %d de dano do cenário"):format(hero.name, amount))

	if hero.currentHp <= 0 then
		KillHero(match, hero, attacker, sourceKey)
	else
		TriggerSkills(match, hero, "onDamage", attacker, isCounterAttack)
	end

end

local function Heal(match, hero, amount, source)
	if not hero.isAlive then return 0 end

	local before = hero.currentHp
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)

	local healer = source or hero
	if healer.stats then
		healer.stats.healed += (hero.currentHp - before)
	end

	if hero.frenzyActive then
		Tally(hero, "frenzyHealing", hero.currentHp - before)
	end

	HeroView.UpdateStats(hero)
	HeroView.PlayHealSound(hero)
	HeroView.Say(hero, "+" .. tostring(amount), "heal")

	local gained = hero.currentHp - before
	if gained > 0 then
		LogEvent(match, "heal", healer.sideIndex, healer == hero
			and ("%s recuperou %d de vida"):format(hero.name, gained)
			or ("%s curou %d em %s"):format(healer.name, gained, hero.name))
	end

	return gained
end

function IncreaseAttack(match, hero, amount)
	hero.attack += amount
	HeroView.UpdateStats(hero)
	HeroView.Say(hero, (amount > 0 and "+" or "") .. tostring(amount) .. " ATK", amount > 0 and "buff" or "debuff")

	LogEvent(match, "buff", hero.sideIndex, amount > 0
		and ("%s ganhou %d de ataque (agora %d)"):format(hero.name, amount, hero.attack)
		or ("%s perdeu %d de ataque (agora %d)"):format(hero.name, -amount, hero.attack))
end

local CC_EFFECTS = { paralysis = true, freeze = true }

local function AllowsReaction(attacker)
	for _, key in ipairs(attacker.abilities) do
		local skill = Skills[key]
		if skill and skill.suppressesReaction and skill.suppressesReaction(attacker) then
			return false
		end
	end
	return true
end

local function IsDisabled(hero)
	return hero ~= nil and FindStatusEffect(hero, "paralysis") ~= nil
end

local REACTION_BLOCKERS = { paralysis = true, freeze = true }

local function CanReact(hero, attacker)
	if not (hero and hero.isAlive) then return false end

	for effectType in pairs(REACTION_BLOCKERS) do
		if FindStatusEffect(hero, effectType) then return false end
	end

	return AllowsReaction(attacker)
end

local EFFECT_NAMES = {
	poison = "envenenado",
	paralysis = "paralisado",
	freeze = "congelado",
	wound = "ferido",
	vengeance = "com o sangue fervendo pelos aliados",
}

local function ApplyStatusEffect(match, hero, effect)
	if hero.frenzyActive and GameConfig.IsNegativeEffect(effect.type) then
		return
	end

	if GameConfig.IsNegativeEffect(effect.type)
		and (hero.shieldJustBroke or FindStatusEffect(hero, "shield")) then
		HeroView.Say(hero, "PROTEGIDO", "absorb")
		return
	end

	for index = #hero.statusEffects, 1, -1 do
		local previous = hero.statusEffects[index]
		if previous.type == effect.type then
			-- Trocar um efeito DEVOLVE o que ele emprestava. Sem isto o bônus do
			-- antigo sumia da lista sem nunca voltar pra ficha e virava
			-- permanente — o herói que quebrava dois barris no mesmo mapa (o
			-- Deserto tem quatro objetos) ficava com +1 de ataque pra sempre.
			if previous.attackBonus then
				IncreaseAttack(match, hero, -previous.attackBonus)
			end
			table.remove(hero.statusEffects, index)
		end
	end

	table.insert(hero.statusEffects, effect)
	HeroView.UpdateStats(hero)

	if CC_EFFECTS[effect.type] and effect.source and effect.source.stats then
		RootOf(effect.source).stats.ccApplied += 1
	end

	local nome = EFFECT_NAMES[effect.type]
	if nome then
		LogEvent(match, "status", hero.sideIndex,
			("%s ficou %s por %d turno(s)"):format(hero.name, nome, effect.duration or 0))
	end
end

local function ClearStatusEffects(match, hero)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.attackBonus then
			IncreaseAttack(match, hero, -effect.attackBonus)
		end
	end

	hero.statusEffects = {}
	HeroView.UpdateStats(hero)
end

local function ClearNegativeEffects(hero)
	local remaining = {}
	local removed = {}

	for _, effect in ipairs(hero.statusEffects) do
		if GameConfig.IsNegativeEffect(effect.type) then
			table.insert(removed, effect.type)
		else
			table.insert(remaining, effect)
		end
	end

	if #removed == 0 then return removed end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
	return removed
end

local function ProcessStatusEffects(match, hero, ownTurnEnding)
	local remaining = {}

	for _, effect in ipairs(hero.statusEffects) do
		if effect.permanent then
			table.insert(remaining, effect)
			continue
		end

		if not (ownTurnEnding or effect.ticksEveryTurn) then
			table.insert(remaining, effect)
			continue
		end

		if effect.appliedTurnToken == match.turnToken then
			table.insert(remaining, effect)
			continue
		end

		if effect.damagePerTurn then
			ApplyDamage(match, hero, effect.damagePerTurn, nil, false, effect.source, effect.type)
		end
		if effect.duration > 1 then
			effect.duration -= 1
			table.insert(remaining, effect)
		elseif effect.attackBonus then
			IncreaseAttack(match, hero, -effect.attackBonus)
		end
	end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
end

local function LightFlame(match, hexId, hero)
	if not HexGrid.Exists(hexId) then return end

	match.flames[hexId] = {
		ownerId = hero.ownerId,
		source = hero,
		duration = GameConfig.FLAME_DURATION,
		appliedTurnToken = match.turnToken,
	}
	BoardVfx.CreateFlame(match.view, hexId, hero.sideIndex)
end

local function ClearFlame(match, hexId)
	if not match.flames[hexId] then return end
	match.flames[hexId] = nil
	BoardVfx.DestroyFlame(match.view, hexId)
end

local function TickFlames(match, endingOwner)
	for hexId, flame in pairs(match.flames) do
		if flame.ownerId == endingOwner and flame.appliedTurnToken ~= match.turnToken then
			if flame.duration > 1 then
				flame.duration -= 1
			else
				ClearFlame(match, hexId)
			end
		end
	end
end

local function ConsumeFlame(match, hero, hexId)
	local flame = match.flames[hexId]
	if not flame then return false, false end

	BoardVfx.PlayFlameHit(match.view, hexId)

	local own = flame.ownerId == hero.ownerId
	if not own then
		ApplyDamage(match, hero, GameConfig.FLAME_DAMAGE, nil, false, flame.source, "flame")
	end

	ClearFlame(match, hexId)
	return true, own
end

local function ForceMove(match, hero, hexId)
	if not IsFree(match, hexId) then return false end

	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	HeroView.SetPosition(hero, hexId)
	ConsumeFlame(match, hero, hexId)
	return true
end

function RemoveStatusEffect(match, hero, effectType)
	for index = #hero.statusEffects, 1, -1 do
		local effect = hero.statusEffects[index]
		if effect.type == effectType then
			table.remove(hero.statusEffects, index)
			if effect.attackBonus then
				IncreaseAttack(match, hero, -effect.attackBonus)
			end
		end
	end
	HeroView.UpdateStats(hero)
end

local function Electrify(match, victim, origin)
	Tally(origin, "charges")
	local existing = FindStatusEffect(victim, "charge")
	local stacks = (existing and existing.stacks or 0) + 1

	if stacks >= GameConfig.VOLT_CHARGES_TO_PARALYZE then
		RemoveStatusEffect(match, victim, "charge")
		ApplyStatusEffect(match, victim, {
			type = "paralysis",
			duration = GameConfig.PARALYSIS_DURATION,
			appliedTurnToken = match.turnToken,
		})
		Tally(origin, "paralysis")
		HeroView.Say(victim, "PARALISADO", "debuff")
	else
		ApplyStatusEffect(match, victim, {
			type = "charge",
			duration = GameConfig.VOLT_CHARGE_DURATION,
			stacks = stacks,
			appliedTurnToken = match.turnToken,
		})
		HeroView.Say(victim, ("%d/%d"):format(stacks, GameConfig.VOLT_CHARGES_TO_PARALYZE), "debuff")
	end
end

-- ===== ESCOLHA DE ALIADO =====
-- A Égide da Kira estreou este arranjo e a Troca de Sombra do Shin entrou nele:
-- o herói selecionado revela, junto das casas de passo e dos inimigos no
-- alcance, a lista de ALIADOS em que clicar faz outra coisa. O `kind` é a única
-- diferença entre as duas — quem pode ser escolhido, e o que acontece no clique.
--
-- Uma oferta por vez e por turno, fechada no uso e zerada no BeginTurn: é o que
-- impede a mesma seleção de valer duas vezes sem inventar contador de ação.
local ALLY_CHOICE = {
	shield = {
		Options = function(match, hero)
			local options = {}
			for _, ally in ipairs(GetAlliesInRange(match, hero, 1)) do
				if not FindStatusEffect(ally, "shield") then
					table.insert(options, ally.uid)
				end
			end
			return options
		end,

		Blocked = function(match, hero)
			local protected = ActiveShieldOf(match, hero)
			if not protected then return nil end

			Tally(hero, "shieldUnavailableAttempts")
			return ("%s ainda protege %s — a Égide só volta quando esse escudo cair")
				:format(hero.name, protected.name), "ESCUDO ATIVO"
		end,
	},

	swap = {
		-- Sem alcance nenhum, e é o ponto da habilidade. Fora invocado, que é
		-- peça de outro herói, e o próprio Shin, que o GetAlliesInRange já tira.
		Options = function(match, hero)
			local options = {}
			for _, ally in ipairs(GetAlliesInRange(match, hero, math.huge)) do
				if not ally.summoner then
					table.insert(options, ally.uid)
				end
			end
			return options
		end,
	},
}

local function AllyOptionsFor(match, hero, kind)
	local spec = kind and ALLY_CHOICE[kind]
	if not (spec and hero and hero.isAlive) then return {} end

	local options = spec.Options(match, hero)
	table.sort(options)
	return options
end

-- UMA OFERTA POR HERÓI, e não uma por partida. Era um slot só, e como a Égide
-- da Kira e a Troca do Shin abrem as duas no mesmo onTurnStart, quem disparasse
-- primeiro tomava o lugar e a habilidade do outro sumia sem aviso naquele turno.
--
-- A infraestrutura continua compartilhada (mesma lista de alvos, mesmo destaque,
-- mesmo clique, mesma limpeza no BeginTurn); o que deixou de ser compartilhado é
-- o ESTADO. Cada herói tem a própria entrada, some sozinha quando é usada, e o
-- uso de uma não encosta na outra.
local function OfferAllyChoice(match, hero, kind)
	if not match.turn or match.turn.ownerId ~= hero.ownerId then return end
	if match.pendingAlly[hero.uid] then return end

	local spec = ALLY_CHOICE[kind]
	if not spec then return end

	if spec.Blocked then
		local reason, shout = spec.Blocked(match, hero)
		if reason then
			HeroView.Say(hero, shout, "absorb")
			LogEvent(match, "skill", hero.sideIndex, reason)
			return
		end
	end

	match.pendingAlly[hero.uid] = {
		ownerId = hero.ownerId,
		sourceUid = hero.uid,
		kind = kind,
	}
end

local function IsChainTarget(origin, occupant)
	return occupant ~= nil
		and occupant ~= origin
		and occupant.isAlive == true
		and occupant.ownerId ~= nil
		and occupant.ownerId ~= origin.ownerId
end

local function ConductsChain(origin, occupant)
	if occupant ~= nil and occupant.isBarrel == true then return true end
	return IsChainTarget(origin, occupant)
end

local WeakPointHunters = MatchQuery.WeakPointHunters
local WeakPointOf = MatchQuery.WeakPointOf

local function RerollWeakPoint(hero)
	hero.weakPoint = HexGrid.RandomDirection(hero.weakPoint)
end


local function ChainHits(match, hero)
	if not match.turn then return nil end
	return match.turn.weakChain[hero.uid]
end

local function RecordChainHit(match, hero, target)
	if not match.turn then return end

	local hits = match.turn.weakChain[hero.uid]
	if not hits then
		hits = {}
		match.turn.weakChain[hero.uid] = hits
	end
	hits[target.uid] = true
end

local function BuildSkillApi(match)
	return {
		ApplyDamage = function(hero, amount, attacker, isCounterAttack, sourceKey)
			ApplyDamage(match, hero, amount, attacker, isCounterAttack, nil, sourceKey)
		end,
		Heal = function(hero, amount, source) return Heal(match, hero, amount, source) end,
		Tally = Tally,
		TurnToken = function() return match.turnToken end,
		TurnNumber = function() return match.turn and match.turn.number or 0 end,
		IncreaseAttack = function(hero, amount) IncreaseAttack(match, hero, amount) end,
		GetHeroAt = function(hexId) return GetHeroAt(match, hexId) end,
		GetAlliesInRange = function(hero, range) return GetAlliesInRange(match, hero, range) end,
		GetEnemiesInRange = function(hero, range) return GetEnemiesInRange(match, hero, range) end,
		GetLineBeyond = HexGrid.GetLineBeyond,
		Distance = HexGrid.Distance,
		IsFree = function(hexId) return IsFree(match, hexId) end,
		ForceMove = function(hero, hexId) return ForceMove(match, hero, hexId) end,
		FindStatusEffect = FindStatusEffect,

		ApplyStatusEffect = function(hero, effect)
			effect.appliedTurnToken = match.turnToken
			ApplyStatusEffect(match, hero, effect)
		end,

		ResolveTogether = function(fn)
			if match.deferDeathTriggers then return fn() end

			match.deferDeathTriggers = true
			match.pendingDeathTriggers = {}

			local ok, err = pcall(fn)

			match.deferDeathTriggers = false
			local pending = match.pendingDeathTriggers
			match.pendingDeathTriggers = {}

			for _, dead in ipairs(pending) do
				for _, other in pairs(match.heroes) do
					if other.isAlive then
						TriggerSkills(match, other, "onAnyDeath", nil, false, { deadHero = dead })
					end
				end
			end

			if not ok then warn("ResolveTogether: " .. tostring(err)) end
		end,

		Electrify = function(victim, origin) Electrify(match, victim, origin) end,
		Say = function(hero, text, kind) HeroView.Say(hero, text, kind) end,

		ChainFrom = function(origin, hexId)
			local visited = { [hexId] = true }
			local depth = { [hexId] = 0 }
			local queue = { hexId }
			local edges = { { from = origin.position, to = hexId, depth = 0 } }
			local hit = {}

			while #queue > 0 do
				local current = table.remove(queue, 1)
				for _, neighbor in ipairs(HexGrid.GetNeighbors(current)) do
					local occupant = match.occupied[neighbor.id]
					if not visited[neighbor.id] and ConductsChain(origin, occupant) then
						visited[neighbor.id] = true
						depth[neighbor.id] = depth[current] + 1
						table.insert(queue, neighbor.id)
						table.insert(edges, {
							from = current,
							to = neighbor.id,
							depth = depth[neighbor.id],
						})
						if IsChainTarget(origin, occupant) then
							table.insert(hit, occupant)
						end
					end
				end
			end

			BoardVfx.PlayChainArcs(match.view, edges)

			for _, victim in ipairs(hit) do
				if victim.isAlive then
					HeroView.PlaySkillEffect(victim, "voltChain")
					Tally(origin, "chainHits")
					Tally(origin, "chainDamage", math.min(GameConfig.VOLT_CHAIN_DAMAGE, math.max(victim.currentHp, 0)))
					ApplyDamage(match, victim, GameConfig.VOLT_CHAIN_DAMAGE, origin, false, nil, "voltChain")
				end
				if victim.isAlive then Electrify(match, victim, origin) end
			end

			return #hit
		end,


		RemoveStatusEffect = function(hero, effectType)
			for index = #hero.statusEffects, 1, -1 do
				local effect = hero.statusEffects[index]
				if effect.type == effectType then
					table.remove(hero.statusEffects, index)
					if effect.attackBonus then
						IncreaseAttack(match, hero, -effect.attackBonus)
					end
				end
			end
			HeroView.UpdateStats(hero)
		end,

		ClearStatusEffects = function(hero) ClearStatusEffects(match, hero) end,
		ClearNegativeEffects = ClearNegativeEffects,
		SetFrenzyAura = function(hero, on) HeroView.SetFrenzyAura(hero, on) end,

		CountAllies = function(hero)
			local living, total = 0, 0
			for _, other in pairs(match.heroes) do
				if other ~= hero and other.ownerId == hero.ownerId then
					total += 1
					if other.isAlive then living += 1 end
				end
			end
			return living, total
		end,
		CountDeaths = function()
			local dead = 0
			for _, other in pairs(match.heroes) do
				if not other.isAlive and not other.summoner then dead += 1 end
			end
			return dead
		end,
		PlaySkillSound = function(key) HeroView.PlaySkillSound(key, match.view) end,

		LightFlame = function(hexId, hero) LightFlame(match, hexId, hero) end,

		IceStorm = function(hero)
			BoardVfx.PlayIceStorm(match.view, hero.position)
		end,

		PoisonBomb = function(hero)
			BoardVfx.PlayPoisonBomb(match.view, hero.position)
		end,

		FireCircle = function(hero)
			BoardVfx.PlayFireCircle(match.view, hero.position)
		end,

		FlashAttackRange = function(hero)
			local hexIds = {}
			for _, hex in ipairs(HexGrid.GetNeighbors(hero.position)) do
				table.insert(hexIds, hex.id)
			end
			BoardVfx.FlashAttackRange(match.view, hexIds)
		end,

		Summon = function(origin, dataId)
			local hexId = FindNearestFreeHex(match, origin.position)
			if not hexId then return nil end

			local minion = CreateHero(match, dataId, origin.ownerId, hexId)
			if minion then
				minion.summoner = origin
				AnnounceArrival(match, minion)
			end
			return minion
		end,

		IsMyTurn = function(hero)
			return match.turn ~= nil and match.turn.ownerId == hero.ownerId
		end,

		GetAllyByData = function(hero, dataId)
			for _, other in pairs(match.heroes) do
				if other.ownerId == hero.ownerId and other.dataId == dataId then
					return other
				end
			end
			return nil
		end,

		SuppressGrave = function(hero)
			hero.noGrave = true
			if match.occupied[hero.position] == hero then
				match.occupied[hero.position] = nil
			end
		end,

		DeferGrave = function(hero, minions)
			hero.gravePending = true
			for _, minion in ipairs(minions or {}) do
				minion.graveOwner = hero
			end
		end,

		OfferAllyChoice = function(hero, kind) OfferAllyChoice(match, hero, kind) end,

		RecordChainHit = function(hero, target) RecordChainHit(match, hero, target) end,
		RerollWeakPoint = RerollWeakPoint,
		WeakPointDirection = HexGrid.DirectionBetween,
		DirectionName = HexGrid.DirectionName,
		BreakWeakPoint = function(hero) HeroView.BreakWeakPoint(hero) end,

		HasAttacked = function(hero)
			return match.turn ~= nil and match.turn.attacked[hero.uid] == true
		end,

		GrantExtraAction = function(hero, includeAttack)
			if not match.turn then return end
			match.turn.bonusMove[hero.uid] = true
			if includeAttack then
				match.turn.attacked[hero.uid] = nil
			end
		end,
	}
end

local function MarkAttacked(match, hero)
	match.turn.attacked[hero.uid] = true

	if GameConfig.HasAgility(hero) and match.turn.ownerId == hero.ownerId then
		match.turn.bonusMove[hero.uid] = true
	end
end

CombatCore.DAMAGE_SOURCES = DAMAGE_SOURCES

CombatCore.KillHero = KillHero
CombatCore.TriggerSkills = TriggerSkills
CombatCore.AnnounceArrival = AnnounceArrival
CombatCore.ApplyDamage = ApplyDamage
CombatCore.Heal = Heal
CombatCore.IncreaseAttack = IncreaseAttack
CombatCore.CanReact = CanReact
CombatCore.IsDisabled = IsDisabled
CombatCore.ApplyStatusEffect = ApplyStatusEffect
CombatCore.ProcessStatusEffects = ProcessStatusEffects
CombatCore.TickFlames = TickFlames
CombatCore.ConsumeFlame = ConsumeFlame
CombatCore.ForceMove = ForceMove
CombatCore.AllyOptionsFor = AllyOptionsFor
CombatCore.ChainHits = ChainHits
CombatCore.BuildSkillApi = BuildSkillApi
CombatCore.MarkAttacked = MarkAttacked

return CombatCore
