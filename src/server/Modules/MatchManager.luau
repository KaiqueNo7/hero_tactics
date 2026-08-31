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
-- O DevAccess saiu daqui junto com a liberação por nível: quem sabe quais heróis
-- o jogador pode levar (inclusive as exceções de testador) é o HeroUnlockService.
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)
local Campaign = require(ReplicatedStorage.Modules.Campaign)

-- ===== CONSULTA E DECISÃO MORAM FORA =====
-- MatchQuery: as perguntas ao tabuleiro (só leitura, nunca cede).
-- BotBrain: a decisão do bot (pura — recebe o tabuleiro, devolve um plano).
-- Este arquivo ficou com o que MUDA a partida: turnos, combate, skills,
-- promoção, ciclo de vida, e a EXECUÇÃO das jogadas que o BotBrain escolheu.
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)
local BotBrain = require(ServerScriptService.Modules.BotBrain)

-- Apelidos das consultas. Alias em vez de reescrever as centenas de chamadas
-- existentes pra `MatchQuery.X(...)`: a mudança seria enorme, arriscada e não
-- deixaria nada mais legível — o objetivo do corte era tirar código do arquivo,
-- não trocar a cara de cada linha que ficou.
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
			-- QUAL gatilho está correndo. A mesma skill pode estar em vários
			-- (a Furtividade escuta cinco), e deduzir isso de `target` já era
			-- frágil: no onDamage o `target` é o ATACANTE, e no dano sem autor
			-- (veneno, fogo, maldição) ele chega nil como num turno qualquer.
			scope.trigger = triggerName
			-- o efeito visual sai com a assinatura da skill que está disparando,
			-- então a skill só diz EM QUEM ele acontece (e, se precisar, qual
			-- variante — o goodLuck tem uma pro sucesso e outra pro fracasso)
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

-- ===================== DANO / CURA =====================
local ApplyDamage, KillHero

-- ===================== TÚMULO PENDENTE (Golem) =====================
-- Todo herói é enterrado na hora em que morre, menos o Golem: ele estilhaça, e
-- o corpo grande só vira lápide quando o ÚLTIMO pedaço cair (ver
-- Skills.shatter e a api DeferGrave). Enquanto isso ele fica morto, SEM túmulo
-- no tabuleiro e sem valer como opção de ressurreição — `graveDestroyed = true`
-- é o que segura as duas coisas (é o campo que o AttackGrave, o
-- TryTriggerPromotion e o cliente já leem).
local function RaisePendingGrave(match, hero)
	-- ONDE O ÚLTIMO PEDAÇO CAIU, não onde o corpo grande rachou. É lá que o
	-- Golem terminou de morrer, e é a casa que o jogador está olhando quando a
	-- lápide sobe — o lugar do estilhaçar já ficou pra trás muitos turnos antes.
	-- `graveHex` é carimbado pelo KillHero a cada pedaço que cai, então ele
	-- sempre guarda o último. Se nenhum pedaço chegou a nascer, sobra a casa do
	-- próprio corpo.
	--
	-- Aquela casa acabou de ser liberada pela morte do pedaço, então o
	-- FindNearestFreeHex devolve ela mesma no caso normal; só expande em anéis
	-- se alguma coisa tiver ocupado, e nunca numa casa de promoção (mesma regra
	-- do enterro comum, mais abaixo).
	local hexId = FindNearestFreeHex(match, hero.graveHex or hero.position, PROMOTION_HEXES)
	-- tabuleiro cheio ao redor: sai sem enterrar e sem apagar a pendência, que
	-- é retentada na próxima baixa
	if not hexId then return end

	-- Baixa a bandeira ANTES de levantar a pedra: é o que garante que dois
	-- eventos de morte no mesmo lance (ou uma segunda passada do resolvedor)
	-- não empilhem dois túmulos do mesmo Golem. Um túmulo por ciclo de morte.
	hero.gravePending = false

	hero.graveHitsLeft = GameConfig.GRAVE_HITS
	hero.graveDestroyed = false
	hero.position = hexId
	match.occupied[hexId] = hero

	-- Sem som próprio: o túmulo sobe no mesmo instante em que o último pedaço
	-- cai, e a morte dele já traz o áudio. O CreateGrave entra desbotando, o
	-- que dá leitura visual suficiente pra pedra que apareceu.
	HeroView.CreateGrave(hero)
end

-- Roda no fim de CADA morte, e varre o tabuleiro em vez de olhar só o morto da
-- vez: quem decide o enterro do Golem é a soma dos pedaços, não este cadáver
-- específico. Barato (no máximo 6 heróis por partida) e imune à ordem em que os
-- eventos chegam — se dois pedaços caírem no mesmo lance, a última passada
-- encontra o tabuleiro já quieto e o túmulo sobe uma vez só.
--
-- A pergunta é sempre "sobrou algum pedaço DESTE Golem de pé?", lida do
-- tabuleiro de agora (`graveOwner`), e não de uma lista tirada no momento do
-- estilhaçar. Vale pra 2 pedaços ou pra 10.
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

	-- Abate contabilizado antes de qualquer skill correr: o onDie do Golem
	-- estilhaça e cria heróis novos, e o onKill do Merlin pode matar de novo em
	-- cascata. Somando depois, o crédito se perderia no meio dessa cadeia.
	-- `attacker ~= hero` porque o Golem se "mata" ao estilhaçar.
	if attacker and attacker ~= hero and attacker.stats and not hero.summoner then
		attacker.stats.kills += 1
	end

	-- a casa NÃO é liberada: o túmulo continua ocupando o hex (Golem é a
	-- exceção — ver noGrave abaixo, que libera a própria antes das invocações)
	TriggerSkills(match, hero, "onDie")

	-- Quem abateu também é avisado, com o morto chegando em ctx.target. Vem
	-- DEPOIS do onDie de propósito: aí o tabuleiro que o finalizador enxerga já
	-- contabiliza a baixa.
	-- Se o autor morreu no mesmo lance — troca por contra-ataque —, o próprio
	-- TriggerSkills barra, porque só o onDie roda em herói morto.
	if attacker and attacker ~= hero then
		TriggerSkills(match, attacker, "onKill", hero)
	end

	-- A BAIXA É ANUNCIADA AO TABULEIRO INTEIRO. `onDie` só avisa quem morreu e
	-- `onKill` só quem matou — uma habilidade que reage à morte dos OUTROS não
	-- tinha por onde saber. É o caso do Faro de Sangue do Merlin: sem este
	-- laço, o lobo só engordava no próximo turno ou no próximo passo dele, e o
	-- jogador via o aliado cair sem nada acontecer na ficha. Vem depois do
	-- onKill pra que o abate e a baixa cheguem na mesma ordem de sempre.
	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(match, other, "onAnyDeath", nil, false, { deadHero = hero })
		end
	end

	-- Golem: perder a PRIMEIRA vida não é uma derrota de verdade — ele quebra
	-- em golens menores (Skills.shatter, disparado pelo onDie acima, que já
	-- marcou hero.noGrave = true, liberou a casa e marcou os pedaços). Sem
	-- lápide, sem animação de morte, sem destaque de finalização: pro jogador,
	-- nada "morreu" ainda — só rachou. O túmulo dele fica PENDENTE e sobe
	-- quando o último pedaço cair (ver ResolvePendingGraves, no fim desta
	-- função). O contador de baixas (Faro de Sangue do Merlin) segue vendo
	-- isAlive=false normalmente, porque em número de corpos isso já é uma
	-- baixa; só a APRESENTAÇÃO some.
	--
	-- São TRÊS caminhos aqui embaixo, e vale ler os três juntos: o corpo que
	-- estilhaçou (nada acontece), o PEDAÇO que cai (morre de verdade, mas sem
	-- pedra própria — o enterro do Golem é um só) e todo o resto do elenco
	-- (morte e lápide, como sempre foi).
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
		-- Destaque do finalizador: fica guardado até o próximo Broadcast e vai UMA
		-- vez só. Morte sem autor (veneno, Morte Súbita) chega aqui com attacker nil
		-- e não gera destaque — não teria de quem mostrar o retrato.
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

		-- PEDAÇO DE GOLEM NÃO TEM LÁPIDE PRÓPRIA. Os três corpos são o MESMO
		-- personagem, e ele é enterrado UMA vez: no túmulo do corpo grande, que
		-- sobe quando o último pedaço cai. A morte do pedaço é normal em tudo
		-- mais (animação, som, destaque de quem finalizou) — o que não existe é
		-- a pedra.
		--
		-- Sem isto, a queda de cada pedaço levantava um túmulo "Golem", e a
		-- Casa de Promoção passava a oferecer TRÊS opções com o mesmo nome:
		-- quem escolhesse errado trazia de volta um mini-golem de 5 de vida no
		-- lugar do corpo grande. A casa é liberada porque não fica nada nela.
		if hero.graveOwner then
			hero.graveDestroyed = true
			hero.graveHitsLeft = 0

			-- carimba a casa: se este for o ÚLTIMO pedaço, é aqui que a lápide
			-- do corpo grande vai nascer (ver RaisePendingGrave)
			hero.graveOwner.graveHex = hero.position

			if match.occupied[hero.position] == hero then
				match.occupied[hero.position] = nil
			end
			HeroView.PlayAnimation(hero, "die")
			HeroView.Destroy(hero)
		else
			-- A lápide nasce com vida própria (ver AttackGrave): o inimigo pode gastar
			-- GRAVE_HITS golpes pra apagá-la e negar a ressurreição deste herói
			-- específico. `graveDestroyed` é o que trava isso pra sempre nesta partida,
			-- mesmo depois dos golpes acabarem — ver TryTriggerPromotion.
			--
			-- ANTES do CreateGrave, não depois: o crachá de golpes restantes é montado
			-- dentro dele (BuildGraveBadge) e LÊ estes campos. Com a ordem invertida, o
			-- primeiro herói a morrer estourava com "arithmetic on nil", matando a
			-- corrotina do bot no meio do turno — e a partida congelava, porque o turno
			-- nunca voltava pro jogador.
			hero.graveHitsLeft = GameConfig.GRAVE_HITS
			hero.graveDestroyed = false

			-- Lápide NUNCA fica em cima de uma casa de promoção: ela ocupa o hex para
			-- sempre e selaria a casa pelo resto da partida — inclusive contra o próprio
			-- dono, que perderia a jogada sem entender por quê. Aconteceu em teste: um
			-- herói morreu na casa e ninguém mais conseguiu usá-la.
			--
			-- A lápide escorrega para a casa livre mais próxima em vez de sumir: ela é
			-- o recurso da ressurreição, e apagá-la puniria quem morreu ali.
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

	-- DEPOIS de resolver a apresentação deste morto, sempre: se ele era o último
	-- pedaço de um Golem, o túmulo do corpo grande sobe agora — e a casa que o
	-- pedaço acabou de liberar já entra na busca por casa livre, então o mais
	-- comum é a pedra nascer exatamente onde o último caiu.
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

