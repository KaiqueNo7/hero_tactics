--[[
	Campaign.lua
	ModuleScript — ReplicatedStorage/Modules/Campaign

	A escada de progressão: quais confrontos contra bot existem, que time cada
	bot leva e o que cada vitória desbloqueia.

	FONTE ÚNICA DE VERDADE: a posse dos heróis, e só ela. Cada confronto premia
	um herói DIFERENTE, então "derrotei o bot X" e "tenho o herói X" são a mesma
	frase — não existe uma segunda lista de bots vencidos pra gravar, sincronizar
	e discordar da primeira. Quem persiste isso é o HeroUnlockService, que já
	gravava a posse antes desta escada existir.

	Daí saem as outras três perguntas, todas derivadas:
	  grupo liberado  -> todos os prêmios do grupo anterior estão na mão
	  confronto feito -> o prêmio dele está na mão
	  PvP liberado    -> #heróis >= PVP_MIN_HEROES (não importa QUAIS)

	Mora em ReplicatedStorage porque é regra de jogo: o lobby desenha os
	quadrados com ela, e o servidor recusa entrada em confronto trancado com a
	MESMA função. Nada de duas cópias da regra.
]]

local Campaign = {}

-- Heróis do elenco inicial (HeroData.CATALOG, `starter = true`): Ralph, Dante e
-- Ceos. São HEROES_PER_PLAYER exatos — o jogador novo monta time completo sem
-- vencer nada.
--
-- `hero` é o prêmio E a identidade do confronto (o quadrado do lobby, o pedido
-- que o cliente manda, a linha do DataStore). `team` é a composição FIXA do
-- bot, na ordem em que ele põe em campo.
Campaign.FIGHTS = {
	{ hero = 2,  group = 1, team = { 2, 10, 11 } },  -- Vic:     Vic, Kor, Merlin
	{ hero = 4,  group = 1, team = { 4, 12, 14 } },  -- Blade:   Blade, Karo, Golem
	{ hero = 3,  group = 1, team = { 3, 14, 4 } },   -- Mineiro: Mineiro, Golem, Blade

	{ hero = 7,  group = 2, team = { 7, 9, 2 } },    -- Noctin:  Noctin, Bramm, Vic
	{ hero = 9,  group = 2, team = { 7, 9, 6 } },    -- Bramm:   Noctin, Bramm, Ceos
	{ hero = 8,  group = 2, team = { 8, 6, 1 } },    -- Elaria:  Elaria, Ceos, Ralph

	{ hero = 10, group = 3, team = { 10, 7, 11 } },  -- Kor:     Kor, Noctin, Merlin
	{ hero = 11, group = 3, team = { 11, 10, 2 } },  -- Merlin:  Merlin, Kor, Vic

	{ hero = 14, group = 4, team = { 3, 14, 8 } },   -- Golem:   Mineiro, Golem, Elaria
	{ hero = 13, group = 4, team = { 10, 7, 13 } },  -- Nash:    Kor, Noctin, Nash
	{ hero = 12, group = 4, team = { 12, 4, 6 } },   -- Karo:    Karo, Blade, Ceos

	{ hero = 17, group = 5, team = { 17, 12, 14 } }, -- Lucy: Lucy, Karo, Golem
	{ hero = 18, group = 5, team = { 18, 7, 13 } },  -- Zeff: Zeff, Noctin, Nash
	{ hero = 19, group = 5, team = { 19, 6, 9 } },   -- Wren: Wren, Ceos, Bramm — dois Taunt na frente, ela atirando de trás; os três confrontos do grupo 5 só abrem com o grupo 4 inteiro na mão
}

-- Quantos heróis abrem o PvP. A condição é a CONTAGEM, não a lista: seis
-- quaisquer servem (o caminho normal são os 3 iniciais + os 3 do grupo 1, mas
-- quem já tinha heróis do sistema antigo entra com os que tem).
Campaign.PVP_MIN_HEROES = 6

-- Tag dos quadrados no cenário. O servidor marca as Parts com ela
-- (GameStartTrigger) e o cliente acha todas por ela pra pintar o estado — em
-- vez de os dois lados combinarem um nome de pasta que só existe no place.
Campaign.PAD_TAG = "FightPad"

function Campaign.GetFight(heroId)
	for _, fight in ipairs(Campaign.FIGHTS) do
		if fight.hero == heroId then return fight end
	end
	return nil
end

-- `owned` é conjunto [dataId] = true com TUDO que o jogador tem, iniciais
-- inclusive — do lado do servidor sai do HeroUnlockService.GetPlayableIds, do
-- lado do cliente do catálogo + RosterUpdate. Mesmo formato dos dois lados.
local function GroupDone(owned, group)
	for _, fight in ipairs(Campaign.FIGHTS) do
		if fight.group == group and not owned[fight.hero] then return false end
	end
	return true
end

-- "done" | "open" | "locked". O grupo 1 nasce aberto; cada grupo seguinte espera
-- o anterior INTEIRO — nunca um confronto solto adiantado.
function Campaign.StateOf(owned, fight)
	if owned[fight.hero] then return "done" end
	if fight.group == 1 or GroupDone(owned, fight.group - 1) then return "open" end
	return "locked"
end

function Campaign.CountOwned(owned)
	local total = 0
	for _ in pairs(owned) do total += 1 end
	return total
end

function Campaign.PvpUnlocked(owned)
	return Campaign.CountOwned(owned) >= Campaign.PVP_MIN_HEROES
end

return Campaign
