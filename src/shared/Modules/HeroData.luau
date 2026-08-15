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

-- O Roblox exige o prefixo rbxassetid:// — número solto não carrega
function HeroData.GetSpriteId()
	local digits = HeroData.SPRITE_SHEET:gsub("%D", "")
	if digits == "" or digits == "0" then return nil end
	return "rbxassetid://" .. digits
end

function HeroData.GetFrameSize()
	return Vector2.new(HeroData.FRAME_WIDTH, HeroData.FRAME_HEIGHT)
end

function HeroData.GetFrameOffset(data)
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
	{ id = 3, name = "Mineiro", frame = 0, attack = 1, hp = 18, ability = "Sprint", abilities = { "goodLuck" },                  color = Color3.fromRGB(180, 140, 70) },
	{ id = 4, name = "Blade",   frame = 4, attack = 3, hp = 16, ability = nil,      abilities = { "beyondFront" },               color = Color3.fromRGB(150, 150, 165) },
	{ id = 5, name = "Dante",   frame = 5, attack = 2, hp = 18, ability = "Ranged", abilities = { "brokenDefense", "trustInTeam" }, color = Color3.fromRGB(90, 150, 200) },
	{ id = 6, name = "Ceos",    frame = 3, attack = 1, hp = 33, ability = "Taunt",  abilities = { "absorbRoots" },               color = Color3.fromRGB(110, 160, 120) },
	{ id = 7, name = "Noctin",  frame = 8, attack = 3, hp = 14, ability = "Sprint", abilities = { "aloneIsBetter" },             color = Color3.fromRGB(80, 80, 110) },
	{ id = 8, name = "Elaria",  frame = 7, attack = 1, hp = 19, ability = "Ranged", abilities = { "health", "clean" },           color = Color3.fromRGB(190, 130, 200) },
	{ id = 9, name = "Bramm",   frame = 6, attack = 2, hp = 26, ability = "Taunt",  abilities = { "rage" },                      color = Color3.fromRGB(160, 110, 60) },
}

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
}

HeroData.ABILITY_INFO = {
	Sprint = "Move até 3 casas por turno em vez de 2.",
	Ranged = "Ataca a até 2 casas de distância.",
	Taunt  = "Inimigos adjacentes só podem atacar este herói.",
}

function HeroData.GetById(id)
	for _, hero in ipairs(HeroData.CATALOG) do
		if hero.id == id then return hero end
	end
	return nil
end

-- Mesma regra do hero.js: attackRange = ability === 'Ranged' ? 2 : 1
function HeroData.GetAttackRange(data)
	return data.ability == "Ranged" and 2 or 1
end

-- Mesma regra do board.js: movimento = ability === 'Sprint' ? 3 : 2
function HeroData.GetMoveRange(data)
	return data.ability == "Sprint" and 3 or 2
end

return HeroData