function ApplyDamage(match, hero, amount, attacker, isCounterAttack, credit, sourceKey)
	if not hero.isAlive then return end

	-- passivas que reduzem dano recebido (ex: autoDefense do Ralph)
	for _, key in ipairs(hero.abilities) do
		local skill = Skills[key]
		if skill and skill.modifyIncomingDamage then
			amount = skill.modifyIncomingDamage(amount, {
				hero = hero, attacker = attacker, isCounterAttack = isCounterAttack or false,
			})
		end
	end

	-- passivas de ALIADOS por perto (ex: emberShield da Lucy) — mesmo formato do
	-- loop acima, mas olhando quem está do lado de quem apanhou, não a própria
	-- vítima. Primeira aura de dano do jogo; até aqui toda passiva olhava só a
	-- ficha de quem estava recebendo.
	for _, ally in ipairs(GetAlliesInRange(match, hero, 1)) do
		for _, key in ipairs(ally.abilities) do
			local skill = Skills[key]
			if skill and skill.modifyIncomingDamageNearby then
				local before = amount
				amount = skill.modifyIncomingDamageNearby(amount, {
					hero = hero, ally = ally, attacker = attacker, isCounterAttack = isCounterAttack or false,
				})

				-- balão SOBRE QUEM ABSORVEU (a Lucy), não sobre quem apanhou — é
				-- crédito pelo bloqueio, não uma segunda leitura do mesmo golpe.
				-- "+N" e cor própria (ver TEXT_STYLES.absorb): não é dano dela, é
				-- dano que deixou de acontecer por causa dela.
				local absorbed = before - amount
				if absorbed > 0 then
					HeroView.Say(ally, "+" .. tostring(absorbed), "absorb")
				end
			end
		end
	end

	-- efeito 'wound' soma dano extra (mesma regra do hero.js)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == "wound" then amount += 1 end
	end

	-- ===== TELEMETRIA =====
	-- Aqui e só aqui. Todo dano do jogo passa por esta função — golpe, revide,
	-- skill, veneno, Morte Súbita, maldição de túmulo — então instrumentar este
	-- ponto pega tudo, e nenhuma skill nova precisa lembrar de somar nada.
	--
	-- Guarda o dano que REALMENTE tirou vida, e não o número cheio do golpe. Um
	-- herói de 10 de vida não pode fechar a partida com 11 recebidos sem cura no
	-- meio: a tela de resultado tem que fechar a conta. Pelo mesmo motivo o dano
	-- causado é o que saiu da vida do outro — excesso de golpe não vira placar.
	--
	-- O balão "-N" em cima do herói continua mostrando o número cheio (ver
	-- HeroView.Say logo abaixo): lá o que importa é a força do golpe.
	--
	-- Sem autor = dano de ambiente: conta como recebido, mas não credita
	-- ninguém. `credit` responde pelo dano ATRASADO (veneno, fogo no chão) —
	-- credita quem plantou sem tratar a ticada como golpe dele.
	local landed = math.min(amount, math.max(hero.currentHp, 0))
	local author = attacker or credit
	hero.stats.taken += landed
	if author and author.stats then
		author.stats.dealt += landed
		author.stats.biggestHit = math.max(author.stats.biggestHit, landed)
	end

	hero.currentHp -= amount
	HeroView.UpdateStats(hero)
	-- Sem autor = dano de ambiente (veneno, morte súbita), e esse é mudo: o som
	-- de pancada é de golpe corpo a corpo, e o veneno tica em vários heróis na
	-- mesma virada de turno. O clarão vermelho e o número continuam.
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

-- `source` é QUEM curou, e é opcional porque quase toda cura do jogo é em si
-- mesmo (Ceos, Merlin, Nash). Só a Elaria cura outro herói, e é a única chamada
-- que passa o parâmetro — ver Skills.health.
local function Heal(match, hero, amount, source)
	if not hero.isAlive then return end

	local before = hero.currentHp
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)

	-- o que REALMENTE entrou na barra, não o que foi oferecido: curar 2 em quem
	-- está com 1 de dano faltando vale 1. Sem isso a Elaria pareceria melhor do
	-- que é justamente nos turnos em que a cura dela se perde.
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

local function IncreaseAttack(match, hero, amount)
	hero.attack += amount
	HeroView.UpdateStats(hero)
	HeroView.Say(hero, (amount > 0 and "+" or "") .. tostring(amount) .. " ATK", amount > 0 and "buff" or "debuff")

	LogEvent(match, "buff", hero.sideIndex, amount > 0
		and ("%s ganhou %d de ataque (agora %d)"):format(hero.name, amount, hero.attack)
		or ("%s perdeu %d de ataque (agora %d)"):format(hero.name, -amount, hero.attack))
end

local CC_EFFECTS = { paralysis = true, freeze = true }

local REJECTIONS = {
	PARALYZED = true, NOT_YOUR_TURN = true, OUT_OF_RANGE = true,
	OCCUPIED = true, INVALID_TARGET = true, INVALID_MOVE = true, TAUNTED = true,
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
}

-- ===================== STATUS EFFECTS =====================
-- PONTO ÚNICO. Todo efeito do jogo entra por aqui: o veneno da Vic, o gelo do
-- Kor (pelo golpe e pela Tempestade), o Furor do Karo e o bônus do barril — uns
-- pelo wrapper da API das skills, o barril chamando direto. É o que torna a
-- imunidade do Frenesi uma regra só, em vez de um `if` repetido em cada skill
-- que hoje aplica debuff (e em cada uma que vier depois).
local function ApplyStatusEffect(match, hero, effect)
	-- Merlin em Frenesi não pega debuff. A checagem é por TIPO
	-- (GameConfig.IsNegativeEffect), então o lobo continua recebendo o que é
	-- bom pra ele: o empréstimo de ataque do barril passa direto.
	if hero.frenzyActive and GameConfig.IsNegativeEffect(effect.type) then
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

local function ClearStatusEffects(hero)
	hero.statusEffects = {}
	HeroView.UpdateStats(hero)
end

-- Limpa SÓ os debuffs, preservando o resto. Existe pro instante em que o Frenesi
-- liga: um lobo que já estava envenenado continuaria queimando por três turnos
-- sob uma habilidade que se anuncia como imunidade, e o jogador leria isso como
-- bug. Não dá pra reaproveitar o ClearStatusEffects acima — ele leva junto o
-- bônus de ataque do barril, e aí a "imunidade" custaria caro ao próprio Merlin.
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

-- Roda no fim de CADA turno, pra todo herói vivo. Aplica o efeito e decrementa.
--
-- DUAS CADÊNCIAS. Por padrão um efeito só corre no fim do turno do DONO do
-- herói — ou seja, uma vez por rodada. Quem marca `ticksEveryTurn` corre em toda
-- passagem de turno, dos dois lados: é o caso do veneno, que precisa ser sentido
-- enquanto a rodada acontece e não só quando a vez volta. `ownTurnEnding` diz
-- qual das duas situações é esta chamada.
--
-- O gelo e o bônus do barril ficam de fora dessa pressa de propósito: o prazo
-- deles foi calibrado em rodadas, e passar a decrementar duas vezes por rodada
-- cortaria a duração pela metade sem ninguém pedir.
--
-- EFEITO NÃO É CONSUMIDO NO TURNO EM QUE ENTROU. O Kor congela contra-atacando,
-- ou seja, no meio do turno do próprio inimigo — que a essa altura já andou as
-- três casas dele. Sem esta regra, o gelo ainda perdia um dos dois turnos aqui,
-- no fim desse mesmo turno: o jogador congelava o inimigo, via ele andar 3 e
-- ainda descolava o efeito na metade do tempo. Vale pra todo efeito com prazo
-- (o veneno pego em contra-ataque tinha exatamente o mesmo furo).
local function ProcessStatusEffects(match, hero, ownTurnEnding)
	local remaining = {}

	for _, effect in ipairs(hero.statusEffects) do
		-- não é a vez deste efeito: atravessa a passagem intacto
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
			-- acabou o empréstimo: o bônus temporário do barril é devolvido aqui,
			-- no mesmo lugar em que o efeito sai da lista
			IncreaseAttack(match, hero, -effect.attackBonus)
		end
	end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
end

