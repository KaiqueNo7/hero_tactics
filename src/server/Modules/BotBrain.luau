--[[
	BotBrain.lua
	ModuleScript — ServerScriptService/Modules/BotBrain

	O CÉREBRO do bot: dado um tabuleiro, qual é a melhor jogada. Nada aqui
	executa nada — não move herói, não aplica dano, não transmite estado, não
	cede. Só lê a partida e devolve um plano.

	QUEM EXECUTA É O MatchManager. A divisão é essa, e ela é a razão de este
	arquivo existir separado: `BotPlayTurn` (lá) chama `PlanFor` (aqui), recebe
	"o herói X vai pra casa Y e bate no Z", e aí sim gasta as chamadas que mexem
	no jogo e esperam animação. Decidir é puro e testável; executar cede e tem
	efeito colateral. Misturar os dois foi o que fez o MatchManager passar de
	3000 linhas.

	Toda consulta ao tabuleiro passa pelo MatchQuery, que também é só leitura.
	Se um dia uma função daqui precisar ESCREVER em `match`, ela está no arquivo
	errado.

	=== A ARQUITETURA DA DECISÃO (herdada do MatchManager) ===
	Pontua cada combinação (herói, casa de destino, alvo) e executa a melhor,
	recalculando TUDO após cada ação. Não existe sequência fixa de if/else: as
	prioridades — abater, proteger o carry, perseguir o Nash, andar em grupo,
	buscar a Casa de Promoção — são parcelas de uma nota só, e a maior ganha. É
	por isso que a mesma peça joga diferente conforme o tabuleiro, sem ninguém
	escrever "se A e B então C".
	
	TRÊS CAMADAS, e cada regra nova entra em uma delas:
	  BuildBoardContext  lê a partida agora (quem é o carry, que ameaças estão
	                     em campo, se a promoção virou objetivo)
	  ScorePosition      quanto vale ESTAR numa casa (proteção, formação, sombra)
	  ScoreAttack        quanto vale BATER dali (dano, abate, efeitos, revide)
	
	Habilidade nova não precisa de sistema novo: é uma linha de `HasSkill` na
	camada certa. Hoje o Noctin caça alvo isolado, o Blade busca alinhamento, a
	Elaria cola em ferido, o Karo procura a casa que pega três, o Nash guarda a
	sombra, os Taunt se metem na frente do carry, os ranged mantêm distância — e
	ninguém tenta bater através de um Taunt.
	
	JOGADA COMBINADA. As três camadas pontuam um herói de cada vez, e por muito
	tempo foi só isso: cada peça buscava o melhor pra si e o time era a soma. Duas
	parcelas quebram esse isolamento sem inventar planejador de turno nenhum —
	elas medem o que uma peça faz PELAS OUTRAS, na moeda das camadas existentes:
	  BuildLineBlocks (posição) o aliado atravessado na linha do Blade perde
	                            pontos por ficar; sair da frente vira jogada
	  PushValue       (ataque)  o empurrão do Bramm vale o dano extra que ele
	                            monta pro Noctin, não só o próprio golpe
	Como o valor do combo entra no plano de QUEM MONTA, a ordem certa (montar
	antes de colher) sai sozinha do desempate por nota — o loop refaz tudo a cada
	ação e o beneficiado já encontra o tabuleiro pronto.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local MatchQuery = require(ServerScriptService.Modules.MatchQuery)

-- Apelidos locais: o corpo abaixo veio do MatchManager, onde estas eram funções
-- locais do arquivo. Alias em vez de reescrever 200 chamadas pra
-- `MatchQuery.X(...)` — o código que decide continua lendo igual, e a busca de
-- upvalue local ainda é mais rápida que a indexação de tabela, o que conta num
-- laço que roda milhares de vezes por jogada do bot.
local AlliesAdjacentTo = MatchQuery.AlliesAdjacentTo
local FindStatusEffect = MatchQuery.FindStatusEffect
local FreeChecker = MatchQuery.FreeChecker
local GetHeroAt = MatchQuery.GetHeroAt
local HasSkill = MatchQuery.HasSkill
local IsFree = MatchQuery.IsFree
local LivingHeroesOf = MatchQuery.LivingHeroesOf
local MoveRangeOf = MatchQuery.MoveRangeOf
local SideOf = MatchQuery.SideOf

local BotBrain = {}


local TAUNT = GameConfig.ABILITIES.TAUNT
local RANGED = GameConfig.ABILITIES.RANGED
end

-- O quanto vale a pena derrubar este inimigo.
--
-- É por HABILIDADE, não por nome de herói: um personagem novo entra na conta da
-- IA no dia em que ganhar uma skill conhecida, e a peculiaridade dele vira uma
-- linha aqui em vez de um caso especial espalhado pelo código. Vale pro resto
-- desta seção inteira.
local function ThreatScore(hero)
	local threat = hero.attack * 3
	if GameConfig.IsRangedAttack(hero.attackRange) then threat += 2 end

	-- Elaria acima de todos: enquanto ela estiver de pé, o dano que a IA gasta
	-- no time inimigo volta como cura. Ela vale mais que o inimigo com menos HP.
	if HasSkill(hero, "health") then threat += 14 end
	if HasSkill(hero, "clean") then threat += 4 end

	-- Nash À VISTA é oportunidade com prazo: ele bate por AMBUSH_BONUS_DAMAGE a
	-- mais saindo da sombra, e some de novo assim que ninguém estiver perto.
	-- Quem chega aqui já está visível (o invisível nem entra na lista de alvos).
	if HasSkill(hero, "ambush") then threat += 12 end

	if HasSkill(hero, "poisonAttack") then threat += 4 end
	if HasSkill(hero, "beyondFront") then threat += 3 end
	if HasSkill(hero, "aloneIsBetter") then threat += 3 end
	if HasSkill(hero, "iceEffect") then threat += 5 end -- controle: rouba turno inteiro
	return threat
end

-- ===== QUEM É O CARRY =====
-- O carry é quem CONVERTE turno em dano — e, de quebra, quem menos aguenta
-- apanhar. Vida alta desconta de propósito: um Ceos de 33 não precisa de babá,
-- e um Taunt nunca é carry (a função dele é o contrário).
local function CarryValue(hero)
	local value = hero.attack * 4

	if GameConfig.IsRangedAttack(hero.attackRange) then value += 3 end
	if HasSkill(hero, "beyondFront") then value += 4 end
	if HasSkill(hero, "aloneIsBetter") then value += 4 end
	if HasSkill(hero, "ambush") then value += 5 end
	if HasSkill(hero, "flameStrike") then value += 3 end
	if HasSkill(hero, "health") then value += 6 end -- cura é dano que não se perde
	if hero.ability == TAUNT then value -= 8 end

	return value - math.floor(hero.maxHp / 6)
end

-- Este inimigo alcança aquele herói AGORA ou no próximo passo dele? É a
-- pergunta que separa "carry exposto" de "carry longe do perigo", e a mesma que
-- diz se vale a pena um Taunt se meter no caminho.
local function Threatens(enemy, hero)
	return HexGrid.Distance(enemy.position, hero.position)
		<= MoveRangeOf(enemy) + enemy.attackRange
end

-- ===================== LEITURA DO TABULEIRO =====================
-- Tudo que a IA precisa saber sobre a partida AGORA, resolvido uma vez por
-- decisão e passado pronto pras funções de pontuação. Existe por dois motivos:
-- as mesmas perguntas (quem é o carry? tem Noctin do outro lado? a Casa de
-- Promoção vale alguma coisa?) seriam refeitas pra cada casa candidata de cada
-- herói, e — mais importante — é isto que dá CONTEXTO à pontuação, em vez de
-- cada regra olhar só o próprio herói.
--
-- É reconstruído a cada ação do bot (ver BotPlayTurn): matou alguém, andou,
-- perdeu um aliado — o tabuleiro é outro, e a leitura também.
local function BuildBoardContext(match, botId, enemies)
	local allies = LivingHeroesOf(match, botId)
	local side = SideOf(match, botId)

	local ctx = {
		enemies = enemies,
		allies = allies,
		turn = match.turn and match.turn.number or 0,
	}

	-- O carry do PRÓPRIO time: quem os Taunt vão cobrir e quem não pode ficar
	-- sozinho perto de um Noctin.
	local bestCarry = -math.huge
	for _, ally in ipairs(allies) do
		local value = CarryValue(ally)
		if value > bestCarry then
			ctx.carry, bestCarry = ally, value
		end
	end

	-- Ameaças do outro lado que mudam o POSICIONAMENTO (as que só mudam a
	-- escolha de alvo já vivem no ThreatScore).
	for _, enemy in ipairs(enemies) do
		-- Nash à vista: colar nele nega a sombra (ele só some sem inimigo a
		-- STEALTH_RANGE), então perseguir é uma jogada de verdade, não teimosia.
		if HasSkill(enemy, "ambush") then ctx.stalker = enemy end
		-- Noctin: enquanto ele estiver vivo, aliado sozinho é dano dobrado
		if HasSkill(enemy, "aloneIsBetter") then ctx.hunter = enemy end
	end

	-- ===== CASA DE PROMOÇÃO =====
	-- Só vira objetivo se a jogada existir de verdade: o lado ainda não gastou o
	-- uso, tem lápide de pé pra trazer alguém de volta, e o turno já está perto
	-- da liberação (começa a andar pra lá ANTES, senão chega tarde).
	local hexId = side and GameConfig.PROMOTION_HEX_FOR_SLOT[side.index]
	if hexId and side and not side.promotionUsed
		and ctx.turn >= GameConfig.PROMOTION_UNLOCK_TURN - 2 then
		local hasGrave = false
		for _, other in pairs(match.heroes) do
			if other.ownerId == botId and not other.isAlive and not other.graveDestroyed then
				hasGrave = true
				break
			end
		end

		if hasGrave then
			-- UM herói vai buscar, e é o mais perto. Sem esta escolha o bônus
			-- valeria pra todo mundo e o time inteiro largaria a briga pra
			-- caminhar até o mesmo canto do mapa.
			local bestDistance = math.huge
			for _, ally in ipairs(allies) do
				local distance = HexGrid.Distance(ally.position, hexId)
				if distance < bestDistance then
					ctx.promotionRunner, bestDistance = ally, distance
				end
			end
			ctx.promotionHex = hexId
		end
	end

	return ctx
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

	-- Emboscada: o golpe que SAI da sombra leva o bônus. Sem isto a IA achava
	-- que o Nash bate por 2 e nunca via o bote — ele vale 6 justamente no
	-- turno em que está invisível, e só naquele.
	if HasSkill(attacker, "ambush") and attacker.stealth then
		damage += GameConfig.AMBUSH_BONUS_DAMAGE
	end

	return damage
end

-- Inimigos extras que o Blade acerta na mesma linha.
--
-- Copia a regra do Skills.beyondFront de perto: SÓ ALIADO VIVO interrompe o
-- corte. Casa vazia, túmulo e barril deixam o golpe passar. Antes esta conta
-- parava na primeira casa que não tivesse inimigo — então um buraco no meio da
-- fila escondia da IA o segundo alvo, e o Blade escolhia a linha errada por não
-- enxergar o que a própria skill acerta.
local function LineHits(match, attacker, target, fromPos)
	if not HasSkill(attacker, "beyondFront") then return 0 end

	local hits = 0
	for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, target.position, 2)) do
		local other = GetHeroAt(match, hexId)
		if other and other.isAlive then
			if other.ownerId == attacker.ownerId then break end
			hits += 1
		end
	end
	return hits
