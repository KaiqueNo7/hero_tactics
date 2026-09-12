local MatchRegistry = {}

local matches = {}
local matchBySlot = {}
local nextMatchId = 0

function MatchRegistry.NextId()
	nextMatchId += 1
	return nextMatchId
end

function MatchRegistry.Add(match)
	matches[match.id] = match
	matchBySlot[match.slot] = match
end

function MatchRegistry.Remove(match)
	matches[match.id] = nil
	if matchBySlot[match.slot] == match then
		matchBySlot[match.slot] = nil
	end
end

function MatchRegistry.IsLive(match)
	return matches[match.id] ~= nil
end

function MatchRegistry.AllocateSlot()
	local slot = 1
	while matchBySlot[slot] do slot += 1 end
	return slot
end

function MatchRegistry.SideOfPlayer(match, player)
	for _, side in ipairs(match.sides) do
		if side.player == player then return side end
	end
	return nil
end

-- Ponte entre o RemoteEvent (que só traz o Player) e a partida dele
function MatchRegistry.MatchOfPlayer(player)
	if not player then return nil end
	for _, match in pairs(matches) do
		if MatchRegistry.SideOfPlayer(match, player) then return match end
	end
	return nil
end

function MatchRegistry.Count()
	local count = 0
	for _ in pairs(matches) do count += 1 end
	return count
end

function MatchRegistry.All()
	return matches
end

return MatchRegistry