-- ===================== FOGO NO CHÃO (Karo) =====================
-- Todo o resto do jogo guarda efeito DENTRO do herói (hero.statusEffects). O
-- fogo do Caminho de Chamas não cabe lá: ele fica na CASA e continua queimando
-- depois que o Karo saiu de cima. Por isso mora numa tabela por partida.
--
--   match.flames[hexId] = { ownerId, source, duration, appliedTurnToken }
--
-- Fogo NÃO ocupa a casa: não entra em match.occupied, não bloqueia passagem e
-- não é alvo de nada. Ele só cobra pedágio de quem atravessa — que é o que o
-- torna zona de controle e não parede.
local function LightFlame(match, hexId, hero)
	if not HexGrid.Exists(hexId) then return end

	match.flames[hexId] = {
		ownerId = hero.ownerId,
		source = hero,
		duration = GameConfig.FLAME_DURATION,
		-- mesmo carimbo dos status de herói: um prazo nunca é consumido no turno
		-- em que começou, senão o rastro aceso agora venceria no fim deste mesmo
		-- turno e o inimigo nunca chegaria a pisar nele
		appliedTurnToken = match.turnToken,
	}
	HeroView.CreateFlame(match.view, hexId, hero.sideIndex)
end

local function ClearFlame(match, hexId)
	if not match.flames[hexId] then return end
	match.flames[hexId] = nil
	HeroView.DestroyFlame(match.view, hexId)
end

-- Uma vez por RODADA, no fim do turno de quem acendeu. A cadência é a mesma do
-- gelo e do bônus do barril, e não a do veneno: FLAME_DURATION foi calibrado em
-- turnos do Karo, e decrementar nas duas passagens cortaria o rastro pela
-- metade sem ninguém pedir.
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

-- Qualquer travessia CONSOME a chama — não é uma zona que fica cobrando de todo
-- mundo até o prazo natural acabar, é pedágio de UMA passagem só. A chama some
-- (efeito + som) IMEDIATAMENTE depois, sempre — o que muda entre dono e inimigo
-- é só se rola DANO junto.
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

-- ===================== MOVIMENTO =====================
-- Reposiciona sem bookkeeping de turno — usado pelo empurrão do rage
local function ForceMove(match, hero, hexId)
	if not IsFree(match, hexId) then return false end

	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	HeroView.SetPosition(hero, hexId)
	ConsumeFlame(match, hero, hexId)
	return true
end

-- ===================== API DAS SKILLS =====================
-- Uma API por partida: as closures já sabem em qual tabuleiro mexer, então a
-- skill continua escrita como antes (ctx.api.ApplyDamage(...)) sem saber que
-- existem outras partidas rodando.
local function RemoveStatusEffect(match, hero, effectType)
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

		-- carimba em que turno o efeito entrou: é o que o ProcessStatusEffects usa
		-- pra não gastar um prazo no mesmo turno em que ele começou
		ApplyStatusEffect = function(hero, effect)
			effect.appliedTurnToken = match.turnToken
			ApplyStatusEffect(match, hero, effect)
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
					if occupant and occupant ~= origin and not visited[neighbor.id] then
						visited[neighbor.id] = true
						depth[neighbor.id] = depth[current] + 1
						table.insert(queue, neighbor.id)
						table.insert(edges, {
							from = current,
							to = neighbor.id,
							depth = depth[neighbor.id],
						})
						if occupant.isAlive and occupant.ownerId ~= origin.ownerId then
							table.insert(hit, occupant)
						end
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

		ClearStatusEffects = ClearStatusEffects,
		ClearNegativeEffects = ClearNegativeEffects,

		-- Contagem no TABULEIRO INTEIRO, não por alcance. O GetAlliesInRange só
		-- enxerga vizinhança, e o Merlin precisa saber se sobrou alguém do time
		-- dele em qualquer casa. Devolve vivos e total (o total inclui os mortos,
		-- porque heróis abatidos continuam em match.heroes com isAlive = false).
		-- Não conta o próprio herói: assim "vivos == 0 e total > 0" lê direto
		-- como "sou o último, e eu tinha alcateia".
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

		-- Karo: acende uma casa. Fogo não ocupa hex nem bloqueia passagem —
		-- só cobra pedágio de quem atravessa (ver o loop de caminhada no
		-- MatchManager.MoveHero, que cobra casa por casa em sincronia com o
		-- passo visual).
		LightFlame = function(hexId, hero) LightFlame(match, hexId, hero) end,

		-- Karo: brilho só cosmético nas 6 casas a distância 1 do golpe giratório
		-- — não muda quem é atingido (isso continua sendo GetEnemiesInRange, do
		-- flameStrike), só deixa o alcance visível antes/durante o impacto.
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

		-- Golem: nasce um herói no meio da partida. O primeiro chamado cai na
		-- própria casa de quem invocou (livre desde o SuppressGrave), e o
		-- seguinte na primeira casa livre ao lado — o FindNearestFreeHex devolve
		-- a casa de origem quando ela está vazia e vai expandindo em anéis
		-- conforme elas são ocupadas.
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

		-- Golem: a PRIMEIRA vida cai sem lápide NA HORA. Libera a casa JÁ,
		-- porque o primeiro golem invocado logo em seguida vai querer nascer
		-- exatamente nela — e marca noGrave, que o KillHero usa pra pular
		-- animação de morte, destaque de finalização e o enterro imediato (ver
		-- o comentário lá).
		SuppressGrave = function(hero)
			hero.noGrave = true
			if match.occupied[hero.position] == hero then
				match.occupied[hero.position] = nil
			end
		end,

		-- Golem: o túmulo fica PENDENTE até os pedaços caírem. A ligação é
		-- marcada NOS PEDAÇOS (`graveOwner` aponta pro registro do corpo
		-- grande), não numa lista de uids guardada no Golem: uid é reusado a
		-- cada geração nova (matchId_dono_dataId), então uma lista velha podia
		-- acabar apontando pros pedaços da geração seguinte. Com a marca no
		-- pedaço, "sobrou alguém deste Golem?" é uma pergunta feita ao
		-- tabuleiro de agora.
		--
		-- Nenhum pedaço nascido (tabuleiro sem casa livre) = nada marcado, e o
		-- ResolvePendingGraves levanta a lápide ainda nesta mesma morte.
		DeferGrave = function(hero, minions)
			hero.gravePending = true
			for _, minion in ipairs(minions or {}) do
				minion.graveOwner = hero
			end
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

local function CanMove(match, hero)
	if not match.turn then return false end
	if match.turn.bonusMove[hero.uid] then return true end
	return not (match.turn.moved[hero.uid] or match.turn.attacked[hero.uid])
end

-- ===================== SNAPSHOT =====================
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
	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

local function PlacementSecondsLeft(match)
	if match.phase ~= "placement" or not match.placementStartedAt then return nil end
	if GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return nil end

	local elapsed = os.clock() - match.placementStartedAt
	return math.max(0, math.floor(GameConfig.PLACEMENT_TIME_LIMIT - elapsed))
end