end

-- ===== SAIR DA FRENTE DO CORTE =====
-- O beyondFront para no primeiro ALIADO vivo da linha. Quando é o próprio time
-- que está atravessado, o golpe que pegaria três pega um — e a IA nunca via
-- isso, porque cada herói pontuava só a própria casa e ninguém tinha motivo pra
-- sair da frente de outro.
--
-- Este mapa é a ponte: casa -> quanto o TIME perde se alguém estiver parado
-- nela. Entra como penalidade no ScorePosition, então o aliado atravessado
-- passa a QUERER sair dali sozinho — sem plano de turno, sem coordenação
-- explícita. Ele anda primeiro (o passo dele vale mais), o Blade corta depois:
-- o loop do bot refaz o plano a cada ação e já encontra a linha limpa.
--
-- Vale pra qualquer portador de beyondFront e só enquanto ele ainda puder
-- atacar neste turno — gasto o golpe, ninguém mais precisa se mexer por ele.
local function BuildLineBlocks(match, ctx)
	local blocks = nil

	for _, cutter in ipairs(ctx.allies) do
		if HasSkill(cutter, "beyondFront") and not match.turn.attacked[cutter.uid] then
			-- de onde ele pode bater neste turno: a casa atual mais as que alcança
			local positions = { [cutter.position] = true }
			if not match.turn.moved[cutter.uid] then
				for hexId in pairs(HexGrid.ComputeReach(cutter.position, MoveRangeOf(cutter), FreeChecker(match))) do
					if IsFree(match, hexId) then positions[hexId] = true end
				end
			end

			for fromPos in pairs(positions) do
				for _, enemy in ipairs(ctx.enemies) do
					if HexGrid.Distance(fromPos, enemy.position) <= cutter.attackRange then
						-- procura UM aliado atravessado; o que vier DEPOIS dele é
						-- exatamente o que se ganha tirando-o dali
						local blockerHex, gain = nil, 0

						for _, hexId in ipairs(HexGrid.GetLineBeyond(fromPos, enemy.position, 2)) do
							local other = GetHeroAt(match, hexId)
							-- o próprio cortador não conta: se ele vai bater de
							-- `fromPos`, a casa velha dele já está vazia
							if other and other.isAlive and other ~= cutter then
								if other.ownerId == cutter.ownerId then
									if blockerHex then break end -- dois aliados na fila: sem jeito
									-- só vale pedir a casa a quem ainda pode andar
									if match.turn.moved[other.uid] or match.turn.attacked[other.uid] then break end
									blockerHex = hexId
								elseif blockerHex then
									gain += 1
								end
							end
						end

						if blockerHex and gain > 0 then
							blocks = blocks or {}
							-- mesmo peso do acerto extra no ScoreAttack: sair da
							-- frente vale exatamente o que o corte ganha
							blocks[blockerHex] = math.max(blocks[blockerHex] or 0, gain * 30)
						end
					end
				end
			end
		end
	end

	return blocks
