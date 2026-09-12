local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)
local MovementService = require(ServerScriptService.Modules.Combat.MovementService)
local AttackService = require(ServerScriptService.Modules.Combat.AttackService)
local PromotionService = require(ServerScriptService.Modules.Combat.PromotionService)
local BotBrain = require(ServerScriptService.Modules.AI.BotBrain)

local BotTurn = {}

local OpponentSide = MatchQuery.OpponentSide
local LivingHeroesOf = MatchQuery.LivingHeroesOf
local MatchIsLive = MatchRegistry.IsLive
local Broadcast = MatchBroadcast.Send
local Tally = MatchLog.Tally
local AllyOptionsFor = CombatCore.AllyOptionsFor

local BOT_ACTION_DELAY = 0.7

local EndTurn

function BotTurn.Bind(deps)
	EndTurn = deps.EndTurn
end

function BotTurn.PickResurrection(match, botId, options)
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

	PromotionService.Resurrect(nil,
		BotTurn.PickResurrection(match, botId, match.pendingPromotion.options), match)
	task.wait(BOT_ACTION_DELAY)
end

function BotTurn.Play(match, botId)
	local scene = match.sceneToken

	task.spawn(function()
		local function MatchIsLive(other)
			return MatchRegistry.IsLive(other) and other.sceneToken == scene
		end

		task.wait(BOT_ACTION_DELAY)

		if match.rules.botPolicy == "hold" then
			if MatchIsLive(match) and match.phase == "battle"
				and match.turn and match.turn.ownerId == botId then
				EndTurn(nil, match)
			end
			return
		end

		ResolveBotPromotion(match, botId)

		-- A escolha de aliado sai ANTES do laço de ações porque ela muda o
		-- tabuleiro que o laço vai ler: a Troca do Shin reposiciona dois heróis e
		-- vira a postura dele, e planejar o passo com as casas antigas seria
		-- decidir com um tabuleiro que já não existe.
		-- Uma passada por oferta aberta: com Kira e Shin no mesmo time o bot
		-- resolve as duas, e a lista é copiada antes porque resolver mexe no mapa.
		local function TentarEscolhaAliada()
			if not MatchIsLive(match) then return end

			local abertas = {}
			for sourceUid, pending in pairs(match.pendingAlly) do
				if pending.ownerId == botId then table.insert(abertas, sourceUid) end
			end

			for _, sourceUid in ipairs(abertas) do
				local pending = match.pendingAlly[sourceUid]
				local source = pending and match.heroes[sourceUid]

				if source then
					local options = AllyOptionsFor(match, source, pending.kind)
					local pick = #options > 0 and (pending.kind == "swap"
						and BotBrain.PickSwapTarget(match, source, options)
						or BotBrain.PickShieldTarget(match, botId, options)) or nil

					-- Recusar é jogada válida na Troca: sem ganho, o Shin fica
					-- onde está e guarda a postura. O escudo sempre vale.
					if pick then
						PromotionService.ResolveAllyChoice(nil, sourceUid, pick, match)
						task.wait(BOT_ACTION_DELAY)
						if not MatchIsLive(match) then return end
					end
				end
			end
		end

		TentarEscolhaAliada()

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
						MovementService.MoveHero(nil, hero.uid, plan.position, match)
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

			-- O BotBrain só avisa; quem grava é aqui, porque lá não se escreve em
			-- `match`. Conta quantas vezes o freio do estopim segurou um abate que
			-- teria explodido o próprio time.
			if best.avoidedUnsafeKill then
				Tally(best.hero, "unsafeExplosiveKillsAvoided")
			end

			if best.position ~= best.hero.position then
				MovementService.MoveHero(nil, best.hero.uid, best.position, match)
				task.wait(BOT_ACTION_DELAY)

				-- Pisou na própria casa de promoção: TryTriggerPromotion (chamado
				-- dentro de MoveHero) já deixou a escolha pendurada em
				-- match.pendingPromotion. Sem resolver isto agora, AuthorizeAction
				-- bloqueia TODO o resto do turno do bot — inclusive o EndTurn.
				ResolveBotPromotion(match, botId)
			end

			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			if best.target and best.target.isAlive and best.hero.isAlive then
				AttackService.AttackHero(nil, best.hero.uid, best.target.uid, match)
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
					AttackService.AttackHero(nil, best.hero.uid, extra.uid, match)
					task.wait(BOT_ACTION_DELAY)
				end

				-- só reposicionou: encerra o herói pra não reavaliá-lo em loop
				resolved[best.hero.uid] = true
			end

			-- o time andou: quem estava fora do alcance da Kira pode estar do
			-- lado dela agora, e uma Troca que não valia a pena antes do
			-- reposicionamento pode valer agora. Se a oferta já foi usada, isto
			-- não faz nada — ela é uma só por turno.
			TentarEscolhaAliada()
		end

		if MatchIsLive(match) and match.phase == "battle" and match.turn.ownerId == botId then
			EndTurn(nil, match)
		end
	end)
end


return BotTurn