-- O estado é montado por espectador: quem olha precisa saber o que é dele,
-- não quem é "o player" e quem é "o bot".
local function Snapshot(match, viewerId)
	local viewerSide = SideOf(match, viewerId)
	local opponent = OpponentSide(match, viewerId)

	-- ===== A ORDEM DA COLUNA SAI DAQUI =====
	-- `match.heroes` é dicionário, e a ordem de `pairs` muda entre snapshots — a
	-- coluna de retratos do cliente segue esta lista, então sem ordenar os
	-- retratos trocavam de lugar sozinhos a cada atualização.
	--
	-- Ordena os REGISTROS, não a lista pronta: só o registro tem `sideIndex` e
	-- `dataId`: o oco do invisível (logo abaixo) nem carrega dataId.
	--
	-- Ordenar por uid era um bug: uid é `matchId_dono_dataId`, uma STRING, e
	-- "1_X_14" < "1_X_2" na comparação textual. O Golem (14) vinha antes do Vic
	-- (2), e quando ele estilhaçava os três registros dele (14, 15, 16) tomavam
	-- as três vagas da coluna e os outros heróis do time sumiam da tela.
	--
	-- `sideIndex` e não `ownerId`: ownerId é número pro jogador e a string "BOT"
	-- pro bot, e comparar os dois tipos com `<` estoura.
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
		-- ===== O QUE ESTE ESPECTADOR NÃO PODE VER =====
		-- Primeiro caso do jogo em que o mesmo herói vai diferente pros dois
		-- lados. O que a sombra esconde é a MIRA, não a existência: a ficha
		-- (nome, vida, ataque) vai junto, porque é informação de placar e o
		-- adversário decide a jogada com ela. Quem apaga o boneco no tabuleiro e
		-- tira a casa do alvo é a marca `hidden`, lida pelo cliente.
		--
		-- A CASA continua indo. É a decisão de projeto: o adversário percebe que
		-- não dá pra passar ali, sem saber por quê. Como STEALTH_RANGE e
		-- BASE_MOVE_RANGE são ambos 2, pra quase todo o elenco o passo que
		-- revelaria o bloqueio é o mesmo que revela o Shadow.
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

			-- Só pro DONO, e só quando ele está escondido: é o que faz o cliente
			-- desenhar o próprio vulto translúcido em vez de sólido. Pro
			-- adversário este herói nem chegou até aqui (ver o desvio acima).
			stealth = hero.stealth or nil,
			name = hero.name,
			position = hero.position,
			currentHp = hero.currentHp,
			maxHp = hero.maxHp,
			-- já somado o bônus da sombra (Nash), do mesmo jeito que o moveRange
			-- abaixo já vem descontado o gelo: o número que a UI mostra é o que o
			-- golpe vai causar. Só o DONO chega a ver isso — o Nash invisível nem
			-- entra no snapshot do adversário (ver o desvio lá em cima).
			attack = GameConfig.EffectiveAttack(hero),
			baseAttack = hero.baseAttack,
			ability = hero.ability,
			attackRange = hero.attackRange,
			moveRange = MoveRangeOf(match, hero), -- já descontado o gelo
			isAlive = hero.isAlive,

			-- o cliente precisa saber POR QUE o herói anda menos: sem isso o
			-- congelado só parece ter perdido alcance sem explicação
			frozen = FindStatusEffect(hero, "freeze") ~= nil,

			-- turnos restantes de veneno, não só "está envenenado?": a coluna de
			-- retratos mostra o mesmo selo em 3 estágios que o crachá do tabuleiro
			-- mostrava, e sem o número não dá pra saber qual estágio é
			poisonTurns = (FindStatusEffect(hero, "poison") or {}).duration or 0,
			isMine = hero.ownerId == viewerId,
			-- 1 = azul, 2 = vermelho. Vai junto pra UI pintar o retrato com a
			-- MESMA cor do anel embaixo do herói no tabuleiro: em PvP quem joga
			-- de lado 2 é dono dos vermelhos, e colorir por "é meu?" mentiria.
			sideIndex = hero.sideIndex,
			hasMoved = match.turn ~= nil and not CanMove(match, hero),
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,

			-- Só importa quando isAlive=false: quantos golpes a lápide ainda
			-- aguenta, e se ela já foi destruída (nesse caso não é mais alvo de
			-- ataque nem opção de ressurreição — ver AttackHero/TryTriggerPromotion).
			-- nil pra herói vivo, de propósito: não é "0 hits", é "não se aplica".
			graveHitsLeft = (not hero.isAlive) and hero.graveHitsLeft or nil,
			graveDestroyed = (not hero.isAlive) and hero.graveDestroyed or nil,

			-- Uid do PAI, não um "sou invocação": sem ele o cliente não tem como
			-- saber que pedaço de Golem e caveira de Morn moram no card de quem
			-- os gerou em vez de gastarem uma vaga própria. `sameBody` separa os
			-- dois casos — o pedaço É o corpo do Golem partido (e por isso mantém
			-- o card "de pé" e as sub-linhas), a caveira é só uma peça a mais.
			summonOf = (hero.graveOwner or hero.summoner)
				and (hero.graveOwner or hero.summoner).uid or nil,
			sameBody = hero.graveOwner ~= nil or nil,

			-- O que ele fez na partida. SÓ NO FIM: durante o jogo isto seria uma
			-- tabela a mais por herói em cada um dos muitos snapshots por turno,
			-- pra alimentar uma tela que ninguém está vendo ainda.
			stats = (match.phase == "finished") and {
				dealt = hero.stats.dealt,
				taken = hero.stats.taken,
				healed = hero.stats.healed,
				kills = hero.stats.kills,
				biggestHit = hero.stats.biggestHit,
			} or nil,
		})
	end

	-- Os barris viajam separados dos heróis porque não têm nada em comum com eles
	-- além de ocupar casa: sem vida, sem dono, sem turno. O cliente usa isto pra
	-- (1) não prometer passagem por cima deles e (2) aceitar o clique de ataque.
	local barrels = {}
	for _, barrel in pairs(match.barrels) do
		table.insert(barrels, {
			uid = barrel.uid,
			position = barrel.position,
			hitsLeft = barrel.hitsLeft,
		})
	end
	table.sort(barrels, function(a, b) return a.uid < b.uid end)

	-- (a ordem dos heróis já foi resolvida lá em cima, antes do laço — ver o
	-- comentário sobre `ordered`. Ordenar de novo aqui, por uid, era exatamente
	-- o bug que derrubava metade do time da coluna.)

	local winner = nil
	if match.winner == "draw" then
		winner = "draw"
	elseif match.winner then
		winner = (match.winner == viewerId) and "win" or "loss"
	end

	-- Vai como ARRAY, não como dicionário {[id] = true}: dicionário com chave
	-- numérica atravessa o RemoteEvent de forma inconsistente (às vezes chega
	-- com chave string), e era por isso que o herói escolhido pelo adversário
	-- nem sempre aparecia marcado como usado no cliente.
	local usedHeroIds = {}
	for dataId in pairs(match.usedHeroIds) do
		table.insert(usedHeroIds, dataId)
	end
	table.sort(usedHeroIds)

	-- O que ESTE espectador ainda não liberou. Vai como array pelo mesmo motivo
	-- do usedHeroIds acima: tabela com chave numérica atravessa o RemoteEvent de
	-- forma inconsistente.
	local lockedHeroIds = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if not viewerSide.unlockedIds[data.id] then
			table.insert(lockedHeroIds, data.id)
		end
	end

	-- `isMine` é resolvido por espectador, igual ao resto do snapshot: o cliente
	-- pinta o destaque com a cor do lado e precisa saber se foi o time dele que
	-- abateu ou que apanhou.
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

	-- Estado das duas casas de promoção — igual pros dois espectadores, não
	-- muda por ponto de vista. "used" vence "active" (uma vez gasta, fica gasta
	-- mesmo depois do turno de liberação); antes do turno de liberação é sempre
	-- "inactive", mesmo que por algum motivo já estivesse marcada como usada.
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
		table.insert(promotionSquares, { hex = hexId, ownerSideIndex = slotIndex, state = squareState })
	end
	table.sort(promotionSquares, function(a, b) return a.hex < b.hex end)

	-- Só o dono da escolha a recebe — o adversário não vê "fulano está
	-- escolhendo", só o resultado quando sair (a mensagem do Broadcast já cobre
	-- isso). `options` são uids que já estão em `heroes` acima; o cliente cruza
	-- os dois pra montar os cartões da escolha.
	local pendingPromotion = nil
	if match.pendingPromotion and match.pendingPromotion.ownerId == viewerId then
		pendingPromotion = { options = match.pendingPromotion.options }
	end

	-- ===== RESUMO DA PARTIDA =====
	-- Do ponto de vista de QUEM RECEBE, como todo o resto do snapshot: cada
	-- jogador vê o destaque do PRÓPRIO time. Num PvP os dois recebem resumos
	-- diferentes da mesma partida, e é isso que se quer — "meu destaque" não é
	-- uma pergunta com resposta global.
	--
	-- Destaque e escudo são separados porque medem coisas opostas e o mesmo
	-- herói raramente é os dois: quem converte turno em dano e quem gastou a
	-- vida pra que o outro pudesse. Empate desempata pelo abate, que é o dano
	-- que valeu mais.
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
			-- uid e não o herói inteiro: o cliente já tem a ficha completa na
			-- lista `heroes` acima e cruza pelo uid, como faz na Casa de Promoção
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
		placementSecondsLeft = PlacementSecondsLeft(match),
		placementTimeLimit = GameConfig.PLACEMENT_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,

		-- O contra-ataque é UM por turno, valendo pros dois lados: quem defende
		-- revida no primeiro golpe do turno e ninguém mais revida até o turno
		-- virar. O cliente mostra isso como um selo aceso/apagado.
		counterAttackUsed = match.turn and match.turn.counterAttack or false,

		arena = match.theme and match.theme.id or nil,
		arenaName = match.theme and match.theme.name or nil,

		winner = winner,
		message = match.message,
		finisher = finisher,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",

		-- o cliente pinta as casas por aqui: procurar "Board" pelo nome no
		-- Workspace acharia o tabuleiro da partida errada
		boardFolder = match.boardFolder,

		-- Pela mesma razão do boardFolder: o cliente precisa alcançar os bonecos
		-- pra aplicar a transparência da furtividade, e "Heroes_" pelo nome no
		-- Workspace acharia a arena da dupla ao lado. Só a PASTA vai — quem está
		-- dentro dela o Roblox replica sozinho, e o que o espectador pode saber
		-- sobre cada um continua sendo decidido na lista `heroes` acima.
		heroesFolder = match.view.heroesFolder,
	}
end

local function Broadcast(match, message)
	match.message = message
	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, Snapshot(match, side.id))
		end
	end
	match.message = nil

	-- o destaque é evento, não estado: sai num snapshot só, senão a animação
	-- dispararia de novo a cada atualização até o fim do turno
	match.finisher = nil
end

-- ===================== HERÓIS =====================
function CreateHero(match, dataId, ownerId, hexId)
	local data = HeroData.GetById(dataId)
	if not data then return nil end

	local hero = {
		-- o matchId entra no uid porque o lado bot se chama "BOT" nas duas
		-- partidas: sem prefixo, dois jogos contra o bot colidiriam
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

		-- Shadow: invisível agora. Nasce FALSO mesmo pro Shadow — o primeiro
		-- onTurnStart resolve. Nascer verdadeiro esconderia qualquer herói cujo
		-- adversário ainda não tivesse sido posicionado.
		stealth = false,

		-- ===== O QUE ESTE HERÓI FEZ NA PARTIDA =====
		-- Mora no próprio herói, e não numa tabela paralela em `match`, por dois
		-- motivos: quem morre leva o histórico junto pro fim da partida (o
		-- snapshot lê do mesmo lugar, vivo ou não), e quem volta pela Casa de
		-- Promoção CONTINUA de onde parou, em vez de renascer zerado.
		--
		-- Alimentado em ApplyDamage, Heal e KillHero; lido no Snapshot (tela de
		-- resultado) e no fim da partida (HeroStatsService).
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

		-- Golem: true só depois do Estilhaçar (Skills.shatter/SuppressGrave).
		-- Nasce false pra todo mundo — herói normal morre com lápide, do jeito
		-- de sempre.
		noGrave = false,

		-- Golem: enterro adiado. `gravePending` fica true no corpo grande, entre
		-- o estilhaçar e a queda do último pedaço; `graveOwner` é a marca que
		-- cada PEDAÇO carrega apontando pro corpo dele (ver
		-- DeferGrave/ResolvePendingGraves), e é ela que diz "este morto não tem
		-- lápide própria". Herói normal nunca liga nenhum dos dois — nasce
		-- inteiro e é enterrado na hora em que morre.
		--
		-- Nascem sempre limpos, inclusive no Golem que volta pela Casa de
		-- Promoção: o corpo que ressuscita é um registro NOVO, sem pendência
		-- nem marca da vida anterior, e por isso pode estilhaçar de novo e
		-- rodar o ciclo inteiro outra vez.
		gravePending = false,
		graveOwner = nil,
		graveHex = nil, -- casa do último pedaço que caiu; é onde a lápide sobe

		skullCooldown = 0,
		summoner = nil,

		view = match.view,
	}

	-- O uid é matchId_dono_dataId, então um herói NOVO com o mesmo dataId
	-- sobrescreve o registro antigo em match.heroes — e a lápide daquele
	-- registro ficaria órfã: visível no tabuleiro, ocupando o hex e sem dono
	-- pra ser atacada ou consumida. Só acontece com invocação repetida (o Golem
	-- ressuscitado estilhaçando de novo), mas o preço de limpar aqui é zero.
	-- A ressurreição comum já faz a própria limpeza antes de chegar aqui
	-- (PerformResurrection), e passar duas vezes não muda nada.
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

