local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local BoardVfx = require(ServerScriptService.Modules.View.BoardVfx)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local MatchOutcome = require(ServerScriptService.Modules.Match.MatchOutcome)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)
local BoardObjectService = require(ServerScriptService.Modules.Combat.BoardObjectService)
local ActionGuard = require(ServerScriptService.Modules.Combat.ActionGuard)

local AttackService = {}

local GetHeroAt = MatchQuery.GetHeroAt
local HasSkill = MatchQuery.HasSkill
local GetAlliesInRange = MatchQuery.GetAlliesInRange
local AttackRangeOf = MatchQuery.AttackRangeOf
local AttackReachFrom = MatchQuery.AttackReachFrom
local TauntBlocks = MatchQuery.TauntBlocks
local MatchOfPlayer = MatchRegistry.MatchOfPlayer
local Broadcast = MatchBroadcast.Send
local LogEvent = MatchLog.Event
local Tally = MatchLog.Tally
local Reject = MatchLog.Reject
local CheckGameOver = MatchOutcome.CheckGameOver
local AuthorizeAction = ActionGuard.Authorize

local TriggerSkills = CombatCore.TriggerSkills
local ApplyDamage = CombatCore.ApplyDamage
local ForceMove = CombatCore.ForceMove
local CanReact = CombatCore.CanReact
local MarkAttacked = CombatCore.MarkAttacked
local ChainHits = CombatCore.ChainHits
local IsDisabled = CombatCore.IsDisabled

local DODGE_CORE = Color3.fromRGB(190, 235, 255)
local DODGE_EDGE = Color3.fromRGB(70, 160, 255)
local COUNTER_ATTACK_DELAY = 0.4

function AttackService.PerformAttack(match, attacker, target, isCounterAttack)
	HeroView.PlayAnimation(attacker, "attack")
	HeroView.PlayAttackSound(attacker)
	if GameConfig.IsRangedAttack(attacker.attackRange) then
		HeroView.ShowRangedAttack(attacker, target)
	end

	if HasSkill(target, "dodge") and CanReact(target, attacker) then
		local escape, reachable, outOfRange = MatchQuery.DodgeHexFor(match, target, attacker)
		local range = AttackRangeOf(match, attacker)

		Tally(target, "escapeAttempts")
		Tally(target, "escapeTilesBeforeRange", reachable)
		Tally(target, "escapeTilesAfterRange", outOfRange)

		if escape then
			local from = target.position
			ForceMove(match, target, escape)
			BoardVfx.FlashAttackRange(match.view, { from }, DODGE_CORE, DODGE_EDGE)
			HeroView.PlaySkillEffect(target, "dodge")
			HeroView.PlaySkillSound("dodge", match.view)

			local away = HexGrid.Distance(escape, attacker.position)
			Tally(target, "successfulEscapes")
			Tally(target, "escapeDistanceSum", away)
			LogEvent(match, "skill", target.sideIndex,
				("%s desviou do ataque de %s (alcance %d, %d de %d rotas livres, parou a %d)")
					:format(target.name, attacker.name, range, outOfRange, reachable, away))

			attacker.firstAttack = true
			HeroView.UpdateStats(attacker)
			return { damageApplied = true, dodged = true }
		end

		Tally(target, "failedEscapes")
		if reachable > 0 then
			Tally(target, "failedEscapesAttackerRange")
			Tally(target, "blockedBy" .. attacker.name)
		else
			Tally(target, "failedEscapesNoValidTile")
		end

		LogEvent(match, "skill", target.sideIndex,
			("%s nao achou rota de fuga contra %s (alcance %d, %d rotas livres, 0 fora do alcance)")
				:format(target.name, attacker.name, range, reachable))
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

	if attacker.summoner then
		Tally(attacker, "summonAttacks")
		if not attacker.firstAttack then
			Tally(attacker, "summonFirstAttackTurnSum", match.turn and match.turn.number or 0)
			Tally(attacker, "summonsThatAttacked")
		end
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

function AttackService.AttackHero(player, attackerUid, targetUid, match)
	match = match or MatchOfPlayer(player)
	local attacker = match and match.heroes[attackerUid]
	if not AuthorizeAction(match, player, attacker) then return end
	if match.turn.attacked[attackerUid] then return end

	local barrel = match.barrels[targetUid]
	if barrel then
		BoardObjectService.AttackBarrel(match, attacker, barrel)
		return
	end

	local target = match.heroes[targetUid]

	if target and not target.isAlive and not target.graveDestroyed
		and target.ownerId ~= attacker.ownerId then
		BoardObjectService.AttackGrave(match, attacker, target)
		return
	end

	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end

	if target.stealth then return end

	local reach = AttackReachFrom(match, attacker)
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
	local attackCtx = AttackService.PerformAttack(match, attacker, target, false)

	if not attackCtx.suppressCounter and not match.turn.counterAttack
		and target.isAlive and attacker.isAlive and not IsDisabled(target) then
		if HexGrid.Distance(target.position, attacker.position) <= target.attackRange then
			match.turn.counterAttack = true

			match.busy = true
			task.wait(COUNTER_ATTACK_DELAY)
			match.busy = false

			local counterCtx = AttackService.PerformAttack(match, target, attacker, true)

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
return AttackService
