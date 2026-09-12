local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local BoardObjectView = require(ServerScriptService.Modules.View.BoardObjectView)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)

local BoardObjectService = {}

local IsFree = MatchQuery.IsFree
local HasSkill = MatchQuery.HasSkill
local AttackReachFrom = MatchQuery.AttackReachFrom
local Broadcast = MatchBroadcast.Send
local LogEvent = MatchLog.Event

local Heal = CombatCore.Heal
local IncreaseAttack = CombatCore.IncreaseAttack
local ApplyStatusEffect = CombatCore.ApplyStatusEffect
local ApplyDamage = CombatCore.ApplyDamage
local MarkAttacked = CombatCore.MarkAttacked

function BoardObjectService.CreateBarrel(match, hexId)
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
	BoardObjectView.Create(barrel)
	return barrel
end

function BoardObjectService.SpawnBarrels(match)
	local hexes = match.theme and match.theme.objectHexes or GameConfig.BARREL_HEXES

	for _, hexId in ipairs(hexes) do
		if not HexGrid.Exists(hexId) then
			warn("MatchManager: casa de barril inexistente: " .. tostring(hexId))
		elseif IsFree(match, hexId) then
			BoardObjectService.CreateBarrel(match, hexId)
		end
	end
end

local function BreakBarrel(match, barrel, breaker)
	match.barrels[barrel.uid] = nil

	if match.occupied[barrel.position] == barrel then
		match.occupied[barrel.position] = nil
	end

	BoardObjectView.Break(barrel)

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


function BoardObjectService.AttackBarrel(match, attacker, barrel)
	local reach = AttackReachFrom(match, attacker)
	if not reach[barrel.position] then return end


	MarkAttacked(match, attacker)

	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if GameConfig.IsRangedAttack(attacker.attackRange) then
		HeroView.ShowRangedAttack(attacker, barrel)
	end

	barrel.hitsLeft -= 1
	BoardObjectView.PlayHit(barrel)

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

function BoardObjectService.AttackGrave(match, attacker, grave)
	local reach = AttackReachFrom(match, attacker)
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

return BoardObjectService
