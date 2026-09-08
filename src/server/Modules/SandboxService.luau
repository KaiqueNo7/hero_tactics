local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local SandboxService = {}

SandboxService.ENABLED = true

if not RunService:IsStudio() then
	function SandboxService.Handle() end
	function SandboxService.Command() end
	function SandboxService.Validate() return {} end

	return SandboxService
end

local Arenas = require(ReplicatedStorage.Modules.Arenas)
local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local HexGrid = require(ReplicatedStorage.Modules.HexGrid)
local BoardSpawner = require(ServerScriptService.Modules.BoardSpawner)
local HeroView = require(ServerScriptService.Modules.HeroView)
local MatchManager = require(ServerScriptService.Modules.MatchManager)

local Internal = MatchManager.Internal
local GameAction = ReplicatedStorage.Remotes:WaitForChild("GameAction")

local CLIENT_COMMANDS = { cam = true, hud = true, cine = true, panel = true }
local NO_MATCH = { open = true, presets = true, scenes = true, rewards = true, help = true, hello = true }
local AUTO_OPEN = { preset = true, scene = true }

local STATUS_TURNS = {
	poison = GameConfig.POISON_DURATION,
	freeze = GameConfig.FREEZE_DURATION,
	paralysis = 1,
	wound = 2,
	charge = 2,
	vengeance = 2,
}

local PRESETS = {
	Zaro_Chain_Kill = {
		"arena Vulcan", "clear",
		"spawn Zaro 1 C4 hp=6",
		"spawn Blade 1 C5", "spawn Elaria 1 D4",
		"kill Blade", "kill Elaria",
		"spawn Vic 2 C3 hp=5", "spawn Wren 2 B2 hp=5", "spawn Volt 2 A4 hp=5",
		"weak Vic C4", "weak Wren B3", "weak Volt B4",
	},
	Bramm_Push_Noctin = {
		"arena Rocky", "clear",
		"spawn Bramm 1 C3", "spawn Noctin 1 D5", "spawn Ceos 1 B3",
		"spawn Vic 2 C4 hp=7", "spawn Kor 2 D4", "spawn Wren 2 D3",
	},
	Blade_Triple_Cut = {
		"arena Florest", "clear",
		"spawn Blade 1 C2", "spawn Ralph 1 B2", "spawn Elaria 1 D2",
		"spawn Vic 2 C3 hp=3", "spawn Wren 2 C4 hp=3", "spawn Volt 2 C5 hp=3",
	},
	Wren_Long_Shot = {
		"arena Desert", "clear",
		"spawn Wren 1 C1", "spawn Ceos 1 B2", "spawn Elaria 1 D2",
		"spawn Volt 2 C5 hp=4", "spawn Kor 2 E4", "spawn Zeff 2 A4",
	},
	Karo_Spin_Three = {
		"arena Vulcan", "clear",
		"spawn Karo 1 C4", "spawn Kira 1 B4", "spawn Elaria 1 B5",
		"spawn Vic 2 C3 hp=2", "spawn Wren 2 D4 hp=2", "spawn Volt 2 C5 hp=2",
	},
	Zeff_Rush_Momentum = {
		"arena Snow", "clear",
		"spawn Zeff 1 C1", "spawn Rush 1 B1", "spawn Ceos 1 D2",
		"spawn Volt 2 C5 hp=4", "spawn Kor 2 D6", "spawn Wren 2 E5",
	},
	Lucy_Karo_Firetrail = {
		"arena Vulcan", "clear",
		"spawn Karo 1 B2", "spawn Lucy 1 C3 hp=8", "spawn Ceos 1 A2",
		"spawn Vic 2 C2 hp=3", "spawn Wren 2 B1", "spawn Volt 2 D2",
	},
	Golem_Shatter = {
		"arena Rocky", "clear",
		"spawn Blade 1 C3", "spawn Elaria 1 B3", "spawn Ceos 1 B4",
		"spawn Golem 2 C4 hp=3", "spawn Kor 2 D6", "spawn Wren 2 E5",
	},
	Vic_Poison_Burst = {
		"arena Florest", "clear",
		"spawn Vic 1 C3", "spawn Ceos 1 B3", "spawn Elaria 1 B4",
		"spawn Wren 2 C4 hp=4", "spawn Kor 2 D6", "spawn Volt 2 E5",
	},
	Maluco_Estopim = {
		"arena Desert", "clear",
		"spawn Blade 1 C3", "spawn Ceos 1 D4", "spawn Elaria 1 A2",
		"spawn Maluco 2 C4 hp=3", "spawn Kor 2 D6", "spawn Wren 2 E5",
	},
	Merlin_Frenzy_Last = {
		"arena Snow", "clear",
		"spawn Merlin 1 C4 hp=8", "spawn Vic 1 C2 hp=1", "spawn Dante 1 B2 hp=1",
		"spawn Ralph 2 C1", "spawn Golem 2 B1", "spawn Wren 2 E3",
	},
	Nash_Ambush = {
		"arena Florest", "clear",
		"spawn Nash 1 C3", "spawn Ceos 1 A3", "spawn Elaria 1 A4",
		"spawn Vic 2 C5 hp=5", "spawn Kor 2 D6", "spawn Wren 2 E5",
		"stealth Nash",
	},
	IceStorm_Showcase = {
		"arena Snow", "clear",
		"spawn Kor 1 C4 hp=3", "spawn Ceos 1 A2", "spawn Elaria 1 B2",
		"spawn Blade 2 C3", "spawn Zaro 2 D4", "spawn Vic 2 C5",
	},
	Victory_Screen_Test = {
		"arena Florest", "clear",
		"spawn Merlin 1 C4 hp=9", "spawn Kira 1 B4", "spawn Nash 1 D4",
		"spawn Vic 2 C2", "kill Vic",
		"finish win",
	},
	Defeat_Screen_Test = {
		"arena Rocky", "clear",
		"spawn Merlin 1 C4", "spawn Golem 2 C2", "spawn Kor 2 D3",
		"kill Merlin",
		"finish loss",
	},
	Zeff_Gust_Test = {
		"arena Snow", "clear",
		"spawn Zeff 1 C3", "spawn Ceos 1 B3", "spawn Elaria 1 B2",
		"spawn Vic 2 C5", "spawn Kor 2 B5", "spawn Wren 2 D5",
	},
	Elaria_Spectre_Test = {
		"arena Rocky", "clear",
		"spawn Elaria 1 C3", "spawn Ralph 1 B3", "spawn Blade 1 B4",
		"spawn Ceos 2 C5", "spawn Bramm 2 B5", "spawn Golem 2 D5",
	},
	Ranged_Fx_Test = {
		"arena Desert", "clear",
		"spawn Wren 1 C1", "spawn Zeff 1 B3", "spawn Elaria 1 D3",
		"spawn Ceos 2 C5", "spawn Bramm 2 B5", "spawn Golem 2 D5",
	},
	Lineup_Forest = {
		"arena Florest", "clear",
		"spawn Ralph 1 A6", "spawn Blade 1 C6", "spawn Merlin 1 E6",
		"spawn Vic 2 A1", "spawn Nash 2 C1", "spawn Kor 2 E1",
	},
	Lineup_Snow = {
		"arena Snow", "clear",
		"spawn Zeff 1 A6", "spawn Wren 1 C6", "spawn Zaro 1 E6",
		"spawn Volt 2 A1", "spawn Spyke 2 C1", "spawn Kira 2 E1",
	},
}

