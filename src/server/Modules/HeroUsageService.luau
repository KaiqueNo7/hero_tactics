local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

local SafeStore = require(ServerScriptService.Modules.SafeStore)

local STORE_NAME = "HeroTactics_HeroUsage_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local CACHE_SECONDS = 300

local HeroUsageService = {}

local cache = {}

function HeroUsageService.AddMatch(userId, dataIds)
	if type(userId) ~= "number" or type(dataIds) ~= "table" or #dataIds == 0 then return end

	cache[userId] = nil

	SafeStore.Update(store, tostring(userId), function(old)
		local counts = old or {}
		for _, dataId in ipairs(dataIds) do
			local key = tostring(dataId)
			counts[key] = (counts[key] or 0) + 1
		end
		return counts
	end, "HeroUsage:" .. userId)
end

function HeroUsageService.GetTop(userId, count)
	if type(userId) ~= "number" then return {} end

	local cached = cache[userId]
	if cached and (os.clock() - cached.at) < CACHE_SECONDS then
		return cached.list
	end

	local ok, data = SafeStore.Get(store, tostring(userId), "HeroUsage:" .. userId)
	local list = {}

	if ok and type(data) == "table" then
		for key, matches in pairs(data) do
			local dataId = tonumber(key)
			if dataId and type(matches) == "number" then
				table.insert(list, { dataId = dataId, matches = matches })
			end
		end

		table.sort(list, function(a, b)
			if a.matches ~= b.matches then return a.matches > b.matches end
			return a.dataId < b.dataId
		end)
	end

	cache[userId] = { at = os.clock(), list = list }

	local top = {}
	for index = 1, math.min(count or 3, #list) do
		table.insert(top, list[index])
	end
	return top
end

return HeroUsageService
