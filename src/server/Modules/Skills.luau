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
		ctx.api.Say(ctx.hero, "Absorve!")
	end,
}

-- Blade — dano em sequência: segue a linha atrás do alvo enquanto houver inimigos
Skills.beyondFront = {
	triggers = { "onAttack" },
	apply = function(ctx)
		local line = ctx.api.GetLineBeyond(ctx.hero.position, ctx.target.position, 2)
		local hits = 0

		for _, hexId in ipairs(line) do
			local other = ctx.api.GetHeroAt(hexId)
			if other and other.isAlive and other.ownerId ~= ctx.hero.ownerId then
				ctx.api.ApplyDamage(other, ctx.hero.attack, ctx.hero, ctx.isCounterAttack)
				hits += 1
			else
				break
			end
		end

		if hits > 0 then
			ctx.api.Say(ctx.hero, "Hiay!")
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
			ctx.api.Say(ctx.hero, "Dano extra!")
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
			if not ctx.hero.firstAttack and not ctx.hero.firstPunchApplied and ctx.hero.attack == 3 then
				ctx.api.IncreaseAttack(ctx.hero, 2)
				ctx.hero.firstPunchApplied = true
				ctx.api.Say(ctx.hero, "Preparando!")
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
			ctx.api.IncreaseAttack(ctx.hero, 1)
			ctx.api.Say(ctx.hero, "Ouro!")
		else
			ctx.api.Say(ctx.hero, "Nada...")
		end
	end,
}

-- Vic — aplica veneno; se o alvo já estiver envenenado, renova e causa ataque +2
Skills.poisonAttack = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local existing = ctx.api.FindStatusEffect(ctx.target, "poison")

		if existing then
			existing.duration = GameConfig.POISON_DURATION
			ctx.api.Say(ctx.hero, "Dano extra!")
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + 2, ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
		else
			ctx.api.ApplyStatusEffect(ctx.target, {
				type = "poison",
				duration = GameConfig.POISON_DURATION,
				damagePerTurn = 1,
			})
			ctx.api.Say(ctx.hero, "Veneno!")
		end
	end,
}

-- Dante — +1 de ataque com aliado adjacente, volta ao normal quando fica sozinho
Skills.trustInTeam = {
	triggers = { "onMove", "onTurnStart", "onDie" },
	apply = function(ctx)
		local allies = ctx.api.GetAlliesInRange(ctx.hero, 1)
		local buffed = ctx.hero.attack > ctx.hero.baseAttack

		if #allies > 0 and not buffed then
			ctx.api.IncreaseAttack(ctx.hero, 1)
		elseif #allies == 0 and buffed then
			ctx.api.IncreaseAttack(ctx.hero, -1)
		end
	end,
}

-- Noctin — dobro de dano contra alvo sem nenhum aliado adjacente
Skills.aloneIsBetter = {
	triggers = { "onAttack", "onCounterAttack" },
	apply = function(ctx)
		local targetAllies = ctx.api.GetAlliesInRange(ctx.target, 1)

		if #targetAllies == 0 then
			ctx.api.Say(ctx.hero, "Muahauhauhaua!")
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
				ctx.api.Say(ally, "Limpo!")
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
			ctx.api.Say(ctx.hero, "Sai da frente!")
			-- sem damageApplied: o alvo ainda leva o dano normal, já empurrado
		else
			ctx.api.ApplyDamage(ctx.target, ctx.hero.attack + 1, ctx.hero, ctx.isCounterAttack)
			ctx.damageApplied = true
			ctx.api.Say(ctx.hero, "Esmaga!")
		end
	end,
}

return Skills
