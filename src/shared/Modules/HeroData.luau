--[[
	HeroData.lua
	ModuleScript — ReplicatedStorage/Modules/HeroData

	Catálogo de heróis (portado de models/heroes.js) + configuração do
	spritesheet e textos das habilidades. Fica em ReplicatedStorage porque
	tanto o servidor (HeroView) quanto o client (seleção) precisam disso.
]]

-- Caminho explícito, como todos os outros módulos do projeto fazem. `script.Parent`
-- funcionaria, mas amarra o módulo a estar dentro da pasta Modules — e quebra
-- calado se alguém clonar o HeroData pra outro lugar.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)

local HeroData = {}

-- ===== SPRITESHEET =====
-- Cole só o número do asset (ou a URI completa). Vazio = placeholder colorido.
HeroData.SPRITE_SHEET = "101129276337487"
HeroData.FRAME_WIDTH = 165
HeroData.FRAME_HEIGHT = 231
HeroData.SHEET_COLUMNS = 3 -- largura do PNG dividida por 165

-- ===== SPRITE PRÓPRIO (HERÓIS NOVOS) =====
-- A folha original tem 9 quadros e já está fechada. Herói criado depois vem no
-- próprio asset: `sprite` é o id e `spriteRect` recorta a arte dentro dele.
--
-- O recorte não é frescura: o PNG do Kor é 1024x1024 com o desenho ocupando
-- x 184..816 / y 24..1006 e o resto transparente. Sem recortar, o herói entraria
-- na moldura com a margem vazia junto — apareceria pequeno no tabuleiro e ainda
-- esticado, porque a moldura tem a proporção do quadro da folha (165x231) e o
-- asset é quadrado. O retângulo abaixo é o desenho centralizado e ampliado até a
-- MESMA proporção da folha, então ele entra em todo lugar (tabuleiro, carta do
-- draft, retrato da UI) sem distorcer e no mesmo tamanho aparente dos outros.
--
-- Para um herói novo: pegue a caixa da arte visível (o bounding box dos pixels
-- opacos), centre nela um retângulo de proporção 165/231 e cole aqui.
-- { offsetX, offsetY, largura, altura }

-- O Roblox exige o prefixo rbxassetid:// — número solto não carrega.
-- Sem `data` (ou com herói da folha) devolve a folha compartilhada.
function HeroData.GetSpriteId(data)
	local raw = (data and data.sprite) or HeroData.SPRITE_SHEET
	local digits = tostring(raw):gsub("%D", "")
	if digits == "" or digits == "0" then return nil end
	return "rbxassetid://" .. digits
end

function HeroData.GetFrameSize(data)
	local rect = data and data.spriteRect
	if rect then return Vector2.new(rect[3], rect[4]) end
	return Vector2.new(HeroData.FRAME_WIDTH, HeroData.FRAME_HEIGHT)
end

function HeroData.GetFrameOffset(data)
	local rect = data and data.spriteRect
	if rect then return Vector2.new(rect[1], rect[2]) end
	return Vector2.new(
		(data.frame % HeroData.SHEET_COLUMNS) * HeroData.FRAME_WIDTH,
		math.floor(data.frame / HeroData.SHEET_COLUMNS) * HeroData.FRAME_HEIGHT
	)
end

-- ===== ÍCONE DE VENENO (POR ESTÁGIO DE DURAÇÃO) =====
-- Tira horizontal com 3 células de largura IGUAL (uma por estágio de duração
-- restante, 3 = GameConfig.POISON_DURATION). Frame 1 = acabou de envenenar,
-- frame 3 = último turno do veneno. Recorte por ESCALA (não por pixel), então
-- não precisa saber a resolução exata do PNG — só as 3 células terem a mesma largura.
-- Vazio = sem sprite, usa o fallback de texto (☠).
HeroData.POISON_SHEET = "81879107964596"
HeroData.POISON_FRAME_COUNT = 3

function HeroData.GetPoisonSpriteId()
	local digits = HeroData.POISON_SHEET:gsub("%D", "")
	if digits == "" or digits == "0" then return nil end
	return "rbxassetid://" .. digits
end

-- durationRemaining: 3 = acabou de aplicar, 1 = último turno -> índice 0,1,2 na tira
function HeroData.GetPoisonStageIndex(durationRemaining)
	return math.clamp(HeroData.POISON_FRAME_COUNT - durationRemaining, 0, HeroData.POISON_FRAME_COUNT - 1)
end

