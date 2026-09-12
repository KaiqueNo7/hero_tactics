local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MatchLog = {}

local LOG_LIMIT = 400

function MatchLog.Event(match, kind, side, text)
	local log = match.log
	if not log then return end

	table.insert(log, {
		turn = match.turn and match.turn.number or 0,
		kind = kind,
		side = side,
		text = text,
	})

	if #log > LOG_LIMIT then
		table.remove(log, 1)
	end
end

local function RootOf(hero)
	local root = hero
	while root.summoner do root = root.summoner end
	return root
end

MatchLog.RootOf = RootOf

function MatchLog.Tally(hero, key, amount)
	if not (hero and hero.stats) then return end
	local root = RootOf(hero)
	root.stats.special[key] = (root.stats.special[key] or 0) + (amount or 1)
end

local REJECTIONS = {
	NOT_YOUR_TURN = true,
	MOVE_OUT_OF_RANGE = true, ATTACK_OUT_OF_RANGE = true,
	OCCUPIED = true, INVALID_TARGET = true, INVALID_MOVE = true,
}

function MatchLog.Reject(player, reason)
	if not (player and REJECTIONS[reason]) then return end
	local remote = ReplicatedStorage.Remotes:FindFirstChild("GameAction")
	if remote then remote:FireClient(player, "reject", reason) end
end

return MatchLog
