local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local HeroChallenges = require(ReplicatedStorage.Modules.HeroChallenges)
local SafeStore = require(ServerScriptService.Modules.Data.SafeStore)

local STORE_NAME = "HeroTactics_Challenges_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local GameAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GameAction")

local ChallengeStore = {}

local records = {}

local function RecordOf(userId)
	return records[userId] or {}
end

local function EmptyRow(heroId)
	local count = HeroChallenges.CountFor(heroId)
	local stars, turns = {}, {}
	for index = 1, count do
		stars[index] = 0
		turns[index] = 0
	end
	return { stars = stars, turns = turns }
end

local function RowOf(record, heroId)
	local row = record[tostring(heroId)]
	if row then return row end
	return EmptyRow(heroId)
end

function ChallengeStore.StarsOf(player, heroId)
	if not player then return {} end
	return RowOf(RecordOf(player.UserId), heroId).stars
end

function ChallengeStore.TurnsOf(player, heroId)
	if not player then return {} end
	return RowOf(RecordOf(player.UserId), heroId).turns
end

function ChallengeStore.MasteredIds(player)
	local mastered = {}
	if not player then return mastered end

	local record = RecordOf(player.UserId)
	for _, heroId in ipairs(HeroChallenges.HeroIds()) do
		if HeroChallenges.IsMastered(RowOf(record, heroId).stars, heroId) then
			table.insert(mastered, heroId)
		end
	end
	return mastered
end

function ChallengeStore.Payload(player)
	local record = RecordOf(player and player.UserId or 0)
	local heroes = {}

	for _, heroId in ipairs(HeroChallenges.HeroIds()) do
		local row = RowOf(record, heroId)
		heroes[tostring(heroId)] = { stars = row.stars, turns = row.turns }
	end

	return { heroes = heroes, mastered = ChallengeStore.MasteredIds(player) }
end

function ChallengeStore.Push(player)
	if not (player and player.Parent) then return end
	GameAction:FireClient(player, "challenges", ChallengeStore.Payload(player))
end

local function Sanitize(value)
	local record = {}
	if type(value) ~= "table" then return record end

	for _, heroId in ipairs(HeroChallenges.HeroIds()) do
		local raw = value[tostring(heroId)]
		if type(raw) == "table" then
			local row = EmptyRow(heroId)
			for index = 1, HeroChallenges.CountFor(heroId) do
				local stars = tonumber((raw.stars or {})[index]) or 0
				local turns = tonumber((raw.turns or {})[index]) or 0
				row.stars[index] = math.clamp(math.floor(stars), 0, HeroChallenges.STARS_PER_CHALLENGE)
				row.turns[index] = math.max(0, math.floor(turns))
			end
			record[tostring(heroId)] = row
		end
	end
	return record
end

local function Load(player)
	local ok, value = SafeStore.Get(store, tostring(player.UserId),
		("leitura dos desafios de %s"):format(player.Name))
	if not ok then value = nil end

	if not player.Parent then return end

	records[player.UserId] = Sanitize(value)
	ChallengeStore.Push(player)
end

function ChallengeStore.Record(player, heroId, index, stars, turns)
	if not player then return 0 end

	local spec = HeroChallenges.Get(heroId, index)
	if not spec then return 0 end

	stars = math.clamp(math.floor(tonumber(stars) or 0), 0, HeroChallenges.STARS_PER_CHALLENGE)
	turns = math.max(0, math.floor(tonumber(turns) or 0))

	local userId = player.UserId
	local key = tostring(heroId)
	local cached = RowOf(RecordOf(userId), heroId)

	local betterStars = stars > (cached.stars[index] or 0)
	local betterTurns = stars > 0 and turns > 0
		and ((cached.turns[index] or 0) == 0 or turns < cached.turns[index])

	if not (betterStars or betterTurns) then return 0 end

	local gained = 0

	local ok, merged = SafeStore.Update(store, tostring(userId), function(old)
		local record = Sanitize(old)
		local row = record[key] or EmptyRow(heroId)

		local previous = row.stars[index] or 0
		gained = math.max(0, stars - previous)
		row.stars[index] = math.max(previous, stars)

		local bestTurns = row.turns[index] or 0
		if stars > 0 and turns > 0 and (bestTurns == 0 or turns < bestTurns) then
			row.turns[index] = turns
		end

		record[key] = row
		return record
	end, ("gravação dos desafios de %s"):format(player.Name))

	if ok and type(merged) == "table" then
		records[userId] = merged
	else
		local record = records[userId] or {}
		cached.stars[index] = math.max(cached.stars[index] or 0, stars)
		if betterTurns then cached.turns[index] = turns end
		record[key] = cached
		records[userId] = record
		gained = 0
		warn(("ChallengeStore: %s fechou %s e o resultado não gravou.")
			:format(player.Name, spec.id))
	end

	ChallengeStore.Push(player)
	return gained
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(Load, player)
end)

Players.PlayerRemoving:Connect(function(player)
	records[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(Load, player)
end

return ChallengeStore