local SCENES = {
	ZaroChainKill = {
		{ 0, "preset Zaro_Chain_Kill" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Zaro 26" },
		{ 1.6, "cam orbit 18 110" },
		{ 0.6, "hit Zaro Vic" },
		{ 2.0, "go Zaro B3" },
		{ 1.2, "hit Zaro Wren" },
		{ 2.0, "go Zaro B4" },
		{ 1.2, "hit Zaro Volt" },
		{ 1.6, "finisher Zaro final" },
	},
	BrammPushNoctin = {
		{ 0, "preset Bramm_Push_Noctin" },
		{ 0.9, "cine on" },
		{ 0.5, "cam pair Bramm Vic 0.8" },
		{ 1.4, "hit Bramm Vic" },
		{ 1.6, "cam focus Noctin 28 0.8" },
		{ 1.2, "hit Noctin Vic" },
		{ 1.4, "finisher Noctin final" },
	},
	BladeTripleCut = {
		{ 0, "preset Blade_Triple_Cut" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Blade 34" },
		{ 1.6, "hit Blade Vic" },
		{ 2.4, "cam orbit 8 60" },
		{ 1.2, "finisher Blade final" },
	},
	WrenLongShot = {
		{ 0, "preset Wren_Long_Shot" },
		{ 0.9, "cine on" },
		{ 0.5, "cam pair Wren Volt 1.2" },
		{ 1.8, "hit Wren Volt" },
		{ 1.6, "finisher Wren final" },
	},
	KaroSpinThree = {
		{ 0, "preset Karo_Spin_Three" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Karo 26" },
		{ 1.6, "hit Karo Vic" },
		{ 2.4, "cam orbit 8 70" },
		{ 1.6, "finisher Karo final" },
	},
	ZeffRushMomentum = {
		{ 0, "preset Zeff_Rush_Momentum" },
		{ 0.9, "cine on" },
		{ 0.5, "cam pair Rush Volt 1.2" },
		{ 1.6, "go Rush B5" },
		{ 1.4, "cam focus Rush 24 0.6" },
		{ 0.8, "hit Rush Volt" },
		{ 1.6, "finisher Rush final" },
	},
	LucyKaroFiretrail = {
		{ 0, "preset Lucy_Karo_Firetrail" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Karo 30" },
		{ 1.2, "go Karo B4" },
		{ 1.6, "cam focus Lucy 26 0.8" },
		{ 1.0, "go Lucy B2" },
		{ 1.8, "go Karo C3" },
		{ 1.4, "hit Karo Vic" },
		{ 1.6, "finisher Karo final" },
	},
	GolemShatter = {
		{ 0, "preset Golem_Shatter" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Golem 28" },
		{ 1.6, "hit Blade Golem" },
		{ 2.6, "cam orbit 10 80" },
	},
	VicPoisonBurst = {
		{ 0, "preset Vic_Poison_Burst" },
		{ 0.9, "cine on" },
		{ 0.5, "cam pair Vic Wren 0.8" },
		{ 1.4, "hit Vic Wren" },
		{ 1.8, "turn 1 2" },
		{ 0.8, "hit Vic Wren" },
		{ 1.6, "finisher Vic final" },
	},
	MalucoEstopim = {
		{ 0, "preset Maluco_Estopim" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Maluco 26" },
		{ 1.6, "hit Blade Maluco" },
		{ 2.6, "cam orbit 10 80" },
	},
	MerlinFrenzyLast = {
		{ 0, "preset Merlin_Frenzy_Last" },
		{ 0.9, "cine on" },
		{ 0.5, "cam focus Merlin 30" },
		{ 1.4, "hit Ralph Vic" },
		{ 1.4, "hit Golem Dante" },
		{ 2.2, "cam focus Merlin 22 0.8" },
		{ 1.4, "cam orbit 10 70" },
	},
	NashAmbush = {
		{ 0, "preset Nash_Ambush" },
		{ 0.9, "cine on" },
		{ 0.6, "cam focus Nash 28" },
		{ 1.4, "go Nash C4" },
		{ 1.2, "hit Nash Vic" },
		{ 1.6, "finisher Nash final" },
	},
	ZeffGust = {
		{ 0, "preset Zeff_Gust_Test" },
		{ 0.9, "cine on" },
		{ 0.5, "cam zoom 58 1" },
		{ 1.6, "hit Zeff Vic" },
		{ 1.6, "cam focus Vic 26 0.8" },
		{ 1.4, "cam orbit 8 60" },
	},
	ElariaSpectre = {
		{ 0, "preset Elaria_Spectre_Test" },
		{ 0.9, "cine on" },
		{ 0.5, "cam pair Elaria Ceos 1" },
		{ 1.6, "hit Elaria Ceos" },
		{ 1.8, "turn 1 2" },
		{ 0.8, "hit Elaria Ceos" },
		{ 1.4, "cam orbit 8 50" },
	},
	RangedFxTest = {
		{ 0, "preset Ranged_Fx_Test" },
		{ 0.9, "cine on" },
		{ 0.5, "cam zoom 62 1" },
		{ 1.6, "shot Wren Ceos" },
		{ 1.4, "shot Zeff Bramm" },
		{ 1.4, "shot Elaria Golem" },
		{ 1.6, "shot Wren Ceos" },
		{ 1.2, "shot Zeff Bramm" },
		{ 1.2, "shot Elaria Golem" },
	},
	IceStormShowcase = {
		{ 0, "preset IceStorm_Showcase" },
		{ 0.9, "cine on" },
		{ 0.6, "cam focus Kor 28" },
		{ 1.6, "hit Blade Kor" },
		{ 1.8, "finisher Kor final" },
		{ 3.2, "cam orbit 10 80" },
	},
}


local sessions = {}

local function IsDev(player)
	return SandboxService.ENABLED and player ~= nil
end

local function Send(player, payload)
	if player and player.Parent then GameAction:FireClient(player, "sandbox", payload) end
end

local function Log(player, text)
	print("[Sandbox] " .. text)
	Send(player, { log = text })
end

local function PresetNames()
	local names = {}
	for name in pairs(PRESETS) do table.insert(names, name) end
	table.sort(names)
	return names
end

local function SessionOf(player)
	sessions[player] = sessions[player] or { sceneToken = 0 }
	return sessions[player]
end

local function Parse(text)
	local words, named = {}, {}

	for word in string.gmatch(text, "[^%s]+") do
		local key, value = string.match(word, "^([%a_]+)=(.+)$")
		if key then
			named[string.lower(key)] = value
		else
			table.insert(words, word)
		end
	end

	return words, named
end

local function MatchOf(player)
	local match = Internal.MatchOfPlayer(player)
	if match and match.sandbox then return match end
	return nil
end

local function ThemeFrom(token)
	if not token or token == "" or string.lower(token) == "random" then return Arenas.Random() end

	local exact = Arenas.ById(token)
	if exact then return exact end

	local lower = string.lower(token)
	for _, theme in ipairs(Arenas.THEMES) do
		if string.sub(string.lower(theme.id), 1, #lower) == lower then return theme end
	end
	return nil
end

local function DataFrom(token)
	if not token then return nil end

	local id = tonumber(token)
	if id then return HeroData.GetById(id) end

	local lower = string.lower(token)
	for _, data in ipairs(HeroData.CATALOG) do
		if string.lower(data.name) == lower then return data end
	end
	for _, data in ipairs(HeroData.CATALOG) do
		if string.find(string.lower(data.name), lower, 1, true) then return data end
	end
	return nil
end

local function HexFrom(token)
	if not token then return nil end
	local id = string.upper(token)
	return HexGrid.Exists(id) and id or nil
end

local function HeroFrom(match, token)
	if not token then return nil end

	local hex = HexFrom(token)
	if hex and match.occupied[hex] then return match.occupied[hex] end

	local lower = string.lower(token)
	for _, hero in pairs(match.heroes) do
		if string.lower(hero.name) == lower then return hero end
	end
	for _, hero in pairs(match.heroes) do
		if string.find(string.lower(hero.name), lower, 1, true) then return hero end
	end
	return nil
end

local function SideIndex(token)
	return tonumber(token) == 2 and 2 or 1
end

local function FirstFreeHex(match)
	for _, hex in ipairs(HexGrid.GetAllHexes()) do
		if not match.occupied[hex.id] then return hex.id end
	end
	return nil
end

local function SetHp(hero, value)
	hero.currentHp = math.clamp(math.floor(value or hero.maxHp), 0, hero.maxHp)
	HeroView.UpdateStats(hero)
end

local function ApplyStatus(match, hero, statusType, turns, stacks)
	local effect = {
		type = statusType,
		duration = turns or STATUS_TURNS[statusType] or 2,
	}

	if statusType == "charge" then effect.stacks = stacks or 1 end

	if statusType == "shield" then
		effect.permanent = true
		effect.duration = 0
		effect.source = hero
		effect.grantedTurn = match.turn and match.turn.number or 0
	end

	match.skillApi.ApplyStatusEffect(hero, effect)

	if statusType == "shield" then HeroView.SetShieldAura(hero, true) end
end

local function ClaimTurn(match, hero)
	local sideId = match.sides[hero.sideIndex].id

	if not match.turn then
		Internal.BeginTurn(match, sideId, 1)
		return
	end

	if match.turn.ownerId == sideId then return end

	match.turn.ownerId = sideId
	match.turn.attacked[hero.uid] = nil
	match.turn.moved[hero.uid] = nil
end

local function RemoveHero(match, hero)
	if match.occupied[hero.position] == hero then match.occupied[hero.position] = nil end
	HeroView.SetShieldAura(hero, false)
	HeroView.SetFrenzyAura(hero, false)
	HeroView.Destroy(hero)
	match.heroes[hero.uid] = nil
end

local function ClearScene(match)
	HeroView.ClearMatch(match.view)

	if match.turn then
		match.turn.moved = {}
		match.turn.attacked = {}
		match.turn.bonusMove = {}
		match.turn.weakChain = {}
		match.turn.counterAttack = false
	end

	match.heroes = {}
	match.occupied = {}
	match.barrels = {}
	match.flames = {}
	match.usedHeroIds = {}
	match.lastSeen = {}
	match.pendingPromotion = nil
	match.pendingShield = nil
	match.finisher = nil
	match.lastDeath = nil
	match.winner = nil
	match.message = nil
	match.busy = false
	match.phase = "battle"
end

local function SetArena(match, theme)
	match.theme = theme
	match.view.theme = theme

	match.boardFolder = BoardSpawner.SpawnBoard(match.slot, false, nil, theme)
	if match.boardFolder then match.boardFolder:SetAttribute("MatchId", match.id) end
end

local COMMANDS = {}

COMMANDS.open = function(player, _match, words)
	local theme = ThemeFrom(words[1])
	if not theme then
		Log(player, "arena desconhecida: " .. tostring(words[1]))
		return
	end

	local current = Internal.MatchOfPlayer(player)
	if current then Internal.EndMatch(current) end

	if not MatchManager.StartMatch(player, nil, nil, nil, { sandbox = true, theme = theme }) then
		Log(player, "sem arena livre")
		return
	end

	Send(player, { presets = PresetNames() })
	Log(player, "sandbox aberto na arena " .. theme.id)
end

COMMANDS.close = function(player, match)
	SessionOf(player).sceneToken += 1
	Internal.EndMatch(match)
	Send(player, { closed = true })
	Log(player, "sandbox fechado")
end

COMMANDS.arena = function(player, match, words)
	local theme = ThemeFrom(words[1])
	if not theme then
		Log(player, "arena desconhecida: " .. tostring(words[1]))
		return
	end

	SetArena(match, theme)
	Internal.Broadcast(match)
	Log(player, "arena " .. theme.id)
end

COMMANDS.clear = function(player, match)
	ClearScene(match)
	Internal.Broadcast(match)
	Log(player, "cena limpa")
end

COMMANDS.reset = function(player, match)
	SessionOf(player).sceneToken += 1
	ClearScene(match)
	SetArena(match, match.theme)
	Internal.BeginTurn(match, match.sides[1].id, 1)
	Log(player, "cena reiniciada")
end

COMMANDS.spawn = function(player, match, words, named)
	local data = DataFrom(words[1])
	if not data then
		Log(player, "herói desconhecido: " .. tostring(words[1]))
		return
	end

	local sideIndex = SideIndex(words[2])
	local hexId = HexFrom(words[3]) or HexFrom(named.hex) or FirstFreeHex(match)
	if not hexId then
		Log(player, "sem casa livre")
		return
	end

	local ownerId = match.sides[sideIndex].id

	local occupant = match.occupied[hexId]
	if occupant then RemoveHero(match, occupant) end

	for _, existing in pairs(match.heroes) do
		if existing.dataId == data.id and existing.ownerId == ownerId then
			RemoveHero(match, existing)
		end
	end

	local hero = Internal.CreateHero(match, data.id, ownerId, hexId)
	if not hero then
		Log(player, "não consegui criar " .. data.name)
		return
	end

	if named.hp then SetHp(hero, tonumber(named.hp)) end
	if named.dir then hero.weakPoint = tonumber(named.dir) end
	if named.status then ApplyStatus(match, hero, named.status, tonumber(named.turns)) end

	Internal.Broadcast(match)
	Log(player, ("%s (lado %d) em %s"):format(hero.name, sideIndex, hexId))
end

COMMANDS.remove = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then
		Log(player, "não achei: " .. tostring(words[1]))
		return
	end

	RemoveHero(match, hero)
	Internal.Broadcast(match)
	Log(player, hero.name .. " removido")
end

COMMANDS.move = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	local hexId = HexFrom(words[2])
	if not (hero and hexId) then
		Log(player, "uso: move <herói> <casa> [walk]")
		return
	end
	if match.occupied[hexId] and match.occupied[hexId] ~= hero then
		Log(player, "casa ocupada: " .. hexId)
		return
	end

	local walk = words[3] == "walk"
	local path = walk and HexGrid.FindPath(hero.position, hexId, 99, function(id)
		return match.occupied[id] == nil
	end) or nil

	if path then
		match.busy = true
		for step, stepHex in ipairs(path) do
			match.occupied[hero.position] = nil
			hero.position = stepHex
			match.occupied[stepHex] = hero
			HeroView.WalkStep(hero, stepHex, step)
		end
		match.busy = false
	else
		match.occupied[hero.position] = nil
		hero.position = hexId
		match.occupied[hexId] = hero
		HeroView.SetPosition(hero, hexId)
	end

	Internal.Broadcast(match)
	Log(player, ("%s -> %s"):format(hero.name, hexId))
end

COMMANDS.hp = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	SetHp(hero, tonumber(words[2]))
	Internal.Broadcast(match)
	Log(player, ("%s com %d/%d"):format(hero.name, hero.currentHp, hero.maxHp))
end

COMMANDS.dmg = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local source = words[3] and HeroFrom(match, words[3]) or nil
	match.skillApi.ApplyDamage(hero, tonumber(words[2]) or 1, source, false)
	Internal.Broadcast(match)
end

COMMANDS.heal = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	match.skillApi.Heal(hero, tonumber(words[2]) or 1, hero)
	Internal.Broadcast(match)
end

COMMANDS.kill = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local killer = words[2] and HeroFrom(match, words[2]) or nil
	Internal.KillHero(match, hero, killer)
	Internal.Broadcast(match)
end

COMMANDS.revive = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local hexId = HexFrom(words[3]) or hero.position
	if match.occupied[hexId] then
		Log(player, "casa ocupada: " .. hexId)
		return
	end

	local fresh = Internal.CreateHero(match, hero.dataId, hero.ownerId, hexId)
	if fresh and words[2] then SetHp(fresh, tonumber(words[2])) end

	Internal.Broadcast(match)
	Log(player, hero.name .. " de volta")
end

COMMANDS.status = function(player, match, words, named)
	local hero = HeroFrom(match, words[1])
	if not (hero and words[2]) then
		Log(player, "uso: status <herói> <poison|freeze|paralysis|wound|charge|shield> [turnos]")
		return
	end

	ApplyStatus(match, hero, string.lower(words[2]), tonumber(words[3]), tonumber(named.stacks))
	Internal.Broadcast(match)
end

COMMANDS.unstatus = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local kind = words[2] and string.lower(words[2]) or "all"

	if kind == "all" then
		match.skillApi.ClearStatusEffects(hero)
		HeroView.SetShieldAura(hero, false)
	else
		match.skillApi.RemoveStatusEffect(hero, kind)
		if kind == "shield" then HeroView.SetShieldAura(hero, false) end
	end

	Internal.Broadcast(match)
end

COMMANDS.stealth = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local on = words[2] ~= "off"
	hero.stealth = on
	HeroView.PlaySkillEffect(hero, on and "stealth" or "stealthBreak")
	HeroView.PlaySkillSound("stealth", match.view)
	Internal.Broadcast(match)
end

COMMANDS.frenzy = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local on = words[2] ~= "off"
	hero.frenzyActive = on
	HeroView.SetFrenzyAura(hero, on)
	Internal.Broadcast(match)
end

COMMANDS.shield = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	if words[2] == "off" then
		match.skillApi.RemoveStatusEffect(hero, "shield")
		HeroView.SetShieldAura(hero, false)
	else
		ApplyStatus(match, hero, "shield")
		HeroView.PlaySkillEffect(hero, "aegis")
	end

	Internal.Broadcast(match)
end

COMMANDS.weak = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local direction = tonumber(words[2])

	if words[2] == "off" then
		hero.weakPoint = nil
	elseif direction then
		hero.weakPoint = math.clamp(direction, 1, HexGrid.DIRECTION_COUNT)
	else
		local other = HeroFrom(match, words[2])
		local hexId = (other and other.position) or HexFrom(words[2])
		local facing = hexId and HexGrid.DirectionBetween(hero.position, hexId)

		if not facing then
			Log(player, "uso: weak <herói> <1-6|herói vizinho|casa vizinha>")
			return
		end

		hero.weakPoint = facing
	end

	Internal.Broadcast(match)
end

COMMANDS.attack = function(player, match, words)
	local attacker = HeroFrom(match, words[1])
	local target = HeroFrom(match, words[2])
	if not (attacker and target) then
		Log(player, "uso: attack <herói> <alvo>")
		return
	end

	Internal.PerformAttack(match, attacker, target, false)
	Internal.Broadcast(match)
end

COMMANDS.hit = function(player, match, words)
	local attacker = HeroFrom(match, words[1])
	local target = HeroFrom(match, words[2])
	if not (attacker and target) then
		Log(player, "uso: hit <herói> <alvo>")
		return
	end

	ClaimTurn(match, attacker)
	MatchManager.AttackHero(match.sides[attacker.sideIndex].player, attacker.uid, target.uid, match)
end

COMMANDS.go = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	local hexId = HexFrom(words[2])
	if not (hero and hexId) then
		Log(player, "uso: go <herói> <casa>")
		return
	end

	ClaimTurn(match, hero)
	MatchManager.MoveHero(match.sides[hero.sideIndex].player, hero.uid, hexId, match)
end

COMMANDS.skill = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not (hero and words[2]) then
		Log(player, "uso: skill <herói> <onAttack|onTurnStart|onDamage|...> [alvo]")
		return
	end

	local target = words[3] and HeroFrom(match, words[3]) or nil
	Internal.TriggerSkills(match, hero, words[2], target, false, {})
	Internal.Broadcast(match)
end

COMMANDS.fx = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	if not (hero and words[2]) then
		Log(player, "uso: fx <herói> <chave>")
		return
	end

	HeroView.PlaySkillEffect(hero, words[2])
	HeroView.PlaySkillSound(words[2], match.view)
end

COMMANDS.shot = function(player, match, words)
	local attacker = HeroFrom(match, words[1])
	local target = HeroFrom(match, words[2])
	if not (attacker and target) then
		Log(player, "uso: shot <herói> <alvo>")
		return
	end

	HeroView.ShowRangedAttack(attacker, target)
end

COMMANDS.anim = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	HeroView.PlayAnimation(hero, words[2] or "attack")
end

COMMANDS.say = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	HeroView.Say(hero, table.concat(words, " ", 2), "buff")
end

COMMANDS.icestorm = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	match.skillApi.IceStorm(hero)
	Internal.Broadcast(match)
end

COMMANDS.poisonbomb = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	match.skillApi.PoisonBomb(hero)
	Internal.Broadcast(match)
end

COMMANDS.firecircle = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	match.skillApi.FireCircle(hero)
	Internal.Broadcast(match)
end

COMMANDS.flame = function(_player, match, words)
	local hexId = HexFrom(words[1])
	if not hexId then return end

	local sideIndex = SideIndex(words[2])
	match.flames[hexId] = {
		ownerId = match.sides[sideIndex].id,
		duration = GameConfig.FLAME_DURATION,
		appliedTurnToken = match.turnToken,
	}
	HeroView.CreateFlame(match.view, hexId, sideIndex)
	Internal.Broadcast(match)
end

COMMANDS.summon = function(player, match, words)
	local hero = HeroFrom(match, words[1])
	local data = DataFrom(words[2])
	if not (hero and data) then
		Log(player, "uso: summon <herói> <invocação>")
		return
	end

	match.skillApi.Summon(hero, data.id)
	Internal.Broadcast(match)
end

COMMANDS.turn = function(_player, match, words)
	local sideIndex = SideIndex(words[1])
	local number = tonumber(words[2]) or (match.turn and match.turn.number or 1)

	Internal.BeginTurn(match, match.sides[sideIndex].id, number)
end

COMMANDS.finisher = function(_player, match, words)
	local hero = HeroFrom(match, words[1])
	if not hero then return end

	local victim = words[2] and HeroFrom(match, words[2]) or nil

	match.finisher = {
		dataId = hero.dataId,
		name = hero.name,
		victim = victim and victim.name or hero.name,
		ownerId = hero.ownerId,
		sideIndex = hero.sideIndex,
		hex = hero.position,
		final = table.find(words, "final") ~= nil,
	}

	Internal.Broadcast(match)
end

COMMANDS.finish = function(player, match, words)
	local result = string.lower(words[1] or "win")

	match.phase = "finished"
	if result == "draw" then
		match.winner = "draw"
	elseif result == "loss" or result == "lose" then
		match.winner = match.sides[2].id
	else
		match.winner = match.sides[1].id
	end

	Internal.Broadcast(match)
	Log(player, "tela final: " .. result)
end

COMMANDS.rewards = function(player, _match, _words, named)
	local heroes = {}
	local data = named.hero and DataFrom(named.hero)
	if data then table.insert(heroes, data.id) end

	GameAction:FireClient(player, "rewards", {
		heroes = heroes,
		xp = tonumber(named.xp) or 0,
		coins = tonumber(named.coins) or 0,
		xpTotal = tonumber(named.xptotal) or tonumber(named.xp) or 0,
		coinsTotal = tonumber(named.coinstotal) or tonumber(named.coins) or 0,
	})

	Log(player, "recompensa de teste enviada (nada foi gravado)")
end

COMMANDS.preset = function(player, _match, words, _named)
	local name = words[1]
	local steps = name and PRESETS[name]

	if not steps then
		for key in pairs(PRESETS) do
			if string.lower(key) == string.lower(name or "") then steps = PRESETS[key] end
		end
	end

	if not steps then
		Log(player, "preset desconhecido: " .. tostring(name))
		return
	end

	for _, line in ipairs(steps) do
		SandboxService.Command(player, line)
	end

	Log(player, "preset " .. name)
end

COMMANDS.dump = function(player, match)
	local lines = { ("arena %s"):format(match.theme and match.theme.id or "Florest"), "clear" }

	local ordered = {}
	for _, hero in pairs(match.heroes) do table.insert(ordered, hero) end
	table.sort(ordered, function(a, b)
		if a.sideIndex ~= b.sideIndex then return a.sideIndex < b.sideIndex end
		return a.position < b.position
	end)

	for _, hero in ipairs(ordered) do
		local line = ("spawn %s %d %s"):format(hero.name, hero.sideIndex, hero.position)
		if hero.currentHp ~= hero.maxHp then line ..= (" hp=%d"):format(hero.currentHp) end
		table.insert(lines, line)

		for _, effect in ipairs(hero.statusEffects) do
			table.insert(lines, ("status %s %s %d"):format(hero.name, effect.type, effect.duration or 0))
		end
		if hero.stealth then table.insert(lines, "stealth " .. hero.name) end
		if hero.frenzyActive then table.insert(lines, "frenzy " .. hero.name) end
		if not hero.isAlive then table.insert(lines, "kill " .. hero.name) end
	end

	for hexId, flame in pairs(match.flames) do
		local side = flame.ownerId == match.sides[1].id and 1 or 2
		table.insert(lines, ("flame %s %d"):format(hexId, side))
	end

	print("[Sandbox] preset:\n\t\t\"" .. table.concat(lines, "\",\n\t\t\"") .. "\",")
	Log(player, ("cena com %d linhas no console (F9 / Output)"):format(#lines))
end

COMMANDS.hello = function(player)
	player:SetAttribute("SandboxCam", true)
	Send(player, { enabled = true, presets = PresetNames() })
end

COMMANDS.presets = function(player)
	local names = PresetNames()

	Send(player, { presets = names })
	Log(player, "presets: " .. table.concat(names, ", "))
end

COMMANDS.scene = function(player, _match, words, named)
	local steps = words[1] and SCENES[words[1]]
	if not steps then
		Log(player, "cena desconhecida: " .. tostring(words[1]))
		return
	end

	local speed = math.clamp(tonumber(named.speed) or 1, 0.1, 5)
	local session = SessionOf(player)
	session.sceneToken += 1
	local token = session.sceneToken

	task.spawn(function()
		for _, step in ipairs(steps) do
			if session.sceneToken ~= token then return end
			if step[1] > 0 then task.wait(step[1] / speed) end
			if session.sceneToken ~= token then return end
			SandboxService.Command(player, step[2])
		end
	end)

	Log(player, "cena " .. words[1])
end

COMMANDS.scenes = function(player)
	local names = {}
	for name in pairs(SCENES) do table.insert(names, name) end
	table.sort(names)

	Log(player, "cenas: " .. table.concat(names, ", "))
end

COMMANDS.stop = function(player)
	SessionOf(player).sceneToken += 1
	Log(player, "cena interrompida")
end

COMMANDS.help = function(player)
	Log(player, "open [arena] | close | arena <id> | clear | reset")
	Log(player, "spawn <herói> [lado] [casa] hp= dir= status= | remove")
	Log(player, "go <h> <casa> = movimento com as regras | move <h> <casa> [walk] = forçado")
	Log(player, "hp | dmg | heal | kill | revive | status | unstatus | stealth | frenzy | shield")
	Log(player, "weak <h> <1-6|herói vizinho|casa vizinha> = vira a abertura pra alguém")
	Log(player, "hit <h> <alvo> = ataque com as regras | attack = forçado, sem contra-ataque")
	Log(player, "skill <h> <trigger> [alvo] | shot <h> <alvo> = so o tiro visual | fx | anim | say | icestorm | poisonbomb | firecircle | flame | summon")
	Log(player, "turn <lado> | finisher <h> [final] | finish win|loss|draw | rewards xp= coins= hero=")
	Log(player, "preset <nome> | presets | dump | scene <nome> [speed=] | scenes | stop")
	Log(player, "cliente: hud on|off | cine on|off|slowmo on|off | cam mark|go|fly|focus|orbit|reset | panel")
end

function SandboxService.Command(player, text)
	if not IsDev(player) then return end
	if type(text) ~= "string" or text == "" then return end

	local words, named = Parse(text)
	local name = string.lower(table.remove(words, 1) or "")
	if name == "" then return end

	if CLIENT_COMMANDS[name] then
		Send(player, { forward = text })
		return
	end

	local handler = COMMANDS[name]
	if not handler then
		Log(player, "comando desconhecido: " .. name)
		return
	end

	local match = MatchOf(player)

	if not match and AUTO_OPEN[name] then
		COMMANDS.open(player, nil, {})
		match = MatchOf(player)
	end

	if not (match or NO_MATCH[name]) then
		Log(player, "sandbox fechado — use: open [arena]")
		return
	end

	local ok, err = pcall(handler, player, match, words, named)
	if not ok then Log(player, "erro em '" .. name .. "': " .. tostring(err)) end
end

function SandboxService.Handle(player, text)
	SandboxService.Command(player, text)
end

local function Announce(player)
	if not IsDev(player) then return end
	player:SetAttribute("SandboxCam", true)
	Send(player, { enabled = true })
end

Players.PlayerAdded:Connect(function(player)
	task.delay(2, Announce, player)
end)

Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Announce, player)
end

local function Validate()
	if #HexGrid.GetAllHexes() == 0 then HexGrid.Generate() end

	local problems = {}

	local function CheckLine(source, line)
		local words, named = Parse(line)
		local name = string.lower(table.remove(words, 1) or "")

		if not (COMMANDS[name] or CLIENT_COMMANDS[name]) then
			table.insert(problems, ("%s: comando '%s'"):format(source, name))
			return
		end

		if name == "spawn" and not DataFrom(words[1]) then
			table.insert(problems, ("%s: herói '%s'"):format(source, tostring(words[1])))
		end
		if name == "spawn" and words[3] and not HexFrom(words[3]) then
			table.insert(problems, ("%s: casa '%s'"):format(source, words[3]))
		end
		if (name == "move" or name == "go" or name == "flame") and not HexFrom(words[name == "flame" and 1 or 2]) then
			table.insert(problems, ("%s: casa de %s"):format(source, name))
		end
		if (name == "arena" or name == "open") and words[1] and not ThemeFrom(words[1]) then
			table.insert(problems, ("%s: arena '%s'"):format(source, words[1]))
		end
		if name == "preset" and not PRESETS[words[1] or ""] then
			table.insert(problems, ("%s: preset '%s'"):format(source, tostring(words[1])))
		end
		if named.hp and not tonumber(named.hp) then
			table.insert(problems, ("%s: hp '%s'"):format(source, named.hp))
		end
	end

	for name, lines in pairs(PRESETS) do
		for _, line in ipairs(lines) do CheckLine(name, line) end
	end
	for name, steps in pairs(SCENES) do
		for _, step in ipairs(steps) do CheckLine(name, step[2]) end
	end

	for _, problem in ipairs(problems) do
		warn("SandboxService: " .. problem)
	end

	return problems
end

SandboxService.Validate = Validate

Validate()

return SandboxService
