--[[
	MatchManager.lua
	ModuleScript — ServerScriptService/Modules/MatchManager

	Regras da partida: draft alternado, turnos, combate, skills e o bot.

	VÁRIAS PARTIDAS AO MESMO TEMPO
	Antes existia um único `match` de módulo — um jogo por servidor. Agora o
	módulo é um registro: cada partida é uma tabela própria, com o seu tabuleiro
	num slot de arena diferente (GameConfig.ArenaOrigin), suas pastas de heróis e
	túmulos, sua ocupação de casas e sua plateia de som. Toda função interna
	recebe o `match` em que está mexendo; nenhuma lê estado global. É isso que
	garante que uma partida não enxergue nem atrapalhe a outra.

	Cada jogador recebe o seu próprio snapshot, com `isMine`/`isMyTurn`/`winner`
	já do ponto de vista dele.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local Arenas = require(ReplicatedStorage.Modules.Arenas)
local Skills = require(ServerScriptService.Modules.Skills)
local HeroView = require(ServerScriptService.Modules.HeroView)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local LeaderboardService = require(ServerScriptService.Modules.LeaderboardService)
local ProgressionService = require(ServerScriptService.Modules.ProgressionService)
local HeroStatsService = require(ServerScriptService.Modules.HeroStatsService)
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)
local Campaign = require(ReplicatedStorage.Modules.Campaign)
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)
local BotBrain = require(ServerScriptService.Modules.BotBrain)
local PROMOTION_HEXES = MatchQuery.PROMOTION_HEXES
local SideOf = MatchQuery.SideOf
local OpponentSide = MatchQuery.OpponentSide
local GetHeroAt = MatchQuery.GetHeroAt
local IsFree = MatchQuery.IsFree
local FreeChecker = MatchQuery.FreeChecker
local GetAlliesInRange = MatchQuery.GetAlliesInRange
local GetEnemiesInRange = MatchQuery.GetEnemiesInRange
local LivingHeroesOf = MatchQuery.LivingHeroesOf
local FindStatusEffect = MatchQuery.FindStatusEffect
local MoveRangeOf = MatchQuery.MoveRangeOf
local HasSkill = MatchQuery.HasSkill
local CanMove = MatchQuery.CanMove

local MatchUpdate = ReplicatedStorage.Remotes.MatchUpdate
local BoardReady = ReplicatedStorage.Remotes.BoardReady

local MatchManager = {}

-- ===== AJUSTE FINO =====
local BOT_ACTION_DELAY = 0.7
local COUNTER_ATTACK_DELAY = 0.4
local DODGE_CORE = Color3.fromRGB(190, 235, 255)
local DODGE_EDGE = Color3.fromRGB(70, 160, 255)

local BOT_ID = "BOT"
local BOT_ONE_ID = "BOT_A"

-- ===== REGISTRO DE PARTIDAS =====
local matches = {} -- [matchId] = match
local matchBySlot = {} -- [slot] = match
local nextMatchId = 0

-- declaradas cedo porque se chamam entre si
local BeginTurn, BotPlayTurn, BotPlaceOne, AdvancePlacement, CheckGameOver
local TryTriggerPromotion, AttackGrave, FindNearestFreeHex, EndMatch

-- O Estilhaçar do Golem invoca pela API das skills (BuildSkillApi), que é
-- montada bem antes do CreateHero existir no arquivo.
local CreateHero

-- ===================== ZONAS =====================
-- Casas de largada fixas, uma por coluna, na primeira fileira de cada lado.
local DEPLOY_ZONES = {
	{ "A6", "B7", "C6", "D7", "E6" },
	{ "A1", "B1", "C1", "D1", "E1" },
}

local function BuildDeployZone(hexIds)
	local zone = {}
	for _, hexId in ipairs(hexIds) do
		if HexGrid.Exists(hexId) then
			table.insert(zone, hexId)
		else
			warn("MatchManager: hex de largada inexistente: " .. hexId)
		end
	end
	return zone
end

-- ===================== LADOS =====================
local function SideOfPlayer(match, player)
	for _, side in ipairs(match.sides) do
		if side.player == player then return side end
	end
	return nil
end

-- Ponte entre o RemoteEvent (que só traz o Player) e a partida dele
local function MatchOfPlayer(player)
	if not player then return nil end
	for _, match in pairs(matches) do
		if SideOfPlayer(match, player) then return match end
	end
	return nil
end

-- ===================== CONSULTAS =====================
local function UnlockedIdsFor(player)
	return HeroUnlockService.GetPlayableIds(player)
end

local function AllHeroIds()
	local ids = {}
	for _, data in ipairs(HeroData.CATALOG) do
		ids[data.id] = true
	end
	return ids
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

local LOG_LIMIT = 400

local function LogEvent(match, kind, side, text)
	local log = match.log
	if not log then return end

	table.insert(log, {
		turn = match.turn and match.turn.number or 0,
		kind = kind,
		side = side,
		text = text,
	})

	if #log > LOG_LIMIT then
		table.remove(log, 1)
	end
end

function KillHero(match, hero, attacker)
	hero.isAlive = false

	LogEvent(match, "death", hero.sideIndex, attacker and attacker ~= hero
		and ("%s derrubou %s"):format(attacker.name, hero.name)
		or ("%s caiu"):format(hero.name))

	if attacker and attacker ~= hero and attacker.stats and not hero.summoner then
		attacker.stats.kills += 1
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
		if attacker and attacker ~= hero and not hero.summoner then
			match.finisher = {
				dataId = attacker.dataId,
				name = attacker.name,
				ownerId = attacker.ownerId,
				sideIndex = attacker.sideIndex,
				victim = hero.name,
				hex = attacker.position,
			}
		end

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

local function ConsumeShield(match, hero, attacker)
	if not attacker then return false end
	if not FindStatusEffect(hero, "shield") then return false end

	RemoveStatusEffect(match, hero, "shield")
	hero.shieldJustBroke = true
	HeroView.SetShieldAura(hero, false)
	HeroView.PlaySkillEffect(hero, "aegisBreak")
	HeroView.Say(hero, "BLOQUEADO", "absorb")

	LogEvent(match, "status", hero.sideIndex,
		("O escudo de %s bloqueou o golpe de %s"):format(hero.name, attacker.name))
	return true
end

function ApplyDamage(match, hero, amount, attacker, isCounterAttack, credit, sourceKey)
	if not hero.isAlive then return end

	if ConsumeShield(match, hero, attacker) then return end

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
		KillHero(match, hero, attacker)
	else
		TriggerSkills(match, hero, "onDamage", attacker, isCounterAttack)
	end

end

local function Heal(match, hero, amount, source)
	if not hero.isAlive then return end

	local before = hero.currentHp
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)

	local healer = source or hero
	if healer.stats then
		healer.stats.healed += (hero.currentHp - before)
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

local REJECTIONS = {
	NOT_YOUR_TURN = true,
	MOVE_OUT_OF_RANGE = true, ATTACK_OUT_OF_RANGE = true,
	OCCUPIED = true, INVALID_TARGET = true, INVALID_MOVE = true,
}

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

local function Reject(player, reason)
	if not (player and REJECTIONS[reason]) then return end
	local remote = ReplicatedStorage.Remotes:FindFirstChild("GameAction")
	if remote then remote:FireClient(player, "reject", reason) end
end

local function SetStandScale(player, scale)
	local character = player and player.Character
	if not character then return end
	pcall(function() character:ScaleTo(scale) end)
end

local function RootOf(hero)
	local root = hero
	while root.summoner do root = root.summoner end
	return root
end

local function Tally(hero, key, amount)
	if not (hero and hero.stats) then return end
	local root = RootOf(hero)
	root.stats.special[key] = (root.stats.special[key] or 0) + (amount or 1)
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
		if hero.statusEffects[index].type == effect.type then
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
	local removeu = false

	for _, effect in ipairs(hero.statusEffects) do
		if GameConfig.IsNegativeEffect(effect.type) then
			removeu = true
		else
			table.insert(remaining, effect)
		end
	end

	if not removeu then return end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
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
	HeroView.CreateFlame(match.view, hexId, hero.sideIndex)
end

local function ClearFlame(match, hexId)
	if not match.flames[hexId] then return end
	match.flames[hexId] = nil
	HeroView.DestroyFlame(match.view, hexId)
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

	HeroView.PlayFlameHit(match.view, hexId)

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

local function ShieldOptionsFor(match, hero)
	local options = {}
	if not (hero and hero.isAlive) then return options end

	for _, ally in ipairs(GetAlliesInRange(match, hero, 1)) do
		if not FindStatusEffect(ally, "shield") then
			table.insert(options, ally.uid)
		end
	end
	table.sort(options)
	return options
end

