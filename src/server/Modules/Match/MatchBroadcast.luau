local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MatchQuery = require(script.Parent.MatchQuery)
local MatchSnapshot = require(script.Parent.MatchSnapshot)
local HeroView = require(ServerScriptService.Modules.View.HeroView)

local MatchUpdate = ReplicatedStorage.Remotes.MatchUpdate

local MatchBroadcast = {}

function MatchBroadcast.RefreshWeakPoints(match)
	local hunters = MatchQuery.WeakPointHunters(match)

	for _, hero in pairs(match.heroes) do
		if hero.part and hero.part.Parent then
			HeroView.SetWeakPoint(hero, MatchQuery.WeakPointOf(hero, hunters))
		end
	end
end

function MatchBroadcast.Send(match, message)
	MatchBroadcast.RefreshWeakPoints(match)

	match.message = message
	for _, side in ipairs(match.sides) do
		if side.player then
			MatchUpdate:FireClient(side.player, MatchSnapshot.Build(match, side.id))
		end
	end
	match.message = nil

	for _, hero in pairs(match.heroes) do
		if hero.isAlive and not hero.stealth then
			match.lastSeen[hero.uid] = hero.position
		end
	end

	for _, hero in pairs(match.heroes) do
		hero.shieldJustBroke = nil
	end

	match.finisher = nil
end

function MatchBroadcast.ToLobby(player)
	MatchUpdate:FireClient(player, { phase = "lobby" })
end

return MatchBroadcast
