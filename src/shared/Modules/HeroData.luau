--[[
	HeroData.lua
	ModuleScript — ReplicatedStorage/Modules/HeroData

	Catálogo de heróis (portado de models/heroes.js) + configuração do
	spritesheet e textos das habilidades. Fica em ReplicatedStorage porque
	tanto o servidor (HeroView) quanto o client (seleção) precisam disso.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local HeroData = {}

HeroData.SPRITE_SHEET = "101129276337487"
HeroData.FRAME_WIDTH = 165
HeroData.FRAME_HEIGHT = 231
HeroData.SHEET_COLUMNS = 3 

function HeroData.GetSpriteId(data)
	local raw = (data and data.sprite) or HeroData.SPRITE_SHEET
	local digits = tostring(raw):gsub("%D", "")
	if digits == "" or digits == "0" then return nil end
	return "rbxassetid://" .. digits
end

local FULL_IMAGE = Vector2.new(0, 0)

function HeroData.GetFrameSize(data)
	local rect = data and data.spriteRect
	if rect then return Vector2.new(rect[3], rect[4]) end
	if data and data.sprite then return FULL_IMAGE end
	return Vector2.new(HeroData.FRAME_WIDTH, HeroData.FRAME_HEIGHT)
end

function HeroData.GetFrameOffset(data)
	local rect = data and data.spriteRect
	if rect then return Vector2.new(rect[1], rect[2]) end
	if data and data.sprite then return FULL_IMAGE end
	return Vector2.new(
		(data.frame % HeroData.SHEET_COLUMNS) * HeroData.FRAME_WIDTH,
		math.floor(data.frame / HeroData.SHEET_COLUMNS) * HeroData.FRAME_HEIGHT
	)
end

-- ===== PROPORÇÃO DA ARTE (por que precisa estar guardada) =====
-- No tabuleiro o sprite é desenhado com ScaleType.Fit dentro de uma moldura
-- 165x231 (RETRATO). Fit preserva a proporção e CENTRALIZA: arte mais larga que
-- a moldura entra "deitada" e sobra faixa vazia em cima E embaixo. A faixa de
-- baixo é o que faz o herói parecer flutuando — quem fica plantado na casa é o
-- pé da MOLDURA, não o do desenho. O Golem (447x361, largo) perdia 21% da
-- altura só nessa faixa, e ampliar a escala dele ampliou a faixa junto.
--
-- Fit não tem alinhamento ("encosta embaixo" não existe), então o HeroView
-- desconta a faixa na mão — e pra isso precisa da proporção da arte, que o
-- engine não expõe em runtime. Daí o spriteSize: é o tamanho em pixels do
-- arquivo, que dá pra ler nas propriedades da imagem ao trocar um sprite.
-- Errar o número não quebra nada, só desalinha o pé daquele herói.
function HeroData.GetArtAspect(data)
	local rect = data and data.spriteRect
	if rect then return rect[3] / rect[4] end
	local size = data and data.spriteSize
	if size then return size.X / size.Y end
	return HeroData.FRAME_WIDTH / HeroData.FRAME_HEIGHT
end

HeroData.POISON_SHEET = "81879107964596"
HeroData.POISON_FRAME_COUNT = 3

function HeroData.GetPoisonSpriteId()
	local digits = HeroData.POISON_SHEET:gsub("%D", "")
	if digits == "" or digits == "0" then return nil end
	return "rbxassetid://" .. digits
end

function HeroData.GetPoisonStageIndex(durationRemaining)
	return math.clamp(HeroData.POISON_FRAME_COUNT - durationRemaining, 0, HeroData.POISON_FRAME_COUNT - 1)
end

HeroData.CATALOG = {
	{ id = 1, name = "Ralph",   frame = 2, attack = 3, hp = 18, ability = nil,      abilities = { "firstPunch", "autoDefense" }, color = Color3.fromRGB(205, 92, 70), starter = true, sprite = "136396565767790", spriteSize = Vector2.new(301, 441), scale = 0.84 },
	{ id = 2, name = "Vic",     frame = 1, attack = 1, hp = 21, ability = nil,      abilities = { "poisonAttack" },              color = Color3.fromRGB(120, 180, 90), sprite = "122742882947541", spriteSize = Vector2.new(855, 1024), scale = 0.98 },
	{ id = 3, name = "Mineiro", frame = 0, attack = 1, hp = 18, ability = "Sprint", abilities = { "goodLuck" },                  color = Color3.fromRGB(180, 140, 70), sprite = "139532054857999", spriteSize = Vector2.new(385, 439), scale = 1.03 },
	{ id = 4, name = "Blade",   frame = 4, attack = 3, hp = 16, ability = nil,      abilities = { "beyondFront" },               color = Color3.fromRGB(150, 150, 165), sprite = "100992479929680", spriteSize = Vector2.new(400, 429), scale = 1.09 },
	{ id = 5, name = "Dante",   frame = 5, attack = 2, hp = 18, ability = "Ranged", abilities = { "brokenDefense", "trustInTeam" }, color = Color3.fromRGB(90, 150, 200), starter = true, sprite = "76020534312617", spriteSize = Vector2.new(407, 426), scale = 1.12 },
	{ id = 6, name = "Ceos",    frame = 3, attack = 1, hp = 33, ability = "Taunt",  abilities = { "absorbRoots" },               color = Color3.fromRGB(110, 160, 120), starter = true, sprite = "125070102363421", spriteSize = Vector2.new(438, 454), scale = 1.26 },
	{ id = 7, name = "Noctin",  frame = 8, attack = 3, hp = 14, ability = "Sprint", abilities = { "aloneIsBetter" },             color = Color3.fromRGB(80, 80, 110), sprite = "126479088125110", spriteSize = Vector2.new(256, 307), scale = 0.85 },
	{ id = 8, name = "Elaria",  frame = 7, attack = 1, hp = 20, ability = "Ranged", abilities = { "health", "clean" },           color = Color3.fromRGB(190, 130, 200), sprite = "98874918804932", spriteSize = Vector2.new(254, 323), scale = 0.92 },
	{ id = 9, name = "Bramm",   frame = 6, attack = 1, hp = 30, ability = "Taunt",  abilities = { "rage" },                      color = Color3.fromRGB(160, 110, 60), sprite = "97869309543381", spriteSize = Vector2.new(358, 319), scale = 1.47 },

	{ id = 10, name = "Kor", attack = 1, hp = 23, ability = "Ranged", attackRange = 3,
		abilities = { "iceEffect", "iceStorm" },
		color = Color3.fromRGB(150, 210, 240),
		sprite = "127914513925837", spriteSize = Vector2.new(299, 358), scale = 0.98
	},

	{ id = 11, name = "Merlin", attack = 2, hp = 22, ability = nil,
		abilities = { "bloodScent", "frenzy" },
		color = Color3.fromRGB(150, 70, 60),
		sprite = "85377589727040", spriteSize = Vector2.new(259, 348), scale = 0.87 
	},

	{ id = 12, name = "Karo", attack = 2, hp = 19, ability = nil,
		abilities = { "flamePath", "flameStrike", "flameFury" },
		color = Color3.fromRGB(255, 140, 70),
		sprite = "73283114537576", spriteSize = Vector2.new(304, 354), scale = 1.01 },

	{ id = 13, name = "Nash", attack = 2, hp = 14, ability = "Sprint",
		abilities = { "stealth", "stealthHeal", "ambush", "huntInstinct" },
		color = Color3.fromRGB(80, 90, 120),
		sprite = "95643253305726", spriteSize = Vector2.new(312, 306), scale = 1.04 },

	{ id = 14, name = "Golem", attack = 1, hp = 40, ability = "Taunt",
		abilities = { "shatter" },
		color = Color3.fromRGB(140, 140, 140),
		sprite = "95596148134035", spriteSize = Vector2.new(447, 361), scale = 1.62 },

	-- Lucy — irmã do Karo. `flamePath` é literalmente a MESMA skill dele, não uma
	-- cópia: o rastro de fogo já é por lado (match.flames[hexId].ownerId), não por
	-- herói, então ela acende e cruza o mesmo fogo sem código extra nenhum. O
	-- payoff é que muda: ele pisa em chama e ganha ataque (flameFury), ela pisa e
	-- se cura (flameHeal). Sem Sprint/Ranged/Taunt de propósito — ela protege de
	-- perto, não de longe.
	{ id = 17, name = "Lucy", attack = 1, hp = 22, ability = nil,
		abilities = { "flamePath", "flameHeal", "emberShield" },
		color = Color3.fromRGB(240, 150, 120),
		sprite = "108465334355138", spriteSize = Vector2.new(312, 416), scale = 0.88 },

	-- Zeff — controle de posicionamento, não dano. Empurra os aliados do ALVO
	-- pra longe dele (não os do próprio Zeff) e o alvo pra longe do Zeff,
	-- abrindo a formação inteira em vez de recuar uma peça só.
	--
	-- `attackRange` aqui é override, não a ability `Ranged` — ele mantém
	-- `Sprint` (move 3, ficha e texto de UI continuam sendo os do Sprint) e
	-- ganha o alcance de ataque padrão do Ranged por fora, igual o Kor fazia
	-- quando atirava mais longe que o resto (ver HeroData.GetAttackRange).
	-- Escreve `GameConfig.RANGED_ATTACK_RANGE` em vez de número solto porque,
	-- ao contrário do Kor, este não é um valor PRÓPRIO — é o padrão do jogo,
	-- e deve acompanhar se ele mudar.
	--
	-- O preço que ele pagava por controlar formação era o contra-ataque (o
	-- revide só exige `Distance <= attackRange do alvo`, não adjacência) —
	-- com alcance 2 ele empurra sem entrar no alcance de ninguém que não seja
	-- Ranged também. Se sair forte demais nos testes, é aqui que se mexe
	-- primeiro, antes de tocar em ataque/vida.
	{ id = 18, name = "Zeff", attack = 2, hp = 17, ability = "Sprint",
		attackRange = GameConfig.RANGED_ATTACK_RANGE,
		abilities = { "gustPush", "tailwind" },
		color = Color3.fromRGB(150, 230, 220),
		sprite = "86076939045382", spriteSize = Vector2.new(412, 405), scale = 1.19 },

	-- Wren — atiradora. `ability = "Ranged"` com `attackRange` próprio é o
	-- mesmo arranjo que o Kor usava quando atirava mais longe que os outros
	-- Ranged: a passiva diz O QUE ela é (e a ficha na UI lê o alcance real
	-- dela, não o padrão), o campo diz QUANTO.
	--
	-- `attack = 3` é DECORATIVO: o longShot sempre substitui o dano pelo valor
	-- da distância (damageApplied), então este número nunca é o dano de fato.
	-- Fica em 3 por ser o meio da faixa que ela causa (1 a 4) — é o palpite
	-- menos mentiroso pro crachá, que não tem como prever o alvo.
	{ id = 19, name = "Wren", attack = 3, hp = 12, ability = "Ranged",
		attackRange = GameConfig.WREN_RANGE,
		abilities = { "longShot" },
		color = Color3.fromRGB(100, 210, 180),
		sprite = "94273398199775", spriteSize = Vector2.new(382, 412), scale = 1.09 },

	{ id = 20, name = "Morn", attack = 1, hp = 18, ability = nil,
		abilities = { "raiseSkulls", "lanternReturn"},
		color = Color3.fromRGB(90, 160, 150),
		sprite = "106777398591637", spriteSize = Vector2.new(400, 601), scale = 0.84 },

	{ id = 23, name = "Dr. Maluco", attack = 1, hp = 10, ability = nil,
		abilities = { "poisonFlask", "estopim" }, attackSound = "PoisonFlask",
		deathHold = GameConfig.ESTOPIM_DEATH_HOLD,
		color = Color3.fromRGB(120, 190, 110),
		sprite = "125043635721594", spriteSize = Vector2.new(734, 866), scale = 0.99 },

	{ id = 24, name = "Rush", attack = 0, hp = 11, ability = GameConfig.ABILITIES.SPRINT,
		moveRange = GameConfig.RUSH_MOVE_RANGE,
		abilities = { "momentum", "dodge" },
		color = Color3.fromRGB(80, 170, 255),
		sprite = "99684090577497", spriteSize = Vector2.new(400, 400), scale = 1.00 },

	{ id = 25, name = "Volt", attack = 2, hp = 18, ability = nil,
		abilities = { "voltChain" }, attackSound = "VoltAttack",
		color = Color3.fromRGB(120, 200, 255),
		sprite = "78746546330925", spriteSize = Vector2.new(400, 400), scale = 1.00 },

	-- Spyke — o primeiro Agility do elenco. `ability = "Agility"` é tudo o que
	-- separa ele dos outros: o segundo passo depois do golpe sai da ability, não
	-- de nada escrito com o nome dele (ver GameConfig.HasAgility).
	--
	-- 1 de ataque na ficha é de propósito: o que ele soma ao time não é o golpe
	-- dele, é o +1 que ele empresta a QUEM ESTÁ DO LADO — e o Agility é o que
	-- deixa ele bater e ainda escolher, no mesmo turno, de quem vai ficar perto.
	-- Move 2 e alcança 1 como qualquer ficha comum: a mobilidade dele vem do
	-- SEGUNDO passo, não de um passo maior.
	{ id = 26, name = "Spyke", attack = 1, hp = 22, ability = "Agility",
		abilities = { "rallyAura", "vengeance" },
		color = Color3.fromRGB(255, 190, 90),
		sprite = "111811180757505", spriteSize = Vector2.new(400, 400), scale = 1.00 },

	-- Kira — tanque de SUPORTE. O Taunt puxa o foco pra ela, e a Égide escolhe
	-- quem sobrevive ao golpe que ela NÃO conseguiu puxar. 1 de ataque é o preço:
	-- ela não converte turno em dano, converte em turno de outro.
	--
	-- Taunt de ficha, sem uma linha de Taunt própria: ela entra inteira na regra
	-- que já existe (ver MatchQuery.TauntBlocks), inclusive na de vários
	-- provocadores em campo ao mesmo tempo.
	{ id = 27, name = "Kira", attack = 1, hp = 33, ability = "Taunt",
		abilities = { "aegis" },
		color = Color3.fromRGB(240, 205, 120),
		sprite = "86628005150597", spriteSize = Vector2.new(400, 400), scale = 1.00 },
}

-- ===== TAMANHO APARENTE =====
-- `scale` multiplica a moldura do sprite no tabuleiro. 1 = normal, e a maioria
-- do elenco não precisa do campo.
--
-- POR QUE ALGUNS PRECISAM. A moldura tem proporção fixa (5.8 x 8.12 studs) e o
-- ScaleType.Fit encaixa a arte dentro dela sem distorcer — logo, quem tem arte
-- LARGA é limitado pela largura e sobra vazio em cima e embaixo. Medindo a arte
-- de cada asset, a altura desenhada ia de 4.5 (Golem) a 7.8 studs (Ralph): 74%
-- de diferença que ninguém escolheu, que saiu só da proporção do PNG. É por
-- isso que o ajuste é por ficha, e não uma constante global.
--
-- Isto é IRMÃO do spriteSize, não substituto: `scale` decide o tamanho, o
-- spriteSize decide onde ficam os pés. Ampliar um sprite largo sem o segundo
-- amplia junto a faixa vazia embaixo dele — foi o que deixou o Golem no ar.
--
-- Ao trocar a arte de um herói, vale remedir os dois números.

local MINI_GOLEM_SPRITE = "125545602412754"
local MINI_GOLEM_SIZE = Vector2.new(251, 202)
local MINI_GOLEM_SCALE = 0.6

local SKULL_SPRITE = "96246085775941"
local SKULL_SIZE = Vector2.new(418, 504)
local SKULL_SCALE = MINI_GOLEM_SCALE
local SKULL_ATTACK = 1
local SKULL_HP = 1
local SKULL_MOVE = 1
local SKULL_DEATH_SOUND = "SkullBreak"

HeroData.SUMMONS = {
	{ id = 15, name = "Golem", attack = 2, hp = 5, ability = nil,
		abilities = {},
		color = Color3.fromRGB(120, 120, 120),
		sprite = MINI_GOLEM_SPRITE, spriteSize = MINI_GOLEM_SIZE, scale = MINI_GOLEM_SCALE },

	{ id = 16, name = "Golem", attack = 2, hp = 5, ability = nil,
		abilities = {},
		color = Color3.fromRGB(100, 100, 100),
		sprite = MINI_GOLEM_SPRITE, spriteSize = MINI_GOLEM_SIZE, scale = MINI_GOLEM_SCALE },

	{ id = 21, name = "Caveira", attack = SKULL_ATTACK, hp = SKULL_HP, ability = nil,
		abilities = {}, moveRange = SKULL_MOVE, deathSound = SKULL_DEATH_SOUND,
		color = Color3.fromRGB(120, 200, 120),
		sprite = SKULL_SPRITE, spriteSize = SKULL_SIZE, scale = SKULL_SCALE },

	{ id = 22, name = "Caveira", attack = SKULL_ATTACK, hp = SKULL_HP, ability = nil,
		abilities = {}, moveRange = SKULL_MOVE, deathSound = SKULL_DEATH_SOUND,
		color = Color3.fromRGB(105, 180, 105),
		sprite = SKULL_SPRITE, spriteSize = SKULL_SIZE, scale = SKULL_SCALE },
}

local SUMMON_IDS = {}
for _, data in ipairs(HeroData.SUMMONS) do
	SUMMON_IDS[data.id] = true
end

function HeroData.IsSummon(dataId)
	return SUMMON_IDS[dataId] == true
end

function HeroData.IsStarter(data)
	return data ~= nil and data.starter == true
end

HeroData.SKILL_INFO = {
	firstPunch    = { name = "First Punch",    desc = "O primeiro ataque do herói na partida causa +2 de dano." },
	autoDefense   = { name = "Auto Defense",   desc = "Recebe 1 ponto a menos de dano ao sofrer contra-ataques." },
	voltChain     = { name = "Corrente Elétrica", desc = ("Ataques espalham %d de dano entre inimigos e objetos conectados. Todo inimigo atingido recebe 1 Carga Elétrica por %d turnos. Ao acumular %d Cargas, fica Paralisado no próximo turno.")
		:format(GameConfig.VOLT_CHAIN_DAMAGE, GameConfig.VOLT_CHARGE_DURATION, GameConfig.VOLT_CHARGES_TO_PARALYZE) },
	momentum      = { name = "Embalo",         desc = ("Cada casa andada no próprio turno vale +%d de ataque no próximo golpe daquele turno. O bônus é gasto no ataque e não passa para o turno seguinte.")
		:format(GameConfig.MOMENTUM_PER_HEX) },
	dodge         = { name = "Reflexo Supersônico", desc = ("Ao ser alvo de um ataque, escapa 1 casa e evita o golpe por completo — mas só para um vizinho livre que o deixe a %d casas ou mais do atacante. Sem essa saída, leva o ataque normalmente.")
		:format(GameConfig.DODGE_MIN_DISTANCE) },
	poisonAttack  = { name = "Poison Attack",  desc = "Envenena o inimigo por 3 turnos." },
	poisonFlask   = { name = "Frasco de Veneno", desc = ("Golpe simples que envenena por %d turnos. Não causa dano extra em quem já está envenenado.")
		:format(GameConfig.POISON_DURATION) },
	goodLuck      = { name = "Good Luck",      desc = ("Tem %d%% de chance de ganhar +1 de ataque e recuperar %d de vida ao mudar o turno.")
		:format(GameConfig.GOOD_LUCK_CHANCE * 100, GameConfig.GOOD_LUCK_HEAL) },
	beyondFront   = { name = "Beyond Front",   desc = "Ataca em linha reta na direção do ataque, atingindo inimigos enfileirados." },
	brokenDefense = { name = "Broken Defense", desc = "Causa +1 de dano contra inimigos com Taunt." },
	trustInTeam   = { name = "Trust in Team",  desc = "Recebe +1 de ataque ao ter aliados em casas adjacentes." },
	absorbRoots   = { name = "Absorb Roots",   desc = "Recupera vida equivalente ao dano causado." },
	aloneIsBetter = { name = "Alone is Better",desc = "Causa o dobro de dano ao atacar um inimigo isolado." },
	health        = { name = "Health",         desc = "Cura aliados próximos em +2 no fim do turno." },
	clean         = { name = "Clean",          desc = "Remove os efeitos negativos de aliados próximos." },
	rage          = { name = "Rage",           desc = ("Move o inimigo uma casa para trás. Se bloqueado, causa +%d de dano.")
		:format(GameConfig.RAGE_BLOCKED_BONUS) },
	iceEffect     = { name = "Efeito de Gelo", desc = "Cada ataque congela o alvo: ele passa a andar só uma casa, mesmo com Sprint. Atacar quem já está congelado causa o dobro de dano." },
	iceStorm      = { name = "Tempestade de Gelo", desc = "Ao morrer, congela todos os inimigos a até uma casa de distância." },
	bloodScent    = { name = "Faro de Sangue", desc = "Ganha +1 de ataque cada vez que um herói morre em campo, até no máximo +2." },
	frenzy        = { name = "Frenesi",        desc = ("Ao ficar como último herói vivo do time, cura %d e ganha +%d de ataque e Sprint. Fica imune a efeitos negativos e recupera %d de vida a cada inimigo abatido.")
		:format(GameConfig.MERLIN_FRENZY_HEAL, GameConfig.MERLIN_FRENZY_ATTACK, GameConfig.MERLIN_FRENZY_KILL_HEAL) },
	flamePath     = { name = "Caminho de Chamas", desc = "Deixa fogo nas casas que atravessa e na de origem — só a de destino fica de fora. O fogo dura 2 turnos e causa 2 de dano em quem pisar nele." },
	flameStrike   = { name = "Soco de Chamas",    desc = "O golpe gira: todos os inimigos a uma casa de distância levam o mesmo dano." },
	flameFury     = { name = "Furor das Chamas",  desc = ("Ao pisar numa casa já em chamas (dele mesmo), ganha +%d de ataque por casa por %d turno. Não acumula, e o ataque não passa de %d.")
		:format(GameConfig.FLAME_FURY_ATTACK, GameConfig.FLAME_FURY_DURATION, GameConfig.FLAME_FURY_MAX_ATTACK) },
	stealth       = { name = "Furtividade",  desc = "Fica invisível enquanto nenhum inimigo estiver a menos de 2 casas. Atacar ou levar dano quebra a invisibilidade." },
	stealthHeal   = { name = "Sombra Densa", desc = "Recupera 1 de vida a cada turno enquanto estiver invisível." },
	ambush        = { name = "Emboscada",    desc = ("O ataque que sai da invisibilidade causa +%d de dano e não pode ser revidado, venha ele de onde vier. Revelado, ele volta na hora ao ataque de ficha.")
		:format(GameConfig.AMBUSH_BONUS_DAMAGE) },
	huntInstinct  = { name = "Instinto de Caça", desc = "Ao atingir um inimigo isolado sem abatê-lo, pode se mover de novo. Ao abater o alvo, recupera movimento E ataque, e volta à invisibilidade se não sobrar ninguém ao lado — abates em sequência encadeiam sem limite." },
	shatter       = { name = "Corpo de Pedra", desc = "Ao perder a primeira vida, se parte em dois golens menores: 2 de ataque e 5 de vida cada. Os pedaços não deixam túmulo — o Golem é enterrado uma vez só, quando o último deles cair." },

	-- Kira
	aegis = { name = "Égide", desc = "Uma vez por turno, escolha um aliado COLADO nela (1 casa) e ainda sem escudo: ele fica com um escudo dourado que anula por completo o próximo golpe que receber, seja de 1 ou de 20. O escudo some ao bloquear, dura o tempo que precisar até lá, e ninguém carrega dois — pra proteger, ela precisa estar no mesmo aperto que o protegido." },

	-- Spyke
	rallyAura = { name = "Ponto de Apoio", desc = ("Aliados a uma casa de distância ganham +%d de ataque enquanto estiverem colados nele. O bônus entra e sai na hora em que a adjacência muda.")
		:format(GameConfig.SPYKE_AURA_ATTACK) },
	vengeance  = { name = "Sangue Fervendo", desc = ("Ao atacar, ferve por %d turno: cada aliado colado nele que sofrer dano rende +%d de ataque ao Spyke. Conta CABEÇA atingida, não o tamanho do golpe. O bônus ACUMULA enquanto ele atacar todo turno — passar um turno sem atacar deixa o efeito vencer e devolve tudo de uma vez.")
		:format(GameConfig.SPYKE_VENGEANCE_DURATION, GameConfig.SPYKE_VENGEANCE_ATTACK) },

	-- Lucy
	flameHeal   = { name = "Calor da Família", desc = ("Ao pisar numa casa em chamas (dela ou do Karo), recupera %d de vida por casa.")
		:format(GameConfig.LUCY_FLAME_HEAL) },
	emberShield = { name = "Chama que Protege", desc = "Aliados adjacentes recebem 1 ponto a menos de dano ao serem atacados." },

	-- Zeff
	gustPush = { name = "Rajada", desc = ("Ao atacar, empurra 1 casa para longe do alvo todo aliado do alvo que estiver colado nele, e o próprio alvo 1 casa para trás. Colado sem para onde ir leva %d de dano; alvo sem para onde ir não se move e o golpe causa +%d.")
		:format(GameConfig.GUST_BLOCKED_DAMAGE, GameConfig.ZEFF_PUSH_BLOCKED_BONUS) },
	tailwind = { name = "Vento a Favor", desc = ("Aliados colados em Zeff andam +%d casa. Vale enquanto estiverem ao lado dele — basta o Zeff chegar perto no meio do turno.")
		:format(GameConfig.WIND_BOOST_MOVE_BONUS) },

	-- Wren (nome de trabalho)
	longShot = { name = "Tiro Longo", desc = ("Causa dano igual à distância até o alvo (mínimo 1, máximo %d) em vez do ataque de ficha. Quanto mais perto o alvo, mais fraco o tiro.")
		:format(GameConfig.WREN_RANGE) },

	estopim = { name = "Estopim", desc = ("Ao morrer, causa %d de dano em todos os inimigos a uma casa de distância e envenena por %d turnos quem sobreviver.")
		:format(GameConfig.ESTOPIM_DAMAGE, GameConfig.POISON_DURATION) },

	raiseSkulls = { name = "Chamado da Lanterna", desc = ("Ergue caveiras de %d de ataque e %d de vida ao lado dele, até %d em campo. No início de cada turno dele, repõe as que caíram.")
		:format(SKULL_ATTACK, SKULL_HP, #GameConfig.MORN_SUMMON_IDS) },
	lanternReturn = { name = "Luz que Volta", desc = ("Quando um aliado chega na Casa de Promoção, Morn levanta sozinho com %d de vida — sem gastar a escolha, que continua valendo pra outro herói.")
		:format(GameConfig.RESURRECT_HP) },
}

HeroData.ABILITY_INFO = {
	Sprint = ("Move até %d casas por turno em vez de %d.")
		:format(GameConfig.SPRINT_MOVE_RANGE, GameConfig.BASE_MOVE_RANGE),
	Ranged = ("Ataca a até %d casas de distância.")
		:format(GameConfig.RANGED_ATTACK_RANGE),
	Taunt  = "Inimigos adjacentes só podem atacar este herói.",
	Agility = "O ataque não encerra o movimento: pode andar, atacar e andar de novo no mesmo turno. O ataque continua sendo um só.",
}

function HeroData.GetById(id)
	for _, hero in ipairs(HeroData.CATALOG) do
		if hero.id == id then return hero end
	end
	for _, summon in ipairs(HeroData.SUMMONS) do
		if summon.id == id then return summon end
	end
	return nil
end

function HeroData.GetAttackRange(data)
	if data.attackRange then return data.attackRange end

	return data.ability == GameConfig.ABILITIES.RANGED
		and GameConfig.RANGED_ATTACK_RANGE
		or GameConfig.BASE_ATTACK_RANGE
end

function HeroData.GetAbilityDescription(data)
	if data.ability == GameConfig.ABILITIES.RANGED then
		return ("Ataca a até %d casas de distância."):format(HeroData.GetAttackRange(data))
	end

	local base = HeroData.ABILITY_INFO[data.ability]

	-- Alcance por FORA da ability (Zeff: Sprint + `attackRange` avulso, ver
	-- HeroData.CATALOG) não aparece em lugar nenhum se não somar aqui — a
	-- frase de cima só fala de alcance quando a ability É Ranged.
	local range = HeroData.GetAttackRange(data)
	if range > GameConfig.BASE_ATTACK_RANGE then
		local rangedText = ("Ataca a até %d casas de distância."):format(range)
		return base and (base .. " " .. rangedText) or rangedText
	end

	return base
end

function HeroData.GetMoveRange(data)
	if data.moveRange then return data.moveRange end

	return data.ability == GameConfig.ABILITIES.SPRINT
		and GameConfig.SPRINT_MOVE_RANGE
		or GameConfig.BASE_MOVE_RANGE
end

return HeroData
