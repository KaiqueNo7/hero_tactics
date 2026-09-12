local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local HeroView = require(ServerScriptService.Modules.View.HeroView)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local MatchOutcome = require(ServerScriptService.Modules.Match.MatchOutcome)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)

local PromotionService = {}

local PROMOTION_HEXES = MatchQuery.PROMOTION_HEXES
local SideOf = MatchQuery.SideOf
local FindNearestFreeHex = MatchQuery.FindNearestFreeHex
local MatchOfPlayer = MatchRegistry.MatchOfPlayer
local Broadcast = MatchBroadcast.Send
local LogEvent = MatchLog.Event
local Tally = MatchLog.Tally
local CheckGameOver = MatchOutcome.CheckGameOver

local AnnounceArrival = CombatCore.AnnounceArrival
local TriggerSkills = CombatCore.TriggerSkills
local ConsumeFlame = CombatCore.ConsumeFlame
local ApplyStatusEffect = CombatCore.ApplyStatusEffect
local IncreaseAttack = CombatCore.IncreaseAttack
local AllyOptionsFor = CombatCore.AllyOptionsFor
local IsDisabled = CombatCore.IsDisabled

local HasSkill = MatchQuery.HasSkill
local ActiveShieldOf = MatchQuery.ActiveShieldOf
local SideOfPlayer = MatchRegistry.SideOfPlayer

local CreateHero

function PromotionService.Bind(deps)
	CreateHero = deps.CreateHero
end

-- ===================== CASAS DE PROMOÇÃO =====================
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
	AnnounceArrival(match, newHero)

	HeroView.UpdateStats(newHero)
	HeroView.PlayMatchSound(match.view, "Resurrect")

	return newHero
end

function PromotionService.TryTrigger(match, hero)
	if not match.rules.promotion then return end
	if match.phase ~= "battle" or not match.turn then return end
	if match.turn.number < GameConfig.PROMOTION_UNLOCK_TURN then return end

	local side = SideOf(match, hero.ownerId)
	if not side or side.promotionUsed then return end
	if not MatchQuery.PromotionOpen(match) then return end
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

-- A postura do Shin troca a FICHA, não empilha bônus: `baseAttack` vira o número
-- da postura nova e só a DIFERENÇA entra no ataque atual. É o que preserva a
-- aura do Spyke, o barril e qualquer attackBonus aberto — reescrever `attack` de
-- ponta a ponta apagaria os três, e somar um bônus de postura viraria a escada
-- de ATK que esta habilidade justamente não é.
function PromotionService.SetStance(match, hero, stanceKey)
	local stance = GameConfig.SHIN_STANCES[stanceKey]
	if not stance then return end

	hero.stance = stanceKey
	hero.ability = stance.ability
	hero.attackRange = stance.attackRange

	local delta = stance.attack - hero.baseAttack
	hero.baseAttack = stance.attack
	if delta ~= 0 then
		IncreaseAttack(match, hero, delta)
	end

	HeroView.Say(hero, stance.label, "buff")
	HeroView.PlaySkillEffect(hero, "stance" .. stance.ability)
	HeroView.UpdateStats(hero)
end