local function OfferShield(match, hero)
	if not match.turn or match.turn.ownerId ~= hero.ownerId then return end
	if match.pendingShield then return end

	match.pendingShield = {
		ownerId = hero.ownerId,
		sourceUid = hero.uid,
	}
end

local function IsChainTarget(origin, occupant)
	return occupant ~= nil
		and occupant ~= origin
		and occupant.isAlive == true
		and occupant.ownerId ~= nil
		and occupant.ownerId ~= origin.ownerId
end

local function WeakPointHunters(match)
	local hunters = nil

	for _, hero in pairs(match.heroes) do
		if hero.isAlive and HasSkill(hero, "weakPoint") then
			hunters = hunters or {}
			hunters[hero.ownerId] = true
		end
	end

	return hunters
end

local function WeakPointOf(hero, hunters)
	if not (hunters and hero.isAlive) or hero.stealth then return nil end
	for ownerId in pairs(hunters) do
		if ownerId ~= hero.ownerId then return hero.weakPoint end
	end
	return nil
end

local function RerollWeakPoint(hero)
	hero.weakPoint = math.random(HexGrid.DIRECTION_COUNT)
end

local function RefreshWeakPoints(match)
	local hunters = WeakPointHunters(match)

	for _, hero in pairs(match.heroes) do
		if hero.part and hero.part.Parent then
			HeroView.SetWeakPoint(hero, WeakPointOf(hero, hunters))
		end
	end
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
		Heal = function(hero, amount, source) Heal(match, hero, amount, source) end,
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
					if not visited[neighbor.id] and IsChainTarget(origin, occupant) then
						visited[neighbor.id] = true
						depth[neighbor.id] = depth[current] + 1
						table.insert(queue, neighbor.id)
						table.insert(edges, {
							from = current,
							to = neighbor.id,
							depth = depth[neighbor.id],
						})
						table.insert(hit, occupant)
					end
				end
			end

			HeroView.PlayChainArcs(match.view, edges)

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
			HeroView.PlayIceStorm(match.view, hero.position)
		end,

		PoisonBomb = function(hero)
			HeroView.PlayPoisonBomb(match.view, hero.position)
		end,

		FireCircle = function(hero)
			HeroView.PlayFireCircle(match.view, hero.position)
		end,

		FlashAttackRange = function(hero)
			local hexIds = {}
			for _, hex in ipairs(HexGrid.GetNeighbors(hero.position)) do
				table.insert(hexIds, hex.id)
			end
			HeroView.FlashAttackRange(match.view, hexIds)
		end,

		Summon = function(origin, dataId)
			local hexId = FindNearestFreeHex(match, origin.position)
			if not hexId then return nil end

			local minion = CreateHero(match, dataId, origin.ownerId, hexId)
			if minion then minion.summoner = origin end
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

		OfferShield = function(hero) OfferShield(match, hero) end,

		RecordChainHit = function(hero, target) RecordChainHit(match, hero, target) end,
		RerollWeakPoint = RerollWeakPoint,
		WeakPointDirection = HexGrid.DirectionBetween,

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

local function RematchWantedByOther(match, viewerId)
	for _, side in ipairs(match.sides) do
		if side.id ~= viewerId and match.rematch[side.id] then return true end
	end
	return false
end

local function TurnIsTimed(match)
	if GameConfig.TURN_TIME_LIMIT <= 0 or not match.turn then return false end
	if not match.vsBot then return true end

	local side = SideOf(match, match.turn.ownerId)
	return side ~= nil and side.isBot
end

local function TurnSecondsLeft(match)
	if not TurnIsTimed(match) then return nil end
	if match.turn.pausedLeft then return match.turn.pausedLeft end

	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

local function ReconnectSecondsLeft(match)
	if not match.suspendedAt then return nil end
	local elapsed = os.clock() - match.suspendedAt
	return math.max(0, math.ceil(GameConfig.RECONNECT_WINDOW - elapsed))
end

local function PlacementSecondsLeft(match)
	if match.phase ~= "placement" or not match.placementStartedAt then return nil end
	if GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return nil end

	local elapsed = os.clock() - match.placementStartedAt
	return math.max(0, math.floor(GameConfig.PLACEMENT_TIME_LIMIT - elapsed))
end

local function Snapshot(match, viewerId)
	local viewerSide = SideOf(match, viewerId)
	local opponent = OpponentSide(match, viewerId)
	local hunters = WeakPointHunters(match)

	local ordered = {}
	for _, hero in pairs(match.heroes) do
		table.insert(ordered, hero)
	end
	table.sort(ordered, function(a, b)
		if a.sideIndex ~= b.sideIndex then return a.sideIndex < b.sideIndex end
		return a.dataId < b.dataId
	end)

	local heroes = {}
	for _, hero in ipairs(ordered) do
		if hero.isAlive and hero.stealth and hero.ownerId ~= viewerId then
			table.insert(heroes, {
				uid = hero.uid,
				position = hero.position,
				isAlive = true,
				isMine = false,
				hidden = true,

				dataId = hero.dataId,
				name = hero.name,
				sideIndex = hero.sideIndex,
				currentHp = hero.currentHp,
				maxHp = hero.maxHp,
				attack = GameConfig.EffectiveAttack(hero),
				baseAttack = hero.baseAttack,
				ability = hero.ability,
			})
			continue
		end

		table.insert(heroes, {
			uid = hero.uid,
			dataId = hero.dataId,
			stealth = hero.stealth or nil,
			name = hero.name,
			position = hero.position,
			currentHp = hero.currentHp,
			maxHp = hero.maxHp,
			attack = GameConfig.EffectiveAttack(hero),
			baseAttack = hero.baseAttack,
			ability = hero.ability,
			attackRange = hero.attackRange,
			moveRange = MoveRangeOf(match, hero), -- já descontado o gelo
			isAlive = hero.isAlive,
			frozen = FindStatusEffect(hero, "freeze") ~= nil,
			poisonTurns = (FindStatusEffect(hero, "poison") or {}).duration or 0,
			shielded = FindStatusEffect(hero, "shield") ~= nil or nil,
			charge = (FindStatusEffect(hero, "charge") or {}).stacks or 0,
			paralyzed = FindStatusEffect(hero, "paralysis") ~= nil or nil,
			isMine = hero.ownerId == viewerId,
			sideIndex = hero.sideIndex,
			hasMoved = match.turn ~= nil and not CanMove(match, hero),
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,
			weakPoint = WeakPointOf(hero, hunters),
			graveHitsLeft = (not hero.isAlive) and hero.graveHitsLeft or nil,
			graveDestroyed = (not hero.isAlive) and hero.graveDestroyed or nil,
			summonOf = (hero.graveOwner or hero.summoner)
				and (hero.graveOwner or hero.summoner).uid or nil,
			sameBody = hero.graveOwner ~= nil or nil,
			stats = (match.phase == "finished") and {
				dealt = hero.stats.dealt,
				taken = hero.stats.taken,
				healed = hero.stats.healed,
				kills = hero.stats.kills,
				biggestHit = hero.stats.biggestHit,
			} or nil,
		})
	end

	local barrels = {}
	for _, barrel in pairs(match.barrels) do
		table.insert(barrels, {
			uid = barrel.uid,
			position = barrel.position,
			hitsLeft = barrel.hitsLeft,
		})
	end
	table.sort(barrels, function(a, b) return a.uid < b.uid end)

	local winner = nil
	if match.winner == "draw" then
		winner = "draw"
	elseif match.winner then
		winner = (match.winner == viewerId) and "win" or "loss"
	end

	local usedHeroIds = {}
	for dataId in pairs(match.usedHeroIds) do
		table.insert(usedHeroIds, dataId)
	end
	table.sort(usedHeroIds)

	local lockedHeroIds = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if not viewerSide.unlockedIds[data.id] then
			table.insert(lockedHeroIds, data.id)
		end
	end

	local finisher = nil
	if match.finisher then
		finisher = {
			dataId = match.finisher.dataId,
			name = match.finisher.name,
			victim = match.finisher.victim,
			final = match.finisher.final,
			sideIndex = match.finisher.sideIndex,
			hex = match.finisher.hex,
			isMine = match.finisher.ownerId == viewerId,
		}
	end

	local promotionSquares = {}
	for slotIndex, hexId in pairs(GameConfig.PROMOTION_HEX_FOR_SLOT) do
		local side = match.sides[slotIndex]
		local squareState
		if side and side.promotionUsed then
			squareState = "used"
		elseif match.turn and match.turn.number >= GameConfig.PROMOTION_UNLOCK_TURN then
			squareState = "active"
		else
			squareState = "inactive"
		end
		table.insert(promotionSquares, {
			hex = hexId,
			ownerSideIndex = slotIndex,
			mine = slotIndex == viewerSide.index,
			state = squareState,
		})
	end
	table.sort(promotionSquares, function(a, b) return a.hex < b.hex end)

	local pendingPromotion = nil
	if match.pendingPromotion and match.pendingPromotion.ownerId == viewerId then
		pendingPromotion = { options = match.pendingPromotion.options }
	end

	local pendingShield = nil
	if match.pendingShield and match.pendingShield.ownerId == viewerId then
		local source = match.heroes[match.pendingShield.sourceUid]
		local options = ShieldOptionsFor(match, source)

		if #options > 0 then
			pendingShield = { sourceUid = match.pendingShield.sourceUid, options = options }
		end
	end

	local summary = nil
	if match.phase == "finished" then
		local mvp, protector, biggest = nil, nil, nil

		for _, hero in pairs(match.heroes) do
			if hero.ownerId == viewerId then
				local stats = hero.stats

				if not mvp or stats.dealt > mvp.stats.dealt
					or (stats.dealt == mvp.stats.dealt and stats.kills > mvp.stats.kills) then
					mvp = hero
				end
				if not protector or stats.taken > protector.stats.taken then
					protector = hero
				end
				if not biggest or stats.biggestHit > biggest.stats.biggestHit then
					biggest = hero
				end
			end
		end

		summary = {
			turns = match.turn and match.turn.number or 0,
			mvpUid = mvp and mvp.stats.dealt > 0 and mvp.uid or nil,
			protectorUid = protector and protector.stats.taken > 0 and protector.uid or nil,
			biggestHitUid = biggest and biggest.stats.biggestHit > 0 and biggest.uid or nil,
			biggestHit = biggest and biggest.stats.biggestHit or 0,
		}
	end

	return {
		phase = match.phase,
		summary = summary,
		deployZone = viewerSide.zone,
		placedCount = viewerSide.placedCount,
		opponentPlacedCount = opponent.placedCount,
		isMyPlacement = match.sides[match.placementSide].id == viewerId,
		heroesPerPlayer = GameConfig.HEROES_PER_PLAYER,
		usedHeroIds = usedHeroIds,
		lockedHeroIds = lockedHeroIds,
		heroes = heroes,
		barrels = barrels,
		promotionSquares = promotionSquares,
		pendingPromotion = pendingPromotion,
		pendingShield = pendingShield,
		campaign = match.fight ~= nil,
		rematch = (match.phase == "finished" and not match.vsBot) and {
			open = match.rematchOpen == true,
			mine = match.rematch[viewerId] == true,
			theirs = RematchWantedByOther(match, viewerId),
		} or nil,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == viewerId or false,
		turnSecondsLeft = TurnSecondsLeft(match),
		turnTimeLimit = GameConfig.TURN_TIME_LIMIT,

		reconnect = match.suspendedAt and {
			secondsLeft = ReconnectSecondsLeft(match),
			window = GameConfig.RECONNECT_WINDOW,
			name = match.suspendedName,
			mine = match.suspendedId == viewerId,
		} or nil,
		placementSecondsLeft = PlacementSecondsLeft(match),
		placementTimeLimit = GameConfig.PLACEMENT_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,

		counterAttackUsed = match.turn and match.turn.counterAttack or false,

		arena = match.theme and match.theme.id or nil,
		arenaName = match.theme and match.theme.name or nil,

		winner = winner,
		message = match.message,
		finisher = finisher,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",
		boardFolder = match.boardFolder,
		heroesFolder = match.view.heroesFolder,
	}
