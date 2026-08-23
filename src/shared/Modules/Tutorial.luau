--[[
	Tutorial.lua
	ModuleScript — ReplicatedStorage/Modules/Tutorial

	As lições do tutorial e QUANDO cada uma aparece.

	NÃO É UMA PARTIDA GUIADA. Nada aqui bloqueia botão, força ordem ou espera o
	jogador fazer o passo certo. Cada lição é um cartão que aparece na primeira
	vez que aquele conceito surge de verdade no tabuleiro — viu um barril, um
	Taunt travou o alvo, o contra-ataque disparou — e some sozinho. Quem já
	entendeu joga por cima; quem não entendeu leu no momento em que a dúvida
	nasceu, que é quando a explicação gruda.

	Foi escolha de projeto contra o roteiro passo a passo: o roteiro ensina mais
	firme, mas custa um estado de máquina amarrado no MatchManager e no
	BattleClient, e prende quem já sabe jogar. Aqui o custo é uma tabela e um
	`when`.

	CADA LIÇÃO SE DECIDE SOZINHA, e só a partir do SNAPSHOT que o cliente já
	recebe (MatchManager.Snapshot). Nenhum evento novo saiu do servidor por causa
	do tutorial: tudo que ele precisa saber — de quem é a vez, quais heróis estão
	em campo e com que passiva, se tem barril, se o contra-ataque já foi usado, se
	a Casa de Promoção abriu — já viajava pra pintar a tela. Lição nova é uma
	entrada nesta lista, não um remote.

	`when(state, memory)` devolve true quando é hora de mostrar.
	  state  — o snapshot da partida, como chega no MatchUpdate
	  memory — o que o cliente já viu acontecer nesta partida (ver TutorialClient)

	A ORDEM DA LISTA É A ORDEM DA FILA. Quando duas lições ficam prontas no mesmo
	quadro, a de cima aparece primeiro — por isso ela vai do básico (escolher,
	andar, bater) pro que só acontece mais tarde (contra-ataque, promoção).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local Tutorial = {}

-- Nome da chave que o servidor persiste. Fica aqui pros dois lados lerem a
-- mesma string, igual ao READY_ATTRIBUTE do LightingSetup.
Tutorial.REMOTE_NAME = "TutorialUpdate"

local TAUNT = GameConfig.ABILITIES.TAUNT
local RANGED = GameConfig.ABILITIES.RANGED

-- ===== AJUDANTES =====
local function anyHero(state, predicate)
	for _, hero in ipairs(state.heroes or {}) do
		-- `hidden` é o registro oco do Nash invisível: sem ficha nenhuma, então
		-- perguntar a passiva dele daria nil e a lição nunca dispararia por ele.
		-- Ficar de fora é o certo — o jogador também não o está vendo.
		if not hero.hidden and predicate(hero) then return true end
	end
	return false
end

local function inBattle(state)
	return state.phase == "battle"
end

-- ===== AS LIÇÕES =====
Tutorial.LESSONS = {
	{
		id = "escolha",
		title = "Monte seu time",
		text = ("Toque num herói da lista e depois numa casa azul do seu lado pra " ..
			"posicioná-lo. Você escolhe %d, alternando com o adversário — o que ele " ..
			"pegar, você não pega mais. Olhe o ataque e a vida de cada um antes."):format(GameConfig.HEROES_PER_PLAYER),
		when = function(state)
			return state.phase == "placement" and state.isMyPlacement and (state.placedCount or 0) == 0
		end,
	},

	{
		id = "mover",
		title = "Sua vez de andar",
		text = ("Toque num herói seu e as casas que ele alcança acendem. Cada herói " ..
			"anda %d casas por turno — quem tem Sprint anda %d. No mesmo turno ele " ..
			"pode andar E atacar, mas depois de atacar não anda mais."):format(
			GameConfig.BASE_MOVE_RANGE, GameConfig.SPRINT_MOVE_RANGE),
		when = function(state)
			return inBattle(state) and state.isMyTurn
		end,
	},

	{
		id = "atacar",
		title = "Hora de bater",
		text = ("Com o herói escolhido, toque num inimigo dentro do alcance. Corpo a " ..
			"corpo alcança %d casa; quem tem Ranged alcança %d. O dano é o número de " ..
			"ataque do herói — e cada um só ataca uma vez por turno."):format(
			GameConfig.BASE_ATTACK_RANGE, GameConfig.RANGED_ATTACK_RANGE),
		-- só depois que ele mexeu em alguém: ensinar a bater antes de o jogador
		-- ter andado é falar de um passo que ainda não é o dele
		when = function(state)
			return inBattle(state) and state.isMyTurn
				and anyHero(state, function(h) return h.isMine and h.hasMoved end)
		end,
	},

	{
		id = "taunt",
		title = "Taunt: o muro",
		text = "Heróis com Taunt são muralhas. Enquanto um deles estiver colado no seu " ..
			"herói, você é OBRIGADO a bater nele — nenhum outro alvo aceita o golpe. " ..
			"Serve pros dois lados: o seu Taunt protege o time inteiro do mesmo jeito.",
		when = function(state)
			return inBattle(state) and anyHero(state, function(h) return h.ability == TAUNT end)
		end,
	},

	{
		id = "ranged",
		title = "Ranged: bate de longe",
		text = ("Quem tem Ranged acerta a até %d casas e, ficando longe, não leva " ..
			"contra-ataque. Em compensação costuma ter pouca vida: deixe um herói " ..
			"forte na frente dele."):format(GameConfig.RANGED_ATTACK_RANGE),
		when = function(state)
			return inBattle(state) and anyHero(state, function(h) return h.ability == RANGED end)
		end,
	},

	{
		id = "barril",
		title = "O barril",
		text = ("O barril não revida e não anda. Quebre com %d golpes e quem deu o " ..
			"último ganha o prêmio: %d de vida de volta, ou +%d de ataque por um " ..
			"turno. Só vale quando não tem inimigo melhor no alcance — atacar barril " ..
			"gasta o ataque do herói."):format(
			GameConfig.BARREL_HITS, GameConfig.BARREL_HEAL, GameConfig.BARREL_ATTACK_BONUS),
		when = function(state)
			return inBattle(state) and #(state.barrels or {}) > 0 and state.isMyTurn
		end,
	},

	{
		id = "contraataque",
		title = "Contra-ataque",
		text = "Quem apanha revida na hora — mas só UMA vez por turno, e o revide " ..
			"vale pros dois lados. Por isso o primeiro golpe do turno é o mais caro: " ..
			"depois que o contra-ataque é gasto, todos os outros saem de graça. " ..
			"O selo no canto da tela mostra se ele ainda está de pé.",
		-- dispara no turno em que ele foi realmente usado: o conceito acabou de
		-- acontecer na cara do jogador, e é aí que a frase explica o que ele viu
		when = function(state)
			return inBattle(state) and state.counterAttackUsed == true
		end,
	},

	{
		id = "promocao",
		title = "Casa de Promoção",
		text = ("A partir do turno %d as duas casas douradas das pontas acendem. Leve " ..
			"um herói até a sua e escolha um companheiro caído pra voltar ao jogo " ..
			"com %d de vida. Só dá pra usar UMA vez na partida inteira — e a lápide " ..
			"dele precisa estar de pé."):format(
			GameConfig.PROMOTION_UNLOCK_TURN, GameConfig.RESURRECT_HP),
		when = function(state)
			for _, square in ipairs(state.promotionSquares or {}) do
				if square.state == "active" then return true end
			end
			return false
		end,
	},
}

function Tutorial.GetLesson(id)
	for _, lesson in ipairs(Tutorial.LESSONS) do
		if lesson.id == id then return lesson end
	end
	return nil
end

-- A primeira lição pronta que ainda não foi vista. Devolve nil quando não há
-- nada a ensinar agora — que é o caso da imensa maioria dos quadros.
function Tutorial.NextLesson(state, seen)
	for _, lesson in ipairs(Tutorial.LESSONS) do
		if not seen[lesson.id] then
			local ok, ready = pcall(lesson.when, state)
			-- Um `when` que estoure (snapshot num formato inesperado) não pode
			-- derrubar o laço e levar o tutorial inteiro junto: a lição só não
			-- aparece naquele quadro.
			if ok and ready then return lesson end
		end
	end
	return nil
end

return Tutorial