local function SwapPlaces(match, hero, ally)
	local from, to = hero.position, ally.position

	-- `busy` fecha a porta do turno enquanto as duas peças estão no ar: é a mesma
	-- trava que o passo e o contra-ataque usam, e sem ela um segundo clique
	-- resolveria alcance contra um tabuleiro que ainda não terminou de mudar.
	match.busy = true
	HeroView.PlaySwap(hero, ally)

	match.occupied[from] = ally
	match.occupied[to] = hero
	hero.position, ally.position = to, from
	HeroView.SetPosition(hero, to)
	HeroView.SetPosition(ally, from)

	HeroView.FinishSwap(hero, ally)
	match.busy = false

	-- A postura vira ANTES do pedágio de fogo e das varreduras: o golpe do mesmo
	-- turno já sai com a ficha nova, e quem for recalculado abaixo lê o Shin que
	-- ele é agora, não o que ele era antes de sumir na fumaça.
	local current = GameConfig.SHIN_STANCES[hero.stance]
	if current then PromotionService.SetStance(match, hero, current.next) end

	ConsumeFlame(match, hero, to)
	ConsumeFlame(match, ally, from)

	-- Duas chegadas, duas varreduras: adjacência, aura do Spyke, Confiança do
	-- Dante e furtividade do Nash são recalculadas pelo MESMO gatilho que o passo
	-- normal dispara, então nada aqui precisa saber quais habilidades existem.
	if hero.isAlive then AnnounceArrival(match, hero) end
	if ally.isAlive then AnnounceArrival(match, ally) end

	LogEvent(match, "skill", hero.sideIndex,
		("%s trocou de lugar com %s e ficou em %s"):format(hero.name, ally.name, hero.ability))

	if hero.isAlive then PromotionService.TryTrigger(match, hero) end
	if ally.isAlive then PromotionService.TryTrigger(match, ally) end
end

local ALLY_RESOLVE = {
	shield = function(match, source, target)
		if ActiveShieldOf(match, source) then return end

		ApplyStatusEffect(match, target, {
			type = "shield",
			permanent = true,
			duration = 0,
			source = source,
			grantedTurn = match.turn.number,
		})
		HeroView.SetShieldAura(target, true)
		HeroView.PlaySkillEffect(target, "aegis")
		HeroView.PlaySkillSound("aegis", match.view)

		Tally(source, "shieldsGranted")
		if source then
			source.shieldedAllies = source.shieldedAllies or {}
			if not source.shieldedAllies[target.uid] then
				source.shieldedAllies[target.uid] = true
				Tally(source, "uniqueAlliesShielded")
			end
		end

		LogEvent(match, "skill", target.sideIndex,
			("%s protegeu %s com um escudo"):format(source and source.name or "Kira", target.name))
	end,

	swap = function(match, source, target)
		Tally(source, "shadowSwaps")
		SwapPlaces(match, source, target)
	end,
}

-- O CLIENTE DIZ DE QUEM É A JOGADA. Com duas ofertas abertas ao mesmo tempo,
-- só o alvo não basta pra saber se aquele clique era escudo da Kira ou Troca do
-- Shin — a fonte é o herói que o jogador tem selecionado. O servidor não confia
-- nela: só usa pra achar a oferta, e a oferta é que diz o que fazer.
function PromotionService.ResolveAllyChoice(player, sourceUid, heroUid, match)
	match = match or MatchOfPlayer(player)
	local pending = match and match.pendingAlly[sourceUid]
	if not pending then return end
	if match.phase ~= "battle" or not match.turn then return end
	if match.turn.ownerId ~= pending.ownerId then return end
	if match.busy then return end

	if player then
		local side = SideOfPlayer(match, player)
		if not side or side.id ~= pending.ownerId then return end
	end

	local source = match.heroes[pending.sourceUid]
	local valid = false
	for _, uid in ipairs(AllyOptionsFor(match, source, pending.kind)) do
		if uid == heroUid then valid = true break end
	end

	local target = match.heroes[heroUid]
	if valid and target and target.isAlive
		and target.ownerId == pending.ownerId
		and source and source.isAlive
		and not IsDisabled(source)
	then
		ALLY_RESOLVE[pending.kind](match, source, target)
	end

	-- Fecha SÓ a oferta usada. A do outro herói segue de pé: usar a Égide não
	-- pode gastar a Troca, nem o contrário.
	match.pendingAlly[sourceUid] = nil

	-- A Troca passa por casa em chamas, e fogo mata: sem esta checagem o último
	-- herói podia cair aqui e a partida seguir aberta até a ação seguinte. Mesma
	-- linha que fecha o MoveHero e o AttackHero.
	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match)
end

function PromotionService.Resurrect(player, heroUid, match)
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

return PromotionService