-- ===== CATÁLOGO =====
HeroData.CATALOG = {
	{ id = 1, name = "Ralph",   frame = 2, attack = 3, hp = 18, ability = nil,      abilities = { "firstPunch", "autoDefense" }, color = Color3.fromRGB(205, 92, 70), starter = true },
	{ id = 2, name = "Vic",     frame = 1, attack = 1, hp = 21, ability = nil,      abilities = { "poisonAttack" },              color = Color3.fromRGB(120, 180, 90) },
	{ id = 3, name = "Mineiro", frame = 0, attack = 1, hp = 18, ability = "Sprint", abilities = { "goodLuck" },                  color = Color3.fromRGB(180, 140, 70) },
	{ id = 4, name = "Blade",   frame = 4, attack = 3, hp = 16, ability = nil,      abilities = { "beyondFront" },               color = Color3.fromRGB(150, 150, 165) },
	{ id = 5, name = "Dante",   frame = 5, attack = 2, hp = 18, ability = "Ranged", abilities = { "brokenDefense", "trustInTeam" }, color = Color3.fromRGB(90, 150, 200), starter = true },
	{ id = 6, name = "Ceos",    frame = 3, attack = 1, hp = 33, ability = "Taunt",  abilities = { "absorbRoots" },               color = Color3.fromRGB(110, 160, 120), starter = true },
	{ id = 7, name = "Noctin",  frame = 8, attack = 3, hp = 14, ability = "Sprint", abilities = { "aloneIsBetter" },             color = Color3.fromRGB(80, 80, 110) },
	{ id = 8, name = "Elaria",  frame = 7, attack = 1, hp = 20, ability = "Ranged", abilities = { "health", "clean" },           color = Color3.fromRGB(190, 130, 200) },
	{ id = 9, name = "Bramm",   frame = 6, attack = 1, hp = 30, ability = "Taunt",  abilities = { "rage" },                      color = Color3.fromRGB(160, 110, 60) },

	-- Kor não tem `frame`: veio depois da folha e mora no próprio asset.
	{
		id = 10, name = "Kor", attack = 1, hp = 23, ability = "Ranged",
		abilities = { "iceEffect", "iceStorm" },
		color = Color3.fromRGB(150, 210, 240),
		sprite = "83205436087529",
		spriteRect = { 210, 143, 562, 787 },
	},

	-- Merlin — o lobo. Também mora no próprio asset.
	--
	-- spriteRect é a CAIXA REAL da arte (bounding box do canal alfa, medido
	-- pixel a pixel), sem forçar a proporção 165/231 da folha. A moldura do
	-- tabuleiro usa ScaleType.Fit (ver HeroView.Create) especificamente pra
	-- aceitar isso: uma caixa mais larga ou mais alta que a moldura encolhe
	-- mantendo a PRÓPRIA proporção, com uma tira vazia de um lado, em vez de
	-- cortar personagem ou esticar o desenho. Cortar ficha real foi o bug que
	-- apareceu quando esse retângulo era forçado a bater 165/231 na unha.
	{
		id = 11, name = "Merlin", attack = 1, hp = 17, ability = nil,
		abilities = { "bloodScent", "frenzy" },
		color = Color3.fromRGB(150, 70, 60),
		sprite = "135349806753304",
		spriteRect = { 0, 3, 600, 813 },
	},

	-- Karo — fogo e zona de controle.
	{ id = 12, name = "Karo", attack = 2, hp = 19, ability = nil,
		abilities = { "flamePath", "flameStrike", "flameFury" },
		color = Color3.fromRGB(255, 140, 70),
		sprite = "134098189560240",
		spriteRect = { 4, 6, 589, 699 } },

	-- Nash — furtivo, emboscador (era "Shadow"; nome próprio, menos genérico).
	-- Sprint é o que deixa a emboscada viável: sem ele, alcance de ataque 1
	-- obrigaria fechar a distância em dois turnos inteiros antes do primeiro
	-- golpe.
	--
	-- Ataque 2 de ficha é de propósito baixo: o número dele é o de DENTRO da
	-- sombra (2 + AMBUSH_BONUS_DAMAGE = 6). Revelado, ele bate como o herói
	-- mais fraco do elenco — é esse o preço de errar a hora do bote.
	{ id = 13, name = "Nash", attack = 2, hp = 14, ability = "Sprint",
		abilities = { "stealth", "stealthHeal", "ambush" },
		color = Color3.fromRGB(80, 90, 120),
		sprite = "84667645314133",
		spriteRect = { 5, 2, 605, 873 } },

	-- Golem — tank gigante que se parte em DOIS golens menores ao perder a
	-- primeira vida. Taunt é o que faz o "tank" ser tank: sem ele, 40 de vida é
	-- só um saco de pancada que ninguém é OBRIGADO a bater. A exceção de Taunt
	-- contra túmulo já existe de forma genérica (qualquer portador de Taunt,
	-- não só o Golem) em AttackGrave — ver o comentário lá.
	{ id = 14, name = "Golem", attack = 1, hp = 40, ability = "Taunt",
		abilities = { "shatter" },
		color = Color3.fromRGB(140, 140, 140),
		sprite = "120512252753630",
		spriteRect = { 2, 7, 634, 663 } },
}

