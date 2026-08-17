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
			ctx.api.IncreaseAttack(ctx.hero, -2)
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

-- Mineiro — no fim do turno, chance de ganhar +1 de ataque (acumula)
Skills.goodLuck = {
	triggers = { "onTurnEnd" },
	apply = function(ctx)
		if math.random() < GameConfig.GOOD_LUCK_CHANCE then
			ctx.api.PlaySkillSound("goodLuck")
			ctx.api.IncreaseAttack(ctx.hero, 1)
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
				ctx.api.Heal(ally, 2)
			end
		end
	end,
}

-- Elaria — limpa efeitos negativos dos aliados adjacentes ao atacar
Skills.clean = {
	triggers = { "onAttack" },
	apply = function(ctx)
		for _, ally in ipairs(ctx.api.GetAlliesInRange(ctx.hero, 1)) do
			if #ally.statusEffects > 0 then
				ctx.api.ClearStatusEffects(ally)
				ctx.api.Effect(ally)
			end
		end
	end,
}

-- Bramm — empurra o alvo 1 casa; se não der, causa ataque +1
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
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + 1, ctx.hero, ctx.isCounterAttack)
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

	hero.frenzyActive = frenzy
end

-- Merlin — passiva: cada morte no tabuleiro (dos dois lados) engorda o ataque
Skills.bloodScent = {
	triggers = { "onTurnStart", "onMove", "onKill" },
	apply = SyncWolf,
}

-- Merlin — último vivo do time: cura, ataque extra, Sprint e cura por abate
Skills.frenzy = {
	triggers = { "onTurnStart", "onMove", "onKill" },
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

return Skills
