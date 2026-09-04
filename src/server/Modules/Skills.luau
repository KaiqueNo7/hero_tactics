--[[
	Skills.lua
	ModuleScript — ServerScriptService/Modules/Skills

	Skills nomeadas, portadas de src/heroes/skills.js.

	Cada skill recebe um ctx com:
	  hero, target, isCounterAttack, api, damageApplied

	Marcar ctx.damageApplied = true SUBSTITUI o dano padrão do ataque
	(mesmo papel do hero.damageApplied no Phaser). Skills que só somam
	efeito — como beyondFront, que atinge alvos EXTRA — deixam false,
	pro alvo principal continuar levando o golpe normal.

	`passive = true` marca skills sem trigger: elas alteram dano recebido
	via modifyIncomingDamage, chamado pelo MatchManager.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local Skills = {}

-- Ceos — cura a si mesmo no valor do próprio ataque
Skills.absorbRoots = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		ctx.api.Heal(ctx.hero, ctx.hero.attack)
		ctx.api.Effect(ctx.hero)
	end,
}

-- Blade — o corte atravessa: todo inimigo alinhado atrás do alvo leva o mesmo dano
Skills.beyondFront = {
	triggers = { "onAttack" },
	apply = function(ctx)
		-- o corte cruza o alvo principal também: o dano dele sai do PerformAttack,
		-- mas quem apanha em primeiro lugar é ele
		ctx.api.Effect(ctx.target)

		local line = ctx.api.GetLineBeyond(ctx.hero.position, ctx.target.position, 2)

		for _, hexId in ipairs(line) do
			local other = ctx.api.GetHeroAt(hexId)

			-- Casa vazia e CORPO CAÍDO não seguram mais o golpe. Antes qualquer
			-- coisa que não fosse inimigo vivo parava a sequência ali — e como o
			-- túmulo continua ocupando o hex depois da morte, um inimigo abatido
			-- em outro turno virava escudo permanente pra quem estava atrás dele.
			-- Só aliado vivo interrompe: o Blade não atravessa o próprio time.
			if other and other.isAlive and other.ownerId == ctx.hero.ownerId then
				break
			end

			-- efeito ANTES do dano: se o golpe mata, o herói perde o modelo (e com
			-- ele o emissor) antes de a partícula sair
			if other and other.isAlive then
				ctx.api.Effect(other)
				ctx.api.ApplyDamage(other, ctx.hero.attack, ctx.hero, ctx.isCounterAttack)
			end
		end
		-- não marca damageApplied: o alvo principal leva o dano normal
	end,
}

-- Dante — dano extra contra inimigos com Taunt
Skills.brokenDefense = {
	triggers = { "onAttack" },
	apply = function(ctx)
		local amount = ctx.hero.attack
		if ctx.target.ability == GameConfig.ABILITIES.TAUNT then
			amount += 1
			ctx.api.PlaySkillSound("brokenDefense")
			ctx.api.Effect(ctx.target)
		end
		ctx.api.ApplyDamage(ctx.target, amount, ctx.hero, ctx.isCounterAttack)
		ctx.damageApplied = true
	end,
}

-- Ralph — guarda +2 de ataque no início do turno e descarrega no primeiro golpe
Skills.firstPunch = {
	triggers = { "onTurnStart", "onAttack", "onCounterAttack" },
	apply = function(ctx)
		if ctx.target == nil then
			-- as duas travas (já atacou / já carregou) bastam. Havia um terceiro
			-- teste, `attack == 3`, que amarrava a skill à ficha do Ralph: bastava
			-- ele ganhar um ponto de ataque por fora — o barril dá — pra carga
			-- nunca acontecer.
			if not ctx.hero.firstAttack and not ctx.hero.firstPunchApplied then
				ctx.api.IncreaseAttack(ctx.hero, 2)
				ctx.hero.firstPunchApplied = true
				ctx.api.Effect(ctx.hero)
			end
			return
		end

		if not ctx.hero.firstAttack then
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack, ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
			-- descarrega só o que foi carregado: quem volta pela Casa de Promoção
			-- e ataca antes do primeiro onTurnStart nunca recebeu o +2, e devolvê-lo
			-- deixava o Ralph com 1 de ataque pelo resto da partida
			if ctx.hero.firstPunchApplied then
				ctx.api.IncreaseAttack(ctx.hero, -2)
			end
		end
	end,
}

-- Ralph — passiva: sofre 1 de dano a menos em contra-ataques
Skills.autoDefense = {
	passive = true,
	triggers = {},
	modifyIncomingDamage = function(amount, info)
		if info.isCounterAttack then
			return math.max(0, amount - 1)
		end
		return amount
	end,
}

-- Mineiro — no fim do turno, chance de ganhar +1 de ataque (acumula) e se curar
Skills.goodLuck = {
	triggers = { "onTurnEnd" },
	apply = function(ctx)
		if math.random() < GameConfig.GOOD_LUCK_CHANCE then
			ctx.api.PlaySkillSound("goodLuck")
			ctx.api.IncreaseAttack(ctx.hero, 1)
			ctx.api.Heal(ctx.hero, GameConfig.GOOD_LUCK_HEAL)
			ctx.api.Effect(ctx.hero)
		else
			-- fumacinha cinza: a habilidade rodou e não deu em nada
			ctx.api.Effect(ctx.hero, "goodLuckFail")
		end
	end,
}

-- Vic — aplica veneno; se o alvo já estiver envenenado, renova e causa ataque +2
Skills.poisonAttack = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local existing = ctx.api.FindStatusEffect(ctx.target, "poison")
		ctx.api.Effect(ctx.target) -- antes do dano: o golpe pode matar o alvo

		if existing then
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + 2, ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
		end

		-- Renovar é aplicar de novo, não mexer na duração do efeito antigo: o
		-- ApplyStatusEffect substitui o que estava lá e recarimba o turno, então
		-- um veneno renovado no contra-ataque não vence junto com o antigo.
		if ctx.target.isAlive then
			ctx.api.ApplyStatusEffect(ctx.target, {
				type = "poison",
				duration = GameConfig.POISON_DURATION,
				damagePerTurn = 1,

				-- Corrói a cada PASSAGEM de turno, dos dois lados, em vez de uma
				-- vez por rodada. Ardendo só quando a vez volta pro envenenado, o
				-- veneno sumia da mesa: o jogador atravessava o turno inteiro do
				-- adversário sem ver nada e esquecia que estava sob efeito.
				ticksEveryTurn = true,
			})
		end
	end,
}