-- ===================== BARRIS =====================
-- Objeto neutro: ocupa uma casa, não é de ninguém e não tem vida. Quebra por
-- CONTAGEM de golpes (GameConfig.BARREL_HITS), então o valor do ataque não
-- importa — o barril custa o mesmo número de turnos pra qualquer herói.

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

-- Nasce no início da partida, antes do draft: os dois jogadores já escolhem os
-- heróis olhando pro tabuleiro que vão jogar, barris incluídos.
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

-- Prêmio: metade cura, metade ataque emprestado. O sorteio é por barril, não
-- por partida, e sai no servidor — o cliente só vê o resultado.
local function BreakBarrel(match, barrel, breaker)
	match.barrels[barrel.uid] = nil

	-- A casa fica LIVRE, ao contrário do túmulo (que segue ocupando o hex do
	-- herói morto). Barril quebrado é entulho: some do tabuleiro e a casa volta a
	-- valer pra andar e pra atirar através.
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
			attackBonus = GameConfig.BARREL_ATTACK_BONUS, -- devolvido no ProcessStatusEffects
			-- mesmo carimbo que a API das skills põe: o herói quebra o barril no
			-- próprio turno, e sem isto o bônus venceria no fim dele
			appliedTurnToken = match.turnToken,
		})
	end
end

-- Golpe no barril. NÃO passa pelo PerformAttack de propósito: barril não sofre
-- dano, não revida e não é alvo de habilidade nenhuma — veneno, gelo e corte em
-- linha são coisas que se fazem a um herói. Também não marca `firstAttack`, pra
-- não queimar o First Punch do Ralph numa caixa de madeira.
local function AttackBarrel(match, attacker, barrel)
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[barrel.position] then return end

	-- Taunt NÃO vale aqui. Ele obriga a escolher o provocador em vez de outro
	-- ALVO — e barril não é alvo: não revida, não tem dono, não decide nada. Um
	-- provocador colado travar a quebra da caixa só tirava do jogador uma jogada
	-- que não competia com ele.

	match.turn.attacked[attacker.uid] = true

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

-- ===================== LÁPIDES =====================
-- Lápide de herói morto: recurso disputado, não decoração bloqueando casa. Só o
-- time INIMIGO destrói (checado em MatchManager.AttackHero, antes de chegar
-- aqui), em GameConfig.GRAVE_HITS golpes — mesma contagem do barril, dano não
-- importa. A diferença é o preço: quebrar uma lápide praga quem desfere o golpe
-- final com GRAVE_CURSE_DAMAGE, e destrói pra sempre a chance daquele herói
-- específico voltar por uma casa de promoção (ver TryTriggerPromotion).
--
-- NÃO existe uma tabela `match.graves` separada: a lápide É o próprio herói
-- morto, ainda em `match.heroes[uid]`, com isAlive=false e os campos
-- graveHitsLeft/graveDestroyed que KillHero inicializa. Reaproveitar o mesmo
-- objeto (e o mesmo uid) é o que deixa a lápide entrar de graça em todo o cano
-- de clique/mira/snapshot que já existe pros heróis — sem isso seria um
-- segundo sistema de targeting só pra ela.
function AttackGrave(match, attacker, grave)
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[grave.position] then return end

	-- Taunt NÃO vale aqui, pelo mesmo motivo do barril: lápide é objeto, não
	-- combatente — "Taunt só protege aliados, não objetos no mapa".

	match.turn.attacked[attacker.uid] = true

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

		-- A maldição: dano SEM autor (nil), igual veneno/Morte Súbita — mudo (sem
		-- o "Hit" de golpe corpo a corpo empilhando em cima do som da quebra) e
		-- sem contar como ataque de habilidade nenhuma. Se isso matar quem
		-- profanou o túmulo, ApplyDamage/KillHero cuidam disso normalmente — a
		-- própria lápide virando outra lápide é o preço fazendo sentido até o fim.
		ApplyDamage(match, attacker, GameConfig.GRAVE_CURSE_DAMAGE, nil, false, nil, "graveCurse")
	end

	Broadcast(match)
end

-- ===================== XP =====================
-- O UpdateAsync do DataStore cede, e o fim de partida roda no meio da resolução
-- de um ataque: task.spawn pra não segurar o Broadcast do golpe final.
local function AwardXp(match, side, result, survivors)
	if not side or side.isBot or not side.player then return end
	task.spawn(ProgressionService.AwardMatchXp, side.player, result, survivors, match.vsBot)
end

-- ===================== PRÊMIO DA CAMPANHA =====================
-- Vencer o confronto ENTREGA o herói. Um lugar só, no mesmo ponto em que o XP
-- é pago: quem decide isso é o fim de partida, não a UI que abriu o confronto.
-- O Unlock é idempotente (já possui = recusa muda), então revanche e evento de
-- fim repetido não desbloqueiam duas vezes.
local function AwardFightHero(match, side)
	if not match.fight or not side or side.isBot or not side.player then return end
	task.spawn(HeroUnlockService.Unlock, side.player, match.fight.hero)
end

-- ===================== TELEMETRIA DE BALANCEAMENTO =====================
-- Fecha a conta de cada herói da partida e entrega ao HeroStatsService, que
-- acumula e grava em lote (ver o cabeçalho de lá — gravar na hora estouraria o
-- limite de escrita da chave).
--
-- CONTA OS DOIS LADOS, inclusive o do bot. O herói é o objeto de estudo, não o
-- jogador: se o Bramm perde sempre, perde tanto na mão de gente quanto na mão
-- da IA, e jogar fora metade da amostra só deixaria o número mais lento de
-- convergir. O que NÃO entra é quem já entrou: a chamada é uma só, no
-- CheckGameOver, que só passa por aqui uma vez por partida.
--
-- `result` é do ponto de vista do LADO, então cada herói herda o resultado do
-- dono. Empate marca os dois lados como "draw".
--
-- PARTIDA ABANDONADA NÃO ENTRA, e isso é de propósito. Desistência e queda de
-- conexão passam por AwardAbandon/EndMatch, que não chamam o CheckGameOver —
-- então nunca chegam aqui. Quem desiste no turno 2 não está dizendo nada sobre
-- o herói que levou; contaria como derrota dele e sujaria justamente a
-- estatística que se quer limpa. Se um dia isso virar interessante, entra como
-- um campo PRÓPRIO (`abandoned`), nunca somado às derrotas.
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

			-- Dois lados levando Ceos somam na mesma linha, que é o que a
			-- telemetria por herói quer. Invocação não abre linha própria: ela
			-- soma no herói que a criou (rootOf), então mini-golem e caveira
			-- viram Golem e Morn em vez de heróis fantasmas no relatório.
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
			match.onStats(entries, {
				turns = match.turn and match.turn.number or 0,
				winner = match.winner,
				sideOneId = match.sides[1].id,
				sideTwoId = match.sides[2].id,
				theme = match.theme and match.theme.id or "?",
				timeout = match.winner == "draw",
			})
		end
	else
		HeroStatsService.AddMatch(entries)
	end
end

-- ===================== FIM DE JOGO =====================
local function IsRankedPvp(match)
	if match.simulated then return nil, "BalanceSim" end
	if match.fight then return nil, "campanha" end
	if not match.turn then return nil, "partida nao chegou a comecar" end

	for _, side in ipairs(match.sides) do
		if side.isBot or not side.player then return nil, "envolve bot" end
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

		-- Ranking = SÓ humano contra humano. Uma vez por partida (rankingDone),
		-- porque o encerramento pode ser reentrado por desconexão.
		if not match.rankingDone then
			match.rankingDone = true

			local ranked, why = IsRankedPvp(match)
			if ranked then
				print(("[Ranking] PvP valido — vitoria registrada para %s"):format(winningSide.player.Name))
				LeaderboardService.RecordWin(tonumber(winningSide.id))
			else
				print(("[Ranking] resultado ignorado — %s"):format(why))
			end
		end

		-- a vitória paga pela margem (heróis vivos), a derrota paga fixo
		AwardXp(match, winningSide, "win", survivors)
		AwardXp(match, losingSide, "loss")

		-- e, se era confronto da campanha, entrega o herói do quadrado
		AwardFightHero(match, winningSide)
	end

	-- Depois de match.winner estar definido nos dois ramos: é dele que sai
	-- vitória/derrota/empate de cada herói.
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

-- ===================== COMBATE =====================
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

	-- O carimbo de furtividade sai ANTES das skills correrem. A Emboscada e a
	-- quebra da invisibilidade moram em skills diferentes do MESMO herói e
	-- disparam no mesmo gatilho: lendo `attacker.stealth` direto, qual das duas
	-- corre primeiro passaria a depender da ordem do array de habilidades do
	-- Shadow. É o mesmo cuidado que o gelo do Kor toma ao valer pelo estado de
	-- antes do golpe.
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

	-- Devolve o ctx pra quem chamou saber se este golpe específico não pode
	-- ser revidado (ver Skills.ambush, que marca suppressCounter).
	return ctx
end

-- ===================== TURNOS =====================
local function MatchIsLive(match)
	return matches[match.id] ~= nil
end