end

local function Broadcast(match, message)
	RefreshWeakPoints(match)

	match.message = message
	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, Snapshot(match, side.id))
		end
	end
	match.message = nil

	for _, hero in pairs(match.heroes) do
		if hero.isAlive and not hero.stealth then
			match.lastSeen[hero.uid] = hero.position
		end
	end

	for _, hero in pairs(match.heroes) do
		hero.shieldJustBroke = nil
	end

	match.finisher = nil
end

function CreateHero(match, dataId, ownerId, hexId)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local hero = {
		uid = match.id .. "_" .. ownerId .. "_" .. dataId,
		dataId = dataId,
		name = data.name,
		ownerId = ownerId,
		sideIndex = SideOf(match, ownerId).index, -- 1 = azul, 2 = vermelho (o HeroView pinta)
		baseAttack = data.attack,
		attack = data.attack,
		maxHp = data.hp,
		currentHp = data.hp,
		ability = data.ability,
		abilities = data.abilities,
		attackRange = HeroData.GetAttackRange(data),
		moveRange = HeroData.GetMoveRange(data),
		deathSound = data.deathSound,
		deathHold = data.deathHold,
		attackSound = data.attackSound,
		position = hexId,
		isAlive = true,
		statusEffects = {},
		firstAttack = false,
		firstPunchApplied = false,
		frenzyActive = false, -- Merlin: Frenesi ligado agora
		frenzyHealed = false, -- Merlin: a cura de entrada do Frenesi já saiu
		stealth = false,

		weakPoint = math.random(HexGrid.DIRECTION_COUNT),

		stats = {
			dealt = 0,
			taken = 0,
			healed = 0,
			kills = 0,
			biggestHit = 0,
			attacks = 0,
			turnsAlive = 0,
			ccApplied = 0,
			special = {},
		},
		noGrave = false,
		gravePending = false,
		graveOwner = nil,
		graveHex = nil, -- casa do último pedaço que caiu; é onde a lápide sobe

		skullCooldown = 0,
		summoner = nil,

		view = match.view,
	}

	local previous = match.heroes[hero.uid]
	if previous and not previous.isAlive then
		hero.stats = previous.stats

		if match.occupied[previous.position] == previous then
			match.occupied[previous.position] = nil
		end
		HeroView.ClearGrave(previous)
	end

	match.heroes[hero.uid] = hero
	match.occupied[hexId] = hero
	HeroView.Create(hero)
	HeroView.PlayPlaceSound(match.view)
	return hero
end

local function CreateBarrel(match, hexId)
	match.nextBarrelId += 1

	local barrel = {
		uid = ("%d_barril_%d"):format(match.id, match.nextBarrelId),
		isBarrel = true, -- é o que o GetHeroAt usa pra não devolver barril como herói
		position = hexId,
		hitsLeft = GameConfig.BARREL_HITS,
		view = match.view,
	}

	match.barrels[barrel.uid] = barrel
	match.occupied[hexId] = barrel
	HeroView.CreateBarrel(barrel)
	return barrel
end

local function SpawnBarrels(match)
	local hexes = match.theme and match.theme.objectHexes or GameConfig.BARREL_HEXES

	for _, hexId in ipairs(hexes) do
		if not HexGrid.Exists(hexId) then
			warn("MatchManager: casa de barril inexistente: " .. tostring(hexId))
		elseif IsFree(match, hexId) then
			CreateBarrel(match, hexId)
		end
	end
end

local function BreakBarrel(match, barrel, breaker)
	match.barrels[barrel.uid] = nil

	if match.occupied[barrel.position] == barrel then
		match.occupied[barrel.position] = nil
	end

	HeroView.BreakBarrel(barrel)

	if not (breaker and breaker.isAlive) then return end

	LogEvent(match, "barrel", breaker.sideIndex,
		("%s quebrou o barril de %s"):format(breaker.name, barrel.position))

	if math.random() < GameConfig.BARREL_HEAL_CHANCE then
		HeroView.PlaySkillEffect(breaker, "barrelHeal")
		Heal(match, breaker, GameConfig.BARREL_HEAL)
	else
		HeroView.PlaySkillEffect(breaker, "barrelAttack")
		IncreaseAttack(match, breaker, GameConfig.BARREL_ATTACK_BONUS)
		ApplyStatusEffect(match, breaker, {
			type = "attackBuff",
			duration = GameConfig.BARREL_BUFF_DURATION,
			attackBonus = GameConfig.BARREL_ATTACK_BONUS,
			appliedTurnToken = match.turnToken,
		})
	end
end


local function AttackBarrel(match, attacker, barrel)
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[barrel.position] then return end


	MarkAttacked(match, attacker)

	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if GameConfig.IsRangedAttack(attacker.attackRange) then
		HeroView.ShowRangedAttack(attacker, barrel)
	end

	barrel.hitsLeft -= 1
	HeroView.PlayBarrelHit(barrel)

	LogEvent(match, "barrel", attacker.sideIndex,
		("%s bateu no barril de %s (faltam %d golpe(s))"):format(attacker.name, barrel.position, math.max(0, barrel.hitsLeft)))

	if barrel.hitsLeft <= 0 then
		BreakBarrel(match, barrel, attacker)
	end

	if HasSkill(attacker, "voltChain") then
		match.skillApi.ChainFrom(attacker, barrel.position)
	end

	Broadcast(match)
end