Skills.poisonFlask = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		ctx.api.Effect(ctx.target)

		if ctx.target.isAlive then
			ctx.api.ApplyStatusEffect(ctx.target, {
				type = "poison",
				duration = GameConfig.POISON_DURATION,
				damagePerTurn = 1,
				ticksEveryTurn = true,
			})
		end
	end,
}

-- Dante — +1 de ataque com aliado adjacente, volta ao normal quando fica sozinho
Skills.trustInTeam = {
	triggers = { "onMove", "onTurnStart", "onDie" },
	apply = function(ctx)
		local hasAlly = #ctx.api.GetAlliesInRange(ctx.hero, 1) > 0

		-- A skill guarda a PRÓPRIA marca em vez de deduzir "estou buffado?" de
		-- `attack > baseAttack`. A dedução funcionava enquanto ela fosse a única
		-- fonte de ataque extra do Dante; com o bônus temporário do barril, ela
		-- passaria a achar que o +1 dela já estava aplicado — e tiraria o ponto do
		-- barril ao ficar sozinho, deixando o Dante abaixo da ficha quando o
		-- empréstimo vencesse.
		if hasAlly and not ctx.hero.trustInTeamApplied then
			ctx.api.IncreaseAttack(ctx.hero, 1)
			ctx.hero.trustInTeamApplied = true
		elseif not hasAlly and ctx.hero.trustInTeamApplied then
			ctx.api.IncreaseAttack(ctx.hero, -1)
			ctx.hero.trustInTeamApplied = false
		end
	end,
}

-- Noctin — dobro de dano contra alvo sem nenhum aliado adjacente
Skills.aloneIsBetter = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local targetAllies = ctx.api.GetAlliesInRange(ctx.target, 1)

		if #targetAllies == 0 then
			ctx.api.PlaySkillSound("aloneIsBetter")
			ctx.api.Effect(ctx.target)
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack * 2, ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
		end
	end,
}

-- Elaria — cura 2 dos aliados adjacentes feridos no fim do turno
Skills.health = {
	triggers = { "onTurnEnd" },
	apply = function(ctx)
		for _, ally in ipairs(ctx.api.GetAlliesInRange(ctx.hero, 1)) do
			if ally.isAlive and ally.currentHp < ally.maxHp then
				-- terceiro parâmetro = quem curou. Única cura do jogo em outro
				-- herói, e por isso a única que precisa dizer de quem é o crédito:
				-- sem ele a telemetria daria a cura ao CURADO, e a coluna da
				-- Elaria (a razão de ela existir) ficaria zerada.
				ctx.api.Heal(ally, 2, ctx.hero)
			end
		end
	end,
}

-- Elaria — limpa efeitos negativos dos aliados adjacentes ao atacar
Skills.clean = {
	triggers = { "onAttack" },
	apply = function(ctx)
		local limpou = false

		-- ClearNegativeEffects, e não ClearStatusEffects: o texto da skill sempre
		-- disse "remove os efeitos NEGATIVOS", mas o código varria a lista
		-- inteira — a Elaria apagava o empréstimo de ataque do barril, o Embalo
		-- do Rush e o Sangue Fervendo do Spyke junto com o veneno, e passou a
		-- apagar também o escudo da Kira no próprio aliado que ela ia proteger.
		for _, ally in ipairs(ctx.api.GetAlliesInRange(ctx.hero, 1)) do
			local sujo = false
			for _, effect in ipairs(ally.statusEffects) do
				if GameConfig.IsNegativeEffect(effect.type) then sujo = true break end
			end

			if sujo then
				ctx.api.ClearNegativeEffects(ally)
				ctx.api.Effect(ally)
				limpou = true
			end
		end

		-- Uma vez so, e nao por aliado: a Elaria pode limpar tres vizinhos no
		-- mesmo golpe, e tres disparos do mesmo som no mesmo quadro viram um
		-- estalo distorcido em vez de tres sons. O efeito VISUAL continua sendo
		-- por aliado, porque ali a repeticao e justamente o que mostra quantos
		-- foram limpos.
		--
		-- A guarda existe pelo mesmo motivo do goodLuck: a skill dispara em todo
		-- ataque da Elaria, mas na maioria deles nao ha nada pra limpar — sem ela
		-- o som viraria parte do som de ataque dela.
		if limpou then
			ctx.api.PlaySkillSound("clean")
		end
	end,
}

-- Bramm — empurra o alvo 1 casa; se não der, o golpe leva RAGE_BLOCKED_BONUS a mais
Skills.rage = {
	triggers = { "onAttack" },
	apply = function(ctx)
		local line = ctx.api.GetLineBeyond(ctx.hero.position, ctx.target.position, 1)
		local behind = line[1]

		if behind and ctx.api.IsFree(behind) then
			ctx.api.ForceMove(ctx.target, behind)
			ctx.api.Effect(ctx.target) -- estoura já na casa nova, onde ele parou
			-- sem damageApplied: o alvo ainda leva o dano normal, já empurrado
		else
			ctx.api.Effect(ctx.target) -- antes do dano: o golpe pode matar o alvo
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + GameConfig.RAGE_BLOCKED_BONUS,
				ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
		end
	end,
}

-- ===== KOR: O GELO =====
-- Congela o alvo: ele anda uma casa a menos. Mora aqui fora e não dentro do
-- iceEffect porque a Tempestade de Gelo aplica exatamente o mesmo efeito.
local function Freeze(api, target)
	-- Sempre aplicar, mesmo já congelado: o ApplyStatusEffect substitui o gelo
	-- anterior (não empilha — dois gelos não deixam ninguém mais lento) e, o que
	-- importa, recarimba o turno em que ele entrou. Renovando a duração do efeito
	-- velho na mão, o carimbo ficava antigo e o gelo do contra-ataque era
	-- descontado no fim do turno do próprio inimigo.
	api.ApplyStatusEffect(target, {
		type = "freeze",
		duration = GameConfig.FREEZE_DURATION,
	})
end