-- O bot não vê modal nenhum, então escolhe sozinho quando MoveHero abre uma
-- escolha pendente (ver o uso logo abaixo).
--
-- Não é "quem morreu primeiro" nem "quem tem mais vida na ficha": volta quem
-- MUDA a partida agora. O ThreatScore já mede exatamente isso — é a mesma
-- pergunta que a IA faz sobre um inimigo ("o quanto este herói pesa no jogo?"),
-- só que virada pro próprio time, com as habilidades dele na conta.
--
-- Duas correções em cima disso, ambas pelo estado ATUAL do tabuleiro: se o time
-- ficou sem ninguém pra segurar a linha, um Taunt de volta vale mais do que
-- mais um atacante; e vida de ficha entra com peso pequeno, como desempate
-- (o ressuscitado nasce com RESURRECT_HP, então a vida máxima dele só diz
-- quanto ele aguenta DEPOIS de se curar).
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

function BotPlayTurn(match, botId)
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		-- age sempre com quem tem a melhor jogada disponível; o tabuleiro muda
		-- a cada movimento/abate, então o plano é refeito a cada iteração
		local resolved = {}

		for _ = 1, GameConfig.HEROES_PER_PLAYER * 2 do
			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			-- O bot enxerga a partida pelo estado do servidor, onde o Shadow
			-- invisível está à vista como qualquer um. Filtrar aqui é o que o
			-- impede de mirar num herói que o JOGADOR humano não conseguiria
			-- mirar — sem isto a furtividade valeria só contra gente.
			local enemies = {}
			for _, enemy in ipairs(LivingHeroesOf(match, OpponentSide(match, botId).id)) do
				if not enemy.stealth then
					table.insert(enemies, enemy)
				end
			end
			if #enemies == 0 then break end

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
				if MatchIsLive(match) and match.pendingPromotion
					and match.pendingPromotion.ownerId == botId then
					MatchManager.Resurrect(nil,
						BotPickResurrection(match, botId, match.pendingPromotion.options), match)
					task.wait(BOT_ACTION_DELAY)
				end
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
		end

		if MatchIsLive(match) and match.phase == "battle" and match.turn.ownerId == botId then
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
		counterAttack = false,
		token = token,
		startedAt = os.clock(),
	}

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
	if TurnIsTimed(match) then
		task.delay(GameConfig.TURN_TIME_LIMIT, function()
			if not (MatchIsLive(match) and match.turn and match.turn.token == token and match.phase == "battle") then return end

			-- espera uma animação em curso terminar, senão o EndTurn seria recusado
			local waited = 0
			while MatchIsLive(match) and match.busy and waited < 3 do
				task.wait(0.1)
				waited += 0.1
			end

			if MatchIsLive(match) and match.turn and match.turn.token == token and match.phase == "battle" then
				Broadcast(match, "⏱ Tempo esgotado!")
				MatchManager.EndTurn(nil, match)
			end
		end)
	end

	if SideOf(match, ownerId).isBot then
		BotPlayTurn(match, ownerId)
	end
end

-- `match` explícito nas chamadas internas (bot/cronômetro); vindo do cliente,
-- é resolvido pelo Player.
function MatchManager.EndTurn(player, match)
	match = match or MatchOfPlayer(player)
	if not match or match.phase ~= "battle" then return end
	if match.busy then return end
	-- "Entrou na casa, tem que escolher": nada mais acontece até a ressurreição
	-- pendente ser resolvida — nem passar o turno.
	if match.pendingPromotion then return end

	local currentSide = SideOf(match, match.turn.ownerId)
	if player and currentSide.player ~= player then return end

	-- Fim de turno: efeitos primeiro, depois skills.
	--
	-- Varre o tabuleiro INTEIRO, não só o lado que está encerrando — é o que
	-- permite o veneno ticar nos dois lados a cada passagem (ver
	-- ProcessStatusEffects). Quem é do lado que encerra continua recebendo o
	-- tratamento completo: os efeitos por rodada e o gatilho onTurnEnd.
	local endingOwner = match.turn.ownerId
	for _, hero in pairs(match.heroes) do
		if hero.isAlive then
			local ownTurnEnding = hero.ownerId == endingOwner
			if ownTurnEnding then hero.stats.turnsAlive += 1 end
			ProcessStatusEffects(match, hero, ownTurnEnding)

			-- releitura do isAlive: o efeito acima pode ter matado o herói
			if ownTurnEnding and hero.isAlive then
				TriggerSkills(match, hero, "onTurnEnd")
			end
		end
	end

	-- O fogo envelhece junto com os efeitos de herói, e na mesma cadência do
	-- gelo: uma vez por RODADA, no fim do turno de quem acendeu.
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

-- ===================== AÇÕES =====================
-- player == nil significa ação do bot (já validada internamente)
local function AuthorizeAction(match, player, hero)
	if not match or match.phase ~= "battle" then return false end
	if match.busy then return false end
	-- Escolha de ressurreição pendente bloqueia QUALQUER outra ação — mover,
	-- atacar, o que for — até ser resolvida via MatchManager.Resurrect.
	if match.pendingPromotion then return false end
	if not hero or not hero.isAlive then return false end
	if IsDisabled(hero) then
		Reject(player, "PARALYZED")
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
		Reject(player, "OUT_OF_RANGE")
		return
	end

	local wasBonusMove = match.turn.bonusMove[heroUid] == true
	match.turn.bonusMove[heroUid] = nil
	match.turn.moved[heroUid] = true
	LogEvent(match, "move", hero.sideIndex,
		("%s andou de %s para %s"):format(hero.name, hero.position, hexId))

	-- Furor das Chamas (Karo): quantas casas do CAMINHO já estavam em chamas
	-- DELE antes deste passo. Tem que ler match.flames AGORA — o acender de
	-- fogo novo só acontece lá embaixo, no despacho do onMove, depois da
	-- caminhada. Calcular depois veria o próprio fogo que ele acabou de
	-- acender, e todo passo daria bônus (não é a regra: só o rastro ANTIGO).
	local enteredFlameCount = 0
	for _, stepHex in ipairs(path) do
		local flame = match.flames[stepHex]
		if flame and flame.ownerId == hero.ownerId then
			enteredFlameCount += 1
		end
	end

	-- Avisa cedo que a jogada travou (moved=true) — a posição só se confirma
	-- de verdade no fim da caminhada, casa por casa, logo abaixo.
	Broadcast(match)

	-- A posição LÓGICA anda EM SINCRONIA com o passo VISUAL, casa por casa —
	-- não tudo de uma vez no início. É o que garante que, se uma chama matar no
	-- meio do caminho, a morte (e a lápide) aconteçam NAQUELA casa, e não na
	-- casa final pra onde o corpo "chegaria" depois de já estar morto. `busy`
	-- trava ações concorrentes durante todo o trecho.
	-- Casas que o PRÓPRIO Karo consumiu nesta caminhada (fogo dele, apagado ao
	-- passar por cima). O flamePath, mais abaixo, acende de novo as casas
	-- ATRAVESSADAS — sem esta lista ele reacenderia a MESMA casa que acabou
	-- de apagar, no mesmo movimento: o fogo sumia e voltava no mesmo instante,
	-- e visualmente nunca desaparecia de verdade (o som tocava, a chama
	-- continuava lá).
	local consumedOwnTiles = {}
	local origin = hero.position

	match.busy = true
	for step, stepHex in ipairs(path) do
		match.occupied[hero.position] = nil
		hero.position = stepHex
		match.occupied[stepHex] = hero

		HeroView.WalkStep(hero, stepHex, step)

		-- o próprio Karo cruzando o rastro dele: sem dano (o bônus de ataque do
		-- Furor já foi contado ANTES deste loop, em enteredFlameCount)
		local _, ownFlame = ConsumeFlame(match, hero, stepHex)
		if ownFlame then
			consumedOwnTiles[stepHex] = true
		elseif not hero.isAlive then
			break
		end
	end
	match.busy = false

	-- onMove só dispara se o herói SOBREVIVEU à própria caminhada — morto não
	-- acende rastro novo (Caminho de Chamas) nem quebra a furtividade de
	-- ninguém por proximidade; a morte em si já saiu tratada via onDie, dentro
	-- do ApplyDamage/KillHero ali em cima. O ctx diz QUEM andou e por onde: o
	-- Caminho de Chamas precisa saber que o passo foi dele (senão o Karo
	-- acenderia o rastro do inimigo do outro lado do mapa) e a Furtividade
	-- precisa do contrário — que o passo NÃO foi dela, porque o movimento do
	-- próprio Shadow não o tira da sombra.
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

	-- DEPOIS do Broadcast: se isto abrir uma escolha pendente, o snapshot que
	-- acabou de sair já reflete a posição nova, e o próximo (dentro de
	-- TryTriggerPromotion) só acrescenta o pedido de escolha em cima dela.
	--
	-- Herói derrubado pelo próprio rastro não promove nada: o TryTriggerPromotion
	-- lê a casa dele, e a essa altura ela já virou lápide.
	if hero.isAlive then
		TryTriggerPromotion(match, hero)
	end
end