function AttackGrave(match, attacker, grave)
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[grave.position] then return end

	MarkAttacked(match, attacker)

	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if GameConfig.IsRangedAttack(attacker.attackRange) then
		HeroView.ShowRangedAttack(attacker, grave)
	end

	grave.graveHitsLeft -= 1
	HeroView.PlayGraveHit(grave)

	if grave.graveHitsLeft <= 0 then
		grave.graveDestroyed = true
		if match.occupied[grave.position] == grave then
			match.occupied[grave.position] = nil
		end
		HeroView.DestroyGrave(grave)

		ApplyDamage(match, attacker, GameConfig.GRAVE_CURSE_DAMAGE, nil, false, nil, "graveCurse")
	end

	Broadcast(match)
end

local function AwardXp(match, side, result, survivors)
	if not side or side.isBot or not side.player then return end
	task.spawn(ProgressionService.AwardMatchXp, side.player, result, survivors, match.vsBot)
end

local function AwardFightHero(match, side)
	if not match.fight or not side or side.isBot or not side.player then return end
	task.spawn(HeroUnlockService.Unlock, side.player, match.fight.hero)
end

local function RecordHeroStats(match)
	if match.statsRecorded then return end
	match.statsRecorded = true

	local entries = {}

	local rootOf, familyAlive = {}, {}
	for _, hero in pairs(match.heroes) do
		local root = hero
		while root.summoner do root = root.summoner end
		rootOf[hero] = root
		if hero.isAlive then familyAlive[root] = true end
	end

	for _, hero in pairs(match.heroes) do
		local side = SideOf(match, hero.ownerId)
		if side then
			local result
			if match.winner == "draw" then
				result = "draws"
			elseif match.winner == side.id then
				result = "wins"
			else
				result = "losses"
			end

			local root = rootOf[hero]
			local row = entries[root.dataId] or {
				matches = 0, wins = 0, losses = 0, draws = 0,
				damageDealt = 0, damageTaken = 0, healed = 0,
				kills = 0, deaths = 0, survived = 0,
				attacks = 0, turnsAlive = 0, ccApplied = 0, special = {},
				pvpMatches = 0, pvpWins = 0,
			}

			if hero == root then
				row.matches += 1
				row[result] += 1

				if not match.vsBot then
					row.pvpMatches += 1
					if result == "wins" then row.pvpWins += 1 end
				end

				if familyAlive[root] then row.survived += 1 else row.deaths += 1 end
			end
			row.damageDealt += hero.stats.dealt
			row.damageTaken += hero.stats.taken
			row.healed += hero.stats.healed
			row.kills += hero.stats.kills
			row.attacks += hero.stats.attacks
			row.turnsAlive += hero.stats.turnsAlive
			row.ccApplied += hero.stats.ccApplied
			for key, value in pairs(hero.stats.special) do
				row.special[key] = (row.special[key] or 0) + value
			end

			entries[root.dataId] = row
		end
	end

	if match.simulated then
		if match.onStats then
			local rosters = { {}, {} }
			for _, hero in pairs(match.heroes) do
				local side = SideOf(match, hero.ownerId)
				if side and not hero.summoner and not HeroData.IsSummon(hero.dataId) then
					table.insert(rosters[side.index], hero.dataId)
				end
			end
			table.sort(rosters[1])
			table.sort(rosters[2])

			match.onStats(entries, {
				turns = match.turn and match.turn.number or 0,
				winner = match.winner,
				sideOneId = match.sides[1].id,
				sideTwoId = match.sides[2].id,
				theme = match.theme and match.theme.id or "?",
				timeout = match.winner == "draw",
				rosters = rosters,
			})
		end
	else
		HeroStatsService.AddMatch(entries)
	end
end

local function IsRankedPvp(match)
	if match.simulated then return nil, "BalanceSim" end
	if match.fight then return nil, "campanha" end
	if not match.turn then return nil, "partida nao chegou a comecar" end

	for _, side in ipairs(match.sides) do
		if side.isBot then return nil, "envolve bot" end
		if not (side.player or side.awaitingReconnect) then
			return nil, "lado sem jogador"
		end
	end

	return true
end

function CheckGameOver(match)
	local aliveOne = #LivingHeroesOf(match, match.sides[1].id)
	local aliveTwo = #LivingHeroesOf(match, match.sides[2].id)

	if aliveOne > 0 and aliveTwo > 0 then return false end

	if match.finisher then
		match.finisher.final = true
		Broadcast(match)
		match.busy = true
		task.wait(GameConfig.FINAL_KILL_HOLD)
		match.busy = false
	end

	match.phase = "finished"
	if aliveOne == 0 and aliveTwo == 0 then
		match.winner = "draw"
		AwardXp(match, match.sides[1], "draw")
		AwardXp(match, match.sides[2], "draw")
	else
		local oneWon = aliveTwo == 0
		local winningSide = oneWon and match.sides[1] or match.sides[2]
		local losingSide = oneWon and match.sides[2] or match.sides[1]
		local survivors = oneWon and aliveOne or aliveTwo

		match.winner = winningSide.id

		if not match.rankingDone then
			match.rankingDone = true

			local ranked, why = IsRankedPvp(match)
			if ranked and winningSide.player then
				print(("[Ranking] PvP valido — vitoria registrada para %s"):format(winningSide.player.Name))
				LeaderboardService.RecordWin(tonumber(winningSide.id))
			else
				print(("[Ranking] resultado ignorado — %s"):format(why))
			end
		end

		AwardXp(match, winningSide, "win", survivors)
		AwardXp(match, losingSide, "loss")

		AwardFightHero(match, winningSide)
	end

	RecordHeroStats(match)

	local winner = match.winner
	local noHumans = not (match.sides[1].player or match.sides[2].player)
	if noHumans or match.onFinish then
		task.defer(function()
			if noHumans then EndMatch(match) end
			if match.onFinish then match.onFinish(winner) end
		end)
	end

	return true
end

local function PerformAttack(match, attacker, target, isCounterAttack)
	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if GameConfig.IsRangedAttack(attacker.attackRange) then
		HeroView.ShowRangedAttack(attacker, target)
	end

	if HasSkill(target, "dodge") and CanReact(target, attacker) then
		local escape = MatchQuery.DodgeHexFor(match, target, attacker.position)
		if escape then
			local from = target.position
			ForceMove(match, target, escape)
			HeroView.FlashAttackRange(match.view, { from }, DODGE_CORE, DODGE_EDGE)
			HeroView.PlaySkillEffect(target, "dodge")
			HeroView.PlaySkillSound("dodge", match.view)
			LogEvent(match, "skill", target.sideIndex,
				("%s desviou do ataque de %s"):format(target.name, attacker.name))

			attacker.firstAttack = true
			HeroView.UpdateStats(attacker)
			return { damageApplied = true, dodged = true }
		end
	end

	local ctx = {
		damageApplied = false,
		attackerWasStealthed = attacker.stealth == true,
		targetWasAlone = #GetAlliesInRange(match, target, 1) == 0,
	}
	TriggerSkills(match, attacker, isCounterAttack and "onCounterAttack" or "onAttack",
		target, isCounterAttack, ctx)

	if not ctx.damageApplied and target.isAlive then
		ApplyDamage(match, target, attacker.attack, attacker, isCounterAttack)
	end

	attacker.stats.attacks += 1
	attacker.firstAttack = true
	HeroView.UpdateStats(attacker)

	if not isCounterAttack then
		ctx.targetKilled = not target.isAlive
		TriggerSkills(match, attacker, "onAttackResolved", target, false, ctx)
	end

	return ctx
end

local function MatchIsLive(match)
	return matches[match.id] ~= nil
end

local function BotPickResurrection(match, botId, options)
	local hasTank = false
	for _, ally in ipairs(LivingHeroesOf(match, botId)) do
		if ally.ability == GameConfig.ABILITIES.TAUNT then hasTank = true break end
	end

	local best, bestScore = options[1], -math.huge
	for _, uid in ipairs(options) do
		local hero = match.heroes[uid]
		local data = hero and HeroData.GetById(hero.dataId)

		if hero and data then
			local score = BotBrain.ThreatScore(hero) * 2 + data.hp / 3
			if not hasTank and data.ability == GameConfig.ABILITIES.TAUNT then score += 25 end

			if score > bestScore then
				best, bestScore = uid, score
			end
		end
	end
	return best
end

local function ResolveBotPromotion(match, botId)
	if not (MatchIsLive(match) and match.pendingPromotion
		and match.pendingPromotion.ownerId == botId) then return end

	MatchManager.Resurrect(nil,
		BotPickResurrection(match, botId, match.pendingPromotion.options), match)
	task.wait(BOT_ACTION_DELAY)
end