-- Kor — passiva: todo ataque congela, e quem já está congelado leva o dobro
Skills.iceEffect = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		-- antes do dano: o golpe pode matar, e herói morto já não tem emissor
		ctx.api.Effect(ctx.target)

		-- o dobro vale pelo estado ANTES deste golpe: é o gelo de um ataque
		-- anterior que faz o próximo doer mais
		if ctx.api.FindStatusEffect(ctx.target, "freeze") then
			ctx.api.ApplyDamage(
				ctx.target,
				ctx.hero.attack * GameConfig.FREEZE_DAMAGE_MULTIPLIER,
				ctx.hero,
				ctx.isCounterAttack
			)
			ctx.damageApplied = true
		end

		-- morto não congela: só renova/aplica se o alvo sobreviveu ao golpe
		if ctx.target.isAlive then
			Freeze(ctx.api, ctx.target)
		end
	end,
}

-- Kor — ao morrer, o gelo estoura em todos os inimigos colados nele
Skills.iceStorm = {
	triggers = { "onDie" },
	apply = function(ctx)
		ctx.api.IceStorm(ctx.hero)
		ctx.api.PlaySkillSound("iceStorm")

		for _, enemy in ipairs(ctx.api.GetEnemiesInRange(ctx.hero, 1)) do
			ctx.api.Effect(enemy)
			Freeze(ctx.api, enemy)
		end
	end,
}

-- ===== MERLIN: O LOBO =====
-- Faro de Sangue e Frenesi mexem no MESMO atributo, então nenhuma das duas soma
-- por conta própria: as duas passam por aqui. Esta função não acumula, ela
-- CORRIGE — calcula o ataque que o Merlin deveria ter agora e aplica só a
-- diferença. Ser idempotente é o que permite que as duas skills disparem no
-- mesmo gatilho sem se atrapalhar, e é o que impede o bônus de inflar se um
-- gatilho rodar duas vezes no mesmo lance (um abate durante o próprio turno
-- dispara onKill e onTurnStart em sequência curta).
local function SyncWolf(ctx)
	local hero = ctx.hero
	local api = ctx.api

	local livingAllies, totalAllies = api.CountAllies(hero)

	-- exige ter TIDO alcateia: sem o totalAllies > 0, um esquadrão de um herói
	-- só entraria em Frenesi no primeiro turno, de graça
	local frenzy = livingAllies == 0 and totalAllies > 0

	local bonus = math.min(api.CountDeaths(), GameConfig.MERLIN_DEATH_ATTACK_MAX)
	if frenzy then
		bonus += GameConfig.MERLIN_FRENZY_ATTACK
	end

	-- Bônus emprestados por fora (o barril é um) entram na conta. Sem isso o
	-- recálculo devolveria o empréstimo antes da hora — e quando o efeito
	-- vencesse, o dono dele descontaria de novo e o Merlin ficaria abaixo da
	-- ficha pelo resto da partida.
	local emprestado = 0
	for _, effect in ipairs(hero.statusEffects or {}) do
		emprestado += effect.attackBonus or 0
	end

	local delta = (hero.baseAttack + bonus + emprestado) - hero.attack
	if delta ~= 0 then
		api.IncreaseAttack(hero, delta)
	end

	-- O Sprint só existe dentro do Frenesi. Escreve no hero (a instância em
	-- jogo), NUNCA em HeroData.CATALOG: as entradas do catálogo são tabelas
	-- compartilhadas, então mexer lá daria Sprint também pro Merlin do
	-- adversário e o valor ainda vazaria pra próxima partida do mesmo servidor.
	-- Quem lê isto é o MoveRangeOf, que ainda desconta o gelo por cima.
	local baseMove = hero.ability == GameConfig.ABILITIES.SPRINT
		and GameConfig.SPRINT_MOVE_RANGE
		or GameConfig.BASE_MOVE_RANGE
	hero.moveRange = frenzy and GameConfig.SPRINT_MOVE_RANGE or baseMove

	-- a cura de entrada é uma vez por partida: sem a trava, um aliado voltando
	-- ao campo e morrendo de novo religaria o Frenesi e curaria outra vez
	if frenzy and not hero.frenzyHealed then
		hero.frenzyHealed = true
		api.Effect(hero, "frenzy")
		api.Heal(hero, GameConfig.MERLIN_FRENZY_HEAL)
	end

	-- A IMUNIDADE COMEÇA LIMPANDO. Bloquear só o que vier depois deixaria o lobo
	-- "imune" ardendo num veneno pego um turno antes — e a cura de entrada, que
	-- sai logo acima, seria comida pelo tique do próprio veneno que ele deveria
	-- estar ignorando. Só na VIRADA (desligado -> ligado): repetir a cada
	-- gatilho faria o mesmo trabalho à toa quatro vezes por turno.
	--
	-- Quem barra o que chega depois é o ApplyStatusEffect, que lê frenzyActive
	-- logo abaixo — por isso a limpeza vem ANTES de escrever o campo.
	if frenzy and not hero.frenzyActive then
		api.ClearNegativeEffects(hero)
	end

	if frenzy ~= hero.frenzyActive then
		api.SetFrenzyAura(hero, frenzy)
	end

	hero.frenzyActive = frenzy
end

-- Merlin — passiva: cada morte no tabuleiro (dos dois lados) engorda o ataque
--
-- `onAnyDeath` é o gatilho que faz o bônus valer NA HORA. Sem ele, a morte de
-- um aliado só chegava ao Merlin no próximo onTurnStart/onMove: o jogador via
-- o companheiro cair no turno do adversário e a ficha do lobo continuar a
-- mesma, como se o Faro tivesse falhado — o ataque só engordava depois de ele
-- andar. Os outros gatilhos continuam de pé porque o SyncWolf é um recálculo
-- idempotente, não uma soma: rodar de novo não infla nada.
Skills.bloodScent = {
	triggers = { "onTurnStart", "onMove", "onKill", "onAnyDeath" },
	apply = SyncWolf,
}