-- ===== INVOCAÇÕES =====
-- As duas metades que nascem quando o Golem quebra. `id` PRECISA ser distinto
-- (15 e 16): o uid de um herói é matchId_dono_dataId, e dois heróis vivos com
-- o MESMO dataId colidiriam no mesmo slot de match.heroes — um sobrescreveria
-- o outro. `name = "Golem"` nos dois é de propósito: pro jogador continuam
-- sendo o mesmo golem, só que em dois pedaços; o dataId diferente é só
-- contabilidade interna, invisível na UI.
--
-- Ficam FORA do CATALOG de propósito. O catálogo é percorrido pela loja, pelo
-- draft, pela tela de carregamento e pelo desbloqueio — entrando lá, os dois
-- apareceriam à venda como heróis próprios.
--
-- O GetById abaixo procura nas duas tabelas, então tudo que já recebe um
-- dataId (HeroView, MatchManager, o modal da UI) funciona sem saber que essa
-- divisão existe. É só a ESCOLHA que enxerga o catálogo puro.
-- Mesmo sprite pros dois (medido do mesmo jeito que Karo/Nash/Golem acima) —
-- são o mesmo desenho de "golem pequeno", só a cor de fallback muda.
local MINI_GOLEM_SPRITE = "88844199109622"
local MINI_GOLEM_RECT = { 6, 2, 270, 352 }
-- Visivelmente menor que o Golem grande (data.scale, lido em HeroView.Create).
-- 0.6 e não menos: abaixo disso o crachá de ATK/HP (tamanho fixo, não escala)
-- passa a competir demais com o próprio desenho.
local MINI_GOLEM_SCALE = 0.6

HeroData.SUMMONS = {
	{ id = 15, name = "Golem", attack = 2, hp = 5, ability = nil,
		abilities = {},
		color = Color3.fromRGB(120, 120, 120),
		sprite = MINI_GOLEM_SPRITE, spriteRect = MINI_GOLEM_RECT, scale = MINI_GOLEM_SCALE },

	{ id = 16, name = "Golem", attack = 2, hp = 5, ability = nil,
		abilities = {},
		color = Color3.fromRGB(100, 100, 100),
		sprite = MINI_GOLEM_SPRITE, spriteRect = MINI_GOLEM_RECT, scale = MINI_GOLEM_SCALE },
}

-- ===== ELENCO INICIAL =====
-- `starter = true` marca quem o jogador já tem no primeiro login: Ralph, Dante
-- e Ceos. Todo o resto é PRÊMIO DE CONFRONTO — cada um sai da vitória contra o
-- bot correspondente (ver ReplicatedStorage.Modules.Campaign). Nem nível nem
-- moeda liberam herói: quem liberava por nível saiu primeiro, a compra por
-- moedas saiu junto com a escada de bots.
--
-- São exatamente HEROES_PER_PLAYER iniciais: dá pra montar time completo no
-- primeiro confronto, sem sobra. Marcar um a menos aqui trava o jogador novo.
--
-- Isto é só a REGRA. QUEM tem o quê mora no servidor
-- (ServerScriptService.Modules.HeroUnlockService) e nunca vem do cliente.
-- Exceções à regra (dono, testadores) continuam em Modules.DevAccess.
function HeroData.IsStarter(data)
	return data ~= nil and data.starter == true
end