function MatchManager.AttackHero(player, attackerUid, targetUid, match)
	match = match or MatchOfPlayer(player)
	local attacker = match and match.heroes[attackerUid]
	if not AuthorizeAction(match, player, attacker) then return end
	if match.turn.attacked[attackerUid] then return end

	-- O barril chega pelo MESMO remote e pelo mesmo botão do ataque: pro jogador
	-- é "bater naquilo ali", e o alvo é que decide o que acontece.
	local barrel = match.barrels[targetUid]
	if barrel then
		AttackBarrel(match, attacker, barrel)
		return
	end

	local target = match.heroes[targetUid]

	-- Lápide inimiga: mesmo remote, mesmo botão, de novo. `target` aqui é o
	-- PRÓPRIO herói morto (ver comentário em AttackGrave) — só entra por este
	-- caminho se ainda não foi destruída, senão cai no "not target.isAlive"
	-- comum logo abaixo e o clique não faz nada.
	if target and not target.isAlive and not target.graveDestroyed
		and target.ownerId ~= attacker.ownerId then
		AttackGrave(match, attacker, target)
		return
	end

	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end

	-- Invisível não é alvo. O snapshot já não conta ao adversário que este herói
	-- existe, mas o uid é adivinhável (matchId_dono_dataId) — sem esta linha, um
	-- cliente adulterado acertaria o Shadow escondido chutando o nome.
	if target.stealth then return end

	-- alcance + caminho livre até o alvo: TODO mundo mira pela mesma regra, e
	-- quem atira longe (Wren) só tem um attackRange maior. Já houve aqui uma
	-- exceção de linha de visada pra ela, e o que ela produzia era alcance
	-- imprevisível — inimigo a duas casas recusado e barril longe aceito.
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[target.position] then
		Reject(player, "OUT_OF_RANGE")
		return
	end

	-- Taunt: trava o ataque em outro alvo quando está colado no ATACANTE, ou
	-- quando um tiro à distância teria que atravessar a casa dele (ver MatchQuery.TauntBlocks)
	local tauntBlocker = MatchQuery.TauntBlocks(match, attacker, target)
	if tauntBlocker then
		Reject(player, "TAUNTED")
		Broadcast(match, ("%s está bloqueado por Taunt de %s"):format(attacker.name, tauntBlocker.name))
		return
	end

	match.turn.attacked[attackerUid] = true
	local attackCtx = PerformAttack(match, attacker, target, false)

	-- contra-ataque: uma vez por turno, se o alvo sobreviveu e alcança o
	-- atacante. Emboscada do Nash (attackCtx.suppressCounter) pula este golpe
	-- SEM marcar match.turn.counterAttack — o alvo perde a chance de revidar
	-- ESTE golpe, mas o "ativo" do turno continua de pé pra outro herói.
	if not attackCtx.suppressCounter and not match.turn.counterAttack
		and target.isAlive and attacker.isAlive then
		if HexGrid.Distance(target.position, attacker.position) <= target.attackRange then
			match.turn.counterAttack = true

			match.busy = true
			task.wait(COUNTER_ATTACK_DELAY)
			match.busy = false

			PerformAttack(match, target, attacker, true)
		end
	end

	if CheckGameOver(match) then
		Broadcast(match)
		return
	end

	Broadcast(match)
end

-- ===================== CASAS DE PROMOÇÃO =====================
-- Duas casas fixas (GameConfig.PROMOTION_HEX_FOR_SLOT), uma por lado, na ponta
-- da coluna central. Cada jogador só ativa a que fica no lado OPOSTO de onde
-- começou — a largada original do adversário — e só depois do turno
-- PROMOTION_UNLOCK_TURN. Ativar é instantâneo: o herói pisa lá, e se existir
-- pelo menos uma lápide aliada ainda não destruída, a partida trava numa
-- escolha obrigatória (ver match.pendingPromotion, checado em AuthorizeAction e
-- em EndTurn) até o jogador decidir quem ressuscita. Uso único por jogador na
-- partida inteira (side.promotionUsed).

-- Casa livre mais próxima de `fromHex`, expandindo em anéis (BFS). O herói que
-- promoveu já ocupa a própria casa de promoção, então o ressuscitado nasce do
-- lado dele — mais perto, e não em cima do herói que morreu (que pode estar em
-- qualquer canto do tabuleiro).
--
-- `avoid` é um conjunto opcional de hexIds que a busca pula mesmo estando
-- livres, sem parar de atravessá-los: é como o túmulo pendente do Golem se
-- recusa a nascer numa casa de promoção (o IsFree só recusa casa de promoção
-- enquanto ela está TRAVADA pelo turno, e depois disso deixaria a lápide selar
-- a casa pro resto da partida).
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

	return nil -- tabuleiro cheio ao redor: praticamente impossível num 3v3
end

-- Executa a ressurreição já validada. Devolve o herói novo, ou nil se não
-- coube em lugar nenhum perto da casa de promoção (falha silenciosa e rara).
local function PerformResurrection(match, pending, grave)
	-- A lápide se apaga ANTES do herói novo nascer: CreateHero usa o MESMO uid
	-- (matchId_dono_dataId) que ela tinha, então o slot em match.heroes já vai
	-- ser sobrescrito na linha seguinte — limpar antes só evita um quadro com os
	-- dois "existindo" ao mesmo tempo. E precisa vir ANTES do FindNearestFreeHex
	-- agora: o destino é a PRÓPRIA casa do túmulo, e ela só está livre depois
	-- desta limpeza.
	HeroView.ClearGrave(grave)
	if match.occupied[grave.position] == grave then
		match.occupied[grave.position] = nil
	end

	-- Nasce na casa do túmulo que o jogador clicou, não perto da casa de
	-- promoção. FindNearestFreeHex devolve a própria casa quando ela já está
	-- livre (o caso comum, já que acabamos de esvaziá-la) — só expande em anéis
	-- no caso raro de alguém ter ocupado o hex entre o clique e esta resolução.
	local spawnHex = FindNearestFreeHex(match, grave.position)
	if not spawnHex then return nil end

	local newHero = CreateHero(match, grave.dataId, pending.ownerId, spawnHex)
	if not newHero then return nil end

	-- Vida fixa de "segunda chance", não a vida máxima da ficha — CreateHero
	-- deixa currentHp = maxHp, isto sobrescreve por cima de propósito.
	newHero.currentHp = math.min(GameConfig.RESURRECT_HP, newHero.maxHp)
	HeroView.UpdateStats(newHero)
	HeroView.PlayMatchSound(match.view, "Resurrect")

	-- De propósito SEM marcar moved/attacked: o ressuscitado é uma unidade nova
	-- que ainda não agiu neste turno, igual qualquer herói que estivesse em
	-- campo a partida inteira. O time já podia agir com até HEROES_PER_PLAYER
	-- heróis por turno — isto não é uma ação extra "de graça", é o efetivo
	-- voltando ao tamanho normal.
	return newHero
end

-- Chamada no fim de MoveHero. Só abre a escolha se: é a casa certa PRA ESTE
-- lado, já passou do turno de liberação, este lado ainda não gastou o próprio
-- uso, e sobra pelo menos uma lápide aliada de pé.
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
	-- chegou, mas não tem ninguém pra trazer de volta: nenhum efeito, e o uso
	-- da casa NÃO é gasto — continua disponível se uma lápide aparecer depois
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

-- player == nil é o bot resolvendo a própria escolha pendente (ver
-- BotPickResurrection, em BotPlayTurn).
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

	-- A lápide escolhida pode ter sido destruída pelo inimigo ENTRE o pedido de
	-- escolha e a resposta do jogador (corrida rara, mas possível). Nesse caso a
	-- promoção é cancelada em silêncio, em vez de travar a partida numa escolha
	-- que não existe mais.
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

-- ===================== DRAFT ALTERNADO (1,2,1,2) =====================
-- `side` filtra pelo que aquele lado liberou por nível. Sem side, devolve só o
-- que ainda não foi escolhido (comportamento antigo).
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

