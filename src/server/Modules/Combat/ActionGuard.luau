local ServerScriptService = game:GetService("ServerScriptService")

local HeroView = require(ServerScriptService.Modules.View.HeroView)
local MatchQuery = require(ServerScriptService.Modules.Match.MatchQuery)
local MatchLog = require(ServerScriptService.Modules.Match.MatchLog)
local CombatCore = require(ServerScriptService.Modules.Combat.CombatCore)

local ActionGuard = {}

function ActionGuard.Authorize(match, player, hero)
	if not match or match.phase ~= "battle" then return false end
	if match.busy then return false end
	if match.suspendedAt then return false end
	if match.pendingPromotion then return false end
	if not hero or not hero.isAlive then return false end
	if CombatCore.IsDisabled(hero) then
		HeroView.Say(hero, "PARALISADO", "taunt")
		return false
	end
	if hero.ownerId ~= match.turn.ownerId then return false end

	if player and MatchQuery.SideOf(match, match.turn.ownerId).player ~= player then
		MatchLog.Reject(player, "NOT_YOUR_TURN")
		return false
	end
	return true
end

return ActionGuard
