local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local MatchQuery = require(script.Parent.MatchQuery)
local MatchClock = require(script.Parent.MatchClock)

local SideOf = MatchQuery.SideOf
local OpponentSide = MatchQuery.OpponentSide
local MoveRangeOf = MatchQuery.MoveRangeOf
local CanMove = MatchQuery.CanMove
local FindStatusEffect = MatchQuery.FindStatusEffect
local WeakPointHunters = MatchQuery.WeakPointHunters
local WeakPointOf = MatchQuery.WeakPointOf

local TurnLimit = MatchClock.TurnLimit
local TurnSecondsLeft = MatchClock.TurnSecondsLeft
local ReconnectSecondsLeft = MatchClock.ReconnectSecondsLeft
local PlacementSecondsLeft = MatchClock.PlacementSecondsLeft

local MatchSnapshot = {}

local AllyOptionsFor
local NextOpenFight

function MatchSnapshot.Bind(deps)
	AllyOptionsFor = deps.AllyOptionsFor
	NextOpenFight = deps.NextOpenFight
end

local function RematchWantedByOther(match, viewerId)
	for _, side in ipairs(match.sides) do
		if side.id ~= viewerId and match.rematch[side.id] then return true end
	end
	return false
end

function MatchSnapshot.Build(match, viewerId)
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

	local campaignNext = nil
	if match.fight and match.phase == "finished"
		and match.winner == viewerId and viewerSide.player then
		local upcoming = NextOpenFight(viewerSide.player, match.fight)
		local data = upcoming and HeroData.GetById(upcoming.hero)
		campaignNext = data and data.name or nil
	end

	local promotionSquares = {}
	for slotIndex, hexId in pairs(match.rules.promotion and GameConfig.PROMOTION_HEX_FOR_SLOT or {}) do
		local side = match.sides[slotIndex]
		local squareState
		if (side and side.promotionUsed) or not MatchQuery.PromotionOpen(match) then
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

	-- Um mapa por uid do dono da oferta, e não uma oferta só: com Kira e Shin no
	-- mesmo time as duas ficam abertas ao mesmo tempo, e o cliente acende a do
	-- herói que estiver selecionado.
	local pendingAlly = nil
	for sourceUid, pending in pairs(match.pendingAlly) do
		if pending.ownerId == viewerId then
			local source = match.heroes[sourceUid]
			local options = AllyOptionsFor(match, source, pending.kind)

			if #options > 0 then
				pendingAlly = pendingAlly or {}
				pendingAlly[sourceUid] = { kind = pending.kind, options = options }
			end
		end
	end

	local summary = nil
	if match.phase == "finished" then
		local mvp, protector, biggest = MatchQuery.MatchHighlights(match, viewerId)

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
		pendingAlly = pendingAlly,
		campaign = match.fight ~= nil,
		campaignNext = campaignNext,
		rematch = (match.phase == "finished" and not match.vsBot) and {
			open = match.rematchOpen == true,
			mine = match.rematch[viewerId] == true,
			theirs = RematchWantedByOther(match, viewerId),
		} or nil,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == viewerId or false,
		turnSecondsLeft = TurnSecondsLeft(match),
		turnTimeLimit = TurnLimit(match),

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

		challenge = match.challengeState,

		-- Só pra quem ganhou as estrelas. O adversário de uma PvP não tem o que
		-- fazer com isso, e o campo mudo é o que evita a tela dele desenhar três
		-- estrelas apagadas do nada.
		fightStars = (match.fightStars and match.fightStars.ownerId == viewerId)
			and match.fightStars or nil,

		winner = winner,
		message = match.message,
		finisher = finisher,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",
		boardFolder = match.boardFolder,
		heroesFolder = match.view.heroesFolder,
	}
end

return MatchSnapshot