end

-- ===== O EMPURRÃO DO BRAMM É JOGADA DE EQUIPE =====
-- A Fúria empurra o alvo uma casa pra trás. Pro Bramm isso não muda quase nada:
-- o dano sai igual. Quem ganha é o TIME — inimigo empurrado pra longe dos
-- companheiros fica ISOLADO, e isolado é o dobro de dano pro Noctin.
--
-- Sem esta conta a IA só via o número do golpe e o arremesso era acidente. Com
-- ela o empurrão vale o que o ALIADO ganha depois, então o Bramm joga primeiro
-- — não porque alguém escreveu "Bramm antes de Noctin", mas porque o plano dele
-- passou a pontuar mais.
--
-- Genérico de propósito: quem colhe é qualquer herói com `aloneIsBetter`, e a
-- conta continua valendo se o elenco crescer. O que ele NÃO faz é segurar o
-- Noctin quando o Noctin já tem um abate na mão neste turno — e está certo:
-- abate agora vale mais que combo depois.
local function PushValue(match, attacker, target, fromPos, ctx, damage)
	if not HasSkill(attacker, "rage") then return 0 end
	if damage >= target.currentHp then return 0 end -- morre no golpe: não há empurrão

	local behind = HexGrid.GetLineBeyond(fromPos, target.position, 1)[1]
	-- bloqueado não empurra, vira +1 de dano (já contado no EstimateDamage)
	if not (behind and IsFree(match, behind)) then return 0 end

	-- isolar é o ponto: já sozinho, o empurrão não muda a conta de ninguém
	if #AlliesAdjacentTo(match, target, target.position) == 0 then return 0 end
	if #AlliesAdjacentTo(match, target, behind) > 0 then return 0 end

	local score = 0
	local remaining = target.currentHp - damage

	for _, ally in ipairs(ctx.allies) do
		local reach = match.turn.moved[ally.uid] and 0 or MoveRangeOf(ally)

		if ally ~= attacker and HasSkill(ally, "aloneIsBetter")
			and not match.turn.attacked[ally.uid]
			and HexGrid.Distance(ally.position, behind) <= reach + ally.attackRange then
			-- na mesma moeda do ScoreAttack (dano * 10): o combo vale o dano
			-- EXTRA que o dobro rende, não o golpe inteiro
			score += ally.attack * 10
			if ally.attack * 2 >= remaining then
				score += 110 -- e o arremesso virou abate
			end
		end
	end

	-- Dante e afins perdem o bônus de aliado adjacente ao ficar sozinhos
	if HasSkill(target, "trustInTeam") and target.trustInTeamApplied then
		score += 10
	end

	return score
