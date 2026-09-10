local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HeroData = require(ReplicatedStorage.Modules.HeroData)

local HeroChallenges = {}

HeroChallenges.STARS_PER_CHALLENGE = 3
HeroChallenges.XP_PER_STAR = 25

local Hero = setmetatable({}, { __index = function(_, name)
	error("HeroChallenges: herói inexistente no HeroData.CATALOG: " .. tostring(name), 2)
end })
for _, data in ipairs(HeroData.CATALOG) do Hero[data.name] = data.id end

HeroChallenges.BY_HERO = {
	[Hero.Nash] = {
		{
			id = "nash1",
			name = "Primeiro Sangue",
			concept = "A sombra fecha sozinha quando nenhum inimigo está colado em você.",
			how = "Nash começa revelado e colado no alvo, e o soco dele não derruba " ..
				"ninguém sozinho. Afaste-se até ninguém estar ao lado, deixe o turno " ..
				"virar pra sombra voltar, e volte pra emboscar: o golpe que sai da " ..
				"sombra causa 4 a mais e não pode ser revidado.",
			arena = "Florest",
			maxTurns = 4,
			botPolicy = "hold",

			player = { { hero = Hero.Nash, hex = "C5" } },
			enemy  = { { hero = Hero.Vic, hex = "C4", hp = 6 } },

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Nash },

			stars = {
				{ text = "Sem receber nenhum dano",
				  check = { kind = "noDamageTaken", hero = Hero.Nash } },
				{ text = "Vencer no turno 2",
				  check = { kind = "withinTurns", turns = 2 } },
			},
		},

		{
			id = "nash2",
			name = "Instinto de Caça",
			concept = "Abater devolve movimento E ataque, e devolve a sombra na hora.",
			how = "Cada abate recarrega o turno do Nash e o esconde de novo, então " ..
				"uma emboscada pode virar três. A ordem dos alvos é o desafio: cada " ..
				"corpo deixa um túmulo que bloqueia a casa, e a rota do próximo tem " ..
				"que caber no movimento que sobrou.",
			arena = "Florest",
			maxTurns = 4,
			botPolicy = "hold",

			player = { { hero = Hero.Nash, hex = "A5", stealth = true } },
			enemy  = {
				{ hero = Hero.Vic,  hex = "A3", hp = 6 },
				{ hero = Hero.Wren, hex = "C2", hp = 6 },
				{ hero = Hero.Kor,  hex = "D3", hp = 6 },
			},

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Nash },

			stars = {
				{ text = "Sem receber nenhum dano",
				  check = { kind = "noDamageTaken", hero = Hero.Nash } },
				{ text = "Derrotar os três no mesmo turno",
				  check = { kind = "withinTurns", turns = 1 } },
			},
		},

		{
			id = "nash3",
			name = "Sombra Longa",
			concept = "Invisível ninguém mira em você, e a sombra ainda fecha ferimento.",
			how = "O Taunt do Ceos só prende quem está COLADO nele: a duas casas, " ..
				"o Wren volta a ser alvo. Enquanto estiver invisível o Nash recupera " ..
				"1 de vida por turno, então dá tempo de escolher o ângulo em vez de " ..
				"correr pro meio.",
			arena = "Rocky",
			maxTurns = 8,
			botPolicy = "hold",

			player = { { hero = Hero.Nash, hex = "C6", hp = 11 } },
			enemy  = {
				{ hero = Hero.Ceos, hex = "C3" },
				{ hero = Hero.Wren, hex = "C2", hp = 6 },
			},

			win  = { kind = "defeatHero", hero = Hero.Wren },
			lose = { kind = "heroDown", hero = Hero.Nash },

			stars = {
				{ text = "Ceos termina intocado",
				  check = { kind = "noDamageTaken", hero = Hero.Ceos, side = "enemy" } },
				{ text = "Nash termina com a vida cheia",
				  check = { kind = "hpFull", hero = Hero.Nash } },
			},
		},
	},

	[Hero.Rush] = {
		{
			id = "rush1",
			name = "Ataque Zero",
			concept = "O ataque do Rush é zero. O dano é o número de casas que ele andou.",
			how = "Cada casa andada no turno vale +1 no golpe daquele turno, e o " ..
				"bônus é gasto no ataque. Ir direto no alvo é o caminho curto, e " ..
				"caminho curto é golpe fraco. Escolha uma casa vizinha ao alvo que " ..
				"esteja LONGE de você.",
			arena = "Desert",
			maxTurns = 3,
			botPolicy = "hold",

			player = { { hero = Hero.Rush, hex = "C6" } },
			enemy  = { { hero = Hero.Vic, hex = "C3", hp = 4 } },

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Rush },

			stars = {
				{ text = "Sem receber nenhum dano",
				  check = { kind = "noDamageTaken", hero = Hero.Rush } },
				{ text = "Vencer no primeiro turno",
				  check = { kind = "withinTurns", turns = 1 } },
			},
		},

		{
			id = "rush2",
			name = "Rota Longa",
			concept = "O bônus morre na virada do turno. Um alvo por turno, sempre pela volta.",
			how = "São dois alvos em pontas opostas do tabuleiro. A viagem de um " ..
				"para o outro é justamente o que carrega o golpe seguinte, então a " ..
				"casa onde você PARA depois do primeiro abate decide se o segundo " ..
				"sai forte ou fraco.",
			arena = "Desert",
			maxTurns = 4,
			botPolicy = "hold",

			player = { { hero = Hero.Rush, hex = "C6" } },
			enemy  = {
				{ hero = Hero.Vic, hex = "C3", hp = 4 },
				{ hero = Hero.Kor, hex = "E4", hp = 4 },
			},

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Rush },

			stars = {
				{ text = "Sem receber nenhum dano",
				  check = { kind = "noDamageTaken", hero = Hero.Rush } },
				{ text = "Vencer em até 2 turnos",
				  check = { kind = "withinTurns", turns = 2 } },
			},
		},

		{
			id = "rush3",
			name = "Reflexo Supersônico",
			concept = "A fuga só existe se sobrar casa que te tire do alcance de quem bate.",
			how = "O Rush escapa de um golpe apenas quando há vizinha livre que o " ..
				"deixe a duas casas ou mais do atacante E fora do alcance dele. " ..
				"Contra o Blade, que bate de perto, sempre existe essa saída — " ..
				"desde que você não termine o turno espremido. O Wren atira de " ..
				"longe e não dá pra desviar dele: a corrida é derrubá-lo antes " ..
				"que a soma dos tiros derrube você.",
			arena = "Snow",
			maxTurns = 6,
			botPolicy = "brain",

			player = { { hero = Hero.Rush, hex = "C6" } },
			enemy  = {
				{ hero = Hero.Wren,  hex = "C2", hp = 8 },
				{ hero = Hero.Blade, hex = "C4" },
			},

			win  = { kind = "defeatHero", hero = Hero.Wren },
			lose = { kind = "heroDown", hero = Hero.Rush },

			stars = {
				{ text = "Terminar com 8 ou mais de vida",
				  check = { kind = "hpAtLeast", hero = Hero.Rush, hp = 8 } },
				{ text = "Vencer em até 4 turnos",
				  check = { kind = "withinTurns", turns = 4 } },
			},
		},
	},

	[Hero.Volt] = {
		{
			id = "volt1",
			name = "Corrente",
			concept = "O alvo leva o golpe inteiro. Quem está encostado nele leva a corrente.",
			how = "O ataque causa o dano cheio em quem você mira e 1 em cada inimigo " ..
				"ligado a ele. Os dois alvos estão colados, então um ataque acerta " ..
				"os dois, mas só uma das duas escolhas derruba os dois de uma vez.",
			arena = "Vulcan",
			maxTurns = 3,
			botPolicy = "hold",

			player = { { hero = Hero.Volt, hex = "C6" } },
			enemy  = {
				{ hero = Hero.Vic,  hex = "C4", hp = 2 },
				{ hero = Hero.Wren, hex = "D5", hp = 1 },
			},

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Volt },

			stars = {
				{ text = "Sem receber nenhum dano",
				  check = { kind = "noDamageTaken", hero = Hero.Volt } },
				{ text = "Vencer no primeiro turno",
				  check = { kind = "withinTurns", turns = 1 } },
			},
		},

		{
			id = "volt2",
			name = "Condutores",
			concept = "Os objetos do tabuleiro conduzem a corrente igual a um inimigo.",
			how = "Nenhum dos três se toca, mas os objetos no meio fecham o circuito. " ..
				"Leia o tabuleiro como um fio antes de andar: quebrar um objeto corta " ..
				"a ligação, e mirar no alvo errado deixa alguém de pé.",
			arena = "Vulcan",
			maxTurns = 4,
			botPolicy = "hold",

			player  = { { hero = Hero.Volt, hex = "C6" } },
			objects = { "C4", "D5" },
			enemy   = {
				{ hero = Hero.Vic,  hex = "B4", hp = 2 },
				{ hero = Hero.Wren, hex = "C5", hp = 1 },
				{ hero = Hero.Kor,  hex = "E4", hp = 1 },
			},

			win  = { kind = "defeatAll" },
			lose = { kind = "heroDown", hero = Hero.Volt },

			stars = {
				{ text = "Espalhar a corrente para dois inimigos de uma vez",
				  check = { kind = "tallyAtLeast", hero = Hero.Volt, key = "chainHits", count = 2 } },
				{ text = "Vencer no primeiro turno",
				  check = { kind = "withinTurns", turns = 1 } },
			},
		},

		{
			id = "volt3",
			name = "Paralisia",
			concept = "Três cargas paralisam, e quem está paralisado não revida.",
			how = "O Ceos puxa o foco enquanto você estiver colado nele e devolve " ..
				"cada golpe recuperando vida, então trocar soco direto não fecha a " ..
				"conta. Carregue-o pela CORRENTE, batendo nos dois ao lado dele a " ..
				"partir de uma casa que não encoste no Ceos. Na terceira carga ele " ..
				"para de revidar, e a janela abre.",
			arena = "Vulcan",
			maxTurns = 10,
			botPolicy = "hold",

			player = { { hero = Hero.Volt, hex = "C5" } },
			enemy  = {
				{ hero = Hero.Ceos, hex = "C3", hp = 10 },
				{ hero = Hero.Vic,  hex = "B4", hp = 5 },
				{ hero = Hero.Wren, hex = "D4", hp = 5 },
			},

			win  = { kind = "defeatHero", hero = Hero.Ceos },
			lose = { kind = "heroDown", hero = Hero.Volt },

			stars = {
				{ text = "Deixar o Ceos paralisado pelo menos uma vez",
				  check = { kind = "tallyAtLeast", hero = Hero.Volt, key = "paralysis", count = 1 } },
				{ text = "Vencer em até 7 turnos",
				  check = { kind = "withinTurns", turns = 7 } },
			},
		},
	},
}

