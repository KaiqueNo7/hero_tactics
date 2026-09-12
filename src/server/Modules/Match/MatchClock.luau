local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Modules.GameConfig)
local MatchQuery = require(script.Parent.MatchQuery)

local MatchClock = {}

-- O relógio do turno é POR PARTIDA. Era uma constante global lida em cinco
-- lugares, e com isso o casual e a ranqueada não podiam ter ritmos diferentes.
-- O valor mora no `rules`, que já carrega o resto do que muda de modo pra modo
-- (draft, promoção, morte súbita, quem resolve o fim).
function MatchClock.TurnLimit(match)
	return (match.rules and match.rules.turnSeconds) or GameConfig.TURN_TIME_LIMIT
end

function MatchClock.TurnIsTimed(match)
	if MatchClock.TurnLimit(match) <= 0 or not match.turn then return false end
	if not match.vsBot then return true end

	local side = MatchQuery.SideOf(match, match.turn.ownerId)
	return side ~= nil and side.isBot
end

function MatchClock.TurnSecondsLeft(match)
	if not MatchClock.TurnIsTimed(match) then return nil end
	if match.turn.pausedLeft then return match.turn.pausedLeft end

	local elapsed = os.clock() - match.turn.startedAt
	return math.max(0, math.floor(MatchClock.TurnLimit(match) - elapsed))
end

function MatchClock.ReconnectSecondsLeft(match)
	if not match.suspendedAt then return nil end
	local elapsed = os.clock() - match.suspendedAt
	return math.max(0, math.ceil(GameConfig.RECONNECT_WINDOW - elapsed))
end

function MatchClock.PlacementSecondsLeft(match)
	if match.phase ~= "placement" or not match.placementStartedAt then return nil end
	if GameConfig.PLACEMENT_TIME_LIMIT <= 0 then return nil end

	local elapsed = os.clock() - match.placementStartedAt
	return math.max(0, math.floor(GameConfig.PLACEMENT_TIME_LIMIT - elapsed))
end

return MatchClock