-- Merlin — último vivo do time: cura, ataque extra, Sprint e cura por abate
--
-- Também escuta `onAnyDeath` pelo mesmo motivo, e aqui o atraso doía mais: o
-- Frenesi nasce justamente da morte do ÚLTIMO aliado, e a cura de entrada
-- chegava um lance tarde — depois de o Merlin já ter apanhado sozinho.
Skills.frenzy = {
	triggers = { "onTurnStart", "onMove", "onKill", "onAnyDeath" },
	apply = function(ctx)
		SyncWolf(ctx)

		-- Cura por abate. O ctx.target só chega preenchido no onKill — nos outros
		-- dois gatilhos ele é nil —, então este if também é o que separa "abateu
		-- alguém agora" de "só reavaliou o estado". O SyncWolf roda antes pra que
		-- a morte deste abate já esteja contada no Faro de Sangue quando a cura
		-- sair, e pra que frenzyActive reflita o tabuleiro atual.
		if ctx.target and ctx.hero.frenzyActive then
			ctx.api.Effect(ctx.hero, "frenzy")
			ctx.api.Heal(ctx.hero, GameConfig.MERLIN_FRENZY_KILL_HEAL)
		end
	end,
}

-- ===== KARO: O FOGO =====
-- O Caminho de Chamas é o primeiro efeito do jogo que NÃO mora num herói: o
-- fogo fica na casa e continua queimando depois que o Karo saiu de cima. Quem
-- guarda isso é match.flames (ver MatchManager), e a skill só acende.
--
-- `onMove` dispara pros heróis dos DOIS lados a cada movimento de qualquer um,
-- então a primeira coisa é perguntar se quem andou fui eu. Sem isso, o Karo
-- acenderia o rastro do inimigo que acabou de passear do outro lado do mapa.
Skills.flamePath = {
	triggers = { "onMove" },
	apply = function(ctx)
		if ctx.movedHero ~= ctx.hero then return end

		-- AS CASAS ATRAVESSADAS mais a de ORIGEM (ele estava de pé nela e a
		-- desocupa ao sair) pegam fogo. A de DESTINO fica de fora: é onde ele
		-- parou, não por onde andou. A1 → B1 → C1 → D1 acende A1, B1 e C1.
		--
		-- `ctx.path` (do HexGrid.FindPath) já vem sem a origem e com o destino
		-- no fim — por isso o laço para em #path - 1 e a origem entra à parte,
		-- via `ctx.origin`. Consequência direta da regra: um passo de UMA casa
		-- só (path com um elemento) acende só a origem, nada no meio.
		local path = ctx.path or {}
		local consumed = ctx.consumedOwnTiles
		local acendeu = false

		if ctx.origin then
			ctx.api.LightFlame(ctx.origin, ctx.hero)
			acendeu = true
		end

		for index = 1, #path - 1 do
			local hexId = path[index]
			-- Casa que ELE MESMO acabou de consumir nesta caminhada (ver
			-- MatchManager.MoveHero) não reacende: sem esta trava, o fogo
			-- apagava e voltava no mesmo movimento — o jogador ouvia o som de
			-- consumir e via a chama continuar lá, porque um segundo depois
			-- ela já tinha sido reacesa por este mesmo laço.
			if not (consumed and consumed[hexId]) then
				ctx.api.LightFlame(hexId, ctx.hero)
				acendeu = true
			end
		end

		-- Efeito só quando acendeu alguma coisa: com o destino fora da regra, o
		-- passo curto agora termina sem rastro nenhum, e soltar a labareda em
		-- cima do Karo prometeria um fogo que não existe no tabuleiro.
		if acendeu then
			ctx.api.Effect(ctx.hero)
		end
	end,
}

-- Karo — o soco gira: todo inimigo colado nele leva o mesmo dano
--
-- `Effect(ctx.hero)` sai PRIMEIRO e incondicional: todo ataque do Karo solta o
-- estouro de fogo em cima dele mesmo, tenha ou não gente extra no raio 1 —
-- reaproveita o MESMO efeito (flameStrike) que HeroView.SKILL_EFFECTS já
-- define, sem sistema de VFX novo.
-- SÓ NO ATAQUE DELE. Revidando, o Karo bate em um herói só — o giro é coisa do
-- golpe que ele escolhe dar, não da resposta automática. É regra, não descuido:
-- `onCounterAttack` fica de fora desta lista de propósito (o iceEffect do Kor e
-- o poisonAttack da Vic estão nos dois gatilhos, então a ausência aqui chama a
-- atenção de quem lê e já foi "corrigida" uma vez por engano).
Skills.flameStrike = {
	triggers = { "onAttack" },
	apply = function(ctx)
		ctx.api.Effect(ctx.hero)
		ctx.api.FireCircle(ctx.hero)
		-- só cosmético: mostra as 6 casas a distância 1 que o giro alcança,
		-- não muda quem é atingido (isso é o GetEnemiesInRange logo abaixo)
		ctx.api.FlashAttackRange(ctx.hero)

		for _, enemy in ipairs(ctx.api.GetEnemiesInRange(ctx.hero, 1)) do
			-- o alvo principal fica de fora: o dano dele sai do PerformAttack, e
			-- bater aqui também o faria levar o golpe duas vezes
			if enemy ~= ctx.target and enemy.isAlive then
				-- efeito ANTES do dano, como no beyondFront: se o golpe mata, o
				-- herói perde o modelo (e com ele o emissor) antes da partícula sair
				ctx.api.Effect(enemy)
				ctx.api.ApplyDamage(enemy, ctx.hero.attack, ctx.hero, ctx.isCounterAttack)
			end
		end
		-- sem damageApplied: o alvo principal leva o dano normal
	end,
}