-- ===== ESCOLHA DO BOT NO DRAFT =====
-- Isto era uma lista de prioridade percorrida de cima pra baixo, então o bot
-- montava SEMPRE o mesmo time — Ceos, Elaria, Blade, partida após partida. Time
-- coerente, e completamente previsível: depois de duas partidas o jogador já
-- sabia o que ia encarar e decorava a resposta.
--
-- Agora é sorteio COM PESO. O peso é o quanto aquele herói serve ao bot (tanque
-- que se cura e curandeira valem mais que herói de kit situacional), e o sorteio
-- é proporcional a ele: o time continua fazendo sentido na maioria das vezes,
-- mas nenhuma escolha é garantida e de vez em quando aparece uma formação
-- esquisita — que é justamente o que obriga o jogador a olhar o tabuleiro.
--
-- Herói fora da tabela entra com PESO_PADRAO: catálogo novo não precisa mexer
-- aqui pra já poder ser sorteado.
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

	-- só chega aqui por arredondamento de ponto flutuante
	return available[#available]
end

-- Tanque no meio da fileira (trava a passagem), ranged nas pontas (fica longe
-- do aperto), o resto preenche do centro pra fora.
local function BotPickHex(data, zone, free)
	local center = (#zone + 1) / 2

	local function offsetFromCenter(hexId)
		local index = table.find(zone, hexId)
		return index and math.abs(index - center) or 0
	end

	-- O desempate é sorteado: numa fileira de 5, as casas 2 e 4 têm a mesma
	-- distância do centro, e ordenar sem desempate devolvia sempre a mesma. Com o
	-- sorteio, dois times iguais ainda entram em pé diferente.
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

-- Cronômetro do draft: reiniciado a cada vez que a escolha troca de lado. O
-- token invalida o relógio anterior — sem ele, a contagem de uma escolha já
-- feita ainda dispararia o sorteio automático da seguinte.
--
-- Só corre contra JOGADOR: o bot tem o BOT_PLACE_DELAY dele e nunca demora.
local function StartPlacementClock(match)
	match.placementToken += 1
	match.placementStartedAt = os.clock()

	local token = match.placementToken
	local side = match.sides[match.placementSide]
	if side.isBot or GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return end

	task.delay(GameConfig.PLACEMENT_TIME_LIMIT, function()
		if not (MatchIsLive(match) and match.phase == "placement" and match.placementToken == token) then return end

		-- Escolhe por ele em vez de pular a vez: pular deixaria o time incompleto
		-- pro resto da partida, que é punição bem maior que a demora.
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

	-- passa a vez, mas pula quem já completou o time
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

	-- Campanha: o time já vem escrito, e sai na ordem em que foi escrito. Não
	-- passa pelo sorteio nem carimba `usedHeroIds` — o cenário é fixo, e o que
	-- o bot leva não pode tirar herói nenhum da mão do jogador.
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

	local side = match.sides[match.placementSide]
	if side.player ~= player then return end
	if side.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	-- o cliente já escurece a carta bloqueada, mas quem manda é aqui: sem esta
	-- linha bastaria um FireServer à mão pra jogar com herói não liberado
	if not side.unlockedIds[dataId] then return end
	if not table.find(side.zone, hexId) then return end
	if not IsFree(match, hexId) then return end

	CreateHero(match, dataId, side.id, hexId)
	match.usedHeroIds[dataId] = true
	side.placedCount += 1

	AdvancePlacement(match)
end

-- ===================== STREAMING =====================
-- Com Workspace.StreamingEnabled, o cliente só recebe as regiões perto do
-- personagem dele. A arena fica a centenas de studs do lobby, então no primeiro
-- instante da partida o tabuleiro AINDA NÃO EXISTE no cliente — e o
-- `boardFolder` que viaja no snapshot é uma REFERÊNCIA de instância: referência
-- para algo que não foi transmitido chega `nil` do outro lado.
--
-- É a causa de raiz de uma família de remendos espalhados pelo cliente ("o Board
-- é replicado de forma assíncrona", a zona de largada que às vezes não ficava
-- verde, o retry do selectHero). Pedir o streaming ANTES de avisar o cliente
-- resolve na origem; os remendos continuam lá como rede de segurança para
-- quando o pedido estourar o prazo.
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

	-- Espera os dois lados, mas nunca além do prazo: entrar com o tabuleiro meio
	-- carregado é ruim; travar a partida esperando é pior.
	local waited = 0
	while pending > 0 and waited < STREAM_TIMEOUT + 1 do
		task.wait(0.1)
		waited += 0.1
	end
end

-- ===================== SLOTS DE ARENA =====================
local function AllocateSlot()
	for slot = 1, GameConfig.MAX_SIMULTANEOUS_MATCHES do
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

-- ===================== CICLO DA PARTIDA =====================
-- playerTwo == nil monta uma partida contra o bot.
-- `slot` só vem preenchido na revanche, pra reaproveitar a mesma arena e não
-- teletransportar a câmera de quem já está sentado ali.
-- `fight` é a entrada do Campaign quando a partida é um confronto da campanha:
-- ela fixa o time do bot e diz qual herói a vitória paga. Sem ela o bot volta a
-- sortear o time e a partida não vale desbloqueio (treino livre pelo pad).
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

	-- num confronto da campanha, quem fica de pé do outro lado é o herói do
	-- confronto (o mesmo do quadrado do lobby), e não o boneco genérico
	local theme = (options and options.theme) or Arenas.ForMatch(fight)
	local boardFolder = BoardSpawner.SpawnBoard(slot, playerTwo == nil, fight and fight.hero, theme)
	if boardFolder then boardFolder:SetAttribute("MatchId", matchId) end

	local sides = {
		{
			index = 1,
			id = playerOne and tostring(playerOne.UserId) or BOT_ONE_ID,
			player = playerOne,
			isBot = playerOne == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[1]),
			placedCount = 0,
			promotionUsed = false, -- Casa de Promoção: um uso por jogador na partida inteira
		},
		{
			index = 2,
			id = playerTwo and tostring(playerTwo.UserId) or BOT_ID,
			player = playerTwo,
			isBot = playerTwo == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[2]),
			placedCount = 0,
			promotionUsed = false,
		},
	}

	-- Resolvido UMA vez, na criação da partida: a posse não muda no meio do
	-- draft, e consultar a cada escolha seria uma ida ao cache por clique.
	-- O bot herda o conjunto do humano (mesma tabela, só leitura) pra partida
	-- sair simétrica quando ele SORTEIA o time — num confronto da campanha isso
	-- não vale nada, porque lá o time dele já vem escrito.
	sides[1].unlockedIds = playerOne and UnlockedIdsFor(playerOne) or AllHeroIds()
	sides[2].unlockedIds = playerTwo and UnlockedIdsFor(playerTwo) or sides[1].unlockedIds

	-- Time PRÉ-SELECIONADO do bot, na ordem em que ele põe em campo. Enquanto
	-- ele existe, o bot não sorteia nada e não marca `usedHeroIds`: o confronto
	-- da campanha é um cenário fixo, e o jogador precisa poder levar os próprios
	-- heróis mesmo que o bot use os mesmos (Bot Elaria leva Ceos e Ralph, que
	-- são dois dos três iniciais — reservar entregaria o jogador sem time).
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

		-- Revanche PvP: quem já pediu, e se a oferta ainda vale (o primeiro que
		-- volta pro lobby fecha a porta pro outro).
		rematch = {},
		rematchOpen = true,

		-- Confronto da campanha (ver Campaign). Segura o desbloqueio no fim da
		-- partida e sobrevive à revanche, pra quem perdeu poder tentar de novo
		-- contra o MESMO time.
		fight = fight,
		simulated = botVsBot,
		onFinish = options and options.onFinish or nil,
		onStats = options and options.onStats or nil,
		phase = "placement",
		heroes = {},
		barrels = {},
		nextBarrelId = 0,
		occupied = {},

		-- Fogo do Karo, por CASA e não por herói: [hexId] = { ownerId, duration,
		-- appliedTurnToken }. Fora de `occupied` de propósito — chama não bloqueia
		-- passagem, só cobra pedágio de quem atravessa.
		flames = {},
		log = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		placementToken = 0,
		placementStartedAt = nil,
		starterId = sides[1].id,
		turn = nil,
		turnToken = 0,
		winner = nil,
		finisher = nil,
		busy = false,
		pendingPromotion = nil, -- ver TryTriggerPromotion/MatchManager.Resurrect
	}

	match.skillApi = BuildSkillApi(match)

	matches[matchId] = match
	matchBySlot[slot] = match

	-- antes do draft: os dois já escolhem o time olhando pro tabuleiro que vão
	-- jogar, com os barris no lugar
	SpawnBarrels(match)

	-- O tabuleiro já existe no servidor; garante que ele existe no CLIENTE antes
	-- de mandar a câmera pra lá e antes do primeiro snapshot.
	StreamArenaTo(players, origin)

	-- a câmera do cliente se ancora na arena DESTA partida
	local hexSize = HexGrid.GetHexSize()
	if playerOne then
		BoardReady:FireClient(playerOne, hexSize, origin, 1)
	end
	if playerTwo then
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
			MatchUpdate:FireClient(side.player, { phase = "lobby" })
		end
	end

	matches[match.id] = nil
	matchBySlot[match.slot] = nil
end

-- O primeiro confronto ainda aberto da escada. É pra onde o "Próximo herói"
-- leva quem acabou de vencer: o Campaign já sabe dizer o que está concluído e o
-- que o grupo anterior liberou, então não existe segunda lista de progresso.
local function NextOpenFight(player)
	local owned = HeroUnlockService.GetPlayableIds(player)

	for _, fight in ipairs(Campaign.FIGHTS) do
		if Campaign.StateOf(owned, fight) == "open" then return fight end
	end
	return nil
end

local function RestartMatch(match, fight)
	local playerOne = match.sides[1].player
	local playerTwo = match.sides[2].player
	local slot = match.slot

	-- se o dono do lado 1 saiu, quem sobrou reassume como lado 1
	if not playerOne then
		playerOne, playerTwo = playerTwo, nil
	end
	if not playerOne then return end

	-- derruba a partida antiga sem mandar ninguém pro lobby: a revanche entra
	-- no lugar dela, na mesma arena
	HeroView.ClearMatch(match.view)
	HeroView.DestroyView(match.view)
	matches[match.id] = nil
	matchBySlot[slot] = nil

	MatchManager.StartMatch(playerOne, playerTwo, slot, fight, { theme = match.theme })
end

-- Contra bot é decisão de um só: não tem ninguém do outro lado pra concordar.
-- No PvP a revanche precisa dos DOIS, e o pedido de quem clicou primeiro fica
-- guardado no `match` até o outro responder ou sair.
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

	-- Venceu o confronto da campanha: o botão vira "Próximo herói" e leva pro
	-- próximo da escada. Perdeu, repete o MESMO cenário — que é o que a revanche
	-- sempre fez, e o que quem perdeu quer.
	local fight = match.fight
	if fight and match.winner == tostring(player.UserId) then
		fight = NextOpenFight(player) or fight
	end

	RestartMatch(match, fight)
end

-- Abandono: quem sai não leva XP; quem ficou recebe como vitória. Só vale pra
-- partida em andamento — depois do fim, "voltar pro lobby" é só sair da tela de
-- resultado, e o XP já foi pago pelo CheckGameOver.
local function AwardAbandon(match, leavingSide)
	if match.phase == "finished" then return end

	local stayingSide = match.sides[leavingSide.index == 1 and 2 or 1]
	if not stayingSide.player or stayingSide.isBot then return end

	local survivors = math.max(#LivingHeroesOf(match, stayingSide.id), 1)
	AwardXp(match, stayingSide, "win", survivors)
end

-- Sair da TELA DE RESULTADO de um PvP não arrasta o adversário junto: ele pode
-- continuar ali olhando o placar. O que a saída faz é fechar a porta da
-- revanche, e o botão do outro vira "Voltar para a fila".
--
-- No meio da partida continua valendo o de sempre: abandonar entrega a vitória
-- pro outro e encerra tudo.
function MatchManager.LeaveMatch(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)

	if match.phase == "finished" and side and not match.vsBot then
		match.rematchOpen = false
		side.player = nil

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

-- Um jogador caiu no meio da partida: encerra pra todo mundo em vez de deixar
-- o outro preso esperando um turno que nunca vem.
function MatchManager.HandlePlayerLeft(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)
	if not side then return end

	AwardAbandon(match, side)
	side.player = nil
	EndMatch(match)
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
