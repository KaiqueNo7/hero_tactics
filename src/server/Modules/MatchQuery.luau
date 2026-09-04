--[[
	MatchQuery.lua
	ModuleScript — ServerScriptService/Modules/MatchQuery

	As perguntas que se faz a um tabuleiro. Nada aqui MUDA nada.

	POR QUE ESTE MÓDULO EXISTE
	O MatchManager passou de 3000 linhas e a IA do bot (BotBrain) é hoje um quinto
	disso. As duas partes precisam das mesmas consultas básicas — quem está nesta
	casa, esta casa está livre, quem ainda está vivo deste lado — e enquanto elas
	moravam dentro do MatchManager, a IA só existia lá dentro junto. Separar as
	consultas é o que tornou possível separar a IA.

	A REGRA DESTE ARQUIVO: função que escreve não entra aqui. Nenhuma mexe em
	`match`, nenhuma chama HeroView, nenhuma dispara Broadcast, nenhuma cede
	(yield). É isso que permite chamá-las de qualquer lugar, em qualquer ordem,
	no meio de qualquer cálculo — inclusive milhares de vezes dentro do laço de
	pontuação da IA — sem risco de efeito colateral.

	O `match` continua sendo passado EXPLICITAMENTE em toda função, como no resto
	do projeto. Várias partidas rodam ao mesmo tempo no mesmo servidor; nenhuma
	função aqui lê estado de módulo, então não existe "a partida atual" pra ser
	confundida com a do vizinho.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)

local MatchQuery = {}

-- ===================== LADOS =====================
function MatchQuery.SideOf(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return index and match.sides[index] or nil
end

function MatchQuery.OpponentSide(match, ownerId)
	local index = match.sideIndexById[ownerId]
	return match.sides[index == 1 and 2 or 1]
end

-- ===================== CASAS =====================
-- Barril ocupa casa mas NÃO é herói: quem pergunta "tem herói aqui?" recebe nil,
-- e quem precisa saber se a casa está livre usa o IsFree abaixo, que conta o
-- barril como obstáculo.
function MatchQuery.GetHeroAt(match, hexId)
	local occupant = match.occupied[hexId]
	if occupant and occupant.isBarrel then return nil end
	return occupant
end

-- Exposto porque o MatchManager também precisa dele: a lápide que cai numa Casa
-- de Promoção escorrega pra casa livre mais próxima, e a busca por essa casa
-- exclui as duas Casas — senão o corpo só andaria de uma pra outra.
MatchQuery.PROMOTION_HEXES = {}
for _, hexId in pairs(GameConfig.PROMOTION_HEX_FOR_SLOT) do
	MatchQuery.PROMOTION_HEXES[hexId] = true
end
local PROMOTION_HEXES = MatchQuery.PROMOTION_HEXES

-- As duas Casas de Promoção não existem como destino antes do turno de
-- liberação: até lá elas são buraco no tabuleiro, pra ninguém estacionar em cima
-- da recompensa esperando ela abrir.
local function PromotionLocked(match, hexId)
	if not PROMOTION_HEXES[hexId] then return false end
	local number = match.turn and match.turn.number or 0
	return number < GameConfig.PROMOTION_UNLOCK_TURN
end

function MatchQuery.IsFree(match, hexId)
	return HexGrid.Exists(hexId)
		and match.occupied[hexId] == nil
		and not PromotionLocked(match, hexId)
end

-- Fecha o `match` numa função de um argumento só, que é o formato que o HexGrid
-- espera em ComputeReach/FindPath.
function MatchQuery.FreeChecker(match)
	return function(hexId)
		return MatchQuery.IsFree(match, hexId)
	end
end

-- ===================== HERÓIS =====================
function MatchQuery.GetAlliesInRange(match, hero, range)
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

function MatchQuery.GetEnemiesInRange(match, hero, range)
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

function MatchQuery.LivingHeroesOf(match, ownerId)
	local result = {}
	for _, hero in pairs(match.heroes) do
		if hero.ownerId == ownerId and hero.isAlive then
			table.insert(result, hero)
		end
	end
	return result
end

-- `position` é explícito, e não `hero.position`, porque a IA precisa perguntar
-- "quem estaria colado em mim SE eu fosse pra aquela casa?" — a pergunta
-- hipotética é o que faz o Dante procurar companhia e o Taunt se meter na
-- frente do carry.
function MatchQuery.AlliesAdjacentTo(match, hero, position)
	local list = {}
	for _, neighbor in ipairs(HexGrid.GetNeighbors(position)) do
		local occupant = MatchQuery.GetHeroAt(match, neighbor.id)
		if occupant and occupant ~= hero and occupant.isAlive
			and occupant.ownerId == hero.ownerId then
			table.insert(list, occupant)
		end
	end
	return list
end

function MatchQuery.HasSkill(hero, key)
	return table.find(hero.abilities, key) ~= nil
end

-- ===================== EFEITOS =====================
function MatchQuery.ActiveShieldOf(match, source)
	if not source then return nil end

	for _, other in pairs(match.heroes) do
		if other.isAlive then
			local effect = MatchQuery.FindStatusEffect(other, "shield")
			if effect and effect.source == source then return other end
		end
	end
	return nil
end

function MatchQuery.FindStatusEffect(hero, effectType)
	for _, effect in ipairs(hero.statusEffects) do
		if effect.type == effectType then return effect end
	end
	return nil
end

-- Teto, não desconto: congelado anda FREEZE_MOVE_RANGE, venha ele de ficha comum
-- ou de Sprint. Descontando uma casa, o Sprint congelado ainda andava 2 — mais
-- do que um herói normal inteiro, o que fazia o gelo do Kor valer menos
-- justamente contra quem corre mais.
function MatchQuery.MoveRangeOf(match, hero)
	local range = hero.moveRange

	for _, ally in ipairs(MatchQuery.AlliesAdjacentTo(match, hero, hero.position)) do
		if MatchQuery.HasSkill(ally, "tailwind") then
			range += GameConfig.WIND_BOOST_MOVE_BONUS
			break
		end
	end

	if MatchQuery.FindStatusEffect(hero, "freeze") then
		range = math.min(range, GameConfig.FREEZE_MOVE_RANGE)
	end

	return math.max(1, range)
end

-- REGRA ÚNICA de "este herói ainda anda neste turno". Mora aqui, e não como
-- local do MatchManager, porque três lugares precisam da MESMA resposta: a
-- validação de MoveHero, o `hasMoved` do snapshot (que pinta as casas no
-- cliente) e o PlanFor do bot. Enquanto o bot tinha a própria cópia da conta,
-- ele simplesmente não enxergava o passo pós-ataque da Agility.
--
-- Três estados distintos, e não um "já agiu" só:
--   moved    = o passo normal do turno foi gasto
--   attacked = o golpe do turno foi gasto (um por turno, sempre)
--   bonusMove = há um passo AVULSO de pé (Agility depois do golpe, Instinto de
--               Caça do Nash) — vale mesmo com moved e attacked marcados
function MatchQuery.CanMove(match, hero)
	if not match.turn then return false end
	if match.turn.bonusMove[hero.uid] then return true end
	if match.turn.moved[hero.uid] then return false end
	return not match.turn.attacked[hero.uid]
end

function MatchQuery.AttackRangeOf(_match, hero)
	return hero.attackRange
end

function MatchQuery.AttackReachFrom(match, hero, fromPos, ignore)
	local isFree = MatchQuery.FreeChecker(match)
	local checker = isFree

	if ignore then
		checker = function(hexId)
			return ignore[hexId] == true or isFree(hexId)
		end
	end

	return HexGrid.ComputeReach(fromPos or hero.position,
		MatchQuery.AttackRangeOf(match, hero), checker)
end

function MatchQuery.DodgeHexFor(match, hero, attacker, fromPos)
	fromPos = fromPos or attacker.position

	local reach = MatchQuery.AttackReachFrom(match, attacker, fromPos, {
		[hero.position] = true,
		[attacker.position] = true,
		[fromPos] = true,
	})
	local best, bestAway, bestExposure = nil, -1, math.huge
	local reachable, outOfRange = 0, 0

	for _, neighbor in ipairs(HexGrid.GetNeighbors(hero.position)) do
		local away = HexGrid.Distance(neighbor.id, fromPos)

		if away >= GameConfig.DODGE_MIN_DISTANCE and MatchQuery.IsFree(match, neighbor.id) then
			reachable += 1

			if not reach[neighbor.id] then
				outOfRange += 1

				local exposure = 0
				for _, other in pairs(match.heroes) do
					if other.isAlive and other ~= hero and other.ownerId ~= hero.ownerId
						and HexGrid.Distance(neighbor.id, other.position)
							<= MatchQuery.AttackRangeOf(match, other) then
						exposure += 1
					end
				end

				if away > bestAway or (away == bestAway and exposure < bestExposure) then
					best, bestAway, bestExposure = neighbor.id, away, exposure
				end
			end
		end
	end

	return best, reachable, outOfRange
end

function MatchQuery.TauntBlocks(match, attacker, target, fromPos)
	-- QUALQUER Taunt é sempre alvo legítimo — esta linha é a regra inteira dos
	-- múltiplos provocadores, e por isso vem antes de tudo. O Taunt diz "não
	-- passe por cima de mim", não "ataque exatamente a mim": com dois ou mais em
	-- condição, o atacante escolhe entre eles, e só o inimigo SEM Taunt fica de
	-- fora.
	--
	-- Já esteve depois da varredura de vizinhos, e era o bug dos dois Taunts que
	-- se travavam: com Bramm e Ceos colados, a varredura devolvia o primeiro que
	-- achasse e recusava o golpe no outro — inclusive um Taunt tentando bater no
	-- Taunt ao lado, que ficava sem jogada nenhuma.
	if target.ability == GameConfig.ABILITIES.TAUNT then return nil end

	fromPos = fromPos or attacker.position

	local function isGuard(hero)
		return hero ~= nil and hero.isAlive
			and hero.ownerId ~= attacker.ownerId
			and hero.ability == GameConfig.ABILITIES.TAUNT
	end

	-- Daqui pra baixo o alvo é comprovadamente SEM Taunt, então basta achar um
	-- provocador em condição pra recusar o golpe — qual deles é indiferente, a
	-- mensagem só precisa nomear alguém.
	--
	-- Taunt colado prende QUALQUER atacante, não só o corpo a corpo: com um
	-- guarda a 1 casa, o Ranged também não escolhe alvo comum mais longe.
	for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
		local occupant = MatchQuery.GetHeroAt(match, neighbor.id)
		if isGuard(occupant) then return occupant end
	end

	if not GameConfig.IsRangedAttack(attacker.attackRange) then return nil end

	local span = HexGrid.Distance(fromPos, target.position)
	for _, other in pairs(match.heroes) do
		if isGuard(other) and other ~= target then
			local ahead = HexGrid.Distance(fromPos, other.position)
			local rest = HexGrid.Distance(other.position, target.position)
			if ahead > 0 and rest > 0 and ahead + rest == span then
				return other
			end
		end
	end

	return nil
end

return MatchQuery