-- Karo — Furor das Chamas: pisar no PRÓPRIO rastro já aceso dá +1 de ataque
-- por casa, direto na ficha. Não marca mais o inimigo — o bônus é só do Karo.
--
-- `ctx.enteredFlameCount` vem PRONTO do MoveHero, calculado ANTES do
-- flamePath acender qualquer coisa nova: é a contagem de quantas casas do
-- caminho já estavam em chamas ANTES deste passo. Calcular aqui dentro
-- dependeria da ORDEM das habilidades do Karo no catálogo (se flamePath
-- rodasse primeiro, este código veria fogo que ELE MESMO acabou de acender
-- agora, e todo passo daria bônus — não é o que a regra pede).
Skills.flameFury = {
	triggers = { "onMove" },
	apply = function(ctx)
		if ctx.movedHero ~= ctx.hero then return end
		if not ctx.enteredFlameCount or ctx.enteredFlameCount <= 0 then return end

		-- Empréstimo, não acúmulo: se ainda restar um Furor de um passo
		-- anterior, desfaz ele PRIMEIRO — o resto da conta parte sempre da
		-- ficha BASE, nunca de cima de um bônus que ainda não venceu. Sem isso,
		-- dois passos em fogo em turnos diferentes se somariam sem nunca
		-- esbarrar no teto.
		local existing = ctx.api.FindStatusEffect(ctx.hero, "flameFury")
		local previous = existing and existing.attackBonus or 0
		if existing then
			ctx.api.IncreaseAttack(ctx.hero, -previous)
		end

		local base = ctx.hero.attack
		for _, effect in ipairs(ctx.hero.statusEffects) do
			if effect ~= existing then
				base -= effect.attackBonus or 0
			end
		end

		local room = GameConfig.FLAME_FURY_MAX_ATTACK - base
		local gained = ctx.enteredFlameCount * GameConfig.FLAME_FURY_ATTACK
		local bonus = math.clamp(math.max(previous, gained), 0, room)
		if bonus <= 0 then return end

		ctx.api.IncreaseAttack(ctx.hero, bonus)

		-- Mesmo padrão do bônus do barril: um status com attackBonus que o
		-- ProcessStatusEffects devolve sozinho quando o prazo acaba — 1 turno
		-- de uso, depois volta pro normal.
		ctx.api.ApplyStatusEffect(ctx.hero, {
			type = "flameFury",
			duration = GameConfig.FLAME_FURY_DURATION,
			attackBonus = bonus,
		})

		-- reaproveita o efeito de "rise" do próprio rastro em vez de criar um
		-- novo — combina mais com "carregou energia" do que o "burst" de impacto
		ctx.api.Effect(ctx.hero, "flamePath")
	end,
}

-- ===== LUCY: A IRMÃ DO KARO =====
-- Mesmo gatilho do flameFury (onMove + enteredFlameCount, já contado pelo
-- MoveHero pras casas em chamas do PRÓPRIO LADO no caminho andado — Karo e
-- Lucy compartilham o mesmo fogo por construção, ver match.flames), payoff
-- oposto: cura em vez de ataque. Mais simples que o espelho dele porque cura
-- é HP instantâneo, não status que acumula — não tem bônus anterior pra
-- desfazer antes de somar de novo.
Skills.flameHeal = {
	triggers = { "onMove" },
	apply = function(ctx)
		if ctx.movedHero ~= ctx.hero then return end
		if not ctx.enteredFlameCount or ctx.enteredFlameCount <= 0 then return end

		ctx.api.Heal(ctx.hero, ctx.enteredFlameCount * GameConfig.LUCY_FLAME_HEAL)
		ctx.api.Effect(ctx.hero, "flamePath") -- reaproveita o efeito visual do Karo
	end,
}

-- Lucy — aliados adjacentes tomam 1 a menos de dano. Mesmo formato do
-- autoDefense do Ralph (passive = true, sem trigger), só que a redução vale
-- pra quem está do LADO dela, não pra ela mesma — por isso o campo se chama
-- modifyIncomingDamageNearby: quem chama isso (ApplyDamage, em MatchManager)
-- itera as aliadas perto de quem apanhou, separado do loop que já existe
-- pras habilidades da própria vítima.
Skills.emberShield = {
	passive = true,
	triggers = {},
	modifyIncomingDamageNearby = function(amount, info)
		return math.max(0, amount - 1)
	end,
}

-- ===== ZEFF: O VENTO =====
-- Rajada — sopra em DUAS direções na mesma jogada: os aliados do alvo voam pra
-- longe DELE (não do Zeff), e o alvo voa pra longe do ZEFF, como no rage do
-- Bramm. São duas origens de linha diferentes no mesmo golpe, e é isso que
-- abre a formação em vez de só recuar uma peça.
--
-- A ORDEM IMPORTA: os colados saem PRIMEIRO, lidos da posição original do alvo.
-- Empurrando o alvo antes, o GetAlliesInRange leria a vizinhança da casa nova e
-- metade da formação nem seria tocada — e a casa atrás do alvo pode ser
-- justamente a que um colado acabou de desocupar, com o alvo caindo atrás dele.
Skills.gustPush = {
	triggers = { "onAttack" },
	apply = function(ctx)
		ctx.api.Effect(ctx.hero) -- a rajada saindo dele, além do que acontece em quem é empurrado
		ctx.api.PlaySkillSound("gustPush")

		-- aliados do ALVO = inimigos de quem atacou. GetAlliesInRange nunca
		-- devolve o próprio ctx.target, então ele fica parado sozinho sem
		-- precisar de exceção escrita à mão (mesma leitura que o
		-- aloneIsBetter do Noctin já faz pra saber se o alvo está isolado).
		for _, other in ipairs(ctx.api.GetAlliesInRange(ctx.target, 1)) do
			local away = ctx.api.GetLineBeyond(ctx.target.position, other.position, 1)[1]
			if away and ctx.api.IsFree(away) then
				ctx.api.ForceMove(other, away)
				ctx.api.Effect(other)
			else
				-- sem pra onde ir: o vento vira dano em vez de reposicionar —
				-- mesmo raciocínio do rage do Bramm quando o empurrão falha
				ctx.api.Effect(other)
				ctx.api.ApplyDamage(other, GameConfig.GUST_BLOCKED_DAMAGE, ctx.hero, ctx.isCounterAttack)
			end
		end

		local behind = ctx.api.GetLineBeyond(ctx.hero.position, ctx.target.position, 1)[1]
		if behind and ctx.api.IsFree(behind) then
			ctx.api.ForceMove(ctx.target, behind)
			ctx.api.Effect(ctx.target)
		else
			ctx.api.Effect(ctx.target)
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + GameConfig.ZEFF_PUSH_BLOCKED_BONUS,
				ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
		end
	end,
}

Skills.tailwind = {
	triggers = { "onMove" },
	apply = function(ctx)
		local moved = ctx.movedHero
		if moved.ownerId ~= ctx.hero.ownerId then return end

		local allies = ctx.api.GetAlliesInRange(ctx.hero, 1)
		if moved ~= ctx.hero then
			allies = table.find(allies, moved) and { moved } or {}
		end
		if #allies == 0 then return end

		for _, ally in ipairs(allies) do
			ctx.api.Effect(ally)
		end
	end,
}