function BotPlayTurn(match, botId)
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		ResolveBotPromotion(match, botId)

		local function TentarEscudo()
			if not (MatchIsLive(match) and match.pendingShield
				and match.pendingShield.ownerId == botId) then return end

			local source = match.heroes[match.pendingShield.sourceUid]
			local options = ShieldOptionsFor(match, source)
			if #options == 0 then return end

			MatchManager.GrantShield(nil, BotBrain.PickShieldTarget(match, botId, options), match)
			task.wait(BOT_ACTION_DELAY)
		end

		TentarEscudo()

		local resolved = {}
		for _ = 1, GameConfig.HEROES_PER_PLAYER * 3 do
			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			local enemies = {}
			for _, enemy in ipairs(LivingHeroesOf(match, OpponentSide(match, botId).id)) do
				if not enemy.stealth then
					table.insert(enemies, enemy)
				end
			end

			if #enemies == 0 then
				local vivos = LivingHeroesOf(match, OpponentSide(match, botId).id)
				if #vivos == 0 then break end

				local ctxBusca = BotBrain.BuildBoardContext(match, botId, {})

				local pista = nil
				for _, inimigo in ipairs(vivos) do
					pista = pista or match.lastSeen[inimigo.uid]
				end

				local goals = BotBrain.SearchGoals(match, ctxBusca, pista)
				local moveu = false

				-- um objetivo DIFERENTE por herói: é o que espalha o time em vez
				-- de empilhar os três na mesma casa
				for index, hero in ipairs(ctxBusca.allies) do
					local goal = goals[((index - 1) % #goals) + 1]
					local plan = BotBrain.SearchPlanFor(match, hero, ctxBusca, goal)

					if plan and plan.position ~= hero.position then
						BotBrain.RememberSearchTile(hero, hero.position)
						MatchManager.MoveHero(nil, hero.uid, plan.position, match)
						moveu = true
						task.wait(BOT_ACTION_DELAY)

						if not MatchIsLive(match) or match.phase ~= "battle"
							or match.turn.ownerId ~= botId then return end
						ResolveBotPromotion(match, botId)
					end
				end

				if not moveu then break end
				continue
			end

			-- Releitura completa do tabuleiro a cada ação: quem é o carry, se o
			-- Nash está à vista, se a Casa de Promoção virou objetivo. Um abate
			-- ou um passo muda tudo isso, e planejar o turno inteiro de uma vez
			-- seria decidir com um tabuleiro que já não existe.
			local ctx = BotBrain.BuildBoardContext(match, botId, enemies)
			-- depende do alcance dos aliados, então sai depois do contexto e
			-- é refeito junto com ele a cada ação
			ctx.lineBlock = BotBrain.BuildLineBlocks(match, ctx)

			local best = nil
			for _, hero in ipairs(ctx.allies) do
				if not resolved[hero.uid] then
					local plan = BotBrain.PlanFor(match, hero, ctx)
					if plan and (not best or plan.score > best.score) then
						best = plan
					end
				end
			end

			if not best then break end

			if best.position ~= best.hero.position then
				MatchManager.MoveHero(nil, best.hero.uid, best.position, match)
				task.wait(BOT_ACTION_DELAY)

				-- Pisou na própria casa de promoção: TryTriggerPromotion (chamado
				-- dentro de MoveHero) já deixou a escolha pendurada em
				-- match.pendingPromotion. Sem resolver isto agora, AuthorizeAction
				-- bloqueia TODO o resto do turno do bot — inclusive o EndTurn.
				ResolveBotPromotion(match, botId)
			end

			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			if best.target and best.target.isAlive and best.hero.isAlive then
				MatchManager.AttackHero(nil, best.hero.uid, best.target.uid, match)
				task.wait(BOT_ACTION_DELAY)
			else
				-- Sem inimigo no alcance, o golpe parado vira alguma coisa em vez
				-- de nada. LÁPIDE ANTES DE BARRIL: o barril é um bônus pra quem
				-- bate, a lápide é a única forma de tirar do adversário a Casa
				-- de Promoção — negar um herói inteiro voltando ao tabuleiro
				-- vale mais que qualquer prêmio de caixote.
				local extra = best.hero.isAlive
					and (BotBrain.GraveInReach(match, best.hero, botId)
						or BotBrain.BarrelInReach(match, best.hero))
					or nil
				if extra then
					MatchManager.AttackHero(nil, best.hero.uid, extra.uid, match)
					task.wait(BOT_ACTION_DELAY)
				end

				-- só reposicionou: encerra o herói pra não reavaliá-lo em loop
				resolved[best.hero.uid] = true
			end

			-- o time andou: quem estava fora do alcance da Kira pode estar do
			-- lado dela agora
			TentarEscudo()
		end

		if MatchIsLive(match) and match.phase == "battle" and match.turn.ownerId == botId then
			MatchManager.EndTurn(nil, match)
		end
	end)
end

function ArmTurnClock(match, token)
	if not TurnIsTimed(match) then return end

	local left = TurnSecondsLeft(match) or GameConfig.TURN_TIME_LIMIT

	task.delay(math.max(left, 0.1), function()
		if not (MatchIsLive(match) and match.turn and match.turn.token == token
			and match.phase == "battle") then return end

		if match.suspendedAt then return end
		if (TurnSecondsLeft(match) or 0) > 0 then
			ArmTurnClock(match, token)
			return
		end

		-- espera uma animação em curso terminar, senão o EndTurn seria recusado
		local waited = 0
		while MatchIsLive(match) and match.busy and waited < 3 do
			task.wait(0.1)
			waited += 0.1
		end

		if MatchIsLive(match) and match.turn and match.turn.token == token
			and match.phase == "battle" and not match.suspendedAt then
			Broadcast(match, "⏱ Tempo esgotado!")
			MatchManager.EndTurn(nil, match)
		end
	end)
end

function BeginTurn(match, ownerId, number)
	match.turnToken += 1
	local token = match.turnToken

	local side = SideOf(match, ownerId)
	LogEvent(match, "turn", side and side.index,
		("Turno %d — %s"):format(number, side and side.player and side.player.DisplayName or "Bot"))

	match.turn = {
		ownerId = ownerId,
		number = number,
		moved = {},
		attacked = {},
		bonusMove = {},
		weakChain = {},
		counterAttack = false,
		token = token,
		startedAt = os.clock(),
	}

	-- A oferta de escudo vale pelo turno em que nasceu. Zerar aqui, ANTES do
	-- onTurnStart, é o que faz a lista ser recalculada do zero a cada turno da
	-- Kira (quem ganhou escudo no turno passado some das opções sozinho) e o que
	-- fecha a oferta que o jogador escolheu ignorar.
	match.pendingShield = nil

	-- onTurnStart dispara pros heróis dos DOIS lados (igual ao Phaser)
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			TriggerSkills(match, hero, "onTurnStart")
		end
	end

	local message = nil
	if number == GameConfig.SUDDEN_DEATH_WARNING_TURN then
		message = "⚠ Morte Súbita se aproxima!"
	end

	if number >= GameConfig.SUDDEN_DEATH_START_TURN then
		for _, hero in pairs(match.heroes) do
			if hero.isAlive then
				ApplyDamage(match, hero, GameConfig.SUDDEN_DEATH_DAMAGE, nil, false, nil, "suddenDeath")
			end
		end
		message = "☠ Morte Súbita: todos perdem 1 de vida!"
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match, message)

	-- cronômetro: encerra o turno sozinho quando o tempo acaba
	ArmTurnClock(match, token)

	local promotionHex = side and GameConfig.PROMOTION_HEX_FOR_SLOT[side.index]
	local standing = promotionHex and match.occupied[promotionHex]
	if standing and standing.isAlive and standing.ownerId == ownerId then
		TryTriggerPromotion(match, standing)
	end

	if SideOf(match, ownerId).isBot then
		BotPlayTurn(match, ownerId)
	end
end

