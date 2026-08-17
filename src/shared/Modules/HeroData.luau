--[[
	HeroData.lua
	ModuleScript — ReplicatedStorage/Modules/HeroData

	Catálogo de heróis (portado de models/heroes.js) + configuração do
	spritesheet e textos das habilidades. Fica em ReplicatedStorage porque
	tanto o servidor (HeroView) quanto o client (seleção) precisam disso.
]]

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
	{ id = 1, name = "Ralph",   frame = 2, attack = 3, hp = 18, ability = nil,      abilities = { "firstPunch", "autoDefense" }, color = Color3.fromRGB(205, 92, 70) },
	{ id = 2, name = "Vic",     frame = 1, attack = 1, hp = 20, ability = nil,      abilities = { "poisonAttack" },              color = Color3.fromRGB(120, 180, 90) },
	{ id = 3, name = "Mineiro", frame = 0, attack = 1, hp = 18, ability = "Sprint", abilities = { "goodLuck" },                  color = Color3.fromRGB(180, 140, 70), unlock = 2 },
	{ id = 4, name = "Blade",   frame = 4, attack = 3, hp = 16, ability = nil,      abilities = { "beyondFront" },               color = Color3.fromRGB(150, 150, 165), unlock = 2 },
	{ id = 5, name = "Dante",   frame = 5, attack = 2, hp = 18, ability = "Ranged", abilities = { "brokenDefense", "trustInTeam" }, color = Color3.fromRGB(90, 150, 200) },
	{ id = 6, name = "Ceos",    frame = 3, attack = 1, hp = 33, ability = "Taunt",  abilities = { "absorbRoots" },               color = Color3.fromRGB(110, 160, 120) },
	{ id = 7, name = "Noctin",  frame = 8, attack = 3, hp = 14, ability = "Sprint", abilities = { "aloneIsBetter" },             color = Color3.fromRGB(80, 80, 110), unlock = 3 },
	{ id = 8, name = "Elaria",  frame = 7, attack = 1, hp = 19, ability = "Ranged", abilities = { "health", "clean" },           color = Color3.fromRGB(190, 130, 200), unlock = 3 },
	{ id = 9, name = "Bramm",   frame = 6, attack = 2, hp = 26, ability = "Taunt",  abilities = { "rage" },                      color = Color3.fromRGB(160, 110, 60), unlock = 3 },

	-- Kor não tem `frame`: veio depois da folha e mora no próprio asset.
	{
		id = 10, name = "Kor", attack = 1, hp = 23, ability = "Ranged",
		attackRange = 3, -- atira uma casa além do Ranged padrão
		abilities = { "iceEffect", "iceStorm" },
		color = Color3.fromRGB(150, 210, 240),
		sprite = "83205436087529",
		spriteRect = { 210, 143, 562, 787 },
		unlock = 4,
	},

	-- Merlin — o lobo. Também mora no próprio asset.
	--
	-- ATENÇÃO: o spriteRect abaixo é PROVISÓRIO. Ele assume um PNG 1024x1024 com
	-- a arte centralizada e só garante a proporção 165/231 — ou seja, o herói
	-- entra sem distorcer, mas se sobrar margem transparente em volta do desenho
	-- ele vai aparecer menor que os outros no tabuleiro. Pro recorte definitivo,
	-- medir o bounding box dos pixels opacos como explicado no topo do arquivo.
	{
		id = 11, name = "Merlin", attack = 1, hp = 17, ability = nil,
		abilities = { "bloodScent", "frenzy" },
		color = Color3.fromRGB(150, 70, 60),
		sprite = "128910559831968",
		spriteRect = { 146, 0, 731, 1024 },
		unlock = 5,
	},
}

-- ===== LIBERAÇÃO POR NÍVEL =====
-- `unlock` no catálogo é o nível mínimo pra usar o herói; ausente = 1, liberado
-- desde a primeira partida. A tabela fica aqui (ReplicatedStorage) porque os
-- dois lados precisam: o cliente pra escurecer a carta, o servidor pra recusar
-- a escolha. O servidor é a autoridade — o cliente só desenha o cadeado.
--
--   Nível 1  Ralph, Vic, Dante, Ceos
--   Nível 2  Mineiro, Blade
--   Nível 3  Noctin, Elaria, Bramm
--   Nível 4  Kor
--   Nível 5  Merlin

-- Aqui mora só a REGRA. Quem é exceção a ela (dono, testadores, amigos do dono)
-- é decidido no servidor, em ServerScriptService.Modules.DevAccess — não dá pra
-- confiar no cliente pra dizer quem é testador.
function HeroData.GetUnlockLevel(data)
	return (data and data.unlock) or 1
end

function HeroData.IsUnlockedFor(data, level)
	return (tonumber(level) or 1) >= HeroData.GetUnlockLevel(data)
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
}

HeroData.ABILITY_INFO = {
	Sprint = "Move até 3 casas por turno em vez de 2.",
	-- texto genérico da passiva; herói com `attackRange` próprio (o Kor atira a 3)
	-- mostra o número dele na ficha, não aqui
	Ranged = "Ataca a até 2 casas de distância.",
	Taunt  = "Inimigos adjacentes só podem atacar este herói.",
}

function HeroData.GetById(id)
	for _, hero in ipairs(HeroData.CATALOG) do
		if hero.id == id then return hero end
	end
	return nil
end

-- Mesma regra do hero.js: attackRange = ability === 'Ranged' ? 2 : 1.
-- O campo `attackRange` na ficha vence a regra: é como um herói tem alcance
-- próprio (o Kor atira a 3) sem inventar uma passiva nova só pra isso, e sem
-- mexer no alcance de todos os outros que têm Ranged.
function HeroData.GetAttackRange(data)
	if data.attackRange then return data.attackRange end
	return data.ability == "Ranged" and 2 or 1
end

-- Mesma regra do board.js: movimento = ability === 'Sprint' ? 3 : 2
function HeroData.GetMoveRange(data)
	return data.ability == "Sprint" and 3 or 2
end

return HeroData
