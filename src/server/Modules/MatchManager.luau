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
local Skills = require(ServerScriptService.Modules.Skills)
local HeroView = require(ServerScriptService.Modules.HeroView)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local LeaderboardService = require(ServerScriptService.Modules.LeaderboardService)
local ProgressionService = require(ServerScriptService.Modules.ProgressionService)
-- O DevAccess saiu daqui junto com a liberação por nível: quem sabe quais heróis
-- o jogador pode levar (inclusive as exceções de testador) é o HeroUnlockService.
local HeroUnlockService = require(ServerScriptService.Modules.HeroUnlockService)

local MatchUpdate = ReplicatedStorage.Remotes.MatchUpdate
local BoardReady = ReplicatedStorage.Remotes.BoardReady

local MatchManager = {}

-- ===== AJUSTE FINO =====
local BOT_ACTION_DELAY = 0.7
local COUNTER_ATTACK_DELAY = 0.4

local BOT_ID = "BOT"

-- ===== REGISTRO DE PARTIDAS =====
local matches = {} -- [matchId] = match
local matchBySlot = {} -- [slot] = match
local nextMatchId = 0

-- declaradas cedo porque se chamam entre si
local BeginTurn, BotPlayTurn, BotPlaceOne, AdvancePlacement, CheckGameOver

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
local function SideOf(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return index and match.sides[index] or nil
end

local function OpponentSide(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return match.sides[index == 1 and 2 or 1]
end

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

-- ===================== OCUPAÇÃO =====================
-- Mora na partida, não no HexGrid: duas partidas usam as MESMAS casas (A1, B2...)
-- e com ocupação global uma bloquearia a outra.
--
-- `occupied` guarda TUDO que ocupa casa — heróis, túmulos e barris. É de
-- propósito: quem pergunta "dá pra andar/atirar através daqui?" (IsFree,
-- FindPath, ComputeReach) quer saber se tem algo no caminho, não o quê. Já quem
-- pergunta por HERÓI usa o GetHeroAt abaixo, que filtra o barril fora — assim
-- nenhuma skill escrita antes do barril precisa saber que ele existe.
local function GetHeroAt(match, hexId)
	local occupant = match.occupied[hexId]
	if occupant and occupant.isBarrel then return nil end
	return occupant
end

local function IsFree(match, hexId)
	return HexGrid.Exists(hexId) and match.occupied[hexId] == nil
end

-- fecha sobre a partida: é o que vai pro ComputeReach/FindPath do HexGrid
local function FreeChecker(match)
	return function(hexId)
		return IsFree(match, hexId)
	end
end

-- ===================== CONSULTAS =====================
local function GetAlliesInRange(match, hero, range)
	local allies = {}
	for _, other in pairs(match.heroes) do
		if other ~= hero and other.isAlive and other.ownerId == hero.ownerId then
			if HexGrid.Distance(hero.position, other.position) <= range then
				table.insert(allies, other)
			end
		end
	end
	return allies
end

local function GetEnemiesInRange(match, hero, range)
	local enemies = {}
	for _, other in pairs(match.heroes) do
		if other.isAlive and other.ownerId ~= hero.ownerId then
			if HexGrid.Distance(hero.position, other.position) <= range then
				table.insert(enemies, other)
			end
		end
	end
	return enemies
end

-- Conjunto de heróis que este jogador pode usar, pelo nível dele. Dono e
-- testadores (DevAccess) recebem o catálogo inteiro sem olhar o nível.
-- Nível não libera mais herói nenhum: quem decide é a posse (grátis de fábrica
-- ou comprado com moeda). O DevAccess continua sendo a exceção, e ele já está
-- embutido no GetPlayableIds.
local function UnlockedIdsFor(player)
	return HeroUnlockService.GetPlayableIds(player)
end

local function LivingHeroesOf(match, ownerId)
	local result = {}
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == ownerId and hero.isAlive then
			table.insert(result, hero)
		end
	end
	return result
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
			-- o efeito visual sai com a assinatura da skill que está disparando,
			-- então a skill só diz EM QUEM ele acontece (e, se precisar, qual
			-- variante — o goodLuck tem uma pro sucesso e outra pro fracasso)
			scope.api = setmetatable({
				Effect = function(target, variant)
					HeroView.PlaySkillEffect(target, variant or key)
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

function KillHero(match, hero, attacker)
	hero.isAlive = false

	-- Destaque do finalizador: fica guardado até o próximo Broadcast e vai UMA
	-- vez só. Morte sem autor (veneno, Morte Súbita) chega aqui com attacker nil
	-- e não gera destaque — não teria de quem mostrar o retrato.
	if attacker and attacker ~= hero then
		match.finisher = {
			dataId = attacker.dataId,
			name = attacker.name,
			ownerId = attacker.ownerId,
			sideIndex = attacker.sideIndex,
			victim = hero.name,
		}
	end

	-- a casa NÃO é liberada: o túmulo continua ocupando o hex
	TriggerSkills(match, hero, "onDie")

	-- Quem abateu também é avisado, com o morto chegando em ctx.target. Vem
	-- DEPOIS do onDie de propósito: aí o tabuleiro que o finalizador enxerga já
	-- contabiliza a baixa (é disso que o Faro de Sangue do Merlin depende).
	-- Se o autor morreu no mesmo lance — troca por contra-ataque —, o próprio
	-- TriggerSkills barra, porque só o onDie roda em herói morto.
	if attacker and attacker ~= hero then
		TriggerSkills(match, attacker, "onKill", hero)
	end

	HeroView.PlayAnimation(hero, "die")
	HeroView.Destroy(hero)
	HeroView.CreateGrave(hero)
end

function ApplyDamage(match, hero, amount, attacker, isCounterAttack)
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

	-- efeito 'wound' soma dano extra (mesma regra do hero.js)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == "wound" then amount += 1 end
	end

	hero.currentHp -= amount
	HeroView.UpdateStats(hero)
	-- Sem autor = dano de ambiente (veneno, morte súbita), e esse é mudo: o som
	-- de pancada é de golpe corpo a corpo, e o veneno tica em vários heróis na
	-- mesma virada de turno. O clarão vermelho e o número continuam.
	HeroView.PlayAnimation(hero, "hit", attacker == nil)
	HeroView.Say(hero, "-" .. tostring(amount), "damage")

	if hero.currentHp <= 0 then
		KillHero(match, hero, attacker)
	else
		TriggerSkills(match, hero, "onDamage", attacker, isCounterAttack)
	end
end

local function Heal(match, hero, amount)
	if not hero.isAlive then return end
	hero.currentHp = math.min(hero.currentHp + amount, hero.maxHp)
	HeroView.UpdateStats(hero)
	HeroView.PlayHealSound(hero)
	HeroView.Say(hero, "+" .. tostring(amount), "heal")
end

local function IncreaseAttack(hero, amount)
	hero.attack += amount
	HeroView.UpdateStats(hero)
	HeroView.Say(hero, (amount > 0 and "+" or "") .. tostring(amount) .. " ATK", amount > 0 and "buff" or "debuff")
end

-- ===================== STATUS EFFECTS =====================
local function FindStatusEffect(hero, effectType)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == effectType then return effect end
	end
	return nil
end

-- Aplicar SUBSTITUI o efeito do mesmo tipo que já estiver lá, em vez de empilhar
-- um segundo. Renovar veneno ou gelo passa por aqui, e é isso que garante que o
-- carimbo de turno (ver BuildSkillApi) seja refeito na renovação — antes as
-- skills mexiam na duração do efeito antigo na mão e o carimbo ficava velho.
local function ApplyStatusEffect(hero, effect)
	for index = #hero.statusEffects, 1, -1 do
		if hero.statusEffects[index].type == effect.type then
			table.remove(hero.statusEffects, index)
		end
	end

	table.insert(hero.statusEffects, effect)
	HeroView.UpdateStats(hero)
end

local function ClearStatusEffects(hero)
	hero.statusEffects = {}
	HeroView.UpdateStats(hero)
end

-- ===================== GELO =====================
-- Alcance de movimento DEPOIS dos efeitos. O `hero.moveRange` continua sendo o
-- valor de ficha (Sprint ou não); quem manda no que o herói consegue andar
-- agora é esta função — e é ela que vai no snapshot, pra pintura de casas do
-- cliente não prometer um passo que o servidor vai recusar.
local function MoveRangeOf(hero)
	local range = hero.moveRange

	-- Teto, não desconto: congelado anda FREEZE_MOVE_RANGE, venha ele de ficha
	-- comum ou de Sprint. Descontando uma casa, o Sprint congelado ainda andava
	-- 2 — mais do que um herói normal inteiro, o que fazia o gelo do Kor valer
	-- menos justamente contra quem corre mais.
	if FindStatusEffect(hero, "freeze") then
		range = math.min(range, GameConfig.FREEZE_MOVE_RANGE)
	end

	return math.max(1, range)
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
			ApplyDamage(match, hero, effect.damagePerTurn, nil, false)
		end
		if effect.duration > 1 then
			effect.duration -= 1
			table.insert(remaining, effect)
		elseif effect.attackBonus then
			-- acabou o empréstimo: o bônus temporário do barril é devolvido aqui,
			-- no mesmo lugar em que o efeito sai da lista
			IncreaseAttack(hero, -effect.attackBonus)
		end
	end

	hero.statusEffects = remaining
	HeroView.UpdateStats(hero)
end

-- ===================== MOVIMENTO =====================
-- Reposiciona sem bookkeeping de turno — usado pelo empurrão do rage
local function ForceMove(match, hero, hexId)
	if not IsFree(match, hexId) then return false end

	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	HeroView.SetPosition(hero, hexId)
	return true
end

-- ===================== API DAS SKILLS =====================
-- Uma API por partida: as closures já sabem em qual tabuleiro mexer, então a
-- skill continua escrita como antes (ctx.api.ApplyDamage(...)) sem saber que
-- existem outras partidas rodando.
local function BuildSkillApi(match)
	return {
		ApplyDamage = function(hero, amount, attacker, isCounterAttack)
			ApplyDamage(match, hero, amount, attacker, isCounterAttack)
		end,
		Heal = function(hero, amount) Heal(match, hero, amount) end,
		IncreaseAttack = IncreaseAttack,
		GetHeroAt = function(hexId) return GetHeroAt(match, hexId) end,
		GetAlliesInRange = function(hero, range) return GetAlliesInRange(match, hero, range) end,
		GetEnemiesInRange = function(hero, range) return GetEnemiesInRange(match, hero, range) end,
		GetLineBeyond = HexGrid.GetLineBeyond,
		IsFree = function(hexId) return IsFree(match, hexId) end,
		ForceMove = function(hero, hexId) return ForceMove(match, hero, hexId) end,
		FindStatusEffect = FindStatusEffect,

		-- carimba em que turno o efeito entrou: é o que o ProcessStatusEffects usa
		-- pra não gastar um prazo no mesmo turno em que ele começou
		ApplyStatusEffect = function(hero, effect)
			effect.appliedTurnToken = match.turnToken
			ApplyStatusEffect(hero, effect)
		end,

		ClearStatusEffects = ClearStatusEffects,

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
				if not other.isAlive then dead += 1 end
			end
			return dead
		end,
		PlaySkillSound = function(key) HeroView.PlaySkillSound(key, match.view) end,
	}
end

-- ===================== SNAPSHOT =====================
local function TurnSecondsLeft(match)
	if not match.turn or GameConfig.TURN_TIME_LIMIT <= 0 then return nil end
	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(GameConfig.TURN_TIME_LIMIT - elapsed))
end

-- O estado é montado por espectador: quem olha precisa saber o que é dele,
-- não quem é "o player" e quem é "o bot".
local function Snapshot(match, viewerId)
	local viewerSide = SideOf(match, viewerId)
	local opponent = OpponentSide(match, viewerId)

	local heroes = {}
	for _, hero in pairs(match.heroes) do
		table.insert(heroes, {
			uid = hero.uid,
			dataId = hero.dataId,
			name = hero.name,
			position = hero.position,
			currentHp = hero.currentHp,
			maxHp = hero.maxHp,
			attack = hero.attack,
			baseAttack = hero.baseAttack,
			ability = hero.ability,
			attackRange = hero.attackRange,
			moveRange = MoveRangeOf(hero), -- já descontado o gelo
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
			hasMoved = match.turn and match.turn.moved[hero.uid] or false,
			hasAttacked = match.turn and match.turn.attacked[hero.uid] or false,
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

	-- `match.heroes` é dicionário: a ordem de pairs() muda entre snapshots. Isso
	-- nunca importou pra pintar o tabuleiro (tudo é lido por hexId), mas a coluna
	-- de retratos da UI segue esta lista — sem ordenar, os retratos trocavam de
	-- lugar sozinhos a cada atualização. O uid é matchId_dono_heroi, então
	-- ordenar por ele agrupa por jogador e mantém a ordem fixa a partida inteira.
	table.sort(heroes, function(a, b) return a.uid < b.uid end)

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
			sideIndex = match.finisher.sideIndex,
			isMine = match.finisher.ownerId == viewerId,
		}
	end

	return {
		phase = match.phase,
		deployZone = viewerSide.zone,
		placedCount = viewerSide.placedCount,
		opponentPlacedCount = opponent.placedCount,
		isMyPlacement = match.sides[match.placementSide].id == viewerId,
		heroesPerPlayer = GameConfig.HEROES_PER_PLAYER,
		usedHeroIds = usedHeroIds,
		lockedHeroIds = lockedHeroIds,
		heroes = heroes,
		barrels = barrels,
		turnNumber = match.turn and match.turn.number or 0,
		isMyTurn = match.turn and match.turn.ownerId == viewerId or false,
		turnSecondsLeft = TurnSecondsLeft(match),
		turnTimeLimit = GameConfig.TURN_TIME_LIMIT,
		suddenDeath = match.turn and match.turn.number >= GameConfig.SUDDEN_DEATH_START_TURN or false,

		-- O contra-ataque é UM por turno, valendo pros dois lados: quem defende
		-- revida no primeiro golpe do turno e ninguém mais revida até o turno
		-- virar. O cliente mostra isso como um selo aceso/apagado.
		counterAttackUsed = match.turn and match.turn.counterAttack or false,

		winner = winner,
		message = match.message,
		finisher = finisher,
		vsBot = match.vsBot,
		opponentName = opponent.player and opponent.player.DisplayName or "Bot",

		-- o cliente pinta as casas por aqui: procurar "Board" pelo nome no
		-- Workspace acharia o tabuleiro da partida errada
		boardFolder = match.boardFolder,
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
local function CreateHero(match, dataId, ownerId, hexId)
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
		position = hexId,
		isAlive = true,
		statusEffects = {},
		firstAttack = false,
		firstPunchApplied = false,
		frenzyActive = false, -- Merlin: Frenesi ligado agora
		frenzyHealed = false, -- Merlin: a cura de entrada do Frenesi já saiu
		view = match.view,
	}

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
	for _, hexId in ipairs(GameConfig.BARREL_HEXES) do
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

	if math.random() < GameConfig.BARREL_HEAL_CHANCE then
		HeroView.PlaySkillEffect(breaker, "barrelHeal")
		Heal(match, breaker, GameConfig.BARREL_HEAL)
	else
		HeroView.PlaySkillEffect(breaker, "barrelAttack")
		IncreaseAttack(breaker, GameConfig.BARREL_ATTACK_BONUS)
		ApplyStatusEffect(breaker, {
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

	if barrel.hitsLeft <= 0 then
		BreakBarrel(match, barrel, attacker)
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

-- ===================== FIM DE JOGO =====================
function CheckGameOver(match)
	local aliveOne = #LivingHeroesOf(match, match.sides[1].id)
	local aliveTwo = #LivingHeroesOf(match, match.sides[2].id)

	if aliveOne > 0 and aliveTwo > 0 then return false end

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

		-- ranking global conta vitória em qualquer modo, menos do próprio bot
		if not winningSide.isBot then
			LeaderboardService.RecordWin(tonumber(winningSide.id))
		end

		-- a vitória paga pela margem (heróis vivos), a derrota paga fixo
		AwardXp(match, winningSide, "win", survivors)
		AwardXp(match, losingSide, "loss")
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

	local ctx = { damageApplied = false }
	TriggerSkills(match, attacker, isCounterAttack and "onCounterAttack" or "onAttack",
		target, isCounterAttack, ctx)

	if not ctx.damageApplied and target.isAlive then
		ApplyDamage(match, target, attacker.attack, attacker, isCounterAttack)
	end

	attacker.firstAttack = true
	HeroView.UpdateStats(attacker)
end

-- ===================== IA DO BOT =====================
-- Pontua cada combinação (herói, casa de destino, alvo) e executa a melhor,
-- recalculando após cada ação. As habilidades entram na conta: Noctin caça
-- alvo isolado, Blade busca alinhamento, Elaria cola em aliado ferido, os
-- ranged mantêm distância pra não levar contra-ataque, e ninguém tenta bater
-- através de um Taunt.

local TAUNT = GameConfig.ABILITIES.TAUNT
local RANGED = GameConfig.ABILITIES.RANGED

local function HasSkill(hero, key)
	return table.find(hero.abilities, key) ~= nil
end

local function AlliesAdjacentTo(match, hero, position)
	local list = {}
	for _, neighbor in ipairs(HexGrid.GetNeighbors(position)) do
		local occupant = GetHeroAt(match, neighbor.id)
		if occupant and occupant ~= hero and occupant.isAlive
			and occupant.ownerId == hero.ownerId then
			table.insert(list, occupant)
		end
	end
	return list
end

-- O quanto vale a pena derrubar este inimigo
local function ThreatScore(hero)
	local threat = hero.attack * 3
	if GameConfig.IsRangedAttack(hero.attackRange) then threat += 2 end
	if HasSkill(hero, "health") then threat += 8 end -- curandeira morre primeiro
	if HasSkill(hero, "clean") then threat += 3 end
	if HasSkill(hero, "poisonAttack") then threat += 4 end
	if HasSkill(hero, "beyondFront") then threat += 3 end
	if HasSkill(hero, "aloneIsBetter") then threat += 3 end
	if HasSkill(hero, "iceEffect") then threat += 5 end -- controle: rouba turno inteiro
	return threat
end

-- Alcance a partir de uma casa hipotética, já contando que o herói saiu da atual
local function ReachFrom(match, hero, fromPos, range)
	local isFree = function(hexId)
		if hexId == hero.position or hexId == fromPos then return true end
		return IsFree(match, hexId)
	end
	return HexGrid.ComputeReach(fromPos, range, isFree)
end

-- Um Taunt inimigo adjacente trava o ataque em qualquer outro alvo
local function TauntBlocks(match, attacker, target, fromPos)
	if target.ability == TAUNT then return false end

	for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
		local occupant = GetHeroAt(match, neighbor.id)
		if occupant and occupant.isAlive
			and occupant.ownerId ~= attacker.ownerId
			and occupant.ability == TAUNT then
			return true
		end
	end
	return false
end

local function EstimateDamage(match, attacker, target, fromPos)
	local damage = attacker.attack

	-- trustInTeam recalcula no onMove: prevê o ataque já pós-movimento. Lê a
	-- marca da própria skill, não `attack > baseAttack`: o herói pode estar com
	-- ataque acima da ficha por outro motivo (bônus do barril).
	if HasSkill(attacker, "trustInTeam") then
		local buffed = attacker.trustInTeamApplied == true
		local willHaveAlly = #AlliesAdjacentTo(match, attacker, fromPos) > 0
		if willHaveAlly and not buffed then
			damage += 1
		elseif not willHaveAlly and buffed then
			damage -= 1
		end
	end

	if HasSkill(attacker, "aloneIsBetter") and #AlliesAdjacentTo(match, target, target.position) == 0 then
		damage *= 2
	end
	if HasSkill(attacker, "brokenDefense") and target.ability == TAUNT then
		damage += 1
	end
	if HasSkill(attacker, "poisonAttack") and FindStatusEffect(target, "poison") then
		damage += 2
	end
	if HasSkill(attacker, "iceEffect") and FindStatusEffect(target, "freeze") then
		damage *= GameConfig.FREEZE_DAMAGE_MULTIPLIER
	end
	if HasSkill(attacker, "rage") then
		local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
		if not (behind and IsFree(match, behind)) then damage += 1 end
	end

	return damage
end

-- Inimigos extras que o Blade acerta na mesma linha
local function LineHits(match, attacker, target, fromPos)
	if not HasSkill(attacker, "beyondFront") then return 0 end

	local hits = 0
	for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, target.position, 2)) do
		local other = GetHeroAt(match, hexId)
		if other and other.isAlive and other.ownerId ~= attacker.ownerId then
			hits += 1
		else
			break
		end
	end
	return hits
end

-- Dano que voltaria em contra-ataque (0 se o alvo morre ou não alcança)
local function CounterDamage(attacker, target, fromPos, damage)
	if damage >= target.currentHp then return 0 end
	if HexGrid.Distance(target.position, fromPos) > target.attackRange then return 0 end

	local incoming = target.attack
	if HasSkill(attacker, "autoDefense") then incoming = math.max(0, incoming - 1) end
	return incoming
end

local function ScoreAttack(match, attacker, target, fromPos)
	if TauntBlocks(match, attacker, target, fromPos) then return nil end

	local damage = EstimateDamage(match, attacker, target, fromPos)
	local score = damage * 10

	if damage >= target.currentHp then
		score += 120 + ThreatScore(target) * 4 -- abater é sempre a prioridade
	else
		score += (target.maxHp - target.currentHp) * 2 -- concentra fogo no ferido
		score += ThreatScore(target) * 2
	end

	score += LineHits(match, attacker, target, fromPos) * 30

	-- veneno novo rende dano ao longo dos turnos seguintes
	if HasSkill(attacker, "poisonAttack") and not FindStatusEffect(target, "poison") then
		score += 15
	end

	-- gelo do Kor: congelar quem ainda não está congelado rende o dobro de dano
	-- no golpe seguinte (o bônus em si já entrou pelo EstimateDamage)
	if HasSkill(attacker, "iceEffect") and not FindStatusEffect(target, "freeze") then
		score += 16
	end

	-- Ceos se cura batendo
	if HasSkill(attacker, "absorbRoots") and attacker.currentHp < attacker.maxHp then
		score += math.min(attacker.attack, attacker.maxHp - attacker.currentHp) * 5
	end

	-- Elaria limpa veneno dos vizinhos ao atacar
	if HasSkill(attacker, "clean") then
		for _, ally in ipairs(AlliesAdjacentTo(match, attacker, fromPos)) do
			if #ally.statusEffects > 0 then score += 25 end
		end
	end

	score -= CounterDamage(attacker, target, fromPos, damage) * 7

	return score
end

-- Valor de ocupar uma casa, mesmo sem atacar neste turno
local function ScorePosition(match, hero, fromPos, enemies)
	local score = 0
	local isTank = hero.ability == TAUNT
	local isRanged = GameConfig.IsRangedAttack(hero.attackRange)

	local nearest = math.huge
	for _, enemy in ipairs(enemies) do
		nearest = math.min(nearest, HexGrid.Distance(fromPos, enemy.position))
	end

	if nearest < math.huge then
		if isRanged then
			-- fica exatamente no alcance: bate sem ser contra-atacado
			score -= math.abs(nearest - hero.attackRange) * 8
		else
			score -= nearest * 5
		end

		if isTank then
			score -= math.abs(nearest - 1) * 8 -- tanque segura a linha de frente
		end
	end

	if HasSkill(hero, "trustInTeam") then
		score += #AlliesAdjacentTo(match, hero, fromPos) * 10
	end

	-- Elaria cura e limpa vizinhos: cola em quem precisa
	if HasSkill(hero, "health") or HasSkill(hero, "clean") then
		for _, ally in ipairs(AlliesAdjacentTo(match, hero, fromPos)) do
			if ally.currentHp < ally.maxHp then score += 18 end
			if FindStatusEffect(ally, "poison") then score += 14 end
		end
	end

	if isRanged then
		for _, enemy in ipairs(enemies) do
			if HexGrid.Distance(fromPos, enemy.position) <= 1 then score -= 22 end
		end
	end

	-- Noctin caça quem está sozinho (dano dobrado)
	if HasSkill(hero, "aloneIsBetter") then
		for _, enemy in ipairs(enemies) do
			if #AlliesAdjacentTo(match, enemy, enemy.position) == 0
				and HexGrid.Distance(fromPos, enemy.position) <= hero.attackRange then
				score += 20
			end
		end
	end

	return score
end

-- O barril mais perto de quebrar dentro do alcance. O bot só consulta isto
-- quando não tem inimigo pra bater: o prêmio é bom, mas trocar um golpe em herói
-- por um golpe em caixote seria péssimo negócio.
local function BarrelInReach(match, hero)
	if match.turn.attacked[hero.uid] then return nil end

	local reach = HexGrid.ComputeReach(hero.position, hero.attackRange, FreeChecker(match))
	local best = nil
	for _, barrel in pairs(match.barrels) do
		if reach[barrel.position] and (not best or barrel.hitsLeft < best.hitsLeft) then
			best = barrel
		end
	end
	return best
end

-- Melhor jogada de um herói: para onde ir e quem bater
local function PlanFor(match, hero, enemies)
	local canMove = not match.turn.moved[hero.uid] and not match.turn.attacked[hero.uid]
	local canAttack = not match.turn.attacked[hero.uid]
	if not canMove and not canAttack then return nil end

	local positions = { [hero.position] = true }
	if canMove then
		for hexId in pairs(HexGrid.ComputeReach(hero.position, MoveRangeOf(hero), FreeChecker(match))) do
			if IsFree(match, hexId) then positions[hexId] = true end
		end
	end

	local best = nil
	for fromPos in pairs(positions) do
		local stayBonus = (fromPos == hero.position) and 2 or 0 -- desempata a favor de ficar
		local positional = ScorePosition(match, hero, fromPos, enemies) + stayBonus

		local bestTarget, bestAttackScore = nil, nil
		if canAttack then
			local reach = ReachFrom(match, hero, fromPos, hero.attackRange)
			for _, enemy in ipairs(enemies) do
				if reach[enemy.position] then
					local attackScore = ScoreAttack(match, hero, enemy, fromPos)
					if attackScore and (not bestAttackScore or attackScore > bestAttackScore) then
						bestTarget, bestAttackScore = enemy, attackScore
					end
				end
			end
		end

		local total = positional + (bestAttackScore or 0)
		if not best or total > best.score then
			best = {
				hero = hero,
				position = fromPos,
				target = bestTarget,
				score = total,
			}
		end
	end

	return best
end

-- ===================== TURNOS =====================
local function MatchIsLive(match)
	return matches[match.id] ~= nil
end

function BotPlayTurn(match, botId)
	task.spawn(function()
		task.wait(BOT_ACTION_DELAY)

		-- age sempre com quem tem a melhor jogada disponível; o tabuleiro muda
		-- a cada movimento/abate, então o plano é refeito a cada iteração
		local resolved = {}

		for _ = 1, GameConfig.HEROES_PER_PLAYER * 2 do
			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			local enemies = LivingHeroesOf(match, OpponentSide(match, botId).id)
			if #enemies == 0 then break end

			local best = nil
			for _, hero in ipairs(LivingHeroesOf(match, botId)) do
				if not resolved[hero.uid] then
					local plan = PlanFor(match, hero, enemies)
					if plan and (not best or plan.score > best.score) then
						best = plan
					end
				end
			end

			if not best then break end

			if best.position ~= best.hero.position then
				MatchManager.MoveHero(nil, best.hero.uid, best.position, match)
				task.wait(BOT_ACTION_DELAY)
			end

			if not MatchIsLive(match) or match.phase ~= "battle" or match.turn.ownerId ~= botId then return end

			if best.target and best.target.isAlive and best.hero.isAlive then
				MatchManager.AttackHero(nil, best.hero.uid, best.target.uid, match)
				task.wait(BOT_ACTION_DELAY)
			else
				-- Sem inimigo no alcance: se sobrou um barril ao lado, o golpe
				-- parado vira cura ou ataque extra em vez de nada.
				local barrel = best.hero.isAlive and BarrelInReach(match, best.hero) or nil
				if barrel then
					MatchManager.AttackHero(nil, best.hero.uid, barrel.uid, match)
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

	match.turn = {
		ownerId = ownerId,
		number = number,
		moved = {},
		attacked = {},
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
				ApplyDamage(match, hero, GameConfig.SUDDEN_DEATH_DAMAGE, nil, false)
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
	if GameConfig.TURN_TIME_LIMIT > 0 then
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
			ProcessStatusEffects(match, hero, ownTurnEnding)

			-- releitura do isAlive: o efeito acima pode ter matado o herói
			if ownTurnEnding and hero.isAlive then
				TriggerSkills(match, hero, "onTurnEnd")
			end
		end
	end

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
	if not hero or not hero.isAlive then return false end
	if hero.ownerId ~= match.turn.ownerId then return false end

	if player and SideOf(match, match.turn.ownerId).player ~= player then return false end
	return true
end

function MatchManager.MoveHero(player, heroUid, hexId, match)
	match = match or MatchOfPlayer(player)
	local hero = match and match.heroes[heroUid]
	if not AuthorizeAction(match, player, hero) then return end

	-- canMoveHero: não pode ter movido NEM atacado neste turno
	if match.turn.moved[heroUid] or match.turn.attacked[heroUid] then return end
	if type(hexId) ~= "string" or not HexGrid.Exists(hexId) then return end
	if not IsFree(match, hexId) then return end

	-- FindPath já garante alcance e caminho livre: substitui o ComputeReach
	local path = HexGrid.FindPath(hero.position, hexId, MoveRangeOf(hero), FreeChecker(match))
	if not path then return end

	-- o estado lógico muda na hora; a caminhada é só visual
	match.occupied[hero.position] = nil
	hero.position = hexId
	match.occupied[hexId] = hero
	match.turn.moved[heroUid] = true

	-- onMove dispara pros heróis dos dois lados (igual ao Phaser)
	for _, other in pairs(match.heroes) do
		if other.isAlive then
			TriggerSkills(match, other, "onMove")
		end
	end

	Broadcast(match)

	-- caminha casa por casa; busy trava ações concorrentes durante o passeio
	match.busy = true
	HeroView.WalkPath(hero, path)
	match.busy = false

	Broadcast(match)
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
	if not target or not target.isAlive then return end
	if target.ownerId == attacker.ownerId then return end

	-- alcance + caminho livre até o alvo
	local reach = HexGrid.ComputeReach(attacker.position, attacker.attackRange, FreeChecker(match))
	if not reach[target.position] then return end

	-- Taunt: inimigo com Taunt adjacente ao atacante trava o ataque em outro alvo
	if target.ability ~= GameConfig.ABILITIES.TAUNT then
		for _, neighbor in ipairs(HexGrid.GetNeighbors(attacker.position)) do
			local occupant = GetHeroAt(match, neighbor.id)
			if occupant and occupant.isAlive
				and occupant.ownerId ~= attacker.ownerId
				and occupant.ability == GameConfig.ABILITIES.TAUNT then
				Broadcast(match, ("%s está bloqueado por Taunt de %s"):format(attacker.name, occupant.name))
				return
			end
		end
	end

	PerformAttack(match, attacker, target, false)
	match.turn.attacked[attackerUid] = true

	-- contra-ataque: uma vez por turno, se o alvo sobreviveu e alcança o atacante
	if not match.turn.counterAttack and target.isAlive and attacker.isAlive then
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
		if data.ability == RANGED then return da > db end
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

	Broadcast(match)

	if match.sides[nextIndex].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, function()
			BotPlaceOne(match)
		end)
	end
end

function BotPlaceOne(match)
	if not MatchIsLive(match) or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if not side.isBot then return end

	local available = AvailableHeroIds(match, side)
	local free = FreeHexesIn(match, side.zone)

	if #available > 0 and #free > 0 then
		local dataId = BotPickHeroId(available)
		local hexId = BotPickHex(HeroData.GetById(dataId), side.zone, free)
		CreateHero(match, dataId, side.id, hexId)
		match.usedHeroIds[dataId] = true
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
function MatchManager.StartMatch(playerOne, playerTwo, slot)
	if not playerOne then return false end

	slot = slot or AllocateSlot()
	if not slot then return false end

	nextMatchId += 1
	local matchId = nextMatchId
	local origin = GameConfig.ArenaOrigin(slot)

	local players = { playerOne }
	if playerTwo then table.insert(players, playerTwo) end

	local boardFolder = BoardSpawner.SpawnBoard(slot, playerTwo == nil)

	local sides = {
		{
			index = 1,
			id = tostring(playerOne.UserId),
			player = playerOne,
			isBot = false,
			zone = BuildDeployZone(DEPLOY_ZONES[1]),
			placedCount = 0,
		},
		{
			index = 2,
			id = playerTwo and tostring(playerTwo.UserId) or BOT_ID,
			player = playerTwo,
			isBot = playerTwo == nil,
			zone = BuildDeployZone(DEPLOY_ZONES[2]),
			placedCount = 0,
		},
	}

	-- Resolvido UMA vez, na criação da partida: o nível não muda no meio do
	-- draft, e consultar a cada escolha seria uma ida ao cache de XP por clique.
	-- O bot herda o conjunto do humano (mesma tabela, só leitura) pra partida
	-- sair simétrica — senão um jogador de nível 1 encararia um bot com Kor e
	-- Merlin, heróis que ele ainda nem viu.
	sides[1].unlockedIds = UnlockedIdsFor(playerOne)
	sides[2].unlockedIds = playerTwo and UnlockedIdsFor(playerTwo) or sides[1].unlockedIds

	local sideIndexById = {}
	for index, side in ipairs(sides) do
		sideIndexById[side.id] = index
	end

	local match = {
		id = matchId,
		slot = slot,
		origin = origin,
		boardFolder = boardFolder,
		view = HeroView.CreateView(matchId, origin, players),
		sides = sides,
		sideIndexById = sideIndexById,
		vsBot = playerTwo == nil,
		phase = "placement",
		heroes = {},
		barrels = {},
		nextBarrelId = 0,
		occupied = {},
		usedHeroIds = {},
		placementSide = 1, -- lado 1 escolhe primeiro: 1,2,1,2...
		starterId = sides[1].id,
		turn = nil,
		turnToken = 0,
		winner = nil,
		finisher = nil,
		busy = false,
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
	BoardReady:FireClient(playerOne, hexSize, origin, 1)
	if playerTwo then
		BoardReady:FireClient(playerTwo, hexSize, origin, 2)
	end

	HeroView.PlayMatchSound(match.view, "MatchStart")

	Broadcast(match)
	print(("MatchManager: partida %d no slot %d (%s)."):format(matchId, slot, playerTwo and "PvP" or "vs bot"))
	return true
end

local function EndMatch(match)
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

function MatchManager.Replay(player)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "finished" then return end

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

	MatchManager.StartMatch(playerOne, playerTwo, slot)
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

function MatchManager.LeaveMatch(player)
	local match = MatchOfPlayer(player)
	if not match then return end

	local side = SideOfPlayer(match, player)
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

function MatchManager.ActiveCount()
	local count = 0
	for _ in pairs(matches) do count += 1 end
	return count
end

return MatchManager