function MatchManager.EndTurn(player, match)
	match = match or MatchOfPlayer(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end
	if match.suspendedAt then return end
	if match.pendingPromotion then
		if player then return end
		MatchManager.Resurrect(nil,
			BotPickResurrection(match, match.pendingPromotion.ownerId,
				match.pendingPromotion.options),
			match)
	end

	local currentSide = SideOf(match, match.turn.ownerId)
	if player and currentSide.player ~= player then return end

	local endingOwner = match.turn.ownerId
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			local ownTurnEnding = hero.ownerId == endingOwner
			if ownTurnEnding then hero.stats.turnsAlive += 1 end
			ProcessStatusEffects(match, hero, ownTurnEnding)

			if ownTurnEnding and hero.isAlive then
				TriggerSkills(match, hero, "onTurnEnd")
			end
		end
	end

	TickFlames(match, endingOwner)

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	local wasStarter = (endingOwner == match.starterId)
	local nextOwner = OpponentSide(match, endingOwner).id
	local nextNumber = match.turn.number + (wasStarter and 0 or 1)

	BeginTurn(match, nextOwner, nextNumber)
end

local function AuthorizeAction(match, player, hero)
	if not match or match.phase ~= "battle" then return false end
	if match.busy then return false end
	if match.suspendedAt then return false end
	if match.pendingPromotion then return false end
	if not hero or not hero.isAlive then return false end
	if IsDisabled(hero) then
		HeroView.Say(hero, "PARALISADO", "taunt")
		return false
	end
	if hero.ownerId ~= match.turn.ownerId then return false end

	if player and SideOf(match, match.turn.ownerId).player ~= player then
		Reject(player, "NOT_YOUR_TURN")
		return false
	end
	return true
end

local function FlameBias(match, hero)
	if next(match.flames) == nil then return nil end

	local converts = HasSkill(hero, "flameFury") or HasSkill(hero, "flameHeal")

	return function(hexId)
		local flame = match.flames[hexId]
		if not flame then return 0 end
		if flame.ownerId ~= hero.ownerId then return -4 end
		return converts and 4 or -1
	end
end

function MatchManager.MoveHero(player, heroUid, hexId, match)
	match = match or MatchOfPlayer(player)
	local hero = match and match.heroes[heroUid]
	if not AuthorizeAction(match, player, hero) then return end

	-- canMoveHero: não pode ter movido NEM atacado neste turno, salvo bônus
	if not CanMove(match, hero) then return end
	if type(hexId) ~= "string" or not HexGrid.Exists(hexId) then
		Reject(player, "INVALID_MOVE")
		return
	end
	if not IsFree(match, hexId) then
		Reject(player, "OCCUPIED")
		return
	end

	-- FindPath já garante alcance e caminho livre: substitui o ComputeReach
	local path = HexGrid.FindPath(hero.position, hexId, MoveRangeOf(match, hero),
		FreeChecker(match), FlameBias(match, hero))
	if not path then
		Reject(player, "MOVE_OUT_OF_RANGE")
		return
	end

	local wasBonusMove = match.turn.bonusMove[heroUid] == true
	match.turn.bonusMove[heroUid] = nil
	match.turn.moved[heroUid] = true
	LogEvent(match, "move", hero.sideIndex,
		("%s andou de %s para %s"):format(hero.name, hero.position, hexId))
	local enteredFlameCount = 0
	for _, stepHex in ipairs(path) do
		local flame = match.flames[stepHex]
		if flame and flame.ownerId == hero.ownerId then
			enteredFlameCount += 1
		end
	end

	Broadcast(match)

	local consumedOwnTiles = {}
	local origin = hero.position

	match.busy = true
	for step, stepHex in ipairs(path) do
		match.occupied[hero.position] = nil
		hero.position = stepHex
		match.occupied[stepHex] = hero

		HeroView.WalkStep(hero, stepHex, step)

		local _, ownFlame = ConsumeFlame(match, hero, stepHex)
		if ownFlame then
			consumedOwnTiles[stepHex] = true
		elseif not hero.isAlive then
			break
		end
	end
	match.busy = false

	if hero.isAlive then
		for _, other in pairs(match.heroes) do
			if other.isAlive then
				TriggerSkills(match, other, "onMove", nil, false, {
					movedHero = hero,
					bonusMove = wasBonusMove,
					path = path,
					origin = origin,
					enteredFlameCount = enteredFlameCount,
					consumedOwnTiles = consumedOwnTiles,
				})
			end
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match)

	if hero.isAlive then
		TryTriggerPromotion(match, hero)
	end
end

function MatchManager.AttackHero(player, attackerUid, targetUid, match)
	match = match or MatchOfPlayer(player)
	local attacker = match and match.heroes[attackerUid]
	if not AuthorizeAction(match, player, attacker) then return end
	if match.turn.attacked[attackerUid] then return end

	local barrel = match.barrels[targetUid]
	if barrel then
		AttackBarrel(match, attacker, barrel)
		return
	end

	local target = match.heroes[targetUid]

	if target and not target.isAlive and not target.graveDestroyed
		and target.ownerId ~= attacker.ownerId then
		AttackGrave(match, attacker, target)
		return
	end

	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end

	if target.stealth then return end

	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[target.position] then
		Reject(player, "ATTACK_OUT_OF_RANGE")
		return
	end

	local tauntBlocker = MatchQuery.TauntBlocks(match, attacker, target)
	if tauntBlocker then
		HeroView.Say(tauntBlocker, "BLOQUEADO", "taunt")
		return
	end

	local hits = ChainHits(match, attacker)
	if hits and hits[targetUid] then
		HeroView.Say(target, "JÁ ATINGIDO", "taunt")
		return
	end

	MarkAttacked(match, attacker)
	local attackCtx = PerformAttack(match, attacker, target, false)

	if not attackCtx.suppressCounter and not match.turn.counterAttack
		and target.isAlive and attacker.isAlive and not IsDisabled(target) then
		if HexGrid.Distance(target.position, attacker.position) <= target.attackRange then
			match.turn.counterAttack = true

			match.busy = true
			task.wait(COUNTER_ATTACK_DELAY)
			match.busy = false

			local counterCtx = PerformAttack(match, target, attacker, true)

			if counterCtx and counterCtx.dodged then
				match.turn.counterAttack = false
			end
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match)
end

-- ===================== CASAS DE PROMOÇÃO =====================
function FindNearestFreeHex(match, fromHex, avoid)
	local function Serve(hexId)
		return IsFree(match, hexId) and not (avoid and avoid[hexId])
	end

	if Serve(fromHex) then return fromHex end

	local seen = { [fromHex] = true }
	local queue = { fromHex }
	local head = 1

	while head <= #queue do
		local id = queue[head]
		head += 1
		for _, neighbor in ipairs(HexGrid.GetNeighbors(id)) do
			if not seen[neighbor.id] then
				seen[neighbor.id] = true
				if Serve(neighbor.id) then return neighbor.id end
				table.insert(queue, neighbor.id)
			end
		end
	end

	return nil 
end

local function PerformResurrection(match, pending, grave)

	HeroView.ClearGrave(grave)
	if match.occupied[grave.position] == grave then
		match.occupied[grave.position] = nil
	end

	local spawnHex = FindNearestFreeHex(match, grave.position)
	if not spawnHex then return nil end

	local newHero = CreateHero(match, grave.dataId, pending.ownerId, spawnHex)
	if not newHero then return nil end

	newHero.currentHp = math.min(GameConfig.RESURRECT_HP, newHero.maxHp)

	TriggerSkills(match, newHero, "onTurnStart")

	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(match, other, "onMove", nil, false, { movedHero = newHero })
		end
	end

	HeroView.UpdateStats(newHero)
	HeroView.PlayMatchSound(match.view, "Resurrect")

	return newHero
end

function TryTriggerPromotion(match, hero)
	if match.phase ~= "battle" or not match.turn then return end
	if match.turn.number < GameConfig.PROMOTION_UNLOCK_TURN then return end

	local side = SideOf(match, hero.ownerId)
	if not side or side.promotionUsed then return end
	if GameConfig.PROMOTION_HEX_FOR_SLOT[side.index] ~= hero.position then return end

	local lantern = nil
	local options = {}
	for _, other in pairs(match.heroes) do
		if other.ownerId == hero.ownerId and not other.isAlive and not other.graveDestroyed then
			if lantern == nil and HasSkill(other, "lanternReturn") then
				lantern = other
			else
				table.insert(options, other.uid)
			end
		end
	end

	if lantern == nil and #options == 0 then return end

	table.sort(options)
	local pending = {
		ownerId = hero.ownerId,
		promotionHex = hero.position,
		options = options,
	}

	local message = nil
	if lantern then
		local revived = PerformResurrection(match, pending, lantern)
		if revived then
			side.promotionUsed = true
			message = ("A lanterna de %s reacendeu sozinha!"):format(revived.name)
			LogEvent(match, "skill", hero.sideIndex,
				("%s voltou pela Luz que Volta"):format(revived.name))
		end
	end

	if #options == 0 then
		Broadcast(match, message)
		return
	end

	match.pendingPromotion = pending
	Broadcast(match, message)
end

function MatchManager.GrantShield(player, heroUid, match)
	match = match or MatchOfPlayer(player)
	local pending = match and match.pendingShield
	if not pending then return end
	if match.phase ~= "battle" or not match.turn then return end
	if match.turn.ownerId ~= pending.ownerId then return end

	if player then
		local side = SideOfPlayer(match, player)
		if not side or side.id ~= pending.ownerId then return end
	end

	local source = match.heroes[pending.sourceUid]
	local valid = false
	for _, uid in ipairs(ShieldOptionsFor(match, source)) do
		if uid == heroUid then valid = true break end
	end

	local target = match.heroes[heroUid]
	if valid and target and target.isAlive
		and target.ownerId == pending.ownerId
	then
		ApplyStatusEffect(match, target, {
			type = "shield",
			permanent = true,
			duration = 0,
		})
		HeroView.SetShieldAura(target, true)
		HeroView.PlaySkillEffect(target, "aegis")
		HeroView.PlaySkillSound("aegis", match.view)

		local source = match.heroes[pending.sourceUid]
		LogEvent(match, "skill", target.sideIndex,
			("%s protegeu %s com um escudo"):format(source and source.name or "Kira", target.name))
	end

	match.pendingShield = nil
	Broadcast(match)