-- ===== WREN: A ATIRADORA =====
-- Substitui o dano de ficha pela DISTÂNCIA até o alvo: quanto mais longe
-- disparou, mais dói. `ctx.hero.attack` nunca é lido aqui de propósito — o
-- crachá de ataque na UI mostra a ficha dela normalmente (mesmo caso do dobro
-- do Kor contra alvo congelado: sem prévia por alvo, o número real só aparece
-- no dano de verdade quando o golpe sai).
--
-- `onCounterAttack` também: revidar de perto dói tão pouco quanto atacar de
-- perto — a fraqueza dela é simétrica, não só na hora de atacar primeiro.
Skills.longShot = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local distance = ctx.api.Distance(ctx.hero.position, ctx.target.position)
		local damage = math.clamp(distance, 1, GameConfig.WREN_RANGE)

		ctx.api.Effect(ctx.target)
		ctx.api.ApplyDamage(ctx.target, damage, ctx.hero, ctx.isCounterAttack)
		ctx.damageApplied = true
	end,
}

-- ===== SHADOW: A FURTIVIDADE =====
-- Quebra IMEDIATA da sombra, com o visual junto: o `stealth` do herói é o
-- ÚNICO estado de invisibilidade do jogo (é ele que o Snapshot lê pra esconder
-- o registro do adversário e que o AttackHero lê pra recusar a mira), então
-- toda saída da sombra passa por aqui — atacar e levar dano usam a mesma porta.
local function BreakStealth(ctx)
	if not ctx.hero.stealth then return end
	ctx.hero.stealth = false
	ctx.api.Effect(ctx.hero, "stealthBreak")
end

-- Fica invisível enquanto nenhum inimigo estiver a STEALTH_RANGE ou menos.
-- Mora aqui fora porque o recálculo acontece em dois gatilhos diferentes.
--
-- SÓ O MOVIMENTO DO INIMIGO CONTA. Se o passo do próprio Shadow recalculasse,
-- a Emboscada seria impossível: ele bate de perto (alcance 1), e 1 é menos que
-- STEALTH_RANGE — a invisibilidade cairia no passo de andar, antes do golpe.
-- O que o tira da sombra é o ATAQUE dele ou o DANO que ele leva (os dois pelo
-- BreakStealth acima), não a própria aproximação.
local function SyncStealth(ctx)
	local hidden = #ctx.api.GetEnemiesInRange(ctx.hero, GameConfig.STEALTH_RANGE) == 0
	if ctx.hero.stealth == hidden then return end

	-- A ORDEM IMPORTA nos dois sentidos, porque a marca `stealth` é o que
	-- silencia TODO efeito visual do herói (ver HeroView): a fumaça do sumiço
	-- sai enquanto ele ainda está à vista, e a da revelação depois de a marca
	-- cair. Invertendo, o efeito da vez seria engolido pelo próprio filtro.
	if hidden then
		ctx.api.Effect(ctx.hero, "stealth")
		-- Som só na ENTRADA na sombra, não na quebra: o pedido era "efeito
		-- quando ele ficar invisível", e a quebra já tem leitura visual própria
		-- (stealthBreak) sem precisar de áudio extra.
		ctx.api.PlaySkillSound("stealth")
		ctx.hero.stealth = true
	else
		ctx.hero.stealth = false
		ctx.api.Effect(ctx.hero, "stealthBreak")
	end
end

Skills.stealth = {
	triggers = { "onTurnStart", "onMove", "onAttack", "onCounterAttack", "onDamage" },
	apply = function(ctx)
		-- ATACAR entrega a posição, venha o golpe de quem for. LEVAR DANO
		-- entrega do mesmo jeito: o vulto apanhou, então ele está ali — e cai
		-- na hora, seja o dano de um golpe, do veneno, do fogo do Karo ou da
		-- maldição da lápide (fonte sem autor chega aqui igual). O dano em si
		-- não muda: quem reduz dano recebido são as passivas do ApplyDamage, e
		-- a furtividade nunca foi uma delas.
		--
		-- Sai antes do recálculo por proximidade: quem bateu pode estar longe
		-- demais pra revelar por distância, e ainda assim a sombra caiu.
		local trigger = ctx.trigger
		if trigger == "onAttack" or trigger == "onCounterAttack" or trigger == "onDamage" then
			BreakStealth(ctx)
			return
		end

		-- o próprio passo não conta contra ele, salvo o bônus do Instinto de Caça
		if ctx.movedHero == ctx.hero and not ctx.bonusMove then return end

		SyncStealth(ctx)
	end,
}

-- Shadow — a sombra fecha os ferimentos
Skills.stealthHeal = {
	triggers = { "onTurnEnd" },
	apply = function(ctx)
		if not ctx.hero.stealth then return end
		if ctx.hero.currentHp >= ctx.hero.maxHp then return end

		ctx.api.Effect(ctx.hero)
		ctx.api.Heal(ctx.hero, GameConfig.STEALTH_HEAL)
	end,
}

-- Shadow — emboscada: o golpe que SAI da sombra causa dano extra
--
-- UMA condição só: o Nash estava invisível quando este golpe começou. Posição
-- não entra mais na conta — frente, lado ou costas do inimigo dão o mesmo
-- bônus (a regra de "pelas costas" foi removida do jogo inteiro, junto com o
-- IsBehind que a calculava).
--
-- A condição vale pelo estado de ANTES do golpe. O `attackerWasStealthed` vem
-- carimbado no ctx pelo PerformAttack, e não lido de `hero.stealth` aqui, de
-- propósito: a skill `stealth` também roda neste mesmo gatilho e apaga a marca,
-- e qual das duas corre primeiro depende da ordem do array de habilidades.
-- Lendo o carimbo, a Emboscada acerta esteja ela em que posição estiver — e é
-- esse mesmo carimbo que faz o bônus valer UMA vez: quem quebrou a sombra foi
-- este golpe, então o próximo ataque já encontra `stealth = false`. Vale
-- também pra quebra por dano (ver Skills.stealth): revelado antes de bater, o
-- ataque seguinte sai sem bônus.
--
-- `hero.attack` CRU + o bônus, e nunca GameConfig.EffectiveAttack: aquela
-- função existe pras TELAS (crachá e ficha), e lê `hero.stealth` ao vivo — se
-- ela entrasse aqui e a skill `stealth` ainda não tivesse corrido, o +4 seria
-- somado duas vezes (2 + 4 + 4 = 10). As duas contas dão o mesmo 6, cada uma
-- lendo a sombra pela fonte certa: a tela pelo estado atual, o golpe pelo
-- carimbo de antes.
Skills.ambush = {
	suppressesReaction = function(hero) return hero.stealth == true end,
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		if not ctx.attackerWasStealthed then return end

		ctx.api.PlaySkillSound("ambush")
		ctx.api.Effect(ctx.target)
		ctx.api.ApplyDamage(
			ctx.target,
			ctx.hero.attack + GameConfig.AMBUSH_BONUS_DAMAGE,
			ctx.hero,
			ctx.isCounterAttack
		)
		ctx.damageApplied = true

		-- Golpe vindo da sombra não dá tempo de revidar — diferente do
		-- autoDefense do Ralph (que deixa o contra-ataque ACONTECER, só com
		-- menos dano), aqui ele nem chega a sair: MatchManager.AttackHero lê
		-- este sinal e pula o contra-ataque inteiro pra este golpe, SEM marcar
		-- match.turn.counterAttack — o alvo ainda pode revidar normalmente se
		-- outro herói o atacar depois, no mesmo turno.
		ctx.suppressCounter = true
	end,
}

