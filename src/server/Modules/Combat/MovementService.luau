local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local MatchOutcome = require(ServerScriptService.Modules.Match.MatchOutcome)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)
local PromotionService = require(ServerScriptService.Modules.Combat.PromotionService)
local ActionGuard = require(ServerScriptService.Modules.Combat.ActionGuard)

local MovementService = {}

local IsFree = MatchQuery.IsFree
local HasSkill = MatchQuery.HasSkill
local FreeChecker = MatchQuery.FreeChecker
local MoveRangeOf = MatchQuery.MoveRangeOf
local CanMove = MatchQuery.CanMove
local AlliesAdjacentTo = MatchQuery.AlliesAdjacentTo
local MatchOfPlayer = MatchRegistry.MatchOfPlayer
local Broadcast = MatchBroadcast.Send
local LogEvent = MatchLog.Event
local Tally = MatchLog.Tally
local Reject = MatchLog.Reject
local CheckGameOver = MatchOutcome.CheckGameOver
local AuthorizeAction = ActionGuard.Authorize
local TryTriggerPromotion = PromotionService.TryTrigger

local TriggerSkills = CombatCore.TriggerSkills
local ConsumeFlame = CombatCore.ConsumeFlame

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

function MovementService.MoveHero(player, heroUid, hexId, match)
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

	if hero.summoner then
		Tally(hero, "summonMoves")
		Tally(hero, "summonDistanceSum", #path)
	end

	for _, ally in ipairs(MatchQuery.AlliesAdjacentTo(match, hero, hero.position)) do
		if HasSkill(ally, "tailwind") then
			Tally(ally, "windBoostApplications")
			if #path > hero.moveRange then
				Tally(ally, "movesEnabledByWindBoost")
			end
			break
		end
	end

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


return MovementService