end

function MatchManager.Resurrect(player, heroUid, match)
	match = match or MatchOfPlayer(player)
	local pending = match and match.pendingPromotion
	if not pending then return end

	if player then
		local side = SideOfPlayer(match, player)
		if not side or side.id ~= pending.ownerId then return end
	end

	local valid = false
	for _, uid in ipairs(pending.options) do
		if uid == heroUid then valid = true break end
	end

	local grave = match.heroes[heroUid]
	local message = nil

	if valid and grave and not grave.isAlive and not grave.graveDestroyed then
		local newHero = PerformResurrection(match, pending, grave)
		if newHero then
			message = ("%s voltou pela Casa de Promoção!"):format(newHero.name)
			SideOf(match, pending.ownerId).promotionUsed = true
		end
	end

	match.pendingPromotion = nil
	Broadcast(match, message)
end

local function AvailableHeroIds(match, side)
	local available = {}
	for _, data in ipairs(HeroData.CATALOG) do
		local unlocked = (side == nil) or side.unlockedIds[data.id]
		if not match.usedHeroIds[data.id] and unlocked then
			table.insert(available, data.id)
		end
	end
	return available
end

local function FreeHexesIn(match, zone)
	local free = {}
	for _, hexId in ipairs(zone) do
		if IsFree(match, hexId) then
			table.insert(free, hexId)
		end
	end
	return free
end

local BOT_DRAFT_WEIGHT = {
	[6] = 10, -- Ceos: tanque que se cura, o mais seguro pra IA
	[8] = 9,  -- Elaria: cura e limpa, segura o time inteiro
	[4] = 8,  -- Blade: dano em linha
	[7] = 7,  -- Noctin: dano alto, corre
	[10] = 6, -- Kor: controle, alcance 3
	[1] = 6,  -- Ralph: dano de abertura
	[9] = 5,  -- Bramm: Taunt que empurra
	[11] = 4, -- Merlin: o kit dele só paga com o time morto, e o bot não joga pra isso
	[5] = 4,  -- Dante
	[2] = 3,  -- Vic: veneno rende a longo prazo, o bot não capitaliza bem
	[3] = 3,  -- Mineiro: depende de sorte
}
local BOT_DRAFT_DEFAULT_WEIGHT = 4

local function BotPickHeroId(available)
	if #available == 0 then return nil end

	local total = 0
	for _, dataId in ipairs(available) do
		total += BOT_DRAFT_WEIGHT[dataId] or BOT_DRAFT_DEFAULT_WEIGHT
	end

	local ticket = math.random() * total
	for _, dataId in ipairs(available) do
		ticket -= BOT_DRAFT_WEIGHT[dataId] or BOT_DRAFT_DEFAULT_WEIGHT
		if ticket <= 0 then return dataId end
	end

	return available[#available]
end

local function BotPickHex(data, zone, free)
	local center = (#zone + 1) / 2

	local function offsetFromCenter(hexId)
		local index = table.find(zone, hexId)
		return index and math.abs(index - center) or 0
	end

	local jitter = {}
	for _, hexId in ipairs(free) do jitter[hexId] = math.random() end

	table.sort(free, function(a, b)
		local da, db = offsetFromCenter(a), offsetFromCenter(b)
		if da == db then return jitter[a] < jitter[b] end
		if data.ability == GameConfig.ABILITIES.RANGED then return da > db end
		return da < db
	end)

	return free[1]
end

local function AllPlaced(match)
	for _, side in ipairs(match.sides) do
		if side.placedCount < GameConfig.HEROES_PER_PLAYER then return false end
	end
	return true
end

local function StartPlacementClock(match)
	match.placementToken += 1
	match.placementStartedAt = os.clock()

	local token = match.placementToken
	local side = match.sides[match.placementSide]
	if side.isBot or GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return end

	task.delay(GameConfig.PLACEMENT_TIME_LIMIT, function()
		if not (MatchIsLive(match) and match.phase == "placement" and match.placementToken == token) then return end

		Broadcast(match, "⏱ Tempo esgotado!")
		BotPlaceOne(match, true)
	end)
end

function AdvancePlacement(match)
	if AllPlaced(match) then
		match.phase = "battle"
		BeginTurn(match, match.starterId, 1)
		return
	end

	local nextIndex = (match.placementSide == 1) and 2 or 1
	if match.sides[nextIndex].placedCount >= GameConfig.HEROES_PER_PLAYER then
		nextIndex = match.placementSide
	end
	match.placementSide = nextIndex
	StartPlacementClock(match)

	Broadcast(match)

	if match.sides[nextIndex].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, function()
			BotPlaceOne(match)
		end)
	end
end

function BotPlaceOne(match, force)
	if not MatchIsLive(match) or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if not (side.isBot or force) then return end

	local free = FreeHexesIn(match, side.zone)

	local dataId = side.roster and side.roster[side.placedCount + 1]
	if not dataId then
		local available = AvailableHeroIds(match, side)
		dataId = #available > 0 and BotPickHeroId(available) or nil
	end

	if dataId and #free > 0 then
		local hexId = BotPickHex(HeroData.GetById(dataId), side.zone, free)
		CreateHero(match, dataId, side.id, hexId)
		if not side.roster then match.usedHeroIds[dataId] = true end
		side.placedCount += 1
	end

	AdvancePlacement(match)
end

function MatchManager.PlaceHero(player, dataId, hexId)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "placement" then return end
	if match.suspendedAt then return end

	local side = match.sides[match.placementSide]
	if side.player ~= player then return end
	if side.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	if not side.unlockedIds[dataId] then return end
	if not table.find(side.zone, hexId) then return end
	if not IsFree(match, hexId) then return end

	CreateHero(match, dataId, side.id, hexId)
	match.usedHeroIds[dataId] = true
	side.placedCount += 1

	AdvancePlacement(match)
end

local STREAM_TIMEOUT = 5

local function StreamArenaTo(players, origin)
	if not Workspace.StreamingEnabled then return end

	local center = HexGrid.GetBoardCenter(origin)
	local pending = 0

	for _, player in ipairs(players) do
		if player and player.Parent then
			pending += 1
			task.spawn(function()
				local ok, err = pcall(function()
					player:RequestStreamAroundAsync(center, STREAM_TIMEOUT)
				end)
				if not ok then
					warn(("MatchManager: streaming da arena falhou para %s: %s")
						:format(player.Name, tostring(err)))
				end
				pending -= 1
			end)
		end
	end

	local waited = 0
	while pending > 0 and waited < STREAM_TIMEOUT + 1 do
		task.wait(0.1)
		waited += 0.1
	end
end

local function AllocateSlot()
	for slot = 1, GameConfig.MatchCapacity() do
		if not matchBySlot[slot] then return slot end
	end
	return nil
end

function MatchManager.HasFreeSlot()
	return AllocateSlot() ~= nil
end

function MatchManager.IsInMatch(player)
	return MatchOfPlayer(player) ~= nil
end

function MatchManager.StartMatch(playerOne, playerTwo, slot, fight, options)
	local botVsBot = options ~= nil and options.botVsBot == true
	if not playerOne and not botVsBot then return false end

	slot = slot or AllocateSlot()
	if not slot then return false end

	nextMatchId += 1
	local matchId = nextMatchId
	local origin = GameConfig.ArenaOrigin(slot)

	local players = {}
	if playerOne then table.insert(players, playerOne) end
	if playerTwo then table.insert(players, playerTwo) end

	local theme = (options and options.theme) or Arenas.ForMatch(fight)
	local boardFolder = BoardSpawner.SpawnBoard(slot, playerTwo == nil, fight and fight.hero, theme)
	if boardFolder then boardFolder:SetAttribute("MatchId", matchId) end

	local sides = {
		{
			index = 1,
			id = playerOne and tostring(playerOne.UserId) or BOT_ONE_ID,
			player = playerOne,
			name = playerOne and playerOne.DisplayName or "Bot",
			isBot = playerOne == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[1]),
			placedCount = 0,
			promotionUsed = false, -- Casa de Promoção: um uso por jogador na partida inteira
		},
		{
			index = 2,
			id = playerTwo and tostring(playerTwo.UserId) or BOT_ID,
			player = playerTwo,
			name = playerTwo and playerTwo.DisplayName or "Bot",
			isBot = playerTwo == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[2]),
			placedCount = 0,
			promotionUsed = false,
		},
	}

	sides[1].unlockedIds = playerOne and UnlockedIdsFor(playerOne) or AllHeroIds()
	sides[2].unlockedIds = playerTwo and UnlockedIdsFor(playerTwo) or sides[1].unlockedIds
	sides[2].roster = fight and fight.team or nil

	if options and options.rosters then
		sides[1].roster = options.rosters[1]
		sides[2].roster = options.rosters[2]
	end

	local sideIndexById = {}
	for index, side in ipairs(sides) do
		sideIndexById[side.id] = index
	end

	local match = {
		id = matchId,
		slot = slot,
		origin = origin,
		boardFolder = boardFolder,
		view = HeroView.CreateView(matchId, origin, players, theme),
		theme = theme,
		sides = sides,
		sideIndexById = sideIndexById,
		vsBot = playerTwo == nil,
		rematch = {},
		rematchOpen = true,
		fight = fight,
		simulated = botVsBot,
		onFinish = options and options.onFinish or nil,
		onStats = options and options.onStats or nil,
		phase = "placement",
		heroes = {},
		barrels = {},
		nextBarrelId = 0,
		occupied = {},
		flames = {},
		log = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		placementToken = 0,
		placementStartedAt = nil,
		starterId = sides[math.random(2)].id,
		turn = nil,
		turnToken = 0,
		winner = nil,
		finisher = nil,
		lastSeen = {},
		busy = false,
		pendingPromotion = nil, -- ver TryTriggerPromotion/MatchManager.Resurrect
		pendingShield = nil, -- ver OfferShield/MatchManager.GrantShield
	}

	match.skillApi = BuildSkillApi(match)

	matches[matchId] = match
	matchBySlot[slot] = match

	SpawnBarrels(match)

	StreamArenaTo(players, origin)

	local hexSize = HexGrid.GetHexSize()
	if playerOne then
		SetStandScale(playerOne, GameConfig.PLAYER_STAND_SCALE)
		BoardReady:FireClient(playerOne, hexSize, origin, 1)
	end
	if playerTwo then
		SetStandScale(playerTwo, GameConfig.PLAYER_STAND_SCALE)
		BoardReady:FireClient(playerTwo, hexSize, origin, 2)
	end

	HeroView.PlayMatchSound(match.view, "MatchStart")

	StartPlacementClock(match)
	Broadcast(match)

	if sides[1].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, function()
			BotPlaceOne(match)
		end)
	end

	local label = playerTwo and "PvP" or (playerOne and "vs bot" or "bot vs bot")
	print(("MatchManager: partida %d no slot %d (%s)."):format(matchId, slot, label))
	return true