end

-- Dano que voltaria em contra-ataque (0 se o alvo morre ou não alcança)
local function CounterDamage(attacker, target, fromPos, damage)
	if damage >= target.currentHp then return 0 end
	if HexGrid.Distance(target.position, fromPos) > target.attackRange then return 0 end
	-- golpe vindo da sombra não dá tempo de revidar (Skills.ambush marca
	-- suppressCounter): pro Nash invisível, bater é de graça
	if HasSkill(attacker, "ambush") and attacker.stealth then return 0 end

	local incoming = target.attack
	if HasSkill(attacker, "autoDefense") then incoming = math.max(0, incoming - 1) end
	return incoming
end

local function ScoreAttack(match, attacker, target, fromPos, ctx)
	if TauntBlocks(match, attacker, target, fromPos) then return nil end

	local damage = EstimateDamage(match, attacker, target, fromPos)
	local score = damage * 10

	-- o que este golpe deixa MONTADO pro resto do time (ver PushValue)
	score += PushValue(match, attacker, target, fromPos, ctx, damage)

	if damage >= target.currentHp then
		score += 120 + ThreatScore(target) * 4 -- abater é sempre a prioridade
	else
		score += (target.maxHp - target.currentHp) * 2 -- concentra fogo no ferido
		score += ThreatScore(target) * 2
	end

	score += LineHits(match, attacker, target, fromPos) * 30

	-- Karo: o soco gira. Cada inimigo EXTRA colado na casa de onde ele vai bater
	-- leva o ataque cheio, então "de onde eu bato" importa tanto quanto "em
	-- quem". Como o PlanFor pontua cada casa candidata, é isto que faz ele
	-- escolher a posição que pega três em vez do golpe fácil que pega um.
	if HasSkill(attacker, "flameStrike") then
		local extra = 0
		for _, neighbor in ipairs(HexGrid.GetNeighbors(fromPos)) do
			local other = GetHeroAt(match, neighbor.id)
			if other and other.isAlive and other ~= target
				and other.ownerId ~= attacker.ownerId then
				extra += 1
				-- inimigo extra que MORRE no giro vale como abate
				if attacker.attack >= other.currentHp then
					score += 90 + ThreatScore(other) * 3
				end
			end
		end
		score += extra * attacker.attack * 9
	end

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
local function ScorePosition(match, hero, fromPos, ctx)
	local enemies = ctx.enemies
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

	-- ===== TAUNT PROTEGE MAIS DO QUE ATACA =====
	-- Vale pra QUALQUER portador de Taunt, não só o Golem. A regra do jogo é que
	-- um Taunt inimigo adjacente trava o ataque em qualquer outro alvo — então
	-- "proteger" aqui é literalmente colar no inimigo que ameaça o carry: ele
	-- passa a só poder bater no tanque. Trabalho PREVENTIVO: a conta usa quem
	-- ALCANÇA o carry no próximo passo, não quem já está batendo nele.
	if isTank and ctx.carry and ctx.carry ~= hero then
		local carryPos = ctx.carry.position

		for _, enemy in ipairs(enemies) do
			if Threatens(enemy, ctx.carry) then
				if HexGrid.Distance(fromPos, enemy.position) <= 1 then
					score += 34 -- Taunt ligado: este inimigo não alcança mais o carry
				end

				-- corpo no caminho: na contagem de casas do hexágono, estar "em
				-- cima da linha" entre os dois é a soma das distâncias bater com
				-- a distância direta
				if HexGrid.Distance(enemy.position, fromPos) + HexGrid.Distance(fromPos, carryPos)
					== HexGrid.Distance(enemy.position, carryPos) then
					score += 12
				end
			end
		end

		-- guarda-costas: não adianta travar um inimigo e deixar o carry sozinho
		-- do outro lado do mapa
		score += math.max(0, 3 - HexGrid.Distance(fromPos, carryPos)) * 6
	end

	-- ===== EU SOU O NASH =====
	-- A sombra é a ficha dele: invisível ele bate por muito mais e não pode ser
	-- alvo. Terminar o passo longe de todo mundo VALE, mesmo sem bater neste
	-- turno — e quando houver um bote bom, o ScoreAttack (que já conta o bônus
	-- e a ausência de contra-ataque) passa por cima deste bônus sozinho.
	if HasSkill(hero, "stealth") and nearest > GameConfig.STEALTH_RANGE then
		score += 26
	end

	-- ===== ENFRENTANDO O NASH =====
	-- Ele só volta pra sombra se ninguém estiver a STEALTH_RANGE. Ficar colado é
	-- o contra-jogo: nega a invisibilidade sem precisar acertar um golpe. Só que
	-- o tanque é quem faz isso de bom grado — mandar o carry perseguir seria
	-- entregar exatamente o alvo que o Nash quer.
	if ctx.stalker and ctx.stalker.isAlive then
		local distance = HexGrid.Distance(fromPos, ctx.stalker.position)
		if distance <= GameConfig.STEALTH_RANGE then
			score += (hero == ctx.carry) and 10 or 24
		end
	end

	-- ===== ENFRENTANDO O NOCTIN =====
	-- Aliado sozinho é dano dobrado pra ele. Andar em grupo é a resposta, e o
	-- carry é quem mais paga por passear sozinho.
	if ctx.hunter and ctx.hunter.isAlive and #AlliesAdjacentTo(match, hero, fromPos) == 0 then
		score -= (hero == ctx.carry) and 22 or 10
	end

	-- ===== NÃO FIQUE NA FRENTE DO CORTE =====
	-- Ver BuildLineBlocks: parado nesta casa, este herói é o que impede o
	-- beyondFront aliado de pegar a fila inteira. Sair vale o que o corte ganha.
	if ctx.lineBlock then
		score -= ctx.lineBlock[fromPos] or 0
	end

	-- ===== CASA DE PROMOÇÃO =====
	-- Só o corredor escolhido no BuildBoardContext puxa por isto, e o valor
	-- cresce conforme ele chega perto: é objetivo estratégico, não corrida cega
	-- — qualquer abate ou proteção urgente continua pontuando mais alto.
	if ctx.promotionHex and hero == ctx.promotionRunner then
		if fromPos == ctx.promotionHex then
			score += 85
		else
			score += math.max(0, 24 - HexGrid.Distance(fromPos, ctx.promotionHex) * 4)
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
local function PlanFor(match, hero, ctx)
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
		local positional = ScorePosition(match, hero, fromPos, ctx) + stayBonus

		local bestTarget, bestAttackScore = nil, nil
		if canAttack then
			local reach = ReachFrom(match, hero, fromPos, hero.attackRange)
			for _, enemy in ipairs(ctx.enemies) do
				if reach[enemy.position] then
					local attackScore = ScoreAttack(match, hero, enemy, fromPos, ctx)
					if attackScore and (not bestAttackScore or attackScore > bestAttackScore) then
						bestTarget, bestAttackScore = enemy, attackScore
					end
				end
			end
		end

		local total = positional + (bestAttackScore or 0)

		-- QUEM ABRE A TROCA É QUEM AGUENTA APANHAR. Entre dois ataques de valor
		-- parecido, o de mais vida sai primeiro: ele absorve o contra-ataque, e
		-- o frágil bate depois, num inimigo já gasto (ou já morto). Peso
		-- pequeno de propósito — é preferência de ORDEM, não regra: um abate ou
		-- uma proteção urgente continua ganhando de qualquer diferença de HP.
		if bestTarget then
			total += hero.currentHp * 0.4
		end
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


-- ===================== API =====================
-- Só o que o MatchManager chama. Todo o resto — as camadas de pontuação, as
-- heurísticas por habilidade, os ajudantes de linha e empurrão — fica privado:
-- é detalhe de COMO se decide, e mexer neles não deve exigir tocar em quem
-- executa.
BotBrain.ThreatScore = ThreatScore
BotBrain.BuildBoardContext = BuildBoardContext
BotBrain.BuildLineBlocks = BuildLineBlocks
BotBrain.PlanFor = PlanFor
BotBrain.BarrelInReach = BarrelInReach

return BotBrain