function HeroChallenges.HeroIds()
	local ids = {}
	for _, data in ipairs(HeroData.CATALOG) do
		if HeroChallenges.BY_HERO[data.id] then table.insert(ids, data.id) end
	end
	return ids
end

function HeroChallenges.ListFor(heroId)
	return HeroChallenges.BY_HERO[heroId] or {}
end

function HeroChallenges.Get(heroId, index)
	return HeroChallenges.ListFor(heroId)[index]
end

function HeroChallenges.CountFor(heroId)
	return #HeroChallenges.ListFor(heroId)
end

function HeroChallenges.MaxStarsFor(heroId)
	return HeroChallenges.CountFor(heroId) * HeroChallenges.STARS_PER_CHALLENGE
end

function HeroChallenges.StateOf(stars, owns, index)
	if not owns then return "locked" end

	local earned = (stars or {})[index] or 0
	if earned > 0 then return "done" end
	if index == 1 then return "open" end

	return ((stars or {})[index - 1] or 0) > 0 and "open" or "locked"
end

function HeroChallenges.TotalStars(stars, heroId)
	local total = 0
	for index = 1, HeroChallenges.CountFor(heroId) do
		total += (stars or {})[index] or 0
	end
	return total
end

function HeroChallenges.IsMastered(stars, heroId)
	local count = HeroChallenges.CountFor(heroId)
	if count == 0 then return false end
	return HeroChallenges.TotalStars(stars, heroId) == count * HeroChallenges.STARS_PER_CHALLENGE
end

return HeroChallenges