end

function EndMatch(match)
	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)

	if match.boardFolder and match.boardFolder.Parent then
		match.boardFolder:Destroy()
	end

	for _, side in ipairs(match.sides) do
		if side.player then
			SetStandScale(side.player, 1)
			MatchUpdate:FireClient(side.player, { phase = "lobby" })
		end
	end

	matches[match.id] = nil
	matchBySlot[match.slot] = nil
end

local function NextOpenFight(player, justWon)
	return Campaign.NextOpen(HeroUnlockService.GetPlayableIds(player), justWon)
end

local function RestartMatch(match, fight)
	local playerOne = match.sides[1].player
	local playerTwo = match.sides[2].player
	local slot = match.slot

	if not playerOne then
		playerOne, playerTwo = playerTwo, nil
	end
	if not playerOne then return end

	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)
	matches[match.id] = nil
	matchBySlot[slot] = nil

	MatchManager.StartMatch(playerOne, playerTwo, slot, fight, { theme = match.theme })
end

function MatchManager.Replay(player)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "finished" then return end

	if not match.vsBot then
		local side = SideOfPlayer(match, player)
		if not side or not match.rematchOpen then return end

		match.rematch[side.id] = true

		for _, other in ipairs(match.sides) do
			if other.player and not match.rematch[other.id] then
				Broadcast(match)
				return
			end
		end

		RestartMatch(match, match.fight)
		return
	end

	local fight = match.fight
	if fight and match.winner == tostring(player.UserId) then
		fight = NextOpenFight(player, fight)
		if not fight then
			Broadcast(match, "Você venceu todos os confrontos disponíveis!")
			return
		end
	end

	RestartMatch(match, fight)
end

local function AwardAbandon(match, leavingSide)
	if match.phase == "finished" then return end

	local stayingSide = match.sides[leavingSide.index == 1 and 2 or 1]
	if not stayingSide.player or stayingSide.isBot then return end

	local survivors = math.max(#LivingHeroesOf(match, stayingSide.id), 1)
	AwardXp(match, stayingSide, "win", survivors)
end

function MatchManager.LeaveMatch(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)

	if match.phase == "finished" and side and not match.vsBot then
		match.rematchOpen = false
		side.player = nil

		SetStandScale(player, 1)
		MatchUpdate:FireClient(player, { phase = "lobby" })

		for _, other in ipairs(match.sides) do
			if other.player then
				Broadcast(match)
				return
			end
		end
	end

	if side then AwardAbandon(match, side) end

	EndMatch(match)
end

local function SuspendForReconnect(match, side)
	match.suspendedAt = os.clock()
	match.suspendedId = side.id
	match.suspendedName = side.name or "Adversário"
	side.awaitingReconnect = true

	if match.turn then
		match.turn.pausedLeft = TurnSecondsLeft(match)
	end
	match.placementToken += 1

	Broadcast(match)

	local stamp = match.suspendedAt
	task.delay(GameConfig.RECONNECT_WINDOW, function()
		if not MatchIsLive(match) then return end
		if match.suspendedAt ~= stamp then return end

		MatchManager.ForfeitDisconnected(match)
	end)
end

function MatchManager.ResumeFromReconnect(match, side, player)
	match.suspendedAt = nil
	match.suspendedId = nil
	match.suspendedName = nil
	side.awaitingReconnect = nil
	side.player = player

	SetStandScale(player, GameConfig.PLAYER_STAND_SCALE)

	StreamArenaTo({ player }, match.origin)
	BoardReady:FireClient(player, HexGrid.GetHexSize(), match.origin, side.index)

	if match.phase == "placement" then
		StartPlacementClock(match)
	elseif match.turn then
		match.turn.startedAt = os.clock()
			- (GameConfig.TURN_TIME_LIMIT - (match.turn.pausedLeft or GameConfig.TURN_TIME_LIMIT))
		match.turn.pausedLeft = nil
		ArmTurnClock(match, match.turn.token)
	end

	Broadcast(match, ("%s voltou para a partida."):format(side.name or "O adversário"))
end

function MatchManager.ForfeitDisconnected(match)
	if match.phase == "finished" then return end

	local losingSide, winningSide
	for _, side in ipairs(match.sides) do
		if side.id == match.suspendedId then losingSide = side else winningSide = side end
	end
	if not (losingSide and winningSide) then return end

	local ranked, why = IsRankedPvp(match)

	match.suspendedAt = nil
	match.suspendedId = nil
	match.suspendedName = nil
	losingSide.awaitingReconnect = nil

	match.phase = "finished"
	match.winner = winningSide.id

	if not match.rankingDone then
		match.rankingDone = true

		if ranked and winningSide.player then
			print(("[Ranking] vitoria por desconexao registrada para %s"):format(winningSide.player.Name))
			LeaderboardService.RecordWin(tonumber(winningSide.id))
		else
			print(("[Ranking] desconexao ignorada — %s"):format(why or "sem vencedor humano"))
		end
	end

	AwardXp(match, winningSide, "win", math.max(#LivingHeroesOf(match, winningSide.id), 1))
	losingSide.player = nil

	Broadcast(match, "Adversário não voltou a tempo.")
end

function MatchManager.HandlePlayerLeft(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)
	if not side then return end

	local other = match.sides[side.index == 1 and 2 or 1]
	local canWait = GameConfig.RECONNECT_WINDOW > 0
		and match.phase ~= "finished"
		and not match.vsBot
		and not match.fight
		and other.player ~= nil
		and not match.suspendedAt

	if canWait then
		side.player = nil
		SuspendForReconnect(match, side)
		return
	end

	AwardAbandon(match, side)
	side.player = nil
	EndMatch(match)
end

function MatchManager.HandlePlayerRejoined(player)
	local wanted = tostring(player.UserId)

	for _, match in pairs(matches) do
		if match.suspendedAt and match.suspendedId == wanted then
			for _, side in ipairs(match.sides) do
				if side.id == wanted and side.awaitingReconnect then
					MatchManager.ResumeFromReconnect(match, side, player)
					return true
				end
			end
		end
	end

	return false
end

function MatchManager.GetLog(player)
	local match = MatchOfPlayer(player)
	return match and match.log or {}
end

function MatchManager.ActiveCount()
	local count = 0
	for _ in pairs(matches) do count += 1 end
	return count
end

return MatchManager
