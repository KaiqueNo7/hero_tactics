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
local heroes = require(game.ReplicatedStorage.Modules.HeroData)

local Hero = setmetatable({}, { __index = function(_, name)
	error("Campaign: herói inexistente no HeroData.CATALOG: " .. tostring(name), 2)
end })
for _, data in ipairs(heroes.CATALOG) do Hero[data.name] = data.id end

local Maluco = Hero["Dr. Maluco"]

Campaign.FIGHTS = {
	{ hero = Hero.Vic,     group = 1, team = { Hero.Vic, Hero.Kor, Hero.Merlin }, island = "Clareira" },
	{ hero = Hero.Blade,   group = 1, team = { Hero.Blade, Hero.Karo, Hero.Golem }, island = "Clareira" },
	{ hero = Hero.Mineiro, group = 1, team = { Hero.Mineiro, Hero.Golem, Hero.Blade }, island = "Clareira" },

	{ hero = Hero.Noctin,  group = 2, team = { Hero.Noctin, Hero.Bramm, Hero.Vic }, island = "Dark_Mountain" },
	{ hero = Hero.Bramm,   group = 2, team = { Hero.Noctin, Hero.Bramm, Hero.Ceos }, island = "Dark_Mountain" },
	{ hero = Hero.Elaria,  group = 2, team = { Hero.Elaria, Hero.Ceos, Hero.Ralph }, island = "Dark_Mountain" },

	{ hero = Hero.Kor,     group = 3, team = { Hero.Kor, Hero.Noctin, Hero.Merlin }, island = "Freezy" },
	{ hero = Hero.Merlin,  group = 3, team = { Hero.Merlin, Hero.Kor, Hero.Vic }, island = "Freezy" },
	{ hero = Hero.Zeff,    group = 3, team = { Hero.Zeff, Hero.Noctin, Hero.Nash }, island = "Freezy" },

	{ hero = Hero.Golem,   group = 4, team = { Hero.Mineiro, Hero.Golem, Hero.Elaria }, island = "Forge" },
	{ hero = Hero.Lucy,    group = 4, team = { Hero.Lucy, Hero.Karo, Hero.Zeff }, island = "Forge" },
	{ hero = Hero.Karo,    group = 4, team = { Hero.Karo, Hero.Lucy, Hero.Zeff }, island = "Forge" },

	{ hero = Hero.Nash,    group = 5, team = { Hero.Kor, Hero.Noctin, Hero.Nash }, island = "Desert" },
	{ hero = Hero.Wren,    group = 5, team = { Hero.Wren, Hero.Ceos, Hero.Bramm }, island = "Desert" },

	{ hero = Maluco,       group = 6, team = { Maluco, Hero.Morn, Hero.Vic }, island = "Boske" },
	{ hero = Hero.Morn,    group = 6, team = { Maluco, Hero.Morn, Hero.Vic }, island = "Boske" },
	{ hero = Hero.Rush,    group = 6, team = { Hero.Rush, Maluco, Hero.Nash }, island = "Boske" },
	{ hero = Hero.Volt,    group = 6, team = { Hero.Volt, Hero.Rush, Hero.Ceos }, island = "Boske" },
	{ hero = Hero.Spyke,   group = 6, team = { Hero.Spyke, Hero.Ralph, Hero.Bramm }, island = "Boske" },   -- dois vizinhos que aproveitam o +1 dele, e é o time que ensina a aura
	{ hero = Hero.Kira,    group = 6, team = { Hero.Kira, Hero.Blade, Hero.Elaria }, island = "Boske" },   -- ela puxa o foco e blinda o Blade, que é quem realmente machuca

	{ hero = Hero.Zaro,    group = 7, team = { Hero.Zaro, Hero.Ceos, Hero.Blade }, island = "Temple" },
}

Campaign.PVP_MIN_HEROES = 6
Campaign.PAD_TAG = "FightPad"

function Campaign.GetFight(heroId)
	for _, fight in ipairs(Campaign.FIGHTS) do
		if fight.hero == heroId then return fight end
	end
	return nil
end

local function GroupDone(owned, group)
	for _, fight in ipairs(Campaign.FIGHTS) do
		if fight.group == group and not owned[fight.hero] then return false end
	end
	return true
end

function Campaign.StateOf(owned, fight)
	if owned[fight.hero] then return "done" end
	if fight.group == 1 or GroupDone(owned, fight.group - 1) then return "open" end
	return "locked"
end

function Campaign.NextOpen(owned, skip)
	for _, fight in ipairs(Campaign.FIGHTS) do
		if fight ~= skip and fight.hero ~= (skip and skip.hero)
			and Campaign.StateOf(owned, fight) == "open" then
			return fight
		end
	end
	return nil
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