local function Restealth(ctx)
	if ctx.hero.stealth then return end
	ctx.api.Effect(ctx.hero, "stealth")
	ctx.api.PlaySkillSound("stealth")
	ctx.hero.stealth = true
end

Skills.huntInstinct = {
	triggers = { "onAttackResolved" },
	apply = function(ctx)
		if ctx.targetKilled then
			ctx.api.GrantExtraAction(ctx.hero, true)
			if ctx.attackerWasStealthed then
				Restealth(ctx)
			else
				SyncStealth(ctx)
			end
		elseif ctx.targetWasAlone then
			ctx.api.GrantExtraAction(ctx.hero, false)
		end
	end,
}

-- ===== GOLEM =====
-- Ao perder a PRIMEIRA vida, vira dois golens novos: um na casa dele, o outro
-- na primeira casa livre ao lado.
--
-- `SuppressGrave` tem que sair ANTES das invocações: o KillHero cria a lápide
-- logo depois deste gatilho, e ela ocuparia a casa em que o primeiro golem
-- novo está tentando nascer.
--
-- O túmulo do corpo grande não some — ele fica PENDENTE. Enquanto sobrar um
-- pedaço de pé, o Golem não está enterrado; quando o ÚLTIMO mini-golem cair, o
-- MatchManager levanta a lápide dele na casa livre mais próxima (ver
-- ResolvePendingGraves). Se nenhum pedaço chegar a nascer — tabuleiro sem casa
-- livre —, não há o que esperar e o túmulo sobe na hora, ainda dentro desta
-- mesma morte.
--
-- O CICLO INTEIRO, que é o que esta ordem toda serve pra sustentar:
--
--   Golem morre -> pedaços nascem -> último pedaço cai -> túmulo do Golem
--   -> Casa de Promoção -> volta o GOLEM GRANDE (dataId 14, RESURRECT_HP de
--   vida) -> joga normal -> morre de novo -> estilhaça de novo...
--
-- Quem ressuscita é o dono do TÚMULO, e o túmulo é do corpo grande: a promoção
-- nunca devolve um mini-golem no lugar dele. E o herói que volta é um registro
-- novo em folha (CreateHero), sem pendência nem marca nenhuma da vida
-- anterior — é por isso que o ciclo pode simplesmente recomeçar.
Skills.shatter = {
	triggers = { "onDie" },
	apply = function(ctx)
		ctx.api.SuppressGrave(ctx.hero)
		ctx.api.Effect(ctx.hero)
		ctx.api.PlaySkillSound("shatter")

		local minions = {}
		for _, dataId in ipairs(GameConfig.GOLEM_SUMMON_IDS) do
			local minion = ctx.api.Summon(ctx.hero, dataId)
			if minion then
				table.insert(minions, minion)
			end
		end

		ctx.api.DeferGrave(ctx.hero, minions)
	end,
}

Skills.raiseSkulls = {
	triggers = { "onTurnStart", "onDie" },
	apply = function(ctx)
		if ctx.trigger == "onDie" then
			for _, dataId in ipairs(GameConfig.MORN_SUMMON_IDS) do
				local minion = ctx.api.GetAllyByData(ctx.hero, dataId)
				if minion and minion.isAlive then
					ctx.api.Effect(minion)
					ctx.api.ApplyDamage(minion, minion.currentHp, nil, false, "summonerFell")
				end
			end
			return
		end

		if not ctx.api.IsMyTurn(ctx.hero) then return end

		local cooldown = ctx.hero.skullCooldown or 0
		if cooldown > 0 then
			ctx.hero.skullCooldown = cooldown - 1
			return
		end

		local raised = false
		for _, dataId in ipairs(GameConfig.MORN_SUMMON_IDS) do
			local existing = ctx.api.GetAllyByData(ctx.hero, dataId)
			if not (existing and existing.isAlive) then
				local minion = ctx.api.Summon(ctx.hero, dataId)
				if minion then
					minion.noGrave = true
					ctx.api.Effect(minion)
					raised = true
				end
			end
		end

		if not raised then return end

		ctx.api.Effect(ctx.hero)
		ctx.api.PlaySkillSound("raiseSkulls")
		ctx.hero.skullCooldown = GameConfig.MORN_SUMMON_COOLDOWN
	end,
}

Skills.lanternReturn = {
	passive = true,
	triggers = {},
}

Skills.estopim = {
	triggers = { "onDie" },
	apply = function(ctx)
		ctx.api.Effect(ctx.hero)
		ctx.api.PoisonBomb(ctx.hero)
		ctx.api.PlaySkillSound("estopim")

		local alvos = ctx.api.GetEnemiesInRange(ctx.hero, 1)

		ctx.api.ResolveTogether(function()
			for _, enemy in ipairs(alvos) do
				ctx.api.Effect(enemy)
				ctx.api.ApplyDamage(enemy, GameConfig.ESTOPIM_DAMAGE, ctx.hero, false)

				if enemy.isAlive then
					ctx.api.ApplyStatusEffect(enemy, {
						type = "poison",
						duration = GameConfig.POISON_DURATION,
						damagePerTurn = 1,
						ticksEveryTurn = true,
					})
				end
			end
		end)
	end,
}