-- ===== HABILIDADES (textos vindos de lang/pt.json) =====
HeroData.SKILL_INFO = {
	firstPunch    = { name = "First Punch",    desc = "O primeiro ataque do herói na partida causa +2 de dano." },
	autoDefense   = { name = "Auto Defense",   desc = "Recebe 1 ponto a menos de dano ao sofrer contra-ataques." },
	poisonAttack  = { name = "Poison Attack",  desc = "Envenena o inimigo por 3 turnos." },
	goodLuck      = { name = "Good Luck",      desc = "Tem 50% de chance de ganhar +1 de ataque ao mudar o turno." },
	beyondFront   = { name = "Beyond Front",   desc = "Ataca em linha reta na direção do ataque, atingindo inimigos enfileirados." },
	brokenDefense = { name = "Broken Defense", desc = "Causa +1 de dano contra inimigos com Taunt." },
	trustInTeam   = { name = "Trust in Team",  desc = "Recebe +1 de ataque ao ter aliados em casas adjacentes." },
	absorbRoots   = { name = "Absorb Roots",   desc = "Recupera vida equivalente ao dano causado." },
	aloneIsBetter = { name = "Alone is Better",desc = "Causa o dobro de dano ao atacar um inimigo isolado." },
	health        = { name = "Health",         desc = "Cura aliados próximos em +2 no fim do turno." },
	clean         = { name = "Clean",          desc = "Remove os efeitos negativos de aliados próximos." },
	rage          = { name = "Rage",           desc = "Move o inimigo uma casa para trás. Se bloqueado, causa +1 de dano." },
	iceEffect     = { name = "Efeito de Gelo", desc = "Cada ataque congela o alvo: ele passa a andar só uma casa, mesmo com Sprint. Atacar quem já está congelado causa o dobro de dano." },
	iceStorm      = { name = "Tempestade de Gelo", desc = "Ao morrer, congela todos os inimigos a até uma casa de distância." },
	bloodScent    = { name = "Faro de Sangue", desc = "Ganha +1 de ataque cada vez que um herói morre em campo, até no máximo +2." },
	frenzy        = { name = "Frenesi",        desc = "Ao ficar como último herói vivo do time, cura 4 e ganha +2 de ataque e Sprint. Durante o Frenesi, recupera 2 de vida a cada inimigo abatido." },

	-- Karo
	flamePath     = { name = "Caminho de Chamas", desc = "Deixa fogo nas casas que atravessa — a de origem e a de destino ficam de fora. O fogo dura 2 turnos e causa 2 de dano em quem pisar nele." },
	flameStrike   = { name = "Soco de Chamas",    desc = "O golpe gira: todos os inimigos a uma casa de distância levam o mesmo dano." },
	flameFury     = { name = "Furor das Chamas",  desc = "Ao pisar numa casa já em chamas (dele mesmo), ganha +1 de ataque por casa por 1 turno. Não acumula, e o ataque não passa de 4." },

	-- Shadow
	stealth       = { name = "Furtividade",  desc = "Fica invisível enquanto nenhum inimigo estiver a menos de 2 casas. Atacar ou levar dano quebra a invisibilidade." },
	stealthHeal   = { name = "Sombra Densa", desc = "Recupera 1 de vida a cada turno enquanto estiver invisível." },
	-- Número vindo do GameConfig, não escrito à mão: esta frase aparece na
	-- ficha do herói e no modal da batalha, e já ficou mentindo antes quando um
	-- valor mudou sem ninguém lembrar de reescrever o texto.
	ambush        = { name = "Emboscada",    desc = ("O ataque que sai da invisibilidade causa +%d de dano e não pode ser revidado, venha ele de onde vier. Revelado, ele volta na hora ao ataque de ficha.")
		:format(GameConfig.AMBUSH_BONUS_DAMAGE) },

	-- Golem
	shatter       = { name = "Corpo de Pedra", desc = "Ao perder a primeira vida, se parte em dois golens menores: 2 de ataque e 5 de vida cada. Os pedaços não deixam túmulo — o Golem é enterrado uma vez só, quando o último deles cair." },
}

-- Os números saem do GameConfig, não escritos à mão: este texto aparece na
-- ficha do herói e no modal da batalha, e já ficou mentindo quando o alcance
-- mudou de valor sem ninguém lembrar de reescrever a frase.
HeroData.ABILITY_INFO = {
	Sprint = ("Move até %d casas por turno em vez de %d.")
		:format(GameConfig.SPRINT_MOVE_RANGE, GameConfig.BASE_MOVE_RANGE),
	Ranged = ("Ataca a até %d casas de distância.")
		:format(GameConfig.RANGED_ATTACK_RANGE),
	Taunt  = "Inimigos adjacentes só podem atacar este herói.",
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

-- A passiva decide o alcance, e os valores moram no GameConfig — nenhum número
-- solto aqui. Mexer no alcance do Ranged é editar UMA linha lá, e a ficha do
-- herói, o texto das regras no lobby e a IA do bot acompanham sozinhos.
--
-- O campo `attackRange` na ficha ainda vence a regra: é a saída pra um herói ter
-- alcance próprio sem inventar uma passiva nova só pra isso. Hoje ninguém usa —
-- o Kor usou enquanto atirava mais longe que os outros Ranged, e voltou pro
-- padrão quando o padrão virou 3.
function HeroData.GetAttackRange(data)
	if data.attackRange then return data.attackRange end

	return data.ability == GameConfig.ABILITIES.RANGED
		and GameConfig.RANGED_ATTACK_RANGE
		or GameConfig.BASE_ATTACK_RANGE
end

-- Mesma ideia do alcance de ataque: a passiva escolhe, o GameConfig guarda.
function HeroData.GetMoveRange(data)
	return data.ability == GameConfig.ABILITIES.SPRINT
		and GameConfig.SPRINT_MOVE_RANGE
		or GameConfig.BASE_MOVE_RANGE
end

return HeroData
