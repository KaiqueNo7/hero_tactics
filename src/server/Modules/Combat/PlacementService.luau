local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local HeroData = require(ReplicatedStorage.Modules.HeroData)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchRegistry = require(ServerScriptService.Modules.Match.MatchRegistry)
local MatchBroadcast = require(ServerScriptService.Modules.Match.MatchBroadcast)

local PlacementService = {}

local IsFree = MatchQuery.IsFree
local MatchIsLive = MatchRegistry.IsLive
local MatchOfPlayer = MatchRegistry.MatchOfPlayer
local Broadcast = MatchBroadcast.Send

local BeginTurn
local CreateHero

function PlacementService.Bind(deps)
	BeginTurn = deps.BeginTurn
	CreateHero = deps.CreateHero
end

local function AvailableHeroIds(match, side)
	local available = {}
	for _, data in ipairs(HeroData.CATALOG) do
		local unlocked = (side == nil) or side.unlockedIds[data.id]
		if not match.usedHeroIds[data.id] and unlocked then
			table.insert(available, data.id)
		end
	end
	return available
end

local function FreeHexesIn(match, zone)
	local free = {}
	for _, hexId in ipairs(zone) do
		if IsFree(match, hexId) then
			table.insert(free, hexId)
		end
	end
	return free
end

local BOT_DRAFT_WEIGHT = {
	[6] = 10, -- Ceos: tanque que se cura, o mais seguro pra IA
	[8] = 9,  -- Elaria: cura e limpa, segura o time inteiro
	[4] = 8,  -- Blade: dano em linha
	[7] = 7,  -- Noctin: dano alto, corre
	[10] = 6, -- Kor: controle, alcance 3
	[1] = 6,  -- Ralph: dano de abertura
	[9] = 5,  -- Bramm: Taunt que empurra
	[11] = 4, -- Merlin: o kit dele só paga com o time morto, e o bot não joga pra isso
	[5] = 4,  -- Dante
	[2] = 3,  -- Vic: veneno rende a longo prazo, o bot não capitaliza bem
	[3] = 3,  -- Mineiro: depende de sorte
}
local BOT_DRAFT_DEFAULT_WEIGHT = 4

local function BotPickHeroId(available)
	if #available == 0 then return nil end

	local total = 0
	for _, dataId in ipairs(available) do
		total += BOT_DRAFT_WEIGHT[dataId] or BOT_DRAFT_DEFAULT_WEIGHT
	end

	local ticket = math.random() * total
	for _, dataId in ipairs(available) do
		ticket -= BOT_DRAFT_WEIGHT[dataId] or BOT_DRAFT_DEFAULT_WEIGHT
		if ticket <= 0 then return dataId end
	end

	return available[#available]
end

local function BotPickHex(data, zone, free)
	local center = (#zone + 1) / 2

	local function offsetFromCenter(hexId)
		local index = table.find(zone, hexId)
		return index and math.abs(index - center) or 0
	end

	local jitter = {}
	for _, hexId in ipairs(free) do jitter[hexId] = math.random() end

	table.sort(free, function(a, b)
		local da, db = offsetFromCenter(a), offsetFromCenter(b)
		if da == db then return jitter[a] < jitter[b] end
		if data.ability == GameConfig.ABILITIES.RANGED then return da > db end
		return da < db
	end)

	return free[1]
end

local function AllPlaced(match)
	for _, side in ipairs(match.sides) do
		if side.placedCount < GameConfig.HEROES_PER_PLAYER then return false end
	end
	return true
end


function PlacementService.StartClock(match)
	match.placementToken += 1
	match.placementStartedAt = os.clock()

	local token = match.placementToken
	local side = match.sides[match.placementSide]
	if side.isBot or GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return end

	task.delay(GameConfig.PLACEMENT_TIME_LIMIT, function()
		if not (MatchIsLive(match) and match.phase == "placement" and match.placementToken == token) then return end

		Broadcast(match, "⏱ Tempo esgotado!")
		PlacementService.BotPlaceOne(match, true)
	end)
end

function PlacementService.Advance(match)
	if AllPlaced(match) then
		match.phase = "battle"
		BeginTurn(match, match.starterId, 1)
		return
	end

	local nextIndex = (match.placementSide == 1) and 2 or 1
	if match.sides[nextIndex].placedCount >= GameConfig.HEROES_PER_PLAYER then
		nextIndex = match.placementSide
	end
	match.placementSide = nextIndex
	PlacementService.StartClock(match)

	Broadcast(match)

	if match.sides[nextIndex].isBot then
		task.delay(GameConfig.BOT_PLACE_DELAY, function()
			PlacementService.BotPlaceOne(match)
		end)
	end
end

function PlacementService.BotPlaceOne(match, force)
	if not MatchIsLive(match) or match.phase ~= "placement" then return end

	local side = match.sides[match.placementSide]
	if not (side.isBot or force) then return end

	local free = FreeHexesIn(match, side.zone)

	local dataId = side.roster and side.roster[side.placedCount + 1]
	if not dataId then
		local available = AvailableHeroIds(match, side)
		dataId = #available > 0 and BotPickHeroId(available) or nil
	end

	if dataId and #free > 0 then
		local hexId = BotPickHex(HeroData.GetById(dataId), side.zone, free)
		CreateHero(match, dataId, side.id, hexId)
		if not side.roster then match.usedHeroIds[dataId] = true end
		side.placedCount += 1
	end

	PlacementService.Advance(match)
end

function PlacementService.PlaceHero(player, dataId, hexId)
	local match = MatchOfPlayer(player)
	if not match or match.phase ~= "placement" then return end
	if match.suspendedAt then return end

	local side = match.sides[match.placementSide]
	if side.player ~= player then return end
	if side.placedCount >= GameConfig.HEROES_PER_PLAYER then return end
	if type(dataId) ~= "number" or type(hexId) ~= "string" then return end
	if not HeroData.GetById(dataId) then return end
	if match.usedHeroIds[dataId] then return end
	if not side.unlockedIds[dataId] then return end
	if not table.find(side.zone, hexId) then return end
	if not IsFree(match, hexId) then return end

	CreateHero(match, dataId, side.id, hexId)
	match.usedHeroIds[dataId] = true
	side.placedCount += 1

	PlacementService.Advance(match)
end

return PlacementService