Skills.voltChain = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local target = ctx.target
		if not target then return end

		if target.isAlive and target.ownerId ~= ctx.hero.ownerId then
			ctx.api.Electrify(target, ctx.hero)
		end

		ctx.api.ChainFrom(ctx.hero, target.position)
	end,
}

Skills.momentum = {
	triggers = { "onMove", "onAttackResolved", "onTurnEnd" },
	apply = function(ctx)
		if ctx.trigger ~= "onMove" then
			ctx.api.RemoveStatusEffect(ctx.hero, "momentum")
			return
		end

		if ctx.movedHero ~= ctx.hero then return end

		ctx.api.RemoveStatusEffect(ctx.hero, "momentum")

		local steps = #(ctx.path or {})
		local bonus = steps * GameConfig.MOMENTUM_PER_HEX
		if bonus <= 0 then return end

		ctx.api.IncreaseAttack(ctx.hero, bonus)
		ctx.api.ApplyStatusEffect(ctx.hero, {
			type = "momentum",
			duration = 1,
			attackBonus = bonus,
		})
		ctx.api.Effect(ctx.hero)
	end,
}

Skills.dodge = {
	passive = true,
	triggers = {},
}

-- ===== SPYKE: O SUPORTE QUE NÃO PARA =====
-- Ponto de Apoio — aura de +1 de ataque em quem estiver colado nele. É o mesmo
-- mecanismo do trustInTeam do Dante (IncreaseAttack + uma marca própria), com
-- uma diferença que muda tudo: o bônus mora em OUTRO herói, então quem recebeu
-- precisa saber DE QUEM recebeu pra ninguém devolver ponto alheio. Daí
-- `rallyAuraFrom` guardar o uid da fonte em vez de um booleano.
--
-- Varre TODOS os aliados vivos, não só os vizinhos: a lista de quem está perto
-- responde a quem GANHA, e a devolução precisa achar quem ficou pra trás — que,
-- por definição, não está mais na lista de perto.
--
-- Uma passagem só resolve tudo (aplicar, devolver, ou não mexer), então
-- recalcular duas vezes seguidas não empilha nada. É o que deixa a coisa
-- pendurada em vários gatilhos sem medo.
local function SyncRallyAura(ctx)
	local giving = ctx.hero.isAlive and ctx.trigger ~= "onDie"

	for _, ally in ipairs(ctx.api.GetAlliesInRange(ctx.hero, math.huge)) do
		local near = giving and ctx.api.Distance(ctx.hero.position, ally.position) <= 1

		if near and ally.rallyAuraFrom == nil then
			ctx.api.IncreaseAttack(ally, GameConfig.SPYKE_AURA_ATTACK)
			ally.rallyAuraFrom = ctx.hero.uid
		elseif not near and ally.rallyAuraFrom == ctx.hero.uid then
			ctx.api.IncreaseAttack(ally, -GameConfig.SPYKE_AURA_ATTACK)
			ally.rallyAuraFrom = nil
		end
	end
end

Skills.rallyAura = {
	-- onMove dispara em TODO herói a cada passo de qualquer um (ver
	-- MatchManager.MoveHero), então a aura se corrige tanto quando o Spyke anda
	-- quanto quando o aliado é que se aproxima ou se afasta. Os dois passos da
	-- Agility entram por aqui igual, sem tratamento especial: cada um é um
	-- onMove, e cada onMove é um recálculo.
	triggers = { "onTurnStart", "onTurnEnd", "onMove", "onDie" },
	apply = SyncRallyAura,
}

-- Sangue Fervendo — 1 turno em que cada aliado COLADO que sofrer dano rende +1 de
-- ataque ao Spyke. Ele NÃO perde vida com isso, e o aliado leva o golpe inteiro:
-- não é absorção, transferência nem interceptação — é o Spyke se acendendo com o
-- que fizeram com quem ele estava protegendo.
--
-- Conta CABEÇA atingida, não pontos de dano: 2 vizinhos pegos por um golpe em
-- área rendem +2, um vizinho que levou 10 rende +1.
--
-- Quem soma é o ApplyDamage, pelo campo attackFromNearbyHit — mesmo arranjo do
-- modifyIncomingDamageNearby da Lucy, só que este não devolve dano modificado,
-- devolve o ataque que o vizinho ganha. O bônus é guardado NESTE efeito
-- (`attackBonus`), que é o que faz o ProcessStatusEffects devolvê-lo sozinho
-- quando o prazo vence.
--
-- ACUMULA ENQUANTO A CORRENTE NÃO QUEBRA. Atacar RENOVA o prazo do efeito que já
-- está aberto, e é a mesma tabela que volta pra lista — o que ele juntou
-- continua lá. Deixar de atacar um turno é o que corta: aí o prazo vence, o
-- ProcessStatusEffects devolve tudo de uma vez e ele recomeça do ataque de ficha.
Skills.vengeance = {
	triggers = { "onAttackResolved" },
	apply = function(ctx)
		ctx.api.RemoveStatusEffect(ctx.hero, "vengeance")
	end,

	attackFromNearbyHit = function(info)
		if not info.ally.isAlive then return 0 end
		return GameConfig.SPYKE_VENGEANCE_ATTACK
	end,
}

-- ===== KIRA: O ESCUDO =====
-- Égide — no início do turno dela, o jogador escolhe um aliado sem escudo e ele
-- fica protegido do próximo golpe.
--
-- A skill faz UMA coisa: abre a oferta. Ela não aplica o escudo, não sabe
-- bloquear dano e não conhece a tabela de efeitos — quem escolhe é o jogador
-- (MatchManager.GrantShield) e quem gasta é o cano de dano (ConsumeShield). Essa
-- divisão é o que deixa o escudo ser um estado do JOGO e não uma regra da Kira:
-- outra fonte que aplique um efeito `shield` ganha o bloqueio inteiro de graça.
--
-- Sem gasto de ação de propósito: a oferta corre junto com o turno, e ignorá-la
-- não custa nada além do escudo daquele turno.
Skills.aegis = {
	triggers = { "onTurnStart" },
	apply = function(ctx)
		ctx.api.OfferShield(ctx.hero)
	end,
}

return Skills
